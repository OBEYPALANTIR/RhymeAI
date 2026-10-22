package com.rhymeai.app.ui.screens

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TitleSubmitKeyTest {
    @Test
    fun enterAndNumPadEnterKeyDownSubmit() {
        assertTrue(isTitleSubmitKey(KeyEventType.KeyDown, Key.Enter, modified = false))
        assertTrue(isTitleSubmitKey(KeyEventType.KeyDown, Key.NumPadEnter, modified = false))
    }

    @Test
    fun keyUpDoesNotSubmit() {
        assertFalse(isTitleSubmitKey(KeyEventType.KeyUp, Key.Enter, modified = false))
        assertFalse(isTitleSubmitKey(KeyEventType.KeyUp, Key.NumPadEnter, modified = false))
    }

    @Test
    fun modifiedEnterDoesNotSubmit() {
        // The caller folds Shift, Ctrl, Alt and Meta into `modified`.
        assertFalse(isTitleSubmitKey(KeyEventType.KeyDown, Key.Enter, modified = true))
        assertFalse(isTitleSubmitKey(KeyEventType.KeyDown, Key.NumPadEnter, modified = true))
    }

    @Test
    fun ordinaryKeysDoNotSubmit() {
        assertFalse(isTitleSubmitKey(KeyEventType.KeyDown, Key.A, modified = false))
        assertFalse(isTitleSubmitKey(KeyEventType.KeyDown, Key.Spacebar, modified = true))
    }
}
