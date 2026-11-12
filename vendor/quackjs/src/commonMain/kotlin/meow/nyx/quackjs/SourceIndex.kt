@file:OptIn(kotlin.concurrent.atomics.ExperimentalAtomicApi::class)

package meow.nyx.quackjs

import kotlin.concurrent.atomics.AtomicReference

/** Lex once to index the player scope; parse and execute only selected dependencies. */
internal class SourceIndex(val source: String, className: String? = null) {
    internal val compilationBudget = CompilationBudget()
    internal val derivedHints: PlayerHints?
    private class ScanBudget {
        private var tokens = 0
        private var units = 0
        private inline fun charge(lexer: Lexer, advance: () -> Unit) {
            if (tokens >= 2_000_000 || units >= 16 * 1024 * 1024) unsupported("Source scan limit exceeded")
            val start = lexer.position
            advance()
            tokens++
            units += lexer.position - start
            if (units > 16 * 1024 * 1024) unsupported("Source scan limit exceeded")
        }
        fun next(lexer: Lexer, previous: String? = null): Token {
            var token: Token? = null
            charge(lexer) { token = lexer.next(previous) }
            return token!!
        }
        fun scan(lexer: Lexer, regexAllowed: Boolean = true) = charge(lexer) { lexer.scan(regexAllowed) }
    }

    private data class Assignment(val lhs: List<Token>, val offset: Int, val braces: Int, val parens: Int)
    private data class CallSite(val target: List<Token>?, val offset: Int, val braces: Int, val statement: Boolean)
    private data class References(val names: Set<String>, val lengths: Set<String>, val end: Int)
    private data class Reference(val name: String, val projected: Boolean)
    private data class CallEffects(val receiver: String?, val predicate: String?, val reversal: String?, val arguments: References)
    private data class FunctionScope(val depth: Int, val parameters: Int, val name: String?)
    private data class ClassScope(val depth: Int, val parameters: List<Int>, val bindings: List<String>, val functionScope: Boolean)
    private fun classScope(depth: Int, scopes: ArrayDeque<FunctionScope>): ClassScope =
        ClassScope(depth, scopes.map { it.parameters }, scopes.mapNotNull { it.name }, scopes.lastOrNull()?.depth == depth)
    private fun discardNestedTargets(found: MutableList<Assignment>, nestedWrites: MutableList<Pair<String, Int>>, calls: MutableList<CallSite>, depth: Int, name: String) {
        calls.removeAll { it.braces > depth }
        found.removeAll {
            if (it.braces > depth && !classTarget(it.lhs, name)) {
                nestedWrites.add(it.lhs.first().text to it.braces)
                true
            } else false
        }
    }
    private enum class DefinitionKind { PRIMITIVE, ARRAY, UNKNOWN }
    private var assignments: List<Assignment>
    private var members: List<Assignment>
    private data class ParsedDefinitions(val entries: Map<String, Expr>, val tokens: Int)
    private var parsedDefinitions: AtomicReference<ParsedDefinitions>? = null
    private val definitions: Map<String, Int>
    private val timestamps: Set<Int>
    val signatureTimestamp: Int? get() = if (timestamps.size <= 1) timestamps.singleOrNull() else unsupported("Conflicting signature timestamps")

