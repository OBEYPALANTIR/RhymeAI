package com.rhymeai.app

import kotlin.test.Test
import kotlin.test.assertEquals

/** A rewrite or suggestion failure never leaves the writer an empty error line. */
class FailureMessageTest {
    @Test
    fun blankOrMissingMessageFallsBackToTheGenericWording() {
        listOf(RuntimeException(), RuntimeException(""), RuntimeException("  \n")).forEach {
            assertEquals("Rewrite failed", failureMessage(it, "Rewrite failed"))
        }
        assertEquals(
            "Provider service error — try again shortly.",
            failureMessage(RuntimeException("Provider service error — try again shortly."), "Rewrite failed")
        )
    }
}
