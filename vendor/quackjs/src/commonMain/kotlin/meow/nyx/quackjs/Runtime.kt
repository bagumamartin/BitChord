package meow.nyx.quackjs

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.log2
import kotlin.math.sqrt

internal class JsThrown(val value: JsValue) : Exception() {
    // Engine-specific messages stay unsupported; implicit errors still expose their JavaScript name.
    constructor(name: String = "TypeError") : this(JsObject(mutableMapOf("name" to JsString(name)), builtin = "Error"))
}
internal class Env(val parent: Env? = null, private val names: Map<String, Int>? = null) {
    private var entries: MutableMap<String, JsValue>? = null
    var revision: Int = 0
        private set
    val values: MutableMap<String, JsValue> get() = entries ?: mutableMapOf<String, JsValue>().also { entries = it }
    val slots: Array<JsValue> = Array(names?.size ?: 0) { Undefined }
    val frame: Env? = if (names != null) this else parent?.frame
    fun owner(name: String): Env? = if (names?.containsKey(name) == true || entries?.containsKey(name) == true) this else parent?.owner(name)
    operator fun get(name: String): JsValue? { val slot = names?.get(name); return if (slot == null) entries?.get(name) else slots[slot] }
    operator fun set(name: String, value: JsValue) { val slot = names?.get(name); if (slot == null) { values[name] = value; revision++ } else slots[slot] = value }
}