    init {
        if (source.length > 8 * 1024 * 1024) unsupported("Player source limit exceeded")
        if (className != null && (className.length > 128 || !identifier(className))) unsupported("Invalid n class hint")
        val landmarks = if (className == null) PlayerLandmarks(source) else null
        val lexer = Lexer(source)
        val scans = ScanBudget()
        val recent = ScanWindow(source)
        val found = mutableListOf<Assignment>()
        val nestedWrites = mutableListOf<Pair<String, Int>>()
        val calls = mutableListOf<CallSite>()
        val updates = mutableListOf<Pair<String, Int>>()
        val stamps = mutableSetOf<Int>()
        var pendingStamp: Int? = null
        var braces = 0
        var parens = 0
        var count = 0
        var callCount = 0
        var assignmentCount = 0
        var previous = true
        var prefixUpdate = false
        val headers = mutableMapOf<Int, Pair<Int, String?>>()
        var bodyParameters: Pair<Int, String?>? = null
        val activeScopes = ArrayDeque<FunctionScope>()
        var classDepth = Int.MAX_VALUE
        val classScopes = mutableMapOf<String, ClassScope>()
        fun recordUpdate(name: String) {
            if (updates.size >= 100_000) unsupported("Source mutation limit exceeded")
            updates.add(name to braces)
        }
        while (true) {
            lexer.scan(previous)
            if (lexer.kind == -1) break
            if (++count > 2_000_000) unsupported("Source token limit exceeded")
            landmarks?.observe(lexer)
            if (className == null && classDepth == Int.MAX_VALUE) landmarks?.selectedClass?.let { name ->
                classScopes[name]?.let { scope ->
                    classDepth = scope.depth
                    discardNestedTargets(found, nestedWrites, calls, classDepth, name)
                }
            }
            val tag = lexer.tag
            bodyParameters?.let { parameters ->
                if (tag == ScanTags.LBRACE) {
                    activeScopes.addLast(FunctionScope(braces + 1, parameters.first, parameters.second))
                }
            }
            bodyParameters = null
            if (pendingStamp != null && (tag == ScanTags.COMMA || tag == ScanTags.RBRACE)) stamps.add(pendingStamp)
            pendingStamp = if (lexer.kind == 2 && lexer.end - lexer.offset in 4..6 && recent.isText(recent.lastIndex, ":") && recent.isText(recent.lastIndex - 1, "signatureTimestamp")) lexer.text.toIntOrNull() else null
            if (prefixUpdate) {
                if (lexer.kind == 0 && scanIdentifier(source, lexer.offset, lexer.end)) {
                    recordUpdate(lexer.text)
                    prefixUpdate = false
                }
                else if (tag != ScanTags.LPAREN) prefixUpdate = false
            }
            if (tag == ScanTags.DELETE) prefixUpdate = true
            if (tag in compoundWriteTags || tag == ScanTags.INC || tag == ScanTags.DEC) {
                val start = assignmentTargetStart(recent, targetEnd(recent), call = true)
                if (start >= 0) recordUpdate(recent.text(start))
                prefixUpdate = tag == ScanTags.INC || tag == ScanTags.DEC
            }
            if (tag == ScanTags.EQUAL) {
                val end = targetEnd(recent)
                val start = assignmentTargetStart(recent, end)
                if (start >= 0) {
                    if (assignmentCount++ >= 100_000) unsupported("Source definition limit exceeded")
                    val isClass = end - start == 2 && recent.isText(start, "g") && recent.isText(start + 1, ".") && (if (className != null) recent.isText(end, className) else recent.text(end) in landmarks!!.classNames)
                    if (isClass) {
                        val name = recent.text(end)
                        if (braces <= (classScopes[name]?.depth ?: Int.MAX_VALUE)) classScopes[name] = classScope(braces, activeScopes)
                    }
                    if (isClass && braces < classDepth && (className != null || recent.text(end) == landmarks?.selectedClass)) {
                        classDepth = braces
                        discardNestedTargets(found, nestedWrites, calls, classDepth, recent.text(end))
                    }
                    if (braces <= classDepth || isClass) found.add(Assignment(recent.retain(start, end + 1), lexer.offset + 1, braces, parens))
                    else nestedWrites.add(recent.text(start) to braces)
                }
            }
            if (tag == ScanTags.LPAREN) {
                val start = assignmentTargetStart(recent, call = true)
                if (start >= 0 && start == recent.lastIndex && recent.isText(start, "function")) headers[parens] = lexer.offset + 1 to null
                else if (recent.lastIndex >= 1 && recent.kind(recent.lastIndex - 1) == 0 && recent.isText(recent.lastIndex - 1, "function")) headers[parens] = lexer.offset + 1 to recent.text(recent.lastIndex)
                if (start >= 0 && nonCalls.none { recent.isText(start, it) } || start < 0 && (recent.isText(recent.lastIndex, ")") || recent.isText(recent.lastIndex, "?."))) {
                    if (callCount++ >= 100_000) unsupported("Source call limit exceeded")
                    // Only call effects at the shallowest class depth can be consumed below.
                    if (braces <= classDepth) {
                        val statement = start >= 0 && (start == 0 || recent.kind(start - 1) == 0 && statementPrefixes.any { recent.isText(start - 1, it) })
                        val target = if (start < 0) null else recent.retain(start, recent.size)
                        calls.add(CallSite(target, lexer.offset + 1, braces, statement))
                    }
                }
            }
            when (tag) {
                ScanTags.LBRACE -> braces++
                ScanTags.RBRACE -> {
                    if (activeScopes.lastOrNull()?.depth == braces) activeScopes.removeLast()
                    braces--
                }
                ScanTags.LPAREN -> parens++
                ScanTags.RPAREN -> { parens--; bodyParameters = headers.remove(parens) }
            }
            if (braces < 0 || parens < 0 || braces > 512 || parens > 512) unsupported("Source nesting limit exceeded")
            recent.add(lexer)
            previous = lexer.regexAfter
        }
        if (braces != 0 || parens != 0) unsupported("Unbalanced player source")
        derivedHints = landmarks?.hints()
        val indexedClass = className ?: derivedHints!!.nClass
        if (indexedClass.length > 128 || !identifier(indexedClass)) unsupported("Invalid n class hint")
        val classes = found.filter { classTarget(it.lhs, indexedClass) }
        val depth = classes.minOfOrNull { it.braces } ?: unsupported("Missing n class '$indexedClass'")
        val classAssignments = classes.filter { it.braces == depth }
        if (classAssignments.size != 1) unsupported("Ambiguous n class '$indexedClass'")
        val rootBraces = classAssignments.single().braces
        val rootParens = classAssignments.single().parens
        val scope = classScopes.getValue(indexedClass)
        assignments = found.filter { it.braces == rootBraces && it.parens == rootParens }
        members = assignments.filter { it.lhs.size > 3 && it.lhs[0].text == "g" && it.lhs[1].text == "." && it.lhs[2].text == indexedClass }
        val names = assignments.filter { it.lhs.size == 1 }.groupBy { it.lhs.single().text }
        val writes = found.filter { it.braces == rootBraces }
        val writeCounts = writes.filter { it.lhs.size == 1 }.groupingBy { it.lhs.single().text }.eachCount()
        val kinds = mutableMapOf<String, DefinitionKind>()
        var nativeSplit = true
        fun canMutate(name: String): Boolean = definitionKind(name, kinds, scans, nativeSplit, names, writeCounts) != DefinitionKind.PRIMITIVE
        fun arrayLength(name: String): Boolean = definitionKind(name, kinds, scans, nativeSplit, names, writeCounts) == DefinitionKind.ARRAY
        val aliases = mutableMapOf<String, MutableSet<String>>()
        val contents = mutableMapOf<String, MutableSet<String>>()
        val lengthContents = mutableMapOf<String, MutableSet<String>>()
        val origins = mutableMapOf<String, MutableSet<String>>()
        val arrays = mutableSetOf<String>()
        for (write in writes) {
            val owner = write.lhs.first().text
            val direct = referenceBase(write.offset, scans)
            val first = if (direct == null) Lexer(source, write.offset).also { scans.scan(it) } else null
            if (direct != null) {
                if (write.lhs.size > 1) contents.getOrPut(owner) { mutableSetOf() }.add(direct.name)
                else if (direct.projected) origins.getOrPut(owner) { mutableSetOf() }.add(direct.name)
                else {
                    aliases.getOrPut(owner) { mutableSetOf() }.add(direct.name)
                    aliases.getOrPut(direct.name) { mutableSetOf() }.add(owner)
                }
            } else if (first != null && (first.tag == ScanTags.LBRACKET || first.tag == ScanTags.LBRACE)) {
                val refs = argumentReferences(first.offset + 1, scans, if (first.text == "[") "]" else "}", first.text)
                contents.getOrPut(owner) { mutableSetOf() }.addAll(refs.names)
                lengthContents.getOrPut(owner) { mutableSetOf() }.addAll(refs.lengths)
                val after = Lexer(source, refs.end).also { scans.scan(it, true) }
                if (write.lhs.size == 1 && first.tag == ScanTags.LBRACKET && after.tag in expressionEnds) arrays.add(owner)
            }
        }
        val arrayQueue = ArrayDeque(arrays)
        while (arrayQueue.isNotEmpty()) for (alias in aliases[arrayQueue.removeFirst()].orEmpty()) if (arrays.add(alias)) arrayQueue.addLast(alias)
        val parameters = scopeParameters(scope, scans)
        val unknownScope = rootBraces > 0 && !scope.functionScope
        val shadowed = names.keys + parameters + scope.bindings + if (unknownScope) readOnlyPredicates.keys else emptySet()
        val builtins = mutableMapOf<String, String>()
        for (root in readOnlyPredicates.keys) if (root !in shadowed) {
            val queue = ArrayDeque(listOf(root))
            while (queue.isNotEmpty()) {
                val name = queue.removeFirst()
                if (name !in builtins) { builtins[name] = root; queue.addAll(aliases[name].orEmpty()) }
            }
        }
        val effects = calls.filter { it.braces == rootBraces }.map { call ->
            val refs = argumentReferences(call.offset, scans)
            val target = call.target?.let(::targetExpression)
            var predicate = target
            if (predicate is Member && predicate.key in setOf(Lit("call"), Lit("apply"))) predicate = predicate.target
            val member = predicate as? Member
            val builtin = (member?.target as? Id)?.name?.let(builtins::get)
            val key = ((member?.key as? Lit)?.value as? JsString)?.value
            val pure = builtin?.takeIf { key != null && key in readOnlyPredicates.getValue(it) }
            val reverse = if (target is Member && target.target is Id && target.key == Lit("reverse") && call.statement) {
                val after = Lexer(source, refs.end).also { scans.scan(it, false) }
                target.target.name.takeIf { after.tag == ScanTags.SEMI || after.tag == ScanTags.RBRACE }
            } else null
            CallEffects(call.target?.takeIf { it.size > 1 }?.first()?.text, pure, reverse, refs)
        }
        val memberWrites = writes.filter { it.lhs.size > 1 }.map { it to targetExpression(it.lhs) }
        val updated = updates.filter { it.second == rootBraces }.map { it.first }
        val reassigned = writeCounts.filterValues { it > 1 }.keys
        val explicit = memberWrites.map { it.first.lhs.first().text }.toSet() + updated + reassigned
        fun ownSlot(expr: Expr?): Boolean = expr is Member && expr.target is Id && expr.key is Lit && expr.key.value.let {
            it === JsNull || it is JsString || it is JsNumber || it is JsBoolean
        } && expr.key.value != JsString("length")
        val deepWrites = memberWrites.filter { !ownSlot(it.second) }.map { it.first.lhs.first().text }
        val changedLookups = (updated + reassigned + memberWrites.filter {
            !ownSlot(it.second) || ((it.second as? Member)?.key as? Lit)?.value in setOf(JsString("reverse"), JsString("__proto__"))
        }.map { it.first.lhs.first().text }).toMutableSet()
        val changedQueue = ArrayDeque(changedLookups)
        while (changedQueue.isNotEmpty()) for (alias in aliases[changedQueue.removeFirst()].orEmpty()) if (changedLookups.add(alias)) changedQueue.addLast(alias)
        fun mutations(blocked: Set<String>): Set<String> {
            val stableSplit = "String" !in blocked && "String" !in shadowed
            if (nativeSplit != stableSplit) { nativeSplit = stableSplit; kinds.clear() }
            val own = mutableSetOf<String>()
            val escaped = mutableSetOf<String>()
            val queue = ArrayDeque<Pair<String, Boolean>>()
            fun add(name: String, escape: Boolean = false) { if (canMutate(name)) queue.addLast(name to escape) }
            explicit.forEach { add(it) }
            (deepWrites + updated).forEach { add(it, true) }
            for (effect in effects) {
                if (effect.predicate != null && effect.predicate !in blocked) continue
                // A discarded native reverse only changes the outer array's own slots.
                val reversal = effect.reversal
                if (reversal != null && reversal in arrays && reversal !in changedLookups && "Array" !in blocked && "Array" !in shadowed) {
                    add(reversal)
                } else {
                    effect.receiver?.let { add(it, true) }
                    effect.arguments.names.forEach { add(it, true) }
                    effect.arguments.lengths.filterNot(::arrayLength).forEach { add(it, true) }
                }
            }
            while (queue.isNotEmpty()) {
                val (name, escape) = queue.removeFirst()
                if (own.add(name)) {
                    aliases[name].orEmpty().forEach { add(it) }
                    origins[name].orEmpty().forEach { add(it, true) }
                }
                if (escape && escaped.add(name)) {
                    (aliases[name].orEmpty() + contents[name].orEmpty()).forEach { add(it, true) }
                    lengthContents[name].orEmpty().filterNot(::arrayLength).forEach { add(it, true) }
                }
            }
            return own
        }
        val builtinWrites = found.filter { it.lhs.size > 1 || it.braces != rootBraces || (writeCounts[it.lhs.first().text] ?: 0) > 1 }
        val blocked = (builtinWrites.mapNotNull { builtins[it.lhs.first().text] } + nestedWrites.mapNotNull { builtins[it.first] } + updates.mapNotNull { builtins[it.first] }).toMutableSet()
        var affected = mutations(blocked)
        while (true) {
            val changed = readOnlyPredicates.keys.filter { it in affected && it !in blocked }
            if (changed.isEmpty()) break
            blocked.addAll(changed)
            affected = mutations(blocked)
        }
        val mutatedObjects = affected + updated
        definitions = names.mapValues { (name, entries) ->
            when {
                entries.size != 1 -> AMBIGUOUS
                name in mutatedObjects || writeCounts[name] != 1 -> MUTATED
                else -> entries.single().offset
            }
        }
        timestamps = stamps
        landmarks?.requireGlobalCalls(this)
    }

