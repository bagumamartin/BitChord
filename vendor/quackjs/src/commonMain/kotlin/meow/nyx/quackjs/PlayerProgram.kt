package meow.nyx.quackjs

/** Optional, externally supplied landmarks from a known player configuration. */
public data class PlayerHints(val signatureExpression: String, val nClass: String, val signatureTimestamp: Int)

public class UnsupportedPlayerException(message: String) : IllegalArgumentException(message)

/** An immutable player slice. Every invocation owns its globals, arrays and execution budget. */
public class PlayerProgram private constructor(
    private val source: SourceIndex,
    private val signature: Expr,
    private val nPlan: NPlan,
    private val parsed: Map<String, Expr>,
    private val templates: Map<String, JsValue>,
    private val dates: Map<String, Double>,
    private val dispatch: Map<DispatchKey, Block>,
    private val globalCount: Int,
    public val signatureTimestamp: Int?,
) {
    public fun decipherSignature(input: String): String = run(input) { runtime ->
        runtime.expression(signature, mapOf("INPUT" to JsString(input)))
    }

    // Each lazy publishes one immutable proof; callers never share interpreter state or outputs.
    private val linearPlans = Array(201) { length -> lazy { deriveLinearN(length) } }

    public fun transformN(input: String): String {
        if (input.length <= 200) linearPlans[input.length].value.plan?.execute(input)?.let { return it }
        return transformNInterpreted(input)
    }

    internal fun transformNInterpreted(input: String): String = run(input) { runtime -> nPlan.execute(runtime, input) }
    internal fun linearNResult(length: Int): LinearNResult = linearPlans[length].value
    private fun deriveLinearN(length: Int): LinearNResult {
        val analysis = LinearNAnalysis(length)
        val runtime = Runtime(source, parsed, templates, dates, dispatch, globalCount = globalCount, analysis = analysis)
        return try {
            analysis.finish(nPlan.execute(runtime, ""), runtime)
        } catch (error: LinearNFailure) {
            LinearNResult(null, (error.message ?: "analysis failed").take(160))
        } catch (error: UnsupportedPlayerException) {
            LinearNResult(null, (error.message ?: "interpreter limit").take(160))
        } catch (_: JsThrown) {
            LinearNResult(null, "JavaScript exception")
        }
    }

    private inline fun run(input: String, transform: (Runtime) -> JsValue): String {
        if (input.length > 16_384) unsupported("Challenge length limit exceeded")
        try {
            val output = transform(Runtime(source, parsed, templates, dates, dispatch, globalCount = globalCount).also { it.challenge = input })
            if (output !is JsString) unsupported("Transform did not return a string")
            if (output.value.length > 65_536) unsupported("Transform output limit exceeded")
            return output.value
        } catch (error: JsThrown) {
            unsupported("Transform threw: ${if (error.value is JsString) error.value.value.take(160) else "JavaScript exception"}")
        }
    }

    public companion object {
        /** Compile a dispatcher/table-based player without running its browser initialization.
         * Throws [UnsupportedPlayerException] for unsupported dependencies or resource limits.
         * Source is capped at 8 Mi UTF-16 units; individual challenges at 16,384 units.
         */
        public fun compile(playerJs: String, hints: PlayerHints? = null): PlayerProgram {
            if (playerJs.length > 8 * 1024 * 1024) unsupported("Player source limit exceeded")
            val source = SourceIndex(playerJs, hints?.nClass)
            val derived = hints ?: source.derivedHints!!
            if (derived.signatureExpression.length > 512) unsupported("Signature expression limit exceeded")
            val signature = Parser(Lexer(derived.signatureExpression).tokens(), derived.signatureExpression, source.compilationBudget).completeExpression()
            validateSignatureExpression(signature)
            try {
                val plan = discoverN(source, derived.nClass, Runtime(source, recordDispatch = true, compilationBudget = source.compilationBudget))
                val runtime = Runtime(source, recordDispatch = true, compilationBudget = source.compilationBudget)
                // Publish only dependencies used by the selected plan, after discarded probes.
                plan.execute(runtime, "KdrqFlzJXl9EcCwlmEy")
                val result = runtime.expression(signature, mapOf("INPUT" to JsString("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")))
                if (result !is JsString) unsupported("Signature transform did not return a string")
                val parsed = runtime.definitions.toMap()
                val initializer = Runtime(source)
                val templates = buildMap {
                    for ((name, expr) in parsed) if (templateSafe(expr)) put(name, initializer.expression(expr))
                }
                val dispatch = runtime.specializedBodies!!.toMap()
                val globals = parsed.keys.withIndex().associate { it.value to it.index }
                val pending = ArrayDeque<SyntaxNode>()
                pending.addAll(parsed.values)
                pending.addAll(listOf(signature, plan.function, plan.constructor, plan.setter))
                pending.addAll(dispatch.values)
                while (pending.isNotEmpty()) {
                    val node = pending.removeLast()
                    if (node is Id && node.free) node.globalSlot = globals[node.name] ?: -1
                    syntaxChildren(node) { pending.add(it) }
                }
                source.releaseCompileState()
                return PlayerProgram(source, signature, plan, parsed, templates, runtime.constantDates.toMap(), dispatch, globals.size, hints?.signatureTimestamp ?: source.signatureTimestamp)
            } catch (error: JsThrown) {
                unsupported("Player initialization failed: ${if (error.value is JsString) error.value.value.take(160) else "JavaScript exception"}")
            }
        }

        private fun validateSignatureExpression(expr: Expr) {
            fun argument(e: Expr): Boolean = e == Id("INPUT") || e is Lit && e.value is JsNumber || e is Unary && e.op in setOf("+", "-") && argument(e.expr)
            if (expr !is Call || expr.construct || expr.fn !is Id || expr.args.count { it == Id("INPUT") } != 1 || !expr.args.all(::argument)) {
                unsupported("Signature hint must be a function call with numeric arguments and INPUT")
            }
        }
    }
}

