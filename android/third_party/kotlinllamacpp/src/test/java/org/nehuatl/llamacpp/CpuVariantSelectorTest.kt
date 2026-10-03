package org.nehuatl.llamacpp

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CpuVariantSelectorTest {
    private val v8Only = "fp asimd evtstrm aes pmull sha1 sha2 crc32 cpuid"
    private val v82 = "fp asimd evtstrm aes pmull sha1 sha2 crc32 atomics fphp asimdhp cpuid asimdrdm"

    private fun line(tokens: String) = "Features\t: $tokens"

    @Test fun armv80OnlyUsesBaseline() = assertEquals(CpuVariantSelector.BASELINE, CpuVariantSelector.select(line(v8Only)))

    @Test fun oldAsimdCrc32AesHeuristicNoLongerSelectsV82() {
        // The former predicate (asimd + crc32 + aes) was true here; Armv8.0 has no LSE or RDM.
        assertEquals(CpuVariantSelector.BASELINE, CpuVariantSelector.select(line("fp asimd aes crc32")))
    }

    @Test fun v82WithoutFp16TokensStillSelectsV82() =
        assertEquals(CpuVariantSelector.V8_2, CpuVariantSelector.select(line("asimd crc32 atomics asimdrdm")))

    @Test fun v82SelectsV82() = assertEquals(CpuVariantSelector.V8_2, CpuVariantSelector.select(line(v82)))

    @Test fun dotprodSelectsDotprod() =
        assertEquals(CpuVariantSelector.V8_2_DOTPROD, CpuVariantSelector.select(line("$v82 asimddp")))

    @Test fun i8mmSelectsI8mm() =
        assertEquals(CpuVariantSelector.V8_2_I8MM, CpuVariantSelector.select(line("$v82 i8mm")))

    @Test fun dotprodAndI8mmSelectsCombined() =
        assertEquals(CpuVariantSelector.V8_2_DOTPROD_I8MM, CpuVariantSelector.select(line("$v82 asimddp i8mm")))

    @Test fun dotprodWithoutV82BaseStillBaseline() =
        assertEquals(CpuVariantSelector.BASELINE, CpuVariantSelector.select(line("fp asimd asimddp i8mm")))

    @Test fun eachV82RequirementIsIndividuallyNeeded() {
        for (missing in listOf("atomics", "asimdrdm", "crc32")) {
            val tokens = "asimd atomics asimdrdm crc32 asimddp i8mm".split(" ").filter { it != missing }.joinToString(" ")
            assertEquals("missing $missing", CpuVariantSelector.BASELINE, CpuVariantSelector.select(line(tokens)))
        }
    }

    @Test fun matchingIsPerTokenNotSubstring() {
        // "asimddp" contains "asimd"; "asimdrdmx" contains "asimdrdm"; neither may count.
        assertEquals(CpuVariantSelector.BASELINE, CpuVariantSelector.select(line("atomics crc32 asimdrdmx")))
        assertEquals(CpuVariantSelector.V8_2, CpuVariantSelector.select(line("atomics crc32 asimdrdm asimddpx i8mmx")))
    }

    @Test fun emptyNullBlankAndUnreadableFallBack() {
        assertEquals(CpuVariantSelector.BASELINE, CpuVariantSelector.select(""))
        assertEquals(CpuVariantSelector.BASELINE, CpuVariantSelector.select(null as String?))
        assertEquals(CpuVariantSelector.BASELINE, CpuVariantSelector.select("   \t "))
        assertEquals(CpuVariantSelector.BASELINE, CpuVariantSelector.select("Features"))
        assertEquals(CpuVariantSelector.BASELINE, CpuVariantSelector.select("Features\t:"))
    }

    @Test fun parsesTabsAndRepeatedWhitespace() {
        val tokens = CpuVariantSelector.parseFeatureTokens("Features\t:  atomics\t crc32   asimdrdm ")
        assertEquals(setOf("atomics", "crc32", "asimdrdm"), tokens)
        assertTrue(CpuVariantSelector.parseFeatureTokens(null).isEmpty())
    }
}