    private fun scopeParameters(scope: ClassScope, scans: ScanBudget): Set<String> =
        scope.parameters.flatMap { argumentReferences(it, scans).let { it.names + it.lengths } }.toSet()

    private fun targetExpression(tokens: List<Token>): Expr? =
        try { Parser(tokens + Token("<eof>", -1), source, compilationBudget).completeExpression() } catch (_: UnsupportedPlayerException) { null }

    /** Prove initializer value kinds without executing unrelated player code. */
    private fun definitionKind(name: String, known: MutableMap<String, DefinitionKind>, scans: ScanBudget, nativeSplit: Boolean, names: Map<String, List<Assignment>>, writeCounts: Map<String, Int>, resolving: MutableSet<String> = mutableSetOf()): DefinitionKind {
        known[name]?.let { return it }
        if (resolving.size >= 64 || !resolving.add(name)) return DefinitionKind.UNKNOWN
        try {
            fun kind(expr: Expr): DefinitionKind = when (expr) {
                is Lit -> if (expr.value === JsNull || expr.value is JsString || expr.value is JsNumber || expr.value is JsBoolean) DefinitionKind.PRIMITIVE else DefinitionKind.UNKNOWN
                is Id -> definitionKind(expr.name, known, scans, nativeSplit, names, writeCounts, resolving)
                is ArrayExpr -> DefinitionKind.ARRAY
                is Unary -> if (expr.op in setOf("!", "~", "+", "-", "typeof", "void", "delete")) DefinitionKind.PRIMITIVE else DefinitionKind.UNKNOWN
                is Binary -> when (expr.op) {
                    "=", "," -> kind(expr.right)
                    "&&", "||", "??" -> kind(expr.left).takeIf { it == kind(expr.right) } ?: DefinitionKind.UNKNOWN
                    else -> DefinitionKind.PRIMITIVE
                }
                is Conditional -> kind(expr.yes).takeIf { it == kind(expr.no) } ?: DefinitionKind.UNKNOWN
                is Member -> if (expr.key == Lit("length") && kind(expr.target) == DefinitionKind.ARRAY) DefinitionKind.PRIMITIVE else DefinitionKind.UNKNOWN
                is Call -> if (nativeSplit && !expr.construct && expr.fn is Member && expr.fn.target is Lit && expr.fn.target.value is JsString && expr.fn.key == Lit("split") && expr.args.all { it is Lit }) DefinitionKind.ARRAY else DefinitionKind.UNKNOWN
                else -> DefinitionKind.UNKNOWN
            }
            val entries = names[name]
            val result = if (entries == null) {
                if (name in setOf("undefined", "NaN", "Infinity")) DefinitionKind.PRIMITIVE else DefinitionKind.UNKNOWN
            } else if (entries.size != 1 || writeCounts[name] != 1) DefinitionKind.UNKNOWN
            else {
                val offset = entries.single().offset
                val first = Lexer(source, offset).also { scans.scan(it) }
                if (first.tag == ScanTags.FUNCTION || first.tag == ScanTags.LBRACE) DefinitionKind.UNKNOWN
                else {
                    val tokens = slice(offset, scans)
                    val expr = try { Parser(tokens, source, compilationBudget).completeExpression() } catch (_: UnsupportedPlayerException) { null }
                    expr?.let(::kind) ?: DefinitionKind.UNKNOWN
                }
            }
            // A budget cut in a longer alias chain must not poison a shorter proof.
            if (result != DefinitionKind.UNKNOWN || resolving.size == 1) known[name] = result
            return result
        } finally { resolving.remove(name) }
    }