// Cache only closed, side-effect-free initializers. Aliases must still resolve against live globals.
private fun templateSafe(expr: Expr): Boolean = when (expr) {
    is Lit, is FunctionExpr -> true
    is ArrayExpr -> expr.items.all(::templateSafe)
    is ObjectExpr -> expr.items.all { templateSafe(it.second) }
    is Call -> !expr.construct && expr.fn is Member && expr.fn.target is Lit && expr.fn.target.value is JsString && expr.fn.key == Lit("split") && expr.args.all { it is Lit }
    else -> false
}

private val RootArgument = Id("<n-root>")
private fun nArguments(runtime: Runtime, arguments: List<Expr>, root: JsObject): List<JsValue> =
    arguments.map { runtime.expression(it, mapOf(RootArgument.name to root)) }

private data class NPlan(val function: FunctionExpr, val arguments: List<Expr>, val selfRoot: Boolean, val mapKey: String, val constructor: FunctionExpr, val setter: FunctionExpr) {
    fun execute(runtime: Runtime, input: String): JsValue {
        runtime.challenge = input
        val root = makeRoot(runtime, constructor, mapKey, input, setter)
        val args = arguments.map {
            when {
                it is Lit -> { runtime.tick(); it.value }
                it === RootArgument -> { runtime.tick(); root }
                else -> runtime.expression(it, mapOf(RootArgument.name to root))
            }
        }
        runtime.invoke(runtime.function(function), if (selfRoot) root else Undefined, args)
        return (root.fields[mapKey] as? JsObject)?.fields?.get("n") ?: unsupported("n transform removed its result")
    }
}

private fun makeRoot(runtime: Runtime, constructor: FunctionExpr, mapKey: String?, input: String, setter: FunctionExpr): JsObject {
    val root = JsObject()
    runtime.invoke(runtime.function(constructor), root, listOf(JsString(""), JsBoolean(true)))
    root.fields["set"] = runtime.function(setter)
    if (mapKey != null) {
        val map = root.fields[mapKey] as? JsObject ?: unsupported("Unsupported n parameter table")
        map.fields["n"] = runtime.input(input)
    }
    return root
}

