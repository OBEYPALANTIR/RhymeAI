package com.rhymeai.app.service

import kotlin.test.Test
import kotlin.test.assertEquals

class LocalModelServiceTest {
    @Test
    fun responseLimitNeverSplitsUtf16SurrogatePairs() {
        val text = "ab\uD83D\uDE00cd"

        assertEquals("ab", text.takeUtf16CodeUnits(3))
        assertEquals("ab\uD83D\uDE00", text.takeUtf16CodeUnits(4))
        assertEquals(text, text.takeUtf16CodeUnits(6))
    }
}
