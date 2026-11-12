package meow.nyx.quackjs

internal class CompilationBudget {
    private var work = 0
    private var syntax = 0
    fun step() {
        if (work >= 2_000_000) unsupported("Compilation work limit exceeded")
        work++
    }
    // Reserve by token count before parsing, including copies of overlapping definitions.
    fun reserveSyntax(tokens: Int) {
        if (tokens > 500_000 - syntax) unsupported("Compilation allocation limit exceeded")
        syntax += tokens
    }
}

/** Left-associative chains do not consume parser recursion, but still need an AST depth cap. */
internal fun validateDepth(root: Expr, budget: CompilationBudget = CompilationBudget()) {
    val pending = ArrayDeque<Pair<SyntaxNode, Int>>()
    pending.addLast(root to 0)
    var nodes = 0
    while (pending.isNotEmpty()) {
        val (node, depth) = pending.removeLast()
        budget.step()
        if (++nodes > 150_000) unsupported("Syntax tree node limit exceeded")
        if (depth > 128) unsupported("Syntax tree depth limit exceeded")
        syntaxChildren(node) { pending.addLast(it to depth + 1) }
    }
}
