package meow.nyx.quackjs

/**
 * Non-Unicode JS code-unit subset: literals, dot, classes/ranges, ^/$, capturing and (?:)
 * groups; at most ONE * + ? on a character atom, or ? on a group (greedy or lazy).
 * Escapes: dDwWsS, nrtvf, class b, xHH/uHHHH/cA, NUL and legacy identity escapes.
 * Flags: gims; i deliberately accepts ASCII patterns/input only. No host regex execution.
 * No alternation, backrefs, lookarounds, word boundaries, counted repeats or other flags.
 */
internal class BoundedRegex(private val runtime: Runtime, raw: String) {
    val global: Boolean
    private val ignoreCase: Boolean
    private val multiline: Boolean
    private val dotAll: Boolean
    private val ops = mutableListOf<Op>()
    private var groups = 0
    private var repeats = 0
    private var p = 1
    private val end: Int
    private val source = raw

    private sealed interface Op
    private class Character(val test: (Char) -> Boolean, val min: Int = 1, val max: Int = 1, val lazy: Boolean = false) : Op
    private class Save(val slot: Int) : Op
    private class Anchor(val start: Boolean) : Op
    private class Optional(val skip: Int, val lazy: Boolean) : Op
    private data object Pass : Op

    init {
        if (raw.length > 518) unsupported("Regular expression size limit exceeded")
        runtime.tick(raw.length * 2)
        runtime.allocate(raw.length)
        if (raw.any(::lineTerminator)) unsupported("Raw line terminator in regular expression literal")
        end = raw.lastIndexOf('/')
        if (!raw.startsWith('/') || end < 1 || end - 1 > 512) unsupported("Invalid regular expression literal")
        var flags = ""
        for (i in end + 1 until raw.length) {
            val flag = raw[i]
            if (flag !in "gims" || flag in flags) unsupported("Unsupported regular expression flags")
            flags += flag
        }
        global = 'g' in flags
        ignoreCase = 'i' in flags
        multiline = 'm' in flags
        dotAll = 's' in flags
        sequence(0)
        if (p != end) unsupported("Invalid regular expression group")
    }

    private fun emit(op: Op) {
        if (ops.size >= 128) unsupported("Regular expression instruction limit exceeded")
        runtime.tick()
        runtime.allocate(1)
        ops.add(op)
    }

    private fun next(): Char {
        runtime.tick()
        if (p >= end) unsupported("Incomplete regular expression")
        return source[p++]
    }

    private fun sequence(depth: Int) {
        if (depth > 16) unsupported("Regular expression group depth limit exceeded")
        while (p < end && source[p] != ')') {
            when (val c = next()) {
                '(' -> {
                    val begin = ops.size
                    emit(Pass)
                    val capture = if (p < end && source[p] == '?') {
                        p++
                        if (next() != ':') unsupported("Unsupported regular expression special group")
                        -1
                    } else {
                        if (++groups > 16) unsupported("Regular expression capture limit exceeded")
                        groups - 1
                    }
                    if (capture >= 0) emit(Save(capture * 2))
                    sequence(depth + 1)
                    if (next() != ')') unsupported("Unclosed regular expression group")
                    if (capture >= 0) emit(Save(capture * 2 + 1))
                    if (p < end && source[p] in "*+?{") {
                        if (next() != '?') unsupported("Only optional regular expression groups are supported")
                        repeatLimit()
                        val reluctant = lazy()
                        runtime.tick(ops.size - begin)
                        // JS never takes a zero-length repetition when its minimum is zero.
                        if (ops.subList(begin, ops.size).none { it is Character }) {
                            while (ops.size > begin) { runtime.tick(); ops.removeAt(ops.lastIndex) }
                        } else ops[begin] = Optional(ops.size, reluctant)
                    }
                }
                '^', '$' -> emit(Anchor(c == '^'))
                '|', '*', '+', '?', '{', '}', ']' -> unsupported("Unsupported regular expression syntax")
                else -> {
                    val test = when (c) {
                        '[' -> characterClass()
                        '.' -> { ch: Char -> dotAll || !lineTerminator(ch) }
                        '\\' -> escape(false).test
                        '/' -> unsupported("Unescaped regular expression delimiter")
                        else -> literal(c).test
                    }
                    var min = 1
                    var max = 1
                    var reluctant = false
                    if (p < end && source[p] in "*+?") {
                        repeatLimit()
                        when (next()) {
                            '*' -> { min = 0; max = 65_536 }
                            '+' -> max = 65_536
                            '?' -> min = 0
                        }
                        reluctant = lazy()
                    }
                    emit(Character(test, min, max, reluctant))
                }
            }
        }
    }