internal class Runtime(val source: SourceIndex, private val parsed: Map<String, Expr> = emptyMap(), private val templates: Map<String, JsValue> = emptyMap(), private val dates: Map<String, Double> = emptyMap(), private val dispatch: Map<DispatchKey, Block> = emptyMap(), recordDispatch: Boolean = false, globalCount: Int = 0, private val analysis: LinearNAnalysis? = null, internal val compilationBudget: CompilationBudget = CompilationBudget()) {
    val definitions = mutableMapOf<String, Expr>()
    val constantDates = mutableMapOf<String, Double>()
    val specializedBodies: MutableMap<DispatchKey, Block>? = if (recordDispatch) mutableMapOf() else null
    private val global = Env()
    private val globalSlots: Array<JsValue?> = arrayOfNulls(globalCount)
    private var globalRevision = 0
    private val resolving = mutableSetOf<String>()
    private var steps = 0
    private var allocated = 0
    private var calls = 0
    var challenge: String? = null
    private var handlers = 0
    private var expressionDepth = 0
    internal val chargedSteps: Int get() = steps
    internal val handlingException: Boolean get() = handlers > 0
    internal val chargedAllocation: Int get() = allocated
    internal fun input(value: String): JsValue = analysis?.input() ?: JsString(value)
    internal fun plainArrayNumberContext(): Boolean = conversionDepth == 0 && calls <= 61
    internal fun symbolicContext() {
        if (conversionDepth != 0) linearReject("symbolic coercion context")
    }
    fun tick(cost: Int = 1) { if (cost < 0 || cost > 2_000_000 - steps) unsupported("Execution step limit exceeded"); steps += cost }
    fun allocate(size: Int) {
        if (size < 0 || size > 65_536) unsupported("Value size limit exceeded")
        allocated += size + 1
        if (allocated > 2_000_000) unsupported("Allocation limit exceeded")
    }
    fun array(items: List<JsValue>): JsArray { allocate(items.size); return JsArray(items.toMutableList()) }
    private fun arrayRange(items: List<JsValue>, start: Int, count: Int): JsArray { allocate(count); return JsArray(MutableList(count) { items.getOrElse(start + it) { Hole } }) }
    fun string(value: String): JsString { allocate(value.length); return JsString(value) }
    private fun number(value: JsValue): Double {
        if (value is JsNumber && conversionDepth < 64) return value.value
        // Default function/regex strings cannot parse as numbers; with no own coercion methods this
        // avoids constructing large join strings without skipping any user code.
        if (value is JsArray) {
            if (arrayAlwaysCoercesToNaN(value)) return Double.NaN
            if (analysis?.primitiveArrayNaN(this, value) == true) return Double.NaN
        }
        val input = primitive(value, PrimitiveHint.NUMBER)
        if (input is JsString) tick(input.value.length)
        return meow.nyx.quackjs.number(input)
    }
    private fun int(value: JsValue): Int = meow.nyx.quackjs.int(number(value))
    private fun uint(value: JsValue): Long = meow.nyx.quackjs.uint(number(value))
    private fun integer(value: JsValue): Int = meow.nyx.quackjs.integer(number(value))
    private fun relative(value: JsValue, length: Int): Int = meow.nyx.quackjs.relative(number(value), length)
    private enum class PrimitiveHint { DEFAULT, NUMBER, STRING }
    private var conversionDepth = 0
    private val joiningArrays = mutableSetOf<JsArray>()
    private fun primitive(value: JsValue, hint: PrimitiveHint = PrimitiveHint.DEFAULT): JsValue {
        if (++conversionDepth > 64) unsupported("Primitive conversion depth limit exceeded")
        try { return when (value) {
            is JsArray, is JsObject -> ordinaryPrimitive(value, hint)
            is JsDate -> if (hint == PrimitiveHint.NUMBER) JsNumber(value.time) else unsupported("Default date coercion is unsupported")
            is JsFunction, is Native -> JsString(text(value).also { tick(it.length); allocate(it.length) })
            is RegexValue -> JsString(BoundedRegex(this, value.source).literalText())
            else -> value
        } } finally { conversionDepth-- }
    }
    private fun ordinaryPrimitive(value: JsValue, hint: PrimitiveHint): JsValue {
        val names = if (hint == PrimitiveHint.STRING) arrayOf("toString", "valueOf") else arrayOf("valueOf", "toString")
        for (name in names) {
            // Look up each method only after the preceding method's side effects.
            val method = get(value, name)
            if (!callable(method)) continue
            val result = invoke(method, value, emptyList())
            if (!isRuntimeObject(result)) return result
        }
        throw JsThrown()
    }
    internal fun stringValue(value: JsValue): String = text(primitive(value, PrimitiveHint.STRING))
    private fun arrayAlwaysCoercesToNaN(root: JsArray): Boolean {
        val pending = ArrayDeque<JsArray>()
        val seen = mutableSetOf<JsArray>()
        pending.addLast(root)
        var hasCallable = false
        while (pending.isNotEmpty()) {
            val array = pending.removeLast()
            tick()
            if (!seen.add(array)) continue
            allocate(1)
            if (array.fields.containsKey("toString") || array.fields.containsKey("valueOf") || array.fields.containsKey("join")) return false
            tick(array.values.size)
            for (item in array.values) when (item) {
                is JsFunction, is Native, is RegexValue -> hasCallable = true
                is JsArray -> { allocate(1); pending.addLast(item) }
                is JsObject -> if (item.fields.containsKey("toString") || item.fields.containsKey("valueOf")) return false
                is JsDate, is LinearNumber -> return false
                is JsNumber -> if (item.value.isFinite() && (item.value != floor(item.value) || abs(item.value) > 9007199254740991.0)) return false
                else -> Unit
            }
        }
        return hasCallable
    }
    private fun joinArray(array: JsArray, separatorValue: JsValue = Undefined): JsValue {
        analysis?.join(this, array, separatorValue)?.let { return it }
        val length = array.values.size
        val separator = if (separatorValue === Undefined) "," else stringValue(separatorValue)
        if (!joiningArrays.add(array)) return JsString("")
        try {
            tick(length)
            val result = StringBuilder()
            for (i in 0 until length) {
                val item = array.values.getOrElse(i) { Undefined }
                val part = if (item === JsNull || item === Undefined || item === Hole) "" else stringValue(item)
                if (result.length.toLong() + part.length + (if (i == 0) 0 else separator.length) > 65_536) unsupported("String size limit exceeded")
                if (i > 0) result.append(separator)
                result.append(part)
            }
            return string(result.toString())
        } finally { joiningArrays.remove(array) }
    }
    private fun callable(value: JsValue): Boolean = value is JsFunction || value is Native && value.callable
    private fun isRuntimeObject(value: JsValue): Boolean =
        value is JsArray || value is JsObject || value is JsFunction || value is Native || value is JsDate || value is RegexValue
    private fun find(value: String, search: String, from: Int, backwards: Boolean = false): Int {
        tick()
        if (search.isEmpty()) return from
        if (search.length == 1) {
            val result = if (backwards) value.lastIndexOf(search[0], from) else value.indexOf(search[0], from)
            val cost = if (backwards) {
                val start = minOf(from, value.lastIndex)
                if (result < 0) start + 1 else start - result + 1
            } else if (result < 0) value.length - from else result - from + 1
            tick(cost)
            return result
        }
        val last = value.length - search.length
        val candidates = if (backwards) minOf(from, last) downTo 0 else from..last
        for (index in candidates) {
            var matched = 0
            while (matched < search.length) {
                tick()
                if (value[index + matched] != search[matched]) break
                matched++
            }
            if (matched == search.length) return index
        }
        return -1
    }
    private fun equal(a: JsValue, b: JsValue, strict: Boolean): Boolean {
        if (analysis != null && (a is LinearValue || b is LinearValue)) linearReject("input-dependent comparison")
        if (!strict) {
            if (isRuntimeObject(a) && !isRuntimeObject(b) && b !== JsNull && b !== Undefined) return equal(primitive(a), b, false)
            if (isRuntimeObject(b) && !isRuntimeObject(a) && a !== JsNull && a !== Undefined) return equal(a, primitive(b), false)
        }
        if (a is JsString && b is JsString) { if (a.value.length == b.value.length) tick(a.value.length) }
        else if (!strict) { if (a is JsString) tick(a.value.length); if (b is JsString) tick(b.value.length) }
        return meow.nyx.quackjs.equal(a, b, strict)
    }
    fun resolve(name: String): JsValue {
        global.values[name]?.let { return it }
        val builtin = if (name !in parsed && name !in definitions && !source.hasDefinition(name)) builtin(name) else null
        if (builtin != null) {
            val value = if (builtin is Native) builtin.named(name) else builtin
            global.values[name] = value
            return value
        }
        if (!resolving.add(name)) unsupported("Circular initializer '$name'")
        if (resolving.size > 64 || parsed.size + definitions.size > 512) unsupported("Dependency limit exceeded")
        try {
            val expr = parsed[name] ?: definitions.getOrPut(name) { source.definition(name, compilationBudget) }
            val value = templates[name]?.let(::copyTemplate) ?: eval(expr, global)
            global.values[name] = value
            return value
        } finally { resolving.remove(name) }
    }
    fun eval(expr: Expr, env: Env): JsValue {
        tick()
        if (expr is Lit) return if (expr.value is RegexValue) { allocate(1); RegexValue(expr.value.source) } else expr.value
        if (expr is Id) return if (expr.slot >= 0) env.frame!!.slots[expr.slot] else if (expr.free && env.frame?.parent === global) globalValue(expr) else { val owner = env.owner(expr.name); if (owner != null) owner[expr.name]!! else resolve(expr.name) }
        return evalComplex(expr, env)
    }
    private fun globalValue(id: Id): JsValue {
        if (id.globalSlot < 0) return resolve(id.name)
        if (globalRevision != global.revision) { globalSlots.fill(null); globalRevision = global.revision }
        val value = globalSlots[id.globalSlot]
        if (value != null) return value
        return resolve(id.name).also { globalSlots[id.globalSlot] = it }
    }
    private fun evalComplex(expr: Expr, env: Env): JsValue {
        if (++expressionDepth > 256) unsupported("Expression execution depth limit exceeded")
        try { return when (expr) {
            is Lit, is Id -> error("Leaf expression in complex evaluator")
            is Unary -> when (expr.op) {
                "typeof" -> {
                    val value = if (expr.expr is Id && env.owner(expr.expr.name) == null && !source.hasDefinition(expr.expr.name) && builtin(expr.expr.name) == null) Undefined else eval(expr.expr, env)
                    JsString(when (value) { Undefined -> "undefined"; is JsString, is LinearString -> "string"; is JsNumber, is LinearNumber -> "number"; is JsBoolean -> "boolean"; is JsFunction, is Native -> "function"; else -> "object" })
                }
                "delete" -> {
                    val target = expr.expr as? Member ?: unsupported("Unsupported delete target")
                    val obj = eval(target.target, env); val rawKey = eval(target.key, env)
                    if (analysis != null && rawKey is LinearValue) linearReject("input-dependent delete position")
                    if (obj !is JsObject && obj !is JsArray) unsupported("Unsupported delete target")
                    val key = stringValue(rawKey)
                    tick(key.length)
                    when (obj) {
                        is JsObject -> obj.fields.remove(key)
                        is JsArray -> { val i = index(key); if (i != null && i < obj.values.size) obj.values[i] = Hole else obj.fields.remove(key) }
                    }; JsBoolean(true)
                }
                "void" -> { eval(expr.expr, env); Undefined }
                "!" -> JsBoolean(!truth(eval(expr.expr, env)))
                "~" -> JsNumber(int(eval(expr.expr, env)).inv().toDouble())
                "+" -> JsNumber(number(eval(expr.expr, env)))
                "-" -> JsNumber(-number(eval(expr.expr, env)))
                else -> unsupported("Unsupported unary operator ${expr.op}")
            }
            is Binary -> {
                when (expr.op) {
                    "=" -> assign(expr.left, env, read = false) { eval(expr.right, env) }
                    "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", ">>>=" -> assign(expr.left, env, read = true) {
                        binary(expr.op.dropLast(1), it, eval(expr.right, env))
                    }
                    "&&" -> eval(expr.left, env).let { if (truth(it)) eval(expr.right, env) else it }
                    "||" -> eval(expr.left, env).let { if (truth(it)) it else eval(expr.right, env) }
                    "??" -> eval(expr.left, env).let { if (it === JsNull || it === Undefined) eval(expr.right, env) else it }
                    "," -> { eval(expr.left, env); eval(expr.right, env) }
                    else -> binary(expr.op, eval(expr.left, env), eval(expr.right, env))
                }
            }
            is Conditional -> eval(if (truth(eval(expr.test, env))) expr.yes else expr.no, env)
            is Member -> property(eval(expr.target, env), eval(expr.key, env))
            is Call -> {
                var self: JsValue = Undefined
                val fn = if (expr.fn is Member) {
                    self = eval(expr.fn.target, env)
                    val key = eval(expr.fn.key, env)
                    if (!expr.construct && key == JsString("call") && (self is JsFunction || self is Native)) {
                        if (expr.args.isEmpty()) return invoke(self, Undefined, emptyList())
                        val receiver = eval(expr.args[0], env)
                        return invoke(self, receiver, arguments(expr.args, env, 1))
                    }
                    val method = property(self, key)
                    if (method === Undefined && key is JsString && (self is JsString || self is JsArray || self is Native || analysis != null && self is LinearString) && identifierProperty(key.value) && key.value !in setOf("NaN", "Infinity", "undefined")) unsupported("Unsupported built-in method '${key.value}'")
                    method
                } else eval(expr.fn, env)
                val args = arguments(expr.args, env)
                if (expr.construct) {
                    if (fn !is Native) unsupported("Only built-in transform constructors are supported")
                    invoke(fn, Undefined, args, construct = true)
                } else invoke(fn, self, args)
            }
            is Update -> {
                var old = 0.0
                val value = assign(expr.target, env, read = true) {
                    old = number(it)
                    JsNumber(old + if (expr.op == "++") 1 else -1)
                }
                if (expr.prefix) value else JsNumber(old)
            }
            is ArrayExpr -> array(expr.items.map { eval(it, env) })
            is ObjectExpr -> { allocate(expr.items.size); JsObject(expr.items.associate { it.first to eval(it.second, env) }.toMutableMap()) }
            is FunctionExpr -> { allocate(1); JsFunction(expr, env) }
        } } finally { expressionDepth-- }
    }
    private fun arguments(args: List<Expr>, env: Env, start: Int = 0): List<JsValue> = when (args.size - start) {
        0 -> emptyList()
        1 -> listOf(eval(args[start], env))
        2 -> listOf(eval(args[start], env), eval(args[start + 1], env))
        3 -> listOf(eval(args[start], env), eval(args[start + 1], env), eval(args[start + 2], env))
        else -> ArrayList<JsValue>(args.size - start).also { values ->
            for (i in start until args.size) values.add(eval(args[i], env))
        }
    }
    fun function(code: FunctionExpr): JsFunction = JsFunction(code, global)
    fun expression(expr: Expr, values: Map<String, JsValue> = emptyMap()): JsValue = eval(expr, Env(global).also { it.values.putAll(values) })
    fun functionEnv(fn: JsFunction, self: JsValue, args: List<JsValue>, reuse: Env? = null): Env {
        if (reuse == null) allocate(fn.code.slots.size)
        tick(fn.code.slots.size)
        tick(fn.code.parameterSlots.size)
        val env = reuse ?: Env(fn.env, fn.code.slots)
        if (reuse != null) env.slots.fill(Undefined)
        env.slots[fn.code.thisSlot] = self
        for (i in fn.code.parameterSlots.indices) env.slots[fn.code.parameterSlots[i]] = args.getOrElse(i) { Undefined }
        if (fn.code.usesArguments) env.slots[fn.code.argumentsSlot] = array(args)
        if (fn.code.nameSlot >= 0) env.slots[fn.code.nameSlot] = fn
        return env
    }
    fun invoke(fn: JsValue, self: JsValue, args: List<JsValue>, construct: Boolean = false, reuse: Env? = null): JsValue {
        tick()
        allocate(args.size)
        if (++calls > 64) unsupported("Call depth limit exceeded")
        try {
            return when (fn) {
                is Native -> {
                    if (construct && !fn.constructible || !construct && !fn.callable) unsupported("Unsupported built-in constructor/call")
                    if (analysis != null) {
                        if (self is LinearValue || args.any { it is LinearValue }) symbolicContext()
                        when (fn) {
                            stringMethods["split"] -> if (self is LinearString) return analysis.split(this, self, args)
                            arrayMethods["indexOf"] -> {
                                if (args.firstOrNull() is LinearValue) return analysis.indexOf(this, self, args)
                                if (self is JsArray && self.values.any { tick(); it is LinearValue }) linearReject("search of symbolic array")
                            }
                            stringMethods["toString"], stringMethods["valueOf"] -> if (self is LinearString) return self
                        }
                        val movesValues = fn === arrayMethods["push"] || fn === arrayMethods["unshift"] ||
                            fn === arrayMethods["splice"] && args.take(2).none { it is LinearValue } ||
                            fn === arrayMethods["forEach"] && args.firstOrNull() !is LinearValue
                        if ((self is LinearValue || args.any { it is LinearValue }) &&
                            !movesValues && fn !== callMethod && fn !== applyMethod) {
                            linearReject("unsupported symbolic native ${fn.functionName}")
                        }
                    }
                    fn.invoke(this, self, args)
                }
                is JsFunction -> {
                    val env = functionEnv(fn, self, args, reuse)
                    // Reserve eleven complex-expression levels for the XOR-key shape; otherwise retain depth checks.
                    if (analysis == null && expressionDepth <= 245 && fn.code.hotCharacterPlan?.execute(this, env) == true) return Undefined
                    val key = if (args.size >= 2 && args[0] is JsNumber && args[1] is JsNumber) DispatchKey(fn.code, (args[0] as JsNumber).value, (args[1] as JsNumber).value) else null
                    val body = if (key == null) fn.code.body else dispatch[key] ?: specializedBodies?.get(key) ?: if (specializedBodies != null && specializedBodies.size < 256) specialize(fn.code, key.first, key.second, this).also { specializedBodies[key] = it } else fn.code.body
                    when (val flow = exec(body, env)) {
                        is Completion.Jumped -> unsupported("Invalid or unsupported jump from transform function")
                        Completion.Normal -> Undefined
                        is Completion.Returned -> flow.value
                    }
                }
                else -> throw JsThrown()
            }
        } finally { calls-- }
    }
    private fun copyTemplate(value: JsValue): JsValue = when (value) {
        is JsArray -> { allocate(value.values.size); JsArray(MutableList(value.values.size) { copyTemplate(value.values[it]) }) }
        is JsObject -> { allocate(value.fields.size); JsObject(value.fields.mapValuesTo(mutableMapOf()) { copyTemplate(it.value) }, value.builtin) }
        is JsFunction -> { allocate(1); JsFunction(value.code, global) }
        else -> value
    }
    fun exec(stmt: Stmt, env: Env): Completion {
        tick()
        when (stmt) {
            is Block -> for (i in stmt.statements.indices) { val flow = exec(stmt.statements[i], env); if (flow !== Completion.Normal) return flow }
            is ExpressionStmt -> { eval(stmt.expr, env) }
            is Vars -> {
                tick(stmt.items.size)
                for (i in stmt.items.indices) { val (name, expr) = stmt.items[i]; if (expr != null) (env.owner(name) ?: env)[name] = eval(expr, env) }
            }
            is IfStmt -> return if (truth(eval(stmt.test, env))) exec(stmt.yes, env) else stmt.no?.let { exec(it, env) } ?: Completion.Normal
            is ReturnStmt -> return Completion.Returned(if (stmt.expr == null) Undefined else eval(stmt.expr, env))
            is ThrowStmt -> throw JsThrown(eval(stmt.expr, env))
            is Loop -> {
                stmt.init?.let { exec(it, env) }
                var first = true
                while (stmt.doFirst && first || stmt.test == null || truth(eval(stmt.test, env))) {
                    tick(); first = false
                    val flow = exec(stmt.body, env)
                    if (flow is Completion.Jumped && flow.label == null) { if (!flow.isContinue) break }
                    else if (flow !== Completion.Normal) return flow
                    stmt.update?.let { eval(it, env) }
                }
            }
            is Jump -> { if (stmt.isContinue && stmt.label != null) unsupported("Labeled continue is unsupported"); return Completion.Jumped(stmt.isContinue, stmt.label) }
            is Label -> {
                val flow = exec(stmt.body, env)
                if (flow !is Completion.Jumped || flow.label != stmt.name || flow.isContinue) return flow
            }
            is TryStmt -> {
                // Unsupported syntax and resource failures are deliberately not JavaScript exceptions.
                var pending: JsThrown? = null
                val flow = try {
                    try { exec(stmt.body, env) } catch (error: JsThrown) {
                        if (stmt.handler == null) throw error
                        val catchEnv = Env(env); catchEnv.values[stmt.catchName!!] = error.value
                        handlers++
                        try { exec(stmt.handler, catchEnv) } finally { handlers-- }
                    }
                } catch (error: JsThrown) { pending = error; Completion.Normal }
                val finalFlow = stmt.finalizer?.let { exec(it, env) } ?: Completion.Normal
                if (finalFlow !== Completion.Normal) return finalFlow
                if (pending != null) throw pending
                return flow
            }
            is SwitchStmt -> {
                val value = eval(stmt.expr, env)
                var start = stmt.cases.indexOfFirst { tick(); it.first != null && equal(value, eval(it.first!!, env), true) }
                if (start < 0) start = stmt.cases.indexOfFirst { tick(); it.first == null }
                if (start >= 0) for (i in start until stmt.cases.size) {
                    tick()
                    val statements = stmt.cases[i].second
                    for (j in statements.indices) {
                        val flow = exec(statements[j], env)
                        if (flow is Completion.Jumped && !flow.isContinue && flow.label == null) return Completion.Normal
                        if (flow !== Completion.Normal) return flow
                    }
                }
            }
            EmptyStmt -> Unit
        }
        return Completion.Normal
    }
    // Keep the target and its old value stable across RHS mutations without allocating a reference.
    private inline fun assign(expr: Expr, env: Env, read: Boolean, value: (JsValue) -> JsValue): JsValue = when (expr) {
        is Id -> {
            if (expr.slot >= 0) {
                val slots = env.frame!!.slots
                val result = value(if (read) slots[expr.slot] else Undefined)
                slots[expr.slot] = result
                result
            } else {
                val owner = env.owner(expr.name) ?: if (expr.name in parsed || source.hasDefinition(expr.name)) {
                    resolve(expr.name)
                    global
                } else unsupported("Assignment to undeclared '${expr.name}'")
                val result = value(if (read) owner[expr.name]!! else Undefined)
                owner[expr.name] = result
                result
            }
        }
        is Member -> {
            val obj = eval(expr.target, env); val rawKey = eval(expr.key, env)
            if (analysis != null && rawKey is LinearValue) linearReject("input-dependent write position")
            if (obj === JsNull || obj === Undefined) {
                if (!read) value(Undefined)
                throw JsThrown()
            }
            val key = if (numericIndex(rawKey) != null) rawKey else JsString(stringValue(rawKey))
            val result = value(if (read) property(obj, key) else Undefined)
            val i = numericIndex(key)
            if (obj is JsArray && i != null) setIndex(obj, i, result) else set(obj, text(key), result)
            result
        }
        else -> unsupported("Invalid assignment target")
    }
    fun set(obj: JsValue, key: String, value: JsValue) {
        tick(key.length)
        when (obj) {
            is JsObject -> { if (!obj.fields.containsKey(key)) allocate(1); obj.fields[key] = value }
            is JsArray -> {
                if (key == "length") {
                    val length = number(value)
                    if (length < 0 || length != floor(length)) throw JsThrown("RangeError")
                    if (length > 65_536) unsupported("Array size limit exceeded")
                    val size = length.toInt()
                    if (size > obj.values.size) { allocate(size - obj.values.size); repeat(size - obj.values.size) { obj.values.add(Hole) } }
                    else while (obj.values.size > size) obj.values.removeAt(obj.values.lastIndex)
                } else {
                    val numeric = key.toLongOrNull()
                    if (numeric != null && numeric in 65_536L..4_294_967_294L && key == numeric.toString()) unsupported("Array index limit exceeded")
                    val i = index(key)
                    if (i == null) { if (!obj.fields.containsKey(key)) allocate(1); obj.fields[key] = value }
                    else setIndex(obj, i, value)
                }
            }
            JsNull, Undefined -> throw JsThrown()
            else -> unsupported("Unsupported property assignment")
        }
    }
    private fun setIndex(obj: JsArray, i: Int, value: JsValue) {
        if (i >= 65_536) unsupported("Array index limit exceeded")
        if (i >= obj.values.size) { allocate(i + 1 - obj.values.size); repeat(i + 1 - obj.values.size) { obj.values.add(Hole) } }
        obj.values[i] = value
    }
    private fun numericIndex(key: JsValue): Int? = if (key is JsNumber && key.value >= 0 && key.value < 65_536 && key.value == key.value.toInt().toDouble()) key.value.toInt() else null
    internal fun property(obj: JsValue, key: JsValue): JsValue {
        if (analysis != null && key is LinearValue) {
            symbolicContext()
            return analysis.lookup(this, obj, key)
        }
        if (obj === JsNull || obj === Undefined) throw JsThrown()
        val i = numericIndex(key)
        if (i != null) when (obj) {
            is JsArray -> { tick(); val value = obj.values.getOrElse(i) { Undefined }; return if (value === Hole) Undefined else value }
            is JsString -> { tick(); return if (i < obj.value.length) JsString(obj.value[i].toString()) else Undefined }
            else -> Unit
        }
        return get(obj, stringValue(key))
    }
    fun get(obj: JsValue, key: String): JsValue {
        tick(key.length + 1)
        if (obj === JsNull || obj === Undefined) throw JsThrown()
        if ((obj is JsFunction || obj is Native) && key == "call") return callMethod
        if ((obj is JsFunction || obj is Native) && key == "apply") return applyMethod
        if (obj is Native) return obj.fields[key] ?: unsupported("Unsupported built-in property '$key'")
        if (obj is JsFunction) return when (key) {
            "length" -> JsNumber(obj.code.params.size.toDouble())
            "name", "prototype", "constructor", "bind", "caller", "arguments", "toString", "valueOf" -> unsupported("Unsupported function property '$key'")
            else -> Undefined
        }
        if (obj is JsObject) {
            obj.fields[key]?.let { return it }
            return when (key) {
                "toString" -> objectToString
                "valueOf" -> objectValueOf
                else -> if (obj.builtin != null) unsupported("Unsupported ${obj.builtin}.$key") else Undefined
            }
        }
        if (obj is JsArray) {
            if (key == "length") return JsNumber(obj.values.size.toDouble())
            index(key)?.let { return obj.values.getOrElse(it) { Undefined }.let { item -> if (item === Hole) Undefined else item } }
            obj.fields[key]?.let { return it }
            return arrayMethods[key] ?: Undefined
        }
        if (obj is JsString) {
            if (key == "length") return JsNumber(obj.value.length.toDouble())
            index(key)?.let { return if (it < obj.value.length) JsString(obj.value[it].toString()) else Undefined }
            return stringMethods[key] ?: Undefined
        }
        if (obj is LinearString) {
            if (key == "length") return JsNumber(obj.refs.size.toDouble())
            index(key)?.let { return if (it < obj.refs.size) LinearString(intArrayOf(obj.refs[it])) else Undefined }
            return stringMethods[key] ?: Undefined
        }
        if (obj is LinearNumber) linearReject("symbolic numeric property")
        if (key == "toString" && (obj is JsNumber || obj is JsBoolean)) return Native(functionName = "toString") { r, self, a ->
            if (obj is JsBoolean && self !is JsBoolean || obj !is JsBoolean && self !is JsNumber) throw JsThrown()
            if (a.isNotEmpty() && r.number(a[0]) != 10.0) unsupported("Unsupported number radix")
            JsString(text(self))
        }
        if (obj is JsDate) unsupported("Unsupported date property '$key'")
        // Regexes may be opaque constants, but must never silently execute with Kotlin regex semantics.
        if (obj is RegexValue) unsupported("Unsupported regex operation '$key'")
        return Undefined
    }
    private companion object {
    val unsupportedObjectProperties = setOf("constructor", "__proto__", "hasOwnProperty", "isPrototypeOf", "propertyIsEnumerable", "toLocaleString", "__defineGetter__", "__defineSetter__", "__lookupGetter__", "__lookupSetter__")
    val unsupportedArrayProperties = setOf(
        "at", "concat", "copyWithin", "entries", "every", "fill", "filter", "find", "findIndex", "findLast", "findLastIndex",
        "flat", "flatMap", "includes", "keys", "lastIndexOf", "map", "reduce", "reduceRight", "some", "sort",
        "toReversed", "toSorted", "toSpliced", "values", "with",
    )
    // Native methods are receiver-driven and immutable; only Runtime and the receiver own state.
    val callMethod = Native(functionName = "call") { r, self, a -> r.invoke(self, a.getOrElse(0) { Undefined }, a.drop(1)) }
    val applyMethod = Native(functionName = "apply") { r, self, a ->
        val args = a.getOrElse(1) { Undefined }
        val items = if (args === JsNull || args === Undefined) emptyList() else (args as? JsArray)?.values ?: throw JsThrown()
        r.tick(items.size); r.allocate(items.size)
        r.invoke(self, a.getOrElse(0) { Undefined }, items.map { if (it === Hole) Undefined else it })
    }
    val stringConstructor = Native(mapOf(
        "fromCharCode" to Native { r, _, a ->
            r.tick(a.size)
            if (a.size == 1) {
                val code = r.int(a[0]) and 65535
                r.allocate(1)
                if (code < latin1Characters.size) latin1Characters[code] else JsString(code.toChar().toString())
            } else r.string(buildString(a.size) { for (value in a) append((r.int(value) and 65535).toChar()) })
        }
    )) { r, _, a -> r.string(if (a.isEmpty()) "" else r.stringValue(a[0])) }
    val numberConstructor = Native(mapOf(
        "isNaN" to Native { _, _, a -> JsBoolean((a.firstOrNull() as? JsNumber)?.value?.isNaN() ?: false) },
        "isFinite" to Native { _, _, a -> JsBoolean((a.firstOrNull() as? JsNumber)?.value?.isFinite() ?: false) }
    )) { r, _, a -> JsNumber(if (a.isEmpty()) 0.0 else r.number(a[0])) }
    val objectToString = Native(functionName = "toString") { _, self, _ ->
        if (self is JsObject && self.builtin == "Error") unsupported("Default Error string coercion is unsupported")
        if (self is JsObject) JsString("[object ${self.builtin ?: "Object"}]") else unsupported("Unsupported object method receiver")
    }
    val objectValueOf = Native(functionName = "valueOf") { _, self, _ ->
        if (self is JsArray || self is JsObject) self else unsupported("Primitive object boxing is unsupported")
    }
    val arrayMethods = listOf("reverse", "join", "toString", "valueOf", "push", "unshift", "pop", "shift", "slice", "splice", "forEach", "indexOf").associateWith { (arrayMethod(it) as Native).named(it) }
    val stringMethods = listOf("split", "slice", "substring", "substr", "charCodeAt", "charAt", "indexOf", "lastIndexOf", "startsWith", "endsWith", "includes", "replace", "toString", "valueOf").associateWith { (stringMethod(it) as Native).named(it) }
    private val latin1Characters = Array(256) { JsString(it.toChar().toString()) }
    private fun arrayMethod(name: String): JsValue {
        return when (name) {
            "reverse" -> Native { r, self, _ -> val target = self as? JsArray ?: unsupported("Unsupported array method receiver"); r.tick(target.values.size); target.values.reverse(); target }
            "join" -> Native { r, self, a ->
                val target = self as? JsArray ?: unsupported("Unsupported array method receiver")
                r.joinArray(target, a.getOrElse(0) { Undefined })
            }
            "toString" -> Native { r, self, _ ->
                val target = self as? JsArray ?: unsupported("Unsupported array method receiver")
                val join = r.get(target, "join")
                if (r.callable(join)) r.invoke(join, target, emptyList()) else JsString("[object Array]")
            }
            "valueOf" -> objectValueOf
            "push" -> Native { r, self, a -> val v = arrayValues(self); r.allocate(a.size); if (v.size + a.size > 65_536) unsupported("Array size limit exceeded"); v.addAll(a); JsNumber(v.size.toDouble()) }
            "unshift" -> Native { r, self, a -> val v = arrayValues(self); r.tick(v.size); r.allocate(a.size); if (v.size + a.size > 65_536) unsupported("Array size limit exceeded"); if (a.size == 1) v.add(0, a[0]) else if (a.isNotEmpty()) v.addAll(0, a); JsNumber(v.size.toDouble()) }
            "pop" -> Native { _, self, _ -> val v = arrayValues(self); if (v.isEmpty()) Undefined else v.removeAt(v.lastIndex).let { if (it === Hole) Undefined else it } }
            "shift" -> Native { r, self, _ -> val v = arrayValues(self); if (v.isEmpty()) Undefined else { r.tick(v.size); v.removeAt(0).let { if (it === Hole) Undefined else it } } }
            "slice" -> Native { r, self, a ->
                val v = arrayValues(self); val length = v.size
                val start = r.relative(a.getOrElse(0) { JsNumber(0.0) }, length)
                val end = if (a.size < 2 || a[1] === Undefined) length else r.relative(a[1], length)
                val count = (end - start).coerceAtLeast(0)
                r.tick(count); r.arrayRange(v, start, count)
            }
            "splice" -> Native { r, self, a ->
                val v = arrayValues(self); val length = v.size
                val start = r.relative(a.getOrElse(0) { JsNumber(0.0) }, length)
                val count = if (a.isEmpty()) 0 else if (a.size < 2) length - start else r.integer(a[1]).coerceIn(0, length - start)
                val added = (a.size - 2).coerceAtLeast(0)
                if (length - count + added > 65_536) unsupported("Array size limit exceeded")
                val removed = r.arrayRange(v, start, count); r.allocate(added); r.tick(length)
                // No user code runs after coercion, so normalize missing live entries to holes before moving them.
                if (v.size < length) { r.allocate(length - v.size); repeat(length - v.size) { v.add(Hole) } }
                else while (v.size > length) v.removeAt(v.lastIndex)
                val change = added - count
                when {
                    count == v.size && added == 0 -> v.clear()
                    count == 1 && added == 0 -> v.removeAt(start)
                    count == 0 && added == 1 -> v.add(start, a[2])
                    else -> {
                        if (change < 0) {
                            for (i in start + count until v.size) v[i + change] = v[i]
                            repeat(-change) { v.removeAt(v.lastIndex) }
                        } else if (change > 0) {
                            val size = v.size
                            repeat(change) { v.add(Hole) }
                            for (i in size - 1 downTo start + count) v[i + change] = v[i]
                        }
                        for (i in 0 until added) v[start + i] = a[i + 2]
                    }
                }
                removed
            }
            "forEach" -> Native { r, self, a ->
                val target = self as? JsArray ?: unsupported("Unsupported array method receiver")
                val v = target.values
                val length = v.size
                val callback = a.getOrElse(0) { Undefined }
                if (callback !is JsFunction && callback !is Native) throw JsThrown()
                val selfArg = a.getOrElse(1) { Undefined }
                // Without closures or arguments, a callback cannot retain its invocation frame.
                var frame: Env? = null
                // Observable arguments are copied by functionEnv; nested traversals own their buffer.
                var callbackArgs: MutableList<JsValue>? = null
                for (i in 0 until length) {
                    r.tick()
                    if (i < v.size && v[i] !== Hole) {
                        if (frame == null && callback is JsFunction && !callback.code.hasClosures && !callback.code.usesArguments) {
                            // Keep the preparation budget, but let invoke initialize the bindings once.
                            r.allocate(callback.code.slots.size)
                            r.tick(callback.code.slots.size)
                            frame = Env(callback.env, callback.code.slots)
                        }
                        if (callbackArgs == null) callbackArgs = mutableListOf(v[i], JsNumber(i.toDouble()), target)
                        else { callbackArgs[0] = v[i]; callbackArgs[1] = JsNumber(i.toDouble()) }
                        r.invoke(callback, selfArg, callbackArgs, reuse = frame)
                    }
                }
                Undefined
            }
            "indexOf" -> Native { r, self, a ->
                val v = arrayValues(self)
                val length = v.size
                if (length == 0) return@Native JsNumber(-1.0)
                val start = r.relative(a.getOrElse(1) { JsNumber(0.0) }, length)
                val end = minOf(length, v.size)
                val search = a.getOrElse(0) { Undefined }
                var result = -1
                if (search is JsString && search.value.length == 1 || search is JsBoolean) {
                    val found = if (start >= end) -1 else if (start == 0 && end == v.size) v.indexOf(search) else v.subList(start, end).indexOf(search)
                    r.tick(if (found < 0) length - start else found + 1)
                    if (found >= 0) result = start + found
                } else for (i in start until length) { r.tick(); val item = v.getOrElse(i) { Hole }; if (item !== Hole && r.equal(item, search, true)) { result = i; break } }
                JsNumber(result.toDouble())
            }
            else -> Undefined
        }
    }
    private fun arrayValues(self: JsValue): MutableList<JsValue> = (self as? JsArray ?: unsupported("Unsupported array method receiver")).values
    private fun stringReceiver(runtime: Runtime, self: JsValue): String = if (self === JsNull || self === Undefined) throw JsThrown() else runtime.stringValue(self)
    private fun stringMethod(name: String): JsValue = when (name) {
        "split" -> Native { r, self, a ->
            val value = stringReceiver(r, self)
            if (a.firstOrNull() is RegexValue) unsupported("Regex split is unsupported")
            val limit = if (a.size < 2 || a[1] === Undefined) 4_294_967_295L else r.uint(a[1])
            val sep = a.getOrElse(0) { Undefined }
            val separator = if (sep !== Undefined) r.stringValue(sep) else null
            if (separator == "") {
                val size = minOf(value.length.toLong(), limit).toInt()
                if (size > 65_536) unsupported("Array size limit exceeded")
                val parts = MutableList<JsValue>(size) { i ->
                    r.tick(2)
                    if (value.length == 1) JsString(value) else {
                        r.allocate(1)
                        val char = value[i]
                        if (char.code < latin1Characters.size) latin1Characters[char.code] else JsString(char.toString())
                    }
                }
                r.allocate(size)
                return@Native JsArray(parts)
            }
            val parts = mutableListOf<JsValue>()
            fun addPart(start: Int, end: Int) {
                r.tick(end - start + 1)
                if (parts.size >= 65_536) unsupported("Array size limit exceeded")
                if (start == 0 && end == value.length) parts.add(JsString(value))
                else { r.allocate(end - start); parts.add(JsString(value.substring(start, end))) }
            }
            if (limit > 0) {
                if (separator == null) addPart(0, value.length)
                else {
                    var start = 0
                    while (parts.size.toLong() < limit) {
                        val end = r.find(value, separator, start)
                        if (end < 0) { addPart(start, value.length); break }
                        addPart(start, end)
                        start = end + separator.length
                    }
                }
            }
            r.allocate(parts.size)
            JsArray(parts)
        }
        "slice", "substring", "substr" -> Native { r, self, a ->
            val value = stringReceiver(r, self)
            val rawStart = a.getOrElse(0) { JsNumber(0.0) }
            var start = if (name == "substring") r.integer(rawStart).coerceIn(0, value.length) else r.relative(rawStart, value.length)
            var end = if (a.size < 2 || a[1] === Undefined) value.length else if (name == "slice") r.relative(a[1], value.length) else if (name == "substr") (start.toLong() + r.integer(a[1]).coerceAtLeast(0)).coerceAtMost(value.length.toLong()).toInt() else r.integer(a[1]).coerceIn(0, value.length)
            if (name == "substring" && start > end) { val temp = start; start = end; end = temp }
            r.tick(end.coerceAtLeast(start) - start)
            r.string(value.substring(start, end.coerceAtLeast(start)))
        }
        "charCodeAt", "charAt" -> Native { r, self, a -> val value = stringReceiver(r, self); val i = r.integer(a.getOrElse(0) { JsNumber(0.0) }); if (i !in value.indices) if (name == "charAt") JsString("") else JsNumber(Double.NaN) else if (name == "charAt") JsString(value[i].toString()) else JsNumber(value[i].code.toDouble()) }
        "indexOf", "lastIndexOf" -> Native { r, self, a ->
            val value = stringReceiver(r, self)
            val search = r.stringValue(a.getOrElse(0) { Undefined })
            val position = if (a.size < 2 || a[1] === Undefined) if (name == "indexOf") 0.0 else Double.POSITIVE_INFINITY else r.number(a[1])
            val from = if (name == "lastIndexOf" && position.isNaN()) value.length else integer(position).coerceIn(0, value.length)
            JsNumber(r.find(value, search, from, backwards = name == "lastIndexOf").toDouble())
        }
        "startsWith", "endsWith", "includes" -> Native { r, self, a ->
            val value = stringReceiver(r, self)
            if (a.firstOrNull() is RegexValue) throw JsThrown()
            val search = r.stringValue(a.getOrElse(0) { Undefined })
            if (name != "includes") r.tick(value.length)
            val pos = if (a.size < 2 || a[1] === Undefined) if (name == "endsWith") value.length else 0 else r.integer(a[1]).coerceIn(0, value.length)
            JsBoolean(when (name) { "startsWith" -> value.startsWith(search, pos); "endsWith" -> value.substring(0, pos).endsWith(search); else -> r.find(value, search, pos) >= 0 })
        }
        "replace" -> Native { r, self, a -> JsString(r.replace(self, a.getOrElse(0) { Undefined }, a.getOrElse(1) { Undefined })) }
        "toString", "valueOf" -> Native { _, self, _ -> self as? JsString ?: throw JsThrown() }
        else -> Undefined
    }
    }
    private fun binary(op: String, left: JsValue, right: JsValue): JsValue {
        if (analysis != null && (left is LinearValue || right is LinearValue)) {
            symbolicContext()
            return analysis.binary(this, op, left, right)
        }
        return rawBinary(op, left, right)
    }
    private fun rawBinary(op: String, left: JsValue, right: JsValue): JsValue = when (op) {
        "+" -> { if (left is JsDate || right is JsDate) unsupported("Default date coercion is unsupported"); val a = primitive(left); val b = primitive(right); if (a is JsString || b is JsString) { val x = text(a); val y = text(b); if (handlers > 0) analysis?.handlerAddition(x.length, JsString(y)); if (analysis == null && handlers > 0 && challenge != null && y == challenge && x.isNotEmpty()) unsupported("Transform entered an exception fallback"); if (x.length.toLong() + y.length > 65_536) unsupported("String size limit exceeded"); string(x + y) } else JsNumber(number(a) + number(b)) }
        "-" -> JsNumber(number(left) - number(right)); "*" -> JsNumber(number(left) * number(right)); "/" -> JsNumber(number(left) / number(right)); "%" -> JsNumber(number(left) % number(right)); "**" -> JsNumber(jsPow(number(left), number(right)))
        "^" -> JsNumber((int(left) xor int(right)).toDouble()); "&" -> JsNumber((int(left) and int(right)).toDouble()); "|" -> JsNumber((int(left) or int(right)).toDouble())
        "<<" -> JsNumber((int(left) shl (int(right) and 31)).toDouble()); ">>" -> JsNumber((int(left) shr (int(right) and 31)).toDouble()); ">>>" -> JsNumber((int(left).toUInt() shr (int(right) and 31)).toDouble())
        "==" -> JsBoolean(equal(left, right, false)); "!=" -> JsBoolean(!equal(left, right, false)); "===" -> JsBoolean(equal(left, right, true)); "!==" -> JsBoolean(!equal(left, right, true))
        "<", ">", "<=", ">=" -> {
            val a = primitive(left, PrimitiveHint.NUMBER); val b = primitive(right, PrimitiveHint.NUMBER)
            JsBoolean(if (a is JsString && b is JsString) { tick(minOf(a.value.length, b.value.length)); when (op) { "<" -> a.value < b.value; ">" -> a.value > b.value; "<=" -> a.value <= b.value; else -> a.value >= b.value } }
            else { val x = number(a); val y = number(b); when (op) { "<" -> x < y; ">" -> x > y; "<=" -> x <= y; else -> x >= y } })
        }
        "in" -> {
            if (right !is JsObject && right !is JsArray) {
                if (isRuntimeObject(right)) unsupported("Unsupported right-hand side of in")
                throw JsThrown()
            }
            val key = stringValue(left); tick(key.length)
            JsBoolean(when (right) {
                is JsObject -> when {
                    right.fields.containsKey(key) || key == "toString" || key == "valueOf" -> true
                    right.builtin != null || key in unsupportedObjectProperties -> unsupported("Unsupported object property presence")
                    else -> false
                }
                is JsArray -> when {
                    key == "length" || right.fields.containsKey(key) || arrayMethods.containsKey(key) -> true
                    key in unsupportedObjectProperties || key in unsupportedArrayProperties -> unsupported("Unsupported array property presence")
                    else -> index(key)?.let { it < right.values.size && right.values[it] !== Hole } ?: false
                }
            })
        }
        else -> unsupported("Unsupported operator '$op'")
    }
    private fun builtin(name: String): JsValue? = when (name) {
        "undefined" -> Undefined; "NaN" -> JsNumber(Double.NaN); "Infinity" -> JsNumber(Double.POSITIVE_INFINITY)
        "String" -> stringConstructor
        "Number" -> numberConstructor
        "Date" -> Native(constructible = true, callable = false) { _, _, a ->
            allocate(1)
            val value = (a.firstOrNull() as? JsString)?.value ?: unsupported("Only constant ISO dates are supported")
            JsDate(dates[value] ?: constantDates[value] ?: parseDate(value).also { if (constantDates.size < 256) constantDates[value] = it })
        }
        "Math" -> math
        "Array" -> Native(mapOf("isArray" to Native { _, _, a -> JsBoolean(a.firstOrNull() is JsArray) }), constructible = true) { r, _, a -> if (a.size == 1 && a[0] is JsNumber) { val n = number(a[0]); if (n != floor(n) || n < 0 || n > 65_536) unsupported("Array size limit exceeded"); r.allocate(n.toInt()); JsArray(MutableList(n.toInt()) { Hole }) } else r.array(a) }
        "Error", "TypeError", "RangeError" -> Native(constructible = true) { r, _, a -> JsObject(mutableMapOf("name" to JsString(name), "message" to JsString(if (a.isEmpty() || a[0] === Undefined) "" else r.stringValue(a[0]))), builtin = "Error") }
        "Object" -> objectConstructor
        else -> null
    }
    private val objectConstructor get() = Native(mapOf(
        "assign" to Native { r, _, a -> val target = a.firstOrNull() as? JsObject ?: unsupported("Unsupported Object.assign target"); a.drop(1).forEach { obj -> if (obj is JsObject) obj.fields.forEach { (k, v) -> r.set(target, k, v) } else if (obj !== JsNull && obj !== Undefined) unsupported("Unsupported Object.assign source") }; target }
    ), constructible = true) { _, _, a ->
        val value = a.getOrElse(0) { Undefined }
        if (value === JsNull || value === Undefined) JsObject() else if (value is JsObject || value is JsArray || value is JsFunction || value is Native) value else unsupported("Primitive object boxing is unsupported")
    }
    private val math get() =
        JsObject(
            mutableMapOf(
                "E" to JsNumber(2.718281828459045),
                "LN10" to JsNumber(2.302585092994046),
                "LN2" to JsNumber(0.6931471805599453),
                "LOG10E" to JsNumber(0.4342944819032518),
                "LOG2E" to JsNumber(1.4426950408889634),
                "PI" to JsNumber(3.141592653589793),
                "SQRT1_2" to JsNumber(0.7071067811865476),
                "SQRT2" to JsNumber(1.4142135623730951),
                "pow" to Native { r, _, a -> JsNumber(jsPow(r.number(a.getOrElse(0) { Undefined }), r.number(a.getOrElse(1) { Undefined }))) },
                "round" to Native { r, _, a -> JsNumber(jsRound(r.number(a.getOrElse(0) { Undefined }))) },
                "log" to Native { r, _, a -> JsNumber(ln(r.number(a.getOrElse(0) { Undefined }))) },
                "log2" to Native { r, _, a -> JsNumber(log2(r.number(a.getOrElse(0) { Undefined }))) },
                "sqrt" to Native { r, _, a -> JsNumber(sqrt(r.number(a.getOrElse(0) { Undefined }))) },
                "exp" to Native { r, _, a -> JsNumber(exp(r.number(a.getOrElse(0) { Undefined }))) },
                "sign" to
                    Native { r, _, a ->
                        val n = r.number(a.getOrElse(0) { Undefined })
                        JsNumber(if (n.isNaN() || n == 0.0) n else if (n < 0.0) -1.0 else 1.0)
                    },
                "imul" to Native { r, _, a -> JsNumber((r.int(a.getOrElse(0) { Undefined }) * r.int(a.getOrElse(1) { Undefined })).toDouble()) },
                "clz32" to Native { r, _, a -> JsNumber(r.int(a.getOrElse(0) { Undefined }).countLeadingZeroBits().toDouble()) },
                "floor" to Native { _, _, a -> JsNumber(floor(number(a.getOrElse(0) { Undefined }))) },
                "ceil" to Native { _, _, a -> JsNumber(ceil(number(a.getOrElse(0) { Undefined }))) },
                "abs" to Native { _, _, a -> JsNumber(abs(number(a.getOrElse(0) { Undefined }))) },
                "trunc" to
                    Native { _, _, a ->
                        val n = number(a.getOrElse(0) { Undefined })
                        JsNumber(if (n < 0) ceil(n) else floor(n))
                    },
                "max" to Native { _, _, a -> JsNumber(a.map(::number).maxOrNull() ?: Double.NEGATIVE_INFINITY) },
                "min" to Native { _, _, a -> JsNumber(a.map(::number).minOrNull() ?: Double.POSITIVE_INFINITY) },
            ).mapValuesTo(mutableMapOf()) { (name, value) -> if (value is Native) value.named(name) else value },
            "Math",
        )
}

