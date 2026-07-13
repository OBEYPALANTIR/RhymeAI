package com.rhymeai.app.ui.screens

import androidx.compose.ui.unit.dp
import kotlin.test.Test
import kotlin.test.assertEquals

class UnBlockSizingTest {
    @Test
    fun normalWordmarkUsesPhiSquaredRestingWidth() {
        assertEquals(144.dp, unBlockButtonWidth(60.dp, 300.dp))
    }

    @Test
    fun enlargedWordmarkExpandsWithoutExceedingAvailableWidth() {
        assertEquals(171.dp, unBlockButtonWidth(120.dp, 240.dp))
        assertEquals(160.dp, unBlockButtonWidth(120.dp, 160.dp))
    }

    @Test
    fun wordmarkWidthIncludesOpticalOverhang() {
        assertEquals(74.dp, unBlockWordmarkWidth(70.dp))
    }
}