/** Follow only calls receiving the URL instance, then execute the n-table update in isolation. */
private fun discoverN(source: SourceIndex, name: String, runtime: Runtime): NPlan {
    val budget = runtime.compilationBudget
    val constructor = source.classFunction(name, budget)
    val getter = source.method(name, "get", runtime)
    val setter = source.method(name, "set", runtime)
    val initial = makeRoot(runtime, constructor, null, "", setter)
    val tables = initial.fields.filterValues { it is JsObject }.keys
    if (tables.size != 1) unsupported("Cannot identify n parameter table")
    val mapKey = tables.single()
    data class Candidate(val function: FunctionExpr, val args: List<Expr>, val selfRoot: Boolean, val level: Int, val label: String)
    data class Key(val label: String, val args: List<Expr>, val selfRoot: Boolean)
    val pending = mutableListOf(
        Candidate(constructor, listOf(Lit(""), Lit(true)), true, 0, "constructor"),
        Candidate(getter, listOf(Lit("n")), true, 0, "getter"),
    )
    val seen = mutableSetOf<Key>()
    val probe = "KdrqFlzJXl9EcCwlmEy"
    var cursor = 0
    var selected: Pair<Key, NPlan>? = null
    var lastError = "No n-table update found"
    while (cursor < pending.size) {
        if (pending.size > 64) unsupported("n discovery dependency limit exceeded")
        val candidate = pending[cursor++]
        if (candidate.level > 8) continue
        val key = Key(candidate.label, candidate.args, candidate.selfRoot)
        if (!seen.add(key)) {
            if (selected?.first == key) unsupported("Ambiguous repeated n-table updates")
            continue
        }
        val root = makeRoot(runtime, constructor, mapKey, probe, setter)
        runtime.challenge = probe
        val args = nArguments(runtime, candidate.args, root)
        var conflicting = false
        if (candidate.label != "constructor") {
            try {
                runtime.invoke(runtime.function(candidate.function), if (candidate.selfRoot) root else Undefined, args)
                val result = (root.fields[mapKey] as? JsObject)?.fields?.get("n")
                if (result is JsString && result.value != probe) {
                    val plan = NPlan(candidate.function, candidate.args, candidate.selfRoot, mapKey, constructor, setter)
                    val second = plan.execute(runtime, "0123456789abcdefghijklmno")
                    if (second is JsString && second.value != "0123456789abcdefghijklmno" && second.value.length < 256) {
                        if (selected != null) conflicting = true else selected = key to plan
                    }
                }
            } catch (error: UnsupportedPlayerException) { lastError = error.message ?: lastError }
            catch (_: JsThrown) { /* URL-only dependencies are not part of the transform. */ }
        }
        if (conflicting) unsupported("Ambiguous n-table updates")
        if (selected?.first == key) continue
        val cleanRoot = makeRoot(runtime, constructor, mapKey, probe, setter)
        val env = runtime.functionEnv(runtime.function(candidate.function), if (candidate.selfRoot) cleanRoot else Undefined, nArguments(runtime, candidate.args, cleanRoot))
        val bindings = mutableMapOf<String, Expr>("this" to if (candidate.selfRoot) RootArgument else Lit(Undefined))
        candidate.function.params.forEachIndexed { i, name -> bindings[name] = candidate.args.getOrElse(i) { Lit(Undefined) } }
        // Preserve input-derived expressions while folding the dispatcher prefix.
        val prefix = mutableSetOf<Vars>()
        for (stmt in candidate.function.body.statements) {
            if (stmt !is Vars) break
            if (stmt.items.any { it.second != null && !constant(it.second!!) }) break
            for ((name, expr) in stmt.items) if (expr != null) {
                val bound = substitute(expr, bindings, env, budget)
                if (bound == null) bindings.remove(name)
                else { validateDepth(bound, budget); bindings[name] = bound }
            }
            runtime.exec(stmt, env)
            prefix.add(stmt)
        }
        val rootNames = bindings.filterValues { it == RootArgument }.keys.toSet()
        val dynamic = bindings.filterValues { dependsOnRoot(it, budget) }.keys.toMutableSet()
        fun rootArgument(expr: Expr): Boolean = when (expr) {
            is Id -> expr.name in rootNames
            is Conditional -> rootArgument(expr.yes) || rootArgument(expr.no)
            is Binary -> if (expr.op in setOf("&&", "||", "??")) rootArgument(expr.left) || rootArgument(expr.right) else expr.op in setOf(",", "=") && rootArgument(expr.right)
            is ArrayExpr -> expr.items.any(::rootArgument)
            is ObjectExpr -> expr.items.any { rootArgument(it.second) }
            is Call -> expr.args.any(::rootArgument)
            else -> false
        }
        var rootWrite = false
        var discardedWrite = false
        var unresolvedRootCalls = 0
        val discovered = mutableListOf<Candidate>()
        // Invalidate bindings in order; a later write must not change an earlier call site.
        walk(candidate.function.body, runtime, env, dynamic, write = { target ->
            if (target is Id) {
                if (env.owner(target.name)?.frame == null) discardedWrite = true
                bindings.remove(target.name); dynamic.add(target.name)
            } else if (target is Member) {
                var base: Expr = target
                while (base is Member) base = base.target
                val bound = substitute(base, bindings, env, budget)
                // Dropping global writes or n-table writes can change a helper's input state.
                if (bound != RootArgument && (bound !is Id || env.owner(bound.name)?.frame == null)) discardedWrite = true
                val written = target.target.let { substitute(it, bindings, env, budget) }
                if (written == Member(RootArgument, Lit(mapKey))) discardedWrite = true
                if (substitute(target, bindings, env, budget) == Member(Member(RootArgument, Lit(mapKey)), Lit("n"))) rootWrite = true
            }
        }, prefix = prefix) { call, guards ->
            var target = call.fn
            var selfRoot = false
            var argExprs = call.args
            if (discovered.isNotEmpty() && target is Member && rootArgument(target.target)) {
                unresolvedRootCalls++
                return@walk
            }
            if (target !is Id && !(target is Member && target.target is Id && target.key in setOf(Lit("call"), Lit("apply")))) return@walk
            val rootTail = discovered.isNotEmpty() && argExprs.any(::rootArgument)
            if (rootTail) unresolvedRootCalls++
            if (target is Member && target.key == Lit("call") && target.target is Id && argExprs.isNotEmpty()) {
                if (!constant(argExprs.first())) return@walk
                val self = substitute(argExprs.first(), bindings, env, budget) ?: return@walk
                if (self != RootArgument && self != Lit(Undefined)) return@walk
                selfRoot = self == RootArgument
                argExprs = argExprs.drop(1); target = target.target
            }
            if (target !is Id || call.construct || env.owner(target.name)?.frame != null || target.name in dynamic) return@walk
            if (!argExprs.all(::constant)) return@walk
            val boundArgs = argExprs.map { substitute(it, bindings, env, budget) ?: return@walk }
            boundArgs.forEach { validateDepth(it, budget) }
            val values = try { nArguments(runtime, boundArgs, cleanRoot) } catch (_: JsThrown) { return@walk } catch (_: UnsupportedPlayerException) { return@walk }
            if (!selfRoot && values.none { it === cleanRoot }) {
                if (rootTail && values.all { it is JsNumber || it is JsString || it is JsBoolean || it === Undefined || it === JsNull }) unresolvedRootCalls--
                return@walk
            }
            if (values.any { it !== cleanRoot && it !is JsNumber && it !is JsString && it !is JsBoolean && it !== Undefined && it !== JsNull }) return@walk
            val fn = try { runtime.resolve(target.name) } catch (_: UnsupportedPlayerException) { return@walk }
            if (fn !is JsFunction) return@walk
            for (guard in guards) {
                val bound = substitute(guard, bindings, env, budget)
                if (bound != null) validateDepth(bound, budget)
                if (bound == null || inputDependentGuard(bound, runtime, mapKey)) {
                    lastError = "Cannot discard input-dependent n control flow"
                    return@walk
                }
            }
            if (pending.size + discovered.size >= 64) unsupported("n discovery dependency limit exceeded")
            discovered.add(Candidate(fn.code, boundArgs, selfRoot, candidate.level + 1, target.name))
            if (rootTail) unresolvedRootCalls--
        }
        // An unbound or guarded second root call may overwrite an earlier helper's result.
        if (!rootWrite && !discardedWrite && unresolvedRootCalls == 0) pending.addAll(discovered)
    }
    return selected?.second ?: unsupported("Cannot isolate n transform: $lastError")
}