private fun identifierProperty(name: String): Boolean = SourceIndex.identifier(name)

internal fun truth(value: JsValue): Boolean = when (value) { is JsBoolean -> value.value; is JsNumber -> value.value != 0.0 && !value.value.isNaN(); is JsString -> value.value.isNotEmpty(); is LinearString -> value.refs.isNotEmpty(); is LinearNumber -> linearReject("input-dependent control"); JsNull, Undefined, Hole -> false; else -> true }
internal fun primitive(value: JsValue): JsValue = when (value) { is JsDate -> JsNumber(value.time); is JsArray -> unsupported("Implicit array coercion is unsupported"); is JsObject -> unsupported("Implicit object coercion is unsupported"); is LinearValue -> linearReject("symbolic coercion"); else -> value }
internal fun number(value: JsValue): Double = when (val v = primitive(value)) { JsNull -> 0.0; Undefined, Hole -> Double.NaN; is JsNumber -> v.value; is JsBoolean -> if (v.value) 1.0 else 0.0; is JsString -> numericString(v.value); else -> Double.NaN }
private val decimalNumber = Regex("^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$")
private fun numericString(value: String): Double {
    val s = value.trim(::jsWhitespace)
    if (s.isEmpty()) return 0.0
    if (s == "Infinity" || s == "+Infinity") return Double.POSITIVE_INFINITY
    if (s == "-Infinity") return Double.NEGATIVE_INFINITY
    val radix = when { s.startsWith("0x", true) -> 16; s.startsWith("0b", true) -> 2; s.startsWith("0o", true) -> 8; else -> 0 }
    if (radix != 0) {
        if (s.length == 2) return Double.NaN
        val digitBits = when (radix) { 16 -> 4; 8 -> 3; else -> 1 }
        var significand = 0L
        var bits = 0
        var guard = false
        var sticky = false
        for (i in 2 until s.length) {
            val digit = when (val c = s[i]) { in '0'..'9' -> c - '0'; in 'a'..'f' -> c - 'a' + 10; in 'A'..'F' -> c - 'A' + 10; else -> return Double.NaN }
            if (digit >= radix) return Double.NaN
            for (shift in digitBits - 1 downTo 0) {
                val bit = (digit shr shift) and 1
                if (bits == 0 && bit == 0) continue
                bits++
                when {
                    bits <= 53 -> significand = (significand shl 1) or bit.toLong()
                    bits == 54 -> guard = bit != 0
                    bit != 0 -> sticky = true
                }
            }
        }
        if (bits <= 53) return significand.toDouble()
        if (bits > 1024) return Double.POSITIVE_INFINITY
        // Round the complete integer to nearest, ties to even, then scale by an exact power of two.
        if (guard && (sticky || significand and 1L != 0L)) significand++
        return significand.toDouble() * Double.fromBits((bits - 53 + 1023).toLong() shl 52)
    }
    if (!decimalNumber.matches(s)) return Double.NaN
    return s.toDoubleOrNull() ?: Double.NaN
}
internal fun int(value: JsValue): Int = int(number(value))
internal fun int(n: Double): Int { if (n >= -2147483648.0 && n < 2147483648.0) return n.toInt(); if (!n.isFinite() || n == 0.0) return 0; val t = if (n < 0) ceil(n) else floor(n); return (t % 4294967296.0).toLong().toInt() }
internal fun uint(value: Double): Long = int(value).toUInt().toLong()
internal fun integer(n: Double): Int { return when { n.isNaN() -> 0; n >= Int.MAX_VALUE -> Int.MAX_VALUE; n <= Int.MIN_VALUE -> Int.MIN_VALUE; else -> n.toInt() } }
internal fun relative(value: Double, length: Int): Int { val n = integer(value); return if (n < 0) (length.toLong() + n).coerceAtLeast(0).toInt() else n.coerceAtMost(length) }
internal fun index(key: String): Int? { if (key.isEmpty() || key.length > 10 || key.length > 1 && key[0] == '0' || key.any { it !in '0'..'9' }) return null; return key.toIntOrNull()?.takeIf { it >= 0 } }
internal fun text(value: JsValue): String = when (value) {
    is JsString -> value.value; JsNull -> "null"; Undefined -> "undefined"; is JsBoolean -> value.value.toString()
    is JsNumber -> value.value.let { n -> when { n.isNaN() -> "NaN"; n == Double.POSITIVE_INFINITY -> "Infinity"; n == Double.NEGATIVE_INFINITY -> "-Infinity"; n == 0.0 -> "0"; abs(n) <= 9007199254740991.0 && n == floor(n) -> n.toLong().toString(); else -> unsupported("Non-integer number string coercion is unsupported") } }
    is RegexValue -> unsupported("Regex string coercion requires bounded validation")
    is JsFunction -> value.code.sourceText() ?: unsupported("Function source text is unavailable")
    is Native -> "function ${value.functionName.orEmpty()}() { [native code] }"
    else -> unsupported("Unsupported string coercion")
}
internal fun equal(a: JsValue, b: JsValue, strict: Boolean): Boolean {
    if (a === b) return a !is JsNumber || !a.value.isNaN()
    if (a is JsNumber && b is JsNumber) return a.value == b.value
    if (a is JsString && b is JsString) return a.value == b.value
    if (a is JsBoolean && b is JsBoolean) return a.value == b.value
    if (!strict) {
        if (a === JsNull || a === Undefined || b === JsNull || b === Undefined) return (a === JsNull || a === Undefined) && (b === JsNull || b === Undefined)
        if ((a is JsArray || a is JsObject || a is JsFunction || a is Native || a is JsDate) && (b is JsString || b is JsNumber || b is JsBoolean) ||
            (b is JsArray || b is JsObject || b is JsFunction || b is Native || b is JsDate) && (a is JsString || a is JsNumber || a is JsBoolean)) unsupported("Implicit object equality coercion is unsupported")
        if (a is JsBoolean || b is JsBoolean || a is JsNumber && b is JsString || a is JsString && b is JsNumber) return number(a) == number(b)
    }
    return false
}

