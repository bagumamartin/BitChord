package meow.nyx.quackjs

internal class LinearNFailure(message: String) : Exception(message)
internal fun linearReject(reason: String): Nothing = throw LinearNFailure(reason)
internal sealed interface LinearValue : JsValue
internal class LinearString(val refs: IntArray) : LinearValue
internal class LinearNumber(val ref: Int) : LinearValue
internal data class LinearNResult(val plan: LinearNPlan?, val reason: String)

/** A length-specific DAG from AST execution, with guarded alphabet reads and no sampled values. */
internal class LinearNPlan(
    val length: Int,
    private val nodes: List<Node>,
    private val output: IntArray,
    private val unequal: List<Pair<IntArray, IntArray>>,
    private val nonNumeric: IntArray,
    val steps: Int,
    val allocation: Int,
) {
    internal data class Node(val op: String, val a: Int = 0, val b: Int = 0, val number: Double = 0.0, val table: String = "")
    val instructions: Int get() = nodes.size

    fun execute(input: String): String? {
        if (input.length != length) return null
        val values = DoubleArray(nodes.size)
        for (i in nodes.indices) {
            val node = nodes[i]
            values[i] = when (node.op) {
                "input" -> input[node.a].code.toDouble()
                "constant" -> node.number
                "+" -> values[node.a] + values[node.b]
                "-" -> values[node.a] - values[node.b]
                "*" -> values[node.a] * values[node.b]
                "%" -> values[node.a] % values[node.b]
                "index" -> node.table.indexOf(values[node.a].toInt().toChar()).toDouble()
                "lookup" -> {
                    val rank = values[node.a]
                    if (rank < 0 || rank >= node.table.length || rank != rank.toInt().toDouble()) return null
                    node.table[rank.toInt()].code.toDouble()
                }
                else -> error("Invalid linear instruction")
            }
        }
        for (ref in nonNumeric) {
            val char = values[ref].toInt().toChar()
            if (char in '0'..'9' || jsWhitespace(char)) return null
        }
        for ((left, right) in unequal) {
            if (left.indices.all { values[left[it]] == values[right[it]] }) return null
        }
        return buildString(output.size) { for (ref in output) append(values[ref].toInt().toChar()) }
    }
}

/** Unknown control, coercion, native calls and write positions stop analysis before publication. */
internal class LinearNAnalysis(private val length: Int) {
    private val nodes = mutableListOf<LinearNPlan.Node>()
    private val constants = mutableMapOf<Double, Int>()
    private var tableUnits = 0
    private val tables = mutableMapOf<String, String>()
    private val unequal = mutableListOf<Pair<IntArray, IntArray>>()
    private val nonNumeric = mutableListOf<Int>()
    private var guardUnits = 0
    private var inputRefs: IntArray? = null
    private fun add(node: LinearNPlan.Node): Int {
        if (nodes.size >= 20_000) linearReject("symbolic instruction limit")
        nodes.add(node)
        return nodes.lastIndex
    }
    private fun constant(value: Double): Int = constants.getOrPut(value) { add(LinearNPlan.Node("constant", number = value)) }
    private fun refs(value: JsValue): IntArray = when (value) {
        is LinearString -> value.refs
        is JsString -> {
            if (value.value.length > 65_536) linearReject("symbolic string size")
            IntArray(value.value.length) { constant(value.value[it].code.toDouble()) }
        }
        else -> linearReject("non-string output")
    }
    private fun numeric(value: JsValue): Int = when (value) {
        is LinearNumber -> value.ref
        is JsNumber -> constant(value.value)
        else -> linearReject("symbolic numeric coercion")
    }
    fun input(): LinearString = LinearString(inputRefs ?: IntArray(length) { add(LinearNPlan.Node("input", a = it)) }.also { inputRefs = it })

    private fun requireUnequal(left: IntArray, right: IntArray) {
        if (left.contentEquals(right)) linearReject("exception fallback")
        guardUnits += left.size + right.size
        if (unequal.size + nonNumeric.size >= 256 || guardUnits > 65_536) linearReject("symbolic guard limit")
        unequal.add(left to right)
    }

    fun handlerAddition(leftLength: Int, right: JsValue) {
        val rightLength = when (right) {
            is JsString -> right.value.length
            is LinearString -> right.refs.size
            else -> linearReject("handler string coercion")
        }
        if (leftLength != 0 && rightLength == length) requireUnequal(refs(right), input().refs)
    }

    fun binary(runtime: Runtime, op: String, a: JsValue, b: JsValue): JsValue {
        if (op in listOf("==", "===", "!=", "!==")) {
            val strict = op.length == 3
            fun stringLength(value: JsValue): Int? = when (value) {
                is LinearString -> value.refs.size
                is JsString -> value.value.length
                else -> null
            }
            val equal = when {
                a === JsNull || a === Undefined || b === JsNull || b === Undefined -> false
                a is LinearString && b is LinearString && a.refs.contentEquals(b.refs) -> true
                stringLength(a) != null && stringLength(b) != null && stringLength(a) != stringLength(b) -> false
                strict && (a is LinearString && b !is LinearString && b !is JsString || b is LinearString && a !is LinearString && a !is JsString) -> false
                strict && (a is LinearNumber && b !is LinearNumber && b !is JsNumber || b is LinearNumber && a !is LinearNumber && a !is JsNumber) -> false
                stringLength(a) != null && stringLength(b) != null -> {
                    val left = refs(a)
                    val right = refs(b)
                    // Choose the unequal path without a sample. Execution checks this path condition.
                    requireUnequal(left, right)
                    false
                }
                else -> linearReject("input-dependent comparison")
            }
            runtime.tick((stringLength(a) ?: 0) + (stringLength(b) ?: 0))
            return JsBoolean(if (op == "!=" || op == "!==") !equal else equal)
        }
        if (op == "+" && (a is LinearString || a is JsString) && (b is LinearString || b is JsString)) {
            val left = refs(a)
            val right = refs(b)
            if (runtime.handlingException) handlerAddition(left.size, b)
            runtime.allocate(left.size + right.size)
            return LinearString(left + right)
        }
        if (op !in listOf("+", "-", "*", "%")) linearReject("input-dependent operator $op")
        return LinearNumber(add(LinearNPlan.Node(op, numeric(a), numeric(b))))
    }

