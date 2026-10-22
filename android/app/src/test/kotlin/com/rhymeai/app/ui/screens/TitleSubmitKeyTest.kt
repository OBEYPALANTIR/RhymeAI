package com.rhymeai.app.ui.screens

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TitleSubmitKeyTest {
    @Test
    fun enterAndNumPadEnterKeyDownSubmit() {
        assertTrue(isTitleSubmitKey(KeyEventType.KeyDown, Key.Enter, shiftPressed = false))
        assertTrue(isTitleSubmitKey(KeyEventType.KeyDown, Key.NumPadEnter, shiftPressed = false))
    }

    @Test
    fun keyUpDoesNotSubmit() {
        assertFalse(isTitleSubmitKey(KeyEventType.KeyUp, Key.Enter, shiftPressed = false))
        assertFalse(isTitleSubmitKey(KeyEventType.KeyUp, Key.NumPadEnter, shiftPressed = false))
    }

    @Test
    fun shiftEnterDoesNotSubmit() {
        assertFalse(isTitleSubmitKey(KeyEventType.KeyDown, Key.Enter, shiftPressed = true))
    }

    @Test
    fun ordinaryKeysDoNotSubmit() {
        assertFalse(isTitleSubmitKey(KeyEventType.KeyDown, Key.A, shiftPressed = false))
        assertFalse(isTitleSubmitKey(KeyEventType.KeyDown, Key.Spacebar, shiftPressed = true))
    }
}
