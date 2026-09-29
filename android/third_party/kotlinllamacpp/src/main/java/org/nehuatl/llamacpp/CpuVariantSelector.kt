package org.nehuatl.llamacpp

/**
 * Chooses the arm64 native library variant from the `Features` line of /proc/cpuinfo.
 *
 * Requirements mirror what the CMake variants actually need (`-march=armv8.2-a` enables LSE
 * atomics, RDM and CRC32; `+dotprod` and `+i8mm` add those extensions; no variant requests
 * `+fp16`). Matching is exact per whitespace-separated token, so "asimd" never satisfies
 * "asimddp". Any missing or partial report falls back to the baseline `rnllama_v8` build.
 */
internal object CpuVariantSelector {
    const val BASELINE = "rnllama_v8"
    const val V8_2 = "rnllama_v8_2"
    const val V8_2_DOTPROD = "rnllama_v8_2_dotprod"
    const val V8_2_I8MM = "rnllama_v8_2_i8mm"
    const val V8_2_DOTPROD_I8MM = "rnllama_v8_2_dotprod_i8mm"

    private val armV82Tokens = setOf("atomics", "asimdrdm", "crc32")
    private const val DOTPROD_TOKEN = "asimddp"
    private const val I8MM_TOKEN = "i8mm"

    /** Splits a `Features\t: a b c` line (or a bare token list) into its feature tokens. */
    fun parseFeatureTokens(featuresLine: String?): Set<String> {
        if (featuresLine.isNullOrBlank()) return emptySet()
        val list = if (featuresLine.trimStart().startsWith("Features")) {
            featuresLine.substringAfter(':', missingDelimiterValue = "")
        } else {
            featuresLine
        }
        return list.split(Regex("\\s+")).filter { it.isNotEmpty() }.toSet()
    }

    fun select(features: Set<String>): String {
        if (!features.containsAll(armV82Tokens)) return BASELINE
        val dotprod = DOTPROD_TOKEN in features
        val i8mm = I8MM_TOKEN in features
        return when {
            dotprod && i8mm -> V8_2_DOTPROD_I8MM
            dotprod -> V8_2_DOTPROD
            i8mm -> V8_2_I8MM
            else -> V8_2
        }
    }

    fun select(featuresLine: String?): String = select(parseFeatureTokens(featuresLine))
}