private fun constant(expr: Expr): Boolean = when (expr) {
    is Lit, is Id -> true
    is Unary -> expr.op in setOf("!", "~", "+", "-", "typeof", "void") && constant(expr.expr)
    is Binary -> expr.op !in assignmentOperators && constant(expr.left) && constant(expr.right)
    is Member -> constant(expr.target) && constant(expr.key)
    is Conditional -> constant(expr.test) && constant(expr.yes) && constant(expr.no)
    else -> false
}

private fun substitute(expr: Expr, bindings: Map<String, Expr>, env: Env, budget: CompilationBudget): Expr? {
    budget.step()
    if (expr !is Lit && expr !is Id) budget.reserveSyntax(1)
    fun child(e: Expr): Expr? = substitute(e, bindings, env, budget)
    return when (expr) {
        is Lit -> expr
        is Id -> bindings[expr.name] ?: expr.takeIf { env.owner(expr.name)?.frame == null }
        is Unary -> Unary(expr.op, child(expr.expr) ?: return null)
        is Binary -> Binary(expr.op, child(expr.left) ?: return null, child(expr.right) ?: return null)
        is Member -> Member(child(expr.target) ?: return null, child(expr.key) ?: return null)
        is Conditional -> Conditional(child(expr.test) ?: return null, child(expr.yes) ?: return null, child(expr.no) ?: return null)
        is Call -> Call(child(expr.fn) ?: return null, expr.args.map { child(it) ?: return null }, expr.construct)
        else -> null
    }
}