    private fun argumentReferences(offset: Int, scans: ScanBudget, closing: String = ")", opening: String = "("): References {
        val lexer = Lexer(source, offset)
        val references = mutableSetOf<String>()
        val lengths = mutableSetOf<String>()
        var previous = true
        var previousTag = ScanTags.code(opening, 0, opening.length)
        val closingTag = ScanTags.code(closing, 0, closing.length)
        var depth = 0
        var count = 0
        var functionDepth: Int? = null
        var functionBody = false
        var parametersClosed = false
        var reference: String? = null
        var beforeReference = -1
        while (true) {
            scans.scan(lexer, previous)
            if (++count > 150_000) unsupported("Initialization call limit exceeded")
            if (lexer.kind == -1) unsupported("Unclosed initialization call")
            val tag = lexer.tag
            reference?.let {
                val projection = Lexer(source, lexer.position)
                val length = when (tag) {
                    ScanTags.DOT -> { scans.scan(projection, false); projection.tag == ScanTags.LENGTH }
                    ScanTags.LBRACKET -> {
                        scans.scan(projection, true)
                        projection.kind == 1 && projection.text == "length" && run { scans.scan(projection, false); projection.tag == ScanTags.RBRACKET }
                    }
                    else -> false
                }
                if (!(tag == ScanTags.COLON && (beforeReference == ScanTags.LBRACE || beforeReference == ScanTags.COMMA))) {
                    if (length) lengths.add(it) else references.add(it)
                }
            }
            reference = null
            // Do not confuse property names or a callback's locals with escaped player globals.
            if (tag == ScanTags.FUNCTION && functionDepth == null) functionDepth = depth
            if (lexer.kind == 0 && functionDepth == null && previousTag != ScanTags.DOT && scanIdentifier(source, lexer.offset, lexer.end)) { reference = lexer.text; beforeReference = previousTag }
            if (lexer.kind == 0) {
                if (functionDepth != null) {
                    if (!functionBody && tag == ScanTags.RPAREN && depth == functionDepth + 1) parametersClosed = true
                    if (!functionBody && parametersClosed && tag == ScanTags.LBRACE && depth == functionDepth) functionBody = true
                    else if (functionBody && tag == ScanTags.RBRACE && depth == functionDepth + 1) { functionDepth = null; functionBody = false; parametersClosed = false }
                }
                if (depth == 0 && tag == closingTag) return References(references, lengths, lexer.position)
                when (tag) {
                    ScanTags.LPAREN, ScanTags.LBRACKET, ScanTags.LBRACE -> depth++
                    ScanTags.RPAREN, ScanTags.RBRACKET, ScanTags.RBRACE -> depth--
                }
            }
            previous = lexer.regexAfter
            previousTag = tag
        }
    }

