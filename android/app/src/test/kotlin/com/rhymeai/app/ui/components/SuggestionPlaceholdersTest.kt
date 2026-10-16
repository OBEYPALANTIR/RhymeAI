package com.rhymeai.app.ui.components

import kotlin.test.Test
import kotlin.test.assertEquals

class SuggestionPlaceholdersTest {
    @Test
    fun `reserves three skeleton slots before the first line arrives`() {
        assertEquals(3, SuggestionPlaceholders.count(isLoading = true, arrived = 0))
        assertEquals(3, SuggestionPlaceholders.slotCount(isLoading = true, arrived = 0))
    }

    @Test
    fun `each arriving line takes the next reserved slot`() {
        assertEquals(2, SuggestionPlaceholders.count(isLoading = true, arrived = 1))
        assertEquals(1, SuggestionPlaceholders.count(isLoading = true, arrived = 2))
        assertEquals(0, SuggestionPlaceholders.count(isLoading = true, arrived = 3))
        assertEquals(3, SuggestionPlaceholders.slotCount(isLoading = true, arrived = 2))
    }

    @Test
    fun `lines past the reserved slots append without new skeletons`() {
        assertEquals(0, SuggestionPlaceholders.count(isLoading = true, arrived = 5))
        assertEquals(5, SuggestionPlaceholders.slotCount(isLoading = true, arrived = 5))
    }

    @Test
    fun `no skeletons remain once generation stops, however many lines came`() {
        assertEquals(0, SuggestionPlaceholders.count(isLoading = false, arrived = 0))
        assertEquals(0, SuggestionPlaceholders.count(isLoading = false, arrived = 1))
        assertEquals(1, SuggestionPlaceholders.slotCount(isLoading = false, arrived = 1))
        assertEquals(0, SuggestionPlaceholders.slotCount(isLoading = false, arrived = 0))
    }
}