private fun dependsOnRoot(expr: Expr, budget: CompilationBudget): Boolean {
    budget.step()
    return when (expr) {
        is Id -> expr == RootArgument
        is Unary -> dependsOnRoot(expr.expr, budget)
        is Binary -> dependsOnRoot(expr.left, budget) || dependsOnRoot(expr.right, budget)
        is Member -> dependsOnRoot(expr.target, budget) || dependsOnRoot(expr.key, budget)
        is Conditional -> dependsOnRoot(expr.test, budget) || dependsOnRoot(expr.yes, budget) || dependsOnRoot(expr.no, budget)
        else -> false
    }
}

private fun inputDependentGuard(expr: Expr, runtime: Runtime, mapKey: String): Boolean {
    fun rootPath(e: Expr): List<String>? {
        if (e == RootArgument) return emptyList()
        if (e !is Member) return null
        val parent = rootPath(e.target) ?: return null
        if (!constant(e.key) || dependsOnRoot(e.key, runtime.compilationBudget)) return null
        val key = try { text(runtime.expression(e.key)) } catch (_: UnsupportedPlayerException) { return null } catch (_: JsThrown) { return null }
        return parent + key
    }
    fun sensitive(e: Expr): Boolean {
        rootPath(e)?.let { return it.isEmpty() || it.first() == mapKey && (it.size == 1 || it[1] == "n") }
        return when (e) {
            is Lit, is Id -> false
            is Unary -> sensitive(e.expr)
            is Binary -> sensitive(e.left) || sensitive(e.right)
            is Member -> sensitive(e.target) || sensitive(e.key)
            is Conditional -> sensitive(e.test) || sensitive(e.yes) || sensitive(e.no)
            is Call -> e.fn.let { it is Member && rootPath(it.target)?.isEmpty() == true } || sensitive(e.fn) || e.args.any(::sensitive)
            else -> true
        }
    }
    return sensitive(expr)
}

