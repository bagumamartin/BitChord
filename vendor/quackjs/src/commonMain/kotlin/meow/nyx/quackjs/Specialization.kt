package meow.nyx.quackjs

internal data class DispatchKey(val function: FunctionExpr, val first: Double, val second: Double)

/** Fold immutable numeric dispatcher inputs, never challenge strings or mutable global tables. */
internal fun specialize(code: FunctionExpr, first: Double, second: Double, runtime: Runtime): Block {
    if (code.usesArguments) return code.body
    val written = mutableSetOf<String>()
    val initialized = mutableMapOf<String, Int>()
    val pending = ArrayDeque<SyntaxNode>()
    pending.add(code.body)
    while (pending.isNotEmpty()) {
        val node = pending.removeLast()
        runtime.tick()
        when (node) {
            is Binary -> if (node.op in assignmentOperators && node.left is Id) written.add(node.left.name)
            is Update -> if (node.target is Id) written.add(node.target.name)
            is Vars -> for ((name, value) in node.items) if (value != null) initialized[name] = (initialized[name] ?: 0) + 1
            is TryStmt -> node.catchName?.let { written.add(it) }
            else -> Unit
        }
        // A nested closure may write a captured local. Its own names are conservatively excluded too.
        syntaxChildren(node) { pending.add(it) }
    }
    for ((name, count) in initialized) if (count > 1 || name in code.params) written.add(name)
    code.name?.let { written.add(it) }
    val constants = mutableMapOf<String, Lit>()
    code.params.getOrNull(0)?.takeIf { it !in written && code.params.lastIndexOf(it) == 0 }?.let { constants[it] = Lit(first) }
    code.params.getOrNull(1)?.takeIf { it !in written && code.params.lastIndexOf(it) == 1 }?.let { constants[it] = Lit(second) }

    fun fold(expr: Expr): Expr {
        runtime.tick()
        fun calculate(e: Expr): Expr = try {
            val value = runtime.expression(e)
            // String addition must retain the runtime exception-fallback check.
            if (e is Binary && e.op == "+" && value is JsString) e else Lit(value)
        } catch (_: UnsupportedPlayerException) { e } catch (_: JsThrown) { e }
        return when (expr) {
            is Id -> constants[expr.name] ?: expr
            is Unary -> {
                val child = fold(expr.expr)
                if (child is Lit && expr.op in setOf("!", "~", "+", "-", "void", "typeof")) calculate(Unary(expr.op, child)) else Unary(expr.op, child)
            }
            is Binary -> {
                val left = fold(expr.left)
                if (left is Lit) {
                    if (expr.op == "&&") return if (truth(left.value)) fold(expr.right) else left
                    if (expr.op == "||") return if (truth(left.value)) left else fold(expr.right)
                    if (expr.op == "??") return if (left.value === JsNull || left.value === Undefined) fold(expr.right) else left
                }
                val right = fold(expr.right)
                val binary = Binary(expr.op, left, right)
                if (left is Lit && right is Lit && expr.op !in assignmentOperators) calculate(binary) else binary
            }
            is Conditional -> {
                val test = fold(expr.test)
                if (test is Lit) fold(if (truth(test.value)) expr.yes else expr.no) else Conditional(test, fold(expr.yes), fold(expr.no))
            }
            is Member -> Member(fold(expr.target), fold(expr.key))
            is Call -> {
                val fn = fold(expr.fn)
                // A folded value expression must not acquire a method receiver.
                val callee = if (expr.fn !is Member && fn is Member) Binary(",", Lit(0.0), fn) else fn
                Call(callee, expr.args.map(::fold), expr.construct)
            }
            is Update -> Update(expr.op, fold(expr.target), expr.prefix)
            is ArrayExpr -> ArrayExpr(expr.items.map(::fold))
            is ObjectExpr -> ObjectExpr(expr.items.map { it.first to fold(it.second) })
            // Nested functions retain their own lexical bindings and captured values.
            else -> expr
        }
    }
    // Preserve declaration order: an earlier initializer can read a still-uninitialized later local.
    val prefix = mutableListOf<Vars>()
    for (stmt in code.body.statements) {
        if (stmt !is Vars) break
        prefix.add(Vars(stmt.items.map { (name, expr) ->
            val value = expr?.let(::fold)
            if (name !in written && value is Lit && (value.value is JsNumber || value.value is JsBoolean)) constants[name] = value
            name to value
        }))
    }
    fun statement(stmt: Stmt): Stmt = when (stmt) {
        is Block -> Block(stmt.statements.map(::statement))
        is ExpressionStmt -> ExpressionStmt(fold(stmt.expr))
        is Vars -> Vars(stmt.items.map { it.first to it.second?.let(::fold) })
        is IfStmt -> {
            val test = fold(stmt.test)
            if (test is Lit) (if (truth(test.value)) stmt.yes else stmt.no)?.let(::statement) ?: EmptyStmt
            else IfStmt(test, statement(stmt.yes), stmt.no?.let(::statement))
        }
        is ReturnStmt -> ReturnStmt(stmt.expr?.let(::fold))
        is ThrowStmt -> ThrowStmt(fold(stmt.expr))
        is Loop -> Loop(stmt.init?.let(::statement), stmt.test?.let(::fold), stmt.update?.let(::fold), statement(stmt.body), stmt.doFirst)
        is Label -> Label(stmt.name, statement(stmt.body))
        is TryStmt -> TryStmt(statement(stmt.body), stmt.catchName, stmt.handler?.let(::statement), stmt.finalizer?.let(::statement))
        is SwitchStmt -> SwitchStmt(fold(stmt.expr), stmt.cases.map { it.first?.let(::fold) to it.second.map(::statement) })
        else -> stmt
    }
    return Block(code.body.statements.mapIndexed { index, stmt -> prefix.getOrNull(index) ?: statement(stmt) })
}

internal fun syntaxChildren(node: SyntaxNode, child: (SyntaxNode) -> Unit) {
    fun optional(value: SyntaxNode?) { if (value != null) child(value) }
    when (node) {
        is Unary -> child(node.expr)
        is Binary -> { child(node.left); child(node.right) }
        is Conditional -> { child(node.test); child(node.yes); child(node.no) }
        is Member -> { child(node.target); child(node.key) }
        is Call -> { child(node.fn); node.args.forEach(child) }
        is Update -> child(node.target)
        is ArrayExpr -> node.items.forEach(child)
        is ObjectExpr -> node.items.forEach { child(it.second) }
        is FunctionExpr -> child(node.body)
        is Block -> node.statements.forEach(child)
        is ExpressionStmt -> child(node.expr)
        is Vars -> node.items.forEach { optional(it.second) }
        is IfStmt -> { child(node.test); child(node.yes); optional(node.no) }
        is ReturnStmt -> optional(node.expr)
        is ThrowStmt -> child(node.expr)
        is Loop -> { optional(node.init); optional(node.test); optional(node.update); child(node.body) }
        is Label -> child(node.body)
        is TryStmt -> { child(node.body); optional(node.handler); optional(node.finalizer) }
        is SwitchStmt -> { child(node.expr); node.cases.forEach { (key, statements) -> optional(key); statements.forEach(child) } }
        is Id, is Lit, is Jump, EmptyStmt -> Unit
    }
}
