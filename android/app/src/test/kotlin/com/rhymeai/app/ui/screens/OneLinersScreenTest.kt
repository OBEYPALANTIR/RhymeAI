package com.rhymeai.app.ui.screens

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OneLinersScreenTest {
    @Test
    fun `only a new capture's stopped take shows its take row`() {
        assertTrue(showsStoppedTake(isEdit = false, isRecording = false, hasTake = true))
        assertFalse(showsStoppedTake(isEdit = false, isRecording = true, hasTake = true))
        assertFalse(showsStoppedTake(isEdit = false, isRecording = false, hasTake = false))
        assertFalse(showsStoppedTake(isEdit = true, isRecording = false, hasTake = true))
    }
}
