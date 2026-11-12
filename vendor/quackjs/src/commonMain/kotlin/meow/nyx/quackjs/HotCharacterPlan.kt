package meow.nyx.quackjs

/** A single table-remapping callback shape, with live bindings and built-in-only calls. */
internal class HotCharacterPlan private constructor(
    private val code: FunctionExpr,
    private val table: Id,
    private val counter: Id,
    private val pushKey: Expr,
    private val indexKey: Expr,
    private val lengthKey: Expr,
) {
    private val steps = 25 + keySteps(pushKey) + 2 * keySteps(indexKey) + keySteps(lengthKey)

    fun execute(runtime: Runtime, env: Env): Boolean {
        fun read(id: Id): JsValue? = env.owner(id.name)?.get(id.name)
        val alphabet = read(table) as? JsArray ?: return false
        val owner = env.owner(counter.name) ?: return false
        val remaining = (owner[counter.name] as? JsNumber)?.value ?: return false
        val self = env.slots[code.thisSlot] as? JsArray ?: return false
        val value = env.slots[code.parameterSlots[0]] as? JsString ?: return false
        val positionValue = env.slots[code.parameterSlots[1]] as? JsNumber ?: return false
        val position = positionValue.value
        val target = env.slots[code.parameterSlots[2]] as? JsArray ?: return false
        if (value.value.length != 1 || position < 0 || position >= target.values.size || position != position.toInt().toDouble()) return false
        if (key(pushKey, env) != "push" || key(indexKey, env) != "indexOf" || key(lengthKey, env) != "length") return false
        if (self.fields.containsKey("push") || alphabet.fields.containsKey("indexOf")) return false

        // Charge the omitted statements/expressions; properties and native calls still charge normally.
        runtime.tick(steps)
        val push = runtime.get(self, "push")
        val first = (runtime.invoke(runtime.get(alphabet, "indexOf"), alphabet, listOf(value)) as JsNumber).value
        val second = (runtime.invoke(runtime.get(alphabet, "indexOf"), alphabet, listOf(runtime.property(self, positionValue))) as JsNumber).value
        owner[counter.name] = JsNumber(remaining - 1)
        val length = (runtime.get(alphabet, "length") as JsNumber).value
        val result = runtime.property(alphabet, JsNumber((first - second + position + remaining) % length))
        // Array reads precede both array writes, including aliased receivers.
        target.values[position.toInt()] = result
        runtime.invoke(push, self, listOf(result))
        return true
    }

    companion object {
        fun compile(code: FunctionExpr): HotCharacterPlan? {
            if (code.params.size != 3 || code.params.distinct().size != 3 || code.params.any { it == "this" || it == "arguments" || it == code.name }) return null
            val body = (code.body.statements.singleOrNull() as? ExpressionStmt)?.expr as? Call ?: return null
            if (body.construct || body.args.size != 1) return null
            val push = body.fn as? Member ?: return null
            if (push.target != Id("this")) return null
            val assignment = body.args.single() as? Binary ?: return null
            if (assignment.op != "=" || assignment.left != Member(Id(code.params[2]), Id(code.params[1]))) return null
            val lookup = assignment.right as? Member ?: return null
            val table = lookup.target as? Id ?: return null
            if (table.slot >= 0 || table.name == "this") return null
            val modulo = lookup.key as? Binary ?: return null
            if (modulo.op != "%") return null
            val length = modulo.right as? Member ?: return null
            if (length.target != table) return null
            val sum = modulo.left as? Binary ?: return null
            if (sum.op != "+") return null
            val decrement = sum.right as? Update ?: return null
            if (decrement.op != "--" || decrement.prefix) return null
            val counter = decrement.target as? Id ?: return null
            if (counter.slot >= 0 || counter.name == "this") return null
            val offset = sum.left as? Binary ?: return null
            if (offset.op != "+" || offset.right != Id(code.params[1])) return null
            val difference = offset.left as? Binary ?: return null
            if (difference.op != "-") return null
            val first = difference.left as? Call ?: return null
            val second = difference.right as? Call ?: return null
            if (first.construct || second.construct || first.args != listOf(Id(code.params[0])) || second.args != listOf(Member(Id("this"), Id(code.params[1])))) return null
            val index = first.fn as? Member ?: return null
            // The only omitted key expressions are primitive reads; none may observe the counter write.
            if (!listOf(push.key, index.key, length.key).all { supportedKey(it, counter.name) }) return null
            if (index.target != table || second.fn != index) return null
            return HotCharacterPlan(code, table, counter, push.key, index.key, length.key)
        }

        private fun supportedKey(expr: Expr, counter: String): Boolean {
            if (expr is Lit) return expr.value is JsString
            if (expr !is Member || expr.target !is Id || expr.target.name == counter) return false
            val index = expr.key
            if (index is Lit) return index.value is JsNumber
            return index is Binary && index.op == "^" && index.left is Id && index.left.name != counter && index.right is Lit && index.right.value is JsNumber
        }

        private fun keySteps(expr: Expr): Int = if (expr is Lit) 1 else if ((expr as Member).key is Lit) 4 else 6

        // A guard never resolves globals, coerces objects, calls code, charges work, or changes state.
        private fun key(expr: Expr, env: Env): String? {
            if (expr is Lit) return (expr.value as? JsString)?.value
            val member = expr as Member
            val table = env.owner((member.target as Id).name)?.get(member.target.name) as? JsArray ?: return null
            val index = member.key
            val number = if (index is Lit) (index.value as JsNumber).value else {
                index as Binary
                val id = index.left as Id
                val value = env.owner(id.name)?.get(id.name) as? JsNumber ?: return null
                (int(value) xor int((index.right as Lit).value)).toDouble()
            }
            if (number < 0 || number >= table.values.size || number != number.toInt().toDouble()) return null
            return (table.values[number.toInt()] as? JsString)?.value
        }
    }
}