    /** Link direct reference paths without evaluating unrelated initializers. */
    private fun referenceBase(offset: Int, scans: ScanBudget): Reference? {
        val lexer = Lexer(source, offset)
        var previous = true
        var count = 0
        fun next(): Boolean {
            if (++count > 1024) return false
            scans.scan(lexer, previous)
            previous = lexer.regexAfter
            return true
        }
        if (!next()) return null
        var groups = 0
        while (lexer.tag == ScanTags.LPAREN) { groups++; if (!next()) return null }
        if (lexer.kind != 0 || !scanIdentifier(source, lexer.offset, lexer.end) || lexer.tag in primitiveTags) return null
        val base = lexer.text
        var projected = false
        if (!next()) return Reference(base, projected)
        while (lexer.tag == ScanTags.DOT || lexer.tag == ScanTags.LBRACKET) {
            projected = true
            if (lexer.tag == ScanTags.DOT) {
                if (!next()) return Reference(base, projected)
                if (lexer.kind != 0 || !scanIdentifier(source, lexer.offset, lexer.end)) return null
            } else {
                var depth = 1
                while (depth > 0) {
                    if (!next()) return Reference(base, projected)
                    if (lexer.kind == -1) return null
                    if (lexer.tag == ScanTags.LBRACKET) depth++
                    if (lexer.tag == ScanTags.RBRACKET) depth--
                }
            }
            if (!next()) return Reference(base, projected)
        }
        while (groups > 0) {
            if (lexer.tag != ScanTags.RPAREN) return null
            groups--; if (!next()) return Reference(base, projected)
        }
        return Reference(base, projected).takeIf { lexer.kind == -1 || lexer.tag in expressionEnds }
    }