private fun knownTruth(expr: Expr, runtime: Runtime, env: Env, dynamic: Set<String>): Boolean? {
    if (expr is Binary && expr.op == "&&") {
        val left = knownTruth(expr.left, runtime, env, dynamic)
        return if (left == false) false else if (left == true) knownTruth(expr.right, runtime, env, dynamic) else null
    }
    if (expr is Binary && expr.op == "||") {
        val left = knownTruth(expr.left, runtime, env, dynamic)
        return if (left == true) true else if (left == false) knownTruth(expr.right, runtime, env, dynamic) else null
    }
    fun independent(e: Expr): Boolean = when (e) {
        is Lit -> true
        is Id -> env.owner(e.name)?.get(e.name).let { value ->
            if (env.owner(e.name)?.frame != null) e.name !in dynamic && value !== Undefined && value !is JsObject && value !is JsArray else runtime.source.hasDefinition(e.name)
        }
        is Member -> independent(e.target) && independent(e.key)
        is Unary -> constant(e) && independent(e.expr)
        is Binary -> constant(e) && independent(e.left) && independent(e.right)
        else -> false
    }
    if (!independent(expr)) return null
    return try { truth(runtime.eval(expr, env)) } catch (_: UnsupportedPlayerException) { null } catch (_: JsThrown) { null }
}

private data class DiscoveryFlow(val guards: List<Expr> = emptyList(), val exits: Boolean = false) {
    init { if (guards.size > 128) unsupported("n control-flow limit exceeded") }
}