private val isoDate = Regex("^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})(?:\\.(\\d{3}))?(Z|[+-]\\d{2}:\\d{2})$")
private fun parseDate(value: String): Double {
    if (value.length !in 20..29) unsupported("Unsupported date literal")
    val match = isoDate.matchEntire(value) ?: unsupported("Unsupported date literal")
    val p = match.groupValues
    val year = p[1].toInt(); val month = p[2].toInt(); val day = p[3].toInt()
    if (year !in 1900..2100 || month !in 1..12 || day !in 1..31 || p[4].toInt() > 23 || p[5].toInt() > 59 || p[6].toInt() > 59) unsupported("Invalid date literal")
    fun daysBefore(y: Int): Int { val n = y - 1; return 365 * n + n / 4 - n / 100 + n / 400 }
    val months = intArrayOf(31, if (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    var days = daysBefore(year) - daysBefore(1970) + day - 1
    for (m in 1 until month) days += months[m - 1]
    val zone = p[8]
    if (zone != "Z" && (zone.substring(1, 3).toInt() > 23 || zone.substring(4, 6).toInt() > 59)) unsupported("Invalid date offset")
    val offset = if (zone == "Z") 0 else (zone.substring(1, 3).toInt() * 60 + zone.substring(4, 6).toInt()) * if (zone[0] == '-') -1 else 1
    return days * 86400000.0 + p[4].toInt() * 3600000.0 + (p[5].toInt() - offset) * 60000.0 + p[6].toInt() * 1000.0 + (p[7].toIntOrNull() ?: 0)
}