    /** Called before publication, after class and method discovery has finished. */
    fun releaseCompileState() {
        assignments = emptyList()
        members = emptyList()
        if (parsedDefinitions == null) parsedDefinitions = AtomicReference(ParsedDefinitions(emptyMap(), 0))
    }

    fun hasDefinition(name: String): Boolean = definitions.containsKey(name)

    fun requireGlobalCall(offset: Int, name: String) {
        val entry = assignments.filter { it.offset <= offset }.maxByOrNull { it.offset }
            ?: unsupported("Cannot establish signature callee binding")
        val tokens = slice(entry.offset)
        if (tokens.last().offset <= offset) unsupported("Cannot establish signature callee binding")
        for (token in tokens) {
            if (token.offset >= offset) break
            if (token.kind != 0 || token.text != "function") continue
            val enclosing = slice(token.offset)
            if (enclosing.last().offset <= offset) continue
            val fn = Parser(enclosing, source, compilationBudget).completeExpression() as? FunctionExpr
                ?: unsupported("Cannot establish signature callee binding")
            if (name in fn.slots) unsupported("Shadowed signature callee")
            val pending = ArrayDeque<SyntaxNode>()
            pending.add(fn.body)
            while (pending.isNotEmpty()) {
                val node = pending.removeLast()
                if (node is TryStmt && node.catchName == name) unsupported("Shadowed signature callee")
                if (node !is FunctionExpr) syntaxChildren(node) { pending.add(it) }
            }
        }
    }

