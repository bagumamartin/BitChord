package meow.nyx.quackjs

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.pow

internal fun jsPow(
    base: Double,
    exponent: Double,
): Double =
    when {
        exponent.isNaN() -> Double.NaN
        exponent == 0.0 -> 1.0
        base.isNaN() || (abs(base) == 1.0 && !exponent.isFinite()) -> Double.NaN
        else -> base.pow(exponent)
    }

internal fun jsRound(value: Double): Double {
    if (!value.isFinite() || value == 0.0) return value
    if (value >= -0.5 && value < 0.0) return -0.0
    val lower = floor(value)
    // Adding 0.5 first rounds representable values just below a tie upwards.
    return if (value - lower < 0.5) lower else lower + 1.0
}