    private fun repeatLimit() {
        if (++repeats > 1) unsupported("Multiple regular expression quantifiers are unsupported")
    }
    private fun lazy(): Boolean = if (p < end && source[p] == '?') { p++; true } else false
    private fun fold(c: Char): Char = if (ignoreCase && c in 'a'..'z') (c.code - 32).toChar() else c
    private class ClassPart(val char: Char?, val test: (Char) -> Boolean)
    private fun literal(c: Char): ClassPart {
        if (ignoreCase && c.code > 127) unsupported("Non-ASCII case-insensitive regular expression")
        return ClassPart(c) { fold(it) == fold(c) }
    }
    private fun hex(count: Int): Char {
        var value = 0
        repeat(count) {
            val c = next()
            val digit = when (c) { in '0'..'9' -> c - '0'; in 'a'..'f' -> c - 'a' + 10; in 'A'..'F' -> c - 'A' + 10; else -> unsupported("Invalid regular expression escape") }
            value = value * 16 + digit
        }
        return value.toChar()
    }
    private fun escape(inClass: Boolean): ClassPart {
        val c = next()
        val predicate: ((Char) -> Boolean)? = when (c) {
            'd', 'D' -> { ch -> (ch in '0'..'9') == (c == 'd') }
            'w', 'W' -> { ch -> (ch in 'a'..'z' || ch in 'A'..'Z' || ch in '0'..'9' || ch == '_') == (c == 'w') }
            's', 'S' -> { ch -> jsWhitespace(ch) == (c == 's') }
            else -> null
        }
        if (predicate != null) return ClassPart(null, predicate)
        return literal(when (c) {
            'n' -> '\n'; 'r' -> '\r'; 't' -> '\t'; 'v' -> '\u000b'; 'f' -> '\u000c'
            'b' -> if (inClass) '\b' else unsupported("Regular expression word boundaries are unsupported")
            'B', 'k' -> unsupported("Unsupported regular expression escape")
            'x' -> hex(2); 'u' -> hex(4)
            'c' -> {
                val letter = next()
                if (letter !in 'a'..'z' && letter !in 'A'..'Z') unsupported("Unsupported regular expression control escape")
                (letter.code % 32).toChar()
            }
            '0' -> { if (p < end && source[p] in '0'..'9') unsupported("Regular expression octal escapes are unsupported"); '\u0000' }
            in '1'..'9' -> unsupported("Regular expression backreferences/octal escapes are unsupported")
            else -> c // Legacy non-u identity escape, including \\A (never a host anchor).
        })
    }
    private fun characterClass(): (Char) -> Boolean {
        val negate = p < end && source[p] == '^'
        if (negate) p++
        val parts = mutableListOf<ClassPart>()
        fun part(): ClassPart = when (val c = next()) { '\\' -> escape(true); else -> literal(c) }
        while (p < end && source[p] != ']') {
            var first = part()
            if (p + 1 < end && source[p] == '-' && source[p + 1] != ']') {
                p++
                val last = part()
                val lo = first.char ?: unsupported("Unsupported regular expression class range")
                val hi = last.char ?: unsupported("Unsupported regular expression class range")
                if (lo > hi) unsupported("Invalid regular expression class range")
                first = ClassPart(null) { ch ->
                    val canonical = fold(ch)
                    canonical in lo..hi || ignoreCase && canonical in 'A'..'Z' && (canonical.code + 32).toChar() in lo..hi
                }
            }
            runtime.allocate(1)
            parts.add(first)
        }
        if (next() != ']') unsupported("Unclosed regular expression class")
        return { ch ->
            var found = false
            for (part in parts) {
                runtime.tick()
                if (part.test(ch)) { found = true; break }
            }
            found != negate
        }
    }

    fun literalText(): String {
        val size = if (end == 1) 6 else end + 1
        runtime.tick(size + 4)
        runtime.allocate(size + 4)
        return buildString(size + 4) {
            if (end == 1) append("/(?:)/") else append(source, 0, end + 1)
            if (global) append('g')
            if (ignoreCase) append('i')
            if (multiline) append('m')
            if (dotAll) append('s')
        }
    }

    fun validateInput(value: String) {
        if (value.length > 65_536) unsupported("String size limit exceeded")
        if (ignoreCase) for (c in value) {
            runtime.tick()
            if (c.code > 127) unsupported("Non-ASCII case-insensitive regular expression input")
        }
    }

    fun find(value: String, from: Int): ReplaceMatch? {
        for (start in from..value.length) {
            runtime.tick(groups * 2 + 1)
            runtime.allocate(groups * 2)
            val captures = IntArray(groups * 2) { -1 }
            val result = match(value, 0, start, captures) ?: continue
            runtime.allocate(3)
            return ReplaceMatch(start, result.first, result.second)
        }
        return null
    }

    // The single-quantifier restriction bounds matching recursion to two frames.
    private fun match(value: String, from: Int, offset: Int, captures: IntArray): Pair<Int, IntArray>? {
        var pos = offset
        var pc = from
        while (pc < ops.size) {
            runtime.tick()
            when (val op = ops[pc]) {
                Pass -> Unit
                is Save -> captures[op.slot] = pos
                is Anchor -> if (op.start) {
                    if (pos != 0 && !(multiline && lineTerminator(value[pos - 1]))) return null
                } else if (pos != value.length && !(multiline && lineTerminator(value[pos]))) return null
                is Optional -> {
                    for (attempt in 0..1) {
                        runtime.tick(captures.size + 1)
                        val branch = if ((attempt == 0) == op.lazy) op.skip else pc + 1
                        runtime.allocate(captures.size)
                        val result = match(value, branch, pos, captures.copyOf())
                        if (result != null) return result
                    }
                    return null
                }
                is Character -> {
                    if (op.min == 1 && op.max == 1) {
                        if (pos == value.length || !op.test(value[pos])) return null
                        pos++
                    } else {
                        var count = 0
                        while (count < op.max && pos + count < value.length) {
                            runtime.tick()
                            if (!op.test(value[pos + count])) break
                            count++
                        }
                        val candidates = if (op.lazy) op.min..count else count downTo op.min
                        for (size in candidates) {
                            runtime.tick(captures.size + 1)
                            runtime.allocate(captures.size)
                            val result = match(value, pc + 1, pos + size, captures.copyOf())
                            if (result != null) return result
                        }
                        return null
                    }
                }
            }
            pc++
        }
        runtime.allocate(2)
        return pos to captures
    }
}

private fun lineTerminator(c: Char): Boolean = c == '\n' || c == '\r' || c == '\u2028' || c == '\u2029'
internal data class ReplaceMatch(val start: Int, val end: Int, val captures: IntArray = intArrayOf())