    fun definition(name: String, budget: CompilationBudget = CompilationBudget()): Expr {
        val cache = parsedDefinitions
        cache?.load()?.entries?.get(name)?.let { return it }
        val offset = definitions[name] ?: unsupported("Missing dependency '$name'")
        if (offset == AMBIGUOUS) unsupported("Ambiguous dependency '$name'")
        if (offset == MUTATED) unsupported("Externally mutated dependency '$name'")
        val tokens = slice(offset)
        val expr = Parser(tokens, source, budget).completeExpression()
        if (cache != null) while (true) {
            val previous = cache.load()
            previous.entries[name]?.let { return it }
            // Bound both the number and total token size of deferred definitions.
            if (previous.entries.size >= 512 || tokens.size > 500_000 - previous.tokens) break
            if (cache.compareAndSet(previous, ParsedDefinitions(previous.entries + (name to expr), previous.tokens + tokens.size))) break
        }
        return expr
    }

    fun parseAt(offset: Int, budget: CompilationBudget = CompilationBudget()): Expr = Parser(slice(offset), source, budget).completeExpression()

    private fun slice(offset: Int, scans: ScanBudget? = null): List<Token> {
        val lexer = Lexer(source, offset)
        val tokens = mutableListOf<Token>()
        var depth = 0
        while (true) {
            val previous = tokens.lastOrNull()?.context
            val token = scans?.next(lexer, previous) ?: lexer.next(previous)
            if (token.kind == -1 || token.kind == 0 && depth == 0 && token.text in setOf(",", ";", ")", "}")) {
                tokens.add(Token("<eof>", -1, token.offset)); return tokens
            }
            if (token.kind == 0) {
                if (token.text == "(" || token.text == "[" || token.text == "{") depth++
                if (token.text == ")" || token.text == "]" || token.text == "}") depth--
            }
            if (depth > 128) unsupported("Source nesting limit exceeded")
            if (tokens.size >= 150_000) unsupported("Definition token limit exceeded")
            tokens.add(token)
        }
    }

    fun classFunction(name: String, budget: CompilationBudget = CompilationBudget()): FunctionExpr {
        val entry = assignments.singleOrNull { classTarget(it.lhs, name) }
            ?: unsupported("Missing or ambiguous n class '$name'")
        return parseAt(entry.offset, budget) as? FunctionExpr ?: unsupported("Unsupported n class")
    }

