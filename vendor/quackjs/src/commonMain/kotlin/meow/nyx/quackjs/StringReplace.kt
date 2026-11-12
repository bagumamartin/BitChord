package meow.nyx.quackjs

internal fun Runtime.replace(receiver: JsValue, searchValue: JsValue, replacement: JsValue): String {
    if (receiver === JsNull || receiver === Undefined) throw JsThrown()
    val value = replacementString(receiver)
    val regex = if (searchValue is RegexValue) BoundedRegex(this, searchValue.source) else null
    val search = if (regex == null) replacementString(searchValue) else null
    val callback = replacement is JsFunction || replacement is Native && replacement.callable
    // JS coerces a non-callable replacement once, before searching, even when no match exists.
    val template = if (callback) null else replacementString(replacement)
    val matches = mutableListOf<ReplaceMatch>()
    fun add(match: ReplaceMatch) {
        if (matches.size >= 65_536) unsupported("Replacement match limit exceeded")
        allocate(3)
        matches.add(match)
    }
    if (regex != null) {
        regex.validateInput(value)
        var from = 0
        while (from <= value.length) {
            tick()
            val match = regex.find(value, from) ?: break
            add(match)
            if (!regex.global) break
            from = match.end + if (match.start == match.end) 1 else 0
        }
    } else {
        val needle = search!!
        search@ for (start in 0..value.length - needle.length) {
            tick()
            for (i in needle.indices) {
                tick()
                if (value[start + i] != needle[i]) continue@search
            }
            add(ReplaceMatch(start, start + needle.length))
            break
        }
    }
    if (matches.isEmpty()) return value
    // RegExp @@replace collects matches before invoking callbacks.
    val output = ReplacementOutput(this)
    var cursor = 0
    for (match in matches) {
        tick()
        output.append(value, cursor, match.start)
        if (callback) {
            allocate(match.captures.size / 2 + 3)
            val args = ArrayList<JsValue>(match.captures.size / 2 + 3)
            args.add(JsString(replacementSlice(value, match.start, match.end)))
            for (i in match.captures.indices step 2) {
                tick()
                val start = match.captures[i]
                args.add(if (start < 0) Undefined else JsString(replacementSlice(value, start, match.captures[i + 1])))
            }
            args.add(JsNumber(match.start.toDouble()))
            args.add(JsString(value))
            output.append(replacementString(invoke(replacement, Undefined, args)))
        } else output.substitute(template!!, value, match)
        cursor = match.end
    }
    output.append(value, cursor, value.length)
    return output.finish()
}

private class ReplacementOutput(private val runtime: Runtime) {
    private val value = StringBuilder()
    fun append(part: String, start: Int = 0, end: Int = part.length) {
        val size = end - start
        if (size > 65_536 - value.length) unsupported("String size limit exceeded")
        runtime.tick(size + 1)
        runtime.allocate(size)
        value.append(part, start, end)
    }
    fun finish(): String {
        runtime.tick(value.length)
        runtime.allocate(value.length)
        return value.toString()
    }
    fun substitute(template: String, input: String, match: ReplaceMatch) {
        var i = 0
        while (i < template.length) {
            runtime.tick()
            val next = if (template[i] == '$') template.getOrNull(i + 1) else null
            when (next) {
                '$' -> { append(template, i, i + 1); i += 2 }
                '&' -> { append(input, match.start, match.end); i += 2 }
                '`' -> { append(input, 0, match.start); i += 2 }
                '\'' -> { append(input, match.end, input.length); i += 2 }
                in '0'..'9' -> {
                    val first = next!! - '0'
                    val second = template.getOrNull(i + 2)?.takeIf { it in '0'..'9' }
                    val two = if (second == null) 0 else first * 10 + (second - '0')
                    val count = match.captures.size / 2
                    val capture = if (two in 1..count) two else if (first in 1..count) first else 0
                    if (capture == 0) { append(template, i, i + 1); i++ }
                    else {
                        val start = match.captures[(capture - 1) * 2]
                        if (start >= 0) append(input, start, match.captures[(capture - 1) * 2 + 1])
                        i += if (two in 1..count) 3 else 2
                    }
                }
                else -> { append(template, i, i + 1); i++ }
            }
        }
    }
}

private fun Runtime.replacementSlice(value: String, start: Int, end: Int): String {
    tick(end - start)
    allocate(end - start)
    return value.substring(start, end)
}

private fun Runtime.replacementString(value: JsValue): String {
    val result = stringValue(value)
    tick(result.length)
    allocate(result.length)
    return result
}