    fun primitiveArrayNaN(runtime: Runtime, array: JsArray): Boolean {
        if (!runtime.plainArrayNumberContext() || array.values.isEmpty() ||
            array.fields.keys.any { it == "valueOf" || it == "toString" || it == "join" }) return false
        val single = if (array.values.size == 1) array.values[0] as? LinearString else null
        if (array.values.size == 1 && single?.refs?.size != 1) return false
        var size = array.values.size - 1L
        for (item in array.values) {
            size += when (item) {
                is JsString -> item.value.length
                is LinearString -> item.refs.size
                Hole, Undefined, JsNull -> 0
                else -> return false
            }
            if (size > 65_536) return false
        }
        if (single != null) {
            // A one-unit string parses numerically only as an ASCII digit or JS whitespace.
            if (unequal.size + nonNumeric.size >= 256 || ++guardUnits > 65_536) linearReject("symbolic guard limit")
            nonNumeric.add(single.refs[0])
        }
        // Native valueOf, toString and join cost 25 steps and three call-allocation units.
        // Multiple entries force a comma; a single symbolic character has a checked NaN guard.
        runtime.tick(25 + array.values.size + size.toInt())
        repeat(3) { runtime.allocate(0) }
        runtime.allocate(size.toInt())
        return true
    }

    fun split(runtime: Runtime, value: LinearString, args: List<JsValue>): JsArray {
        if (args.size != 1 || args[0] != JsString("")) linearReject("symbolic split shape")
        val size = value.refs.size
        runtime.tick(2 * size)
        if (size != 1) repeat(size) { runtime.allocate(1) }
        runtime.allocate(size)
        return JsArray(MutableList(size) { LinearString(intArrayOf(value.refs[it])) })
    }

    fun join(runtime: Runtime, value: JsArray, separator: JsValue): LinearString? {
        if (value.values.none { it is LinearValue }) return null
        runtime.symbolicContext()
        if (separator != JsString("")) linearReject("symbolic join separator")
        runtime.tick(value.values.size)
        val output = mutableListOf<Int>()
        for (item in value.values) {
            if (item === Hole || item === Undefined || item === JsNull) continue
            output.addAll(refs(item).asList())
            if (output.size > 65_536) linearReject("symbolic output size")
        }
        runtime.allocate(output.size)
        return LinearString(output.toIntArray())
    }

    private fun alphabet(value: JsValue): String {
        val array = value as? JsArray ?: linearReject("non-array alphabet")
        if (array.values.size > 256) linearReject("alphabet size")
        val table = buildString(array.values.size) {
            for (item in array.values) {
                if (item !is JsString || item.value.length != 1) linearReject("mutable or non-character alphabet")
                append(item.value)
            }
        }
        return tables.getOrPut(table) {
            tableUnits += table.length
            if (tableUnits > 65_536) linearReject("symbolic table limit")
            table
        }
    }

    fun indexOf(runtime: Runtime, self: JsValue, args: List<JsValue>): LinearNumber {
        if (args.size != 1) linearReject("symbolic indexOf arguments")
        val value = args[0] as? LinearString ?: linearReject("non-character search")
        if (value.refs.size != 1) linearReject("non-character search")
        val table = alphabet(self)
        runtime.tick(table.length)
        val character = nodes[value.refs[0]]
        // The earlier lookup retains its range guard even if its character is no longer needed.
        if (character.op == "lookup" && character.table == table && table.toSet().size == table.length) {
            // indexOf returns positive zero even when the lookup used negative zero.
            return LinearNumber(add(LinearNPlan.Node("+", character.a, constant(0.0))))
        }
        return LinearNumber(add(LinearNPlan.Node("index", value.refs[0], table = table)))
    }

    fun lookup(runtime: Runtime, self: JsValue, key: JsValue): LinearString {
        val rank = key as? LinearNumber ?: linearReject("non-numeric lookup")
        val table = alphabet(self)
        // A valid integer index takes the numeric property path, without coercion or user code.
        runtime.tick()
        return LinearString(intArrayOf(add(LinearNPlan.Node("lookup", rank.ref, table = table))))
    }

    fun finish(value: JsValue, runtime: Runtime): LinearNResult {
        val output = refs(value)
        // Bound retained proofs across all 201 slots, independently of construction's transient limits.
        if (nodes.size + output.size + tableUnits + guardUnits > 8_192) linearReject("plan retained size")
        // Analysis charges the interpreter's concrete work and worst-case alphabet searches.
        // Plan execution is also bounded, including reads that do not reach the final output.
        val steps = runtime.chargedSteps.toLong() + nodes.sumOf { if (it.op == "index") it.table.length.toLong() else 1L } + output.size + guardUnits
        val allocation = runtime.chargedAllocation.toLong() + nodes.size + output.size + guardUnits + 2
        if (steps > 2_000_000 || allocation > 2_000_000) linearReject("plan resource bound")
        return LinearNResult(LinearNPlan(length, nodes.toList(), output, unequal.toList(), nonNumeric.toIntArray(), steps.toInt(), allocation.toInt()), "plan")
    }
}
