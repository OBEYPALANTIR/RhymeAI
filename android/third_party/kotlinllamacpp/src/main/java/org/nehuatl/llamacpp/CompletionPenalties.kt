package org.nehuatl.llamacpp

/**
 * Penalty arguments for a completion request. A field the caller did not set is passed as
 * [UNSET_LAST_N] / NaN, which the native side reads as "leave the model's load-time setting"
 * (GGUF metadata or native default) rather than forcing a value.
 */
internal data class CompletionPenalties(
    val lastN: Int,
    val repeat: Float,
    val freq: Float,
    val present: Float
) {
    companion object {
        const val UNSET_LAST_N = Int.MIN_VALUE

        fun from(params: Map<String, Any>): CompletionPenalties = CompletionPenalties(
            lastN = params["penalty_last_n"] as? Int ?: UNSET_LAST_N,
            repeat = (params["penalty_repeat"] as? Double)?.toFloat() ?: Float.NaN,
            freq = (params["penalty_freq"] as? Double)?.toFloat() ?: Float.NaN,
            present = (params["penalty_present"] as? Double)?.toFloat() ?: Float.NaN
        )
    }
}
