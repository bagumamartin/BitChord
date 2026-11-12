package meow.nyx.quackjs

internal sealed interface JsValue
internal data class JsString(val value: String) : JsValue
internal data class JsNumber(val value: Double) : JsValue
internal data class JsBoolean(val value: Boolean) : JsValue
internal data object JsNull : JsValue
internal data object Undefined : JsValue
internal data object Hole : JsValue
internal class JsObject(val fields: MutableMap<String, JsValue> = mutableMapOf(), val builtin: String? = null) : JsValue
internal class JsArray(val values: MutableList<JsValue>, val fields: MutableMap<String, JsValue> = mutableMapOf()) : JsValue
internal class JsFunction(val code: FunctionExpr, val env: Env) : JsValue
internal class Native(fields: Map<String, JsValue> = emptyMap(), val constructible: Boolean = false, val callable: Boolean = true, val functionName: String? = null, val invoke: (Runtime, JsValue, List<JsValue>) -> JsValue) : JsValue {
    val fields = fields.mapValues { (name, value) -> if (value is Native) value.named(name) else value }
    fun named(name: String): Native = if (functionName != null) this else Native(fields, constructible, callable, name, invoke)
}
internal class JsDate(val time: Double) : JsValue
internal class RegexValue(val source: String) : JsValue

internal sealed interface Completion {
    data object Normal : Completion
    data class Returned(val value: JsValue) : Completion
    data class Jumped(val isContinue: Boolean, val label: String?) : Completion
}