private fun walk(stmt: Stmt, runtime: Runtime, env: Env, dynamic: Set<String>, guards: List<Expr> = emptyList(), write: (Expr) -> Unit = {}, prefix: Set<Vars> = emptySet(), visit: (Call, List<Expr>) -> Unit): DiscoveryFlow {
    if (guards.size > 128) unsupported("n control-flow limit exceeded")
    fun expr(e: Expr, path: List<Expr> = guards) { walkExpression(e, runtime, env, dynamic, path, write, visit) }
    fun child(s: Stmt, path: List<Expr> = guards): DiscoveryFlow = walk(s, runtime, env, dynamic, path, write, prefix, visit)
    when (stmt) {
        is Block -> {
            val tail = mutableListOf<Expr>()
            for (s in stmt.statements) {
                val flow = child(s, guards + tail)
                tail.addAll(flow.guards)
                if (tail.size > 128) unsupported("n control-flow limit exceeded")
                if (flow.exits) return DiscoveryFlow(tail, true)
            }
            return DiscoveryFlow(tail)
        }
        is ExpressionStmt -> expr(stmt.expr)
        is Vars -> stmt.items.forEach { (name, value) -> if (value != null) { expr(value); if (stmt !in prefix) write(Id(name)) } }
        is IfStmt -> {
            expr(stmt.test)
            val known = knownTruth(stmt.test, runtime, env, dynamic)
            if (known == true) return child(stmt.yes)
            if (known == false) return stmt.no?.let { child(it) } ?: DiscoveryFlow()
            val path = guards + stmt.test
            val yes = child(stmt.yes, path)
            val no = stmt.no?.let { child(it, path) } ?: DiscoveryFlow()
            val tail = if (yes.exits || no.exits || yes.guards.isNotEmpty() || no.guards.isNotEmpty()) listOf(stmt.test) + yes.guards + no.guards else emptyList()
            return DiscoveryFlow(tail, yes.exits && no.exits)
        }
        is ReturnStmt -> { stmt.expr?.let { expr(it) }; return DiscoveryFlow(exits = true) }
        is ThrowStmt -> { expr(stmt.expr); return DiscoveryFlow(exits = true) }
        is Jump -> return DiscoveryFlow(exits = true)
        is Loop -> {
            stmt.init?.let { child(it) }; stmt.test?.let { expr(it) }
            val known = stmt.test?.let { knownTruth(it, runtime, env, dynamic) }
            // Isolating one call cannot preserve a loop's iteration count or loop-carried writes.
            val path = guards + if (stmt.test != null && known == null) stmt.test else RootArgument
            stmt.update?.let { expr(it, path) }
            if (stmt.test == null || known != false) {
                val body = child(stmt.body, path)
                if (body.exits || body.guards.isNotEmpty()) return DiscoveryFlow(listOfNotNull(stmt.test) + body.guards)
            }
        }
        is Label -> return child(stmt.body)
        is TryStmt -> {
            val body = child(stmt.body)
            val handler = stmt.handler?.let { child(it, guards + RootArgument) }
            val finalizer = stmt.finalizer?.let { child(it) }
            return DiscoveryFlow(body.guards + handler?.guards.orEmpty() + finalizer?.guards.orEmpty(), finalizer?.exits == true || body.exits && (handler == null || handler.exits))
        }
        is SwitchStmt -> {
            expr(stmt.expr)
            val flows = stmt.cases.map { (key, body) -> key?.let { expr(it) }; child(Block(body), guards + stmt.expr) }
            val tail = if (flows.any { it.exits || it.guards.isNotEmpty() }) listOf(stmt.expr) + flows.flatMap { it.guards } else emptyList()
            return DiscoveryFlow(tail, stmt.cases.any { it.first == null } && flows.all { it.exits })
        }
        else -> Unit
    }
    return DiscoveryFlow()
}
private fun walkExpression(e: Expr, runtime: Runtime, env: Env, dynamic: Set<String>, guards: List<Expr>, write: (Expr) -> Unit, visit: (Call, List<Expr>) -> Unit) {
    if (guards.size > 128) unsupported("n control-flow limit exceeded")
    fun child(expr: Expr, path: List<Expr> = guards) { walkExpression(expr, runtime, env, dynamic, path, write, visit) }
    when (e) {
        is Call -> { visit(e, guards); child(e.fn); e.args.forEach { child(it) } }
        is Unary -> { child(e.expr); if (e.op == "delete") write(e.expr) }
        is Binary -> {
            child(e.left)
            val logical = e.op == "&&" || e.op == "||"
            val known = if (logical) knownTruth(e.left, runtime, env, dynamic) else null
            if (!(e.op == "&&" && known == false || e.op == "||" && known == true)) child(e.right, if (logical && known == null) guards + e.left else guards)
            if (e.op in assignmentOperators) write(e.left)
        }
        is Conditional -> {
            child(e.test)
            val known = knownTruth(e.test, runtime, env, dynamic)
            val path = if (known == null) guards + e.test else guards
            if (known != false) child(e.yes, path)
            if (known != true) child(e.no, path)
        }
        is Member -> { child(e.target); child(e.key) }
        is Update -> { child(e.target); write(e.target) }
        is ArrayExpr -> e.items.forEach { child(it) }
        is ObjectExpr -> e.items.forEach { child(it.second) }
        is FunctionExpr -> {
            // A closure can change a substituted outer local before the isolated call.
            val pending = ArrayDeque<SyntaxNode>()
            pending.add(e.body)
            while (pending.isNotEmpty()) {
                val node = pending.removeLast()
                val target = when (node) {
                    is Binary -> if (node.op in assignmentOperators) node.left else null
                    is Update -> node.target
                    is Unary -> if (node.op == "delete") node.expr else null
                    else -> null
                }
                var base = target
                while (base is Member) base = base.target
                if (base is Id && base.slot < 0 && target != null) write(target)
                syntaxChildren(node) { pending.add(it) }
            }
        }
        else -> Unit
    }
}