    fun method(name: String, methodName: String, runtime: Runtime): FunctionExpr {
        val methods = mutableListOf<FunctionExpr>()
        for (entry in members) {
            val target = Parser(entry.lhs + Token("<eof>", -1), source, runtime.compilationBudget).completeExpression() as? Member ?: continue
            val parent = target.target as? Member ?: continue
            val root = parent.target as? Member ?: continue
            if (root.target != Id("g") || root.key != Lit(name)) continue
            if (runtime.expression(parent.key) == JsString("prototype") && runtime.expression(target.key) == JsString(methodName)) {
                methods.add(parseAt(entry.offset, runtime.compilationBudget) as? FunctionExpr ?: unsupported("Invalid n method"))
            }
        }
        if (methods.size != 1) unsupported("Missing or ambiguous n $methodName method for '$name'")
        return methods.single()
    }

    companion object {
        private const val AMBIGUOUS = -1
        private const val MUTATED = -2
        // Track String mutations too: an overridden split need not return an array.
        private val readOnlyPredicates = mapOf("Array" to setOf("isArray"), "Number" to setOf("isNaN", "isFinite"), "String" to emptySet())
        fun identifier(name: String): Boolean = name.isNotEmpty() && name[0].let { it in 'A'..'Z' || it in 'a'..'z' || it == '_' || it == '$' } && name.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it == '_' || it == '$' }
        private val nonCalls = setOf("function", "if", "while", "for", "switch", "catch", "with", "typeof", "void", "delete", "return", "throw", "new")
        private val compoundWriteTags = intArrayOf(ScanTags.PLUS_ASSIGN, ScanTags.MINUS_ASSIGN, ScanTags.STAR_ASSIGN, ScanTags.SLASH_ASSIGN, ScanTags.MOD_ASSIGN, ScanTags.AMP_ASSIGN, ScanTags.PIPE_ASSIGN, ScanTags.CARET_ASSIGN, ScanTags.SHL_ASSIGN, ScanTags.SHR_ASSIGN, ScanTags.USHR_ASSIGN, ScanTags.POW_ASSIGN, ScanTags.AND_ASSIGN, ScanTags.OR_ASSIGN, ScanTags.NULL_ASSIGN)
        private val expressionEnds = intArrayOf(ScanTags.SEMI, ScanTags.COMMA, ScanTags.RPAREN, ScanTags.RBRACE)
        private val primitiveTags = intArrayOf(ScanTags.TRUE, ScanTags.FALSE, ScanTags.NULL, ScanTags.UNDEFINED, ScanTags.NAN, ScanTags.INFINITY)
        private val statementPrefixes = setOf(";", "{", "}", ")", "else")
        private val targetPrefixes = setOf("var", "let", "const", ";", ",", "{", "}", "(", ")")
        private val callPrefixes = setOf("=", "return", "new", "(", "?", ":")
        private fun classTarget(tokens: List<Token>, name: String): Boolean =
            tokens.size == 3 && tokens[0].text == "g" && tokens[1].text == "." && tokens[2].text == name
        private fun targetEnd(tokens: ScanWindow): Int {
            var end = tokens.lastIndex
            while (end >= 0 && tokens.kind(end) == 0 && tokens.isText(end, ")")) end--
            return end
        }
        private fun assignmentTargetStart(tokens: ScanWindow, end: Int = tokens.lastIndex, call: Boolean = false): Int {
            var start = end
            if (start < 0) return -1
            var brackets = 0
            while (start >= 0) {
                if (tokens.kind(start) != 0) { if (brackets == 0) return -1; start--; continue }
                if (tokens.isText(start, "]")) brackets++
                if (tokens.isText(start, "[")) brackets--
                if (brackets == 0 && !tokens.isText(start, ".") && !tokens.isText(start, "[") && !tokens.isText(start, "]")) {
                    if (!tokens.identifier(start)) return -1
                    if (tokens.isText(start - 1, ".")) { start--; continue }
                    if (start > 0 && targetPrefixes.none { tokens.isText(start - 1, it) } && !(call && callPrefixes.any { tokens.isText(start - 1, it) })) return -1
                    return start
                }
                start--
            }
            return -1
        }
    }
}
