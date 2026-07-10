package com.rhymeai.app.ui.screens

import androidx.compose.ui.unit.dp
import kotlin.test.Test
import kotlin.test.assertEquals

class UnBlockSizingTest {
    @Test
    fun normalWordmarkKeepsExistingMinimumWidth() {
        assertEquals(150.dp, unBlockButtonWidth(60.dp, 300.dp))
    }

    @Test
    fun doubledWordmarkExpandsWithoutExceedingAvailableWidth() {
        assertEquals(178.dp, unBlockButtonWidth(120.dp, 240.dp))
        assertEquals(160.dp, unBlockButtonWidth(120.dp, 160.dp))
    }
}
