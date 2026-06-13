package com.rhymeai.app.data.repository

import com.rhymeai.app.data.repository.ProjectRepository.EditorToggles
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Unit tests for the EditorToggles data class used as a persistence snapshot.
 *
 * DataStore itself cannot be unit-tested without a full Android context (it is
 * an instrumented concern); these tests cover the round-trip contract of the
 * EditorToggles data class: default values, field integrity, and copy semantics.
 * The actual DataStore read/write path is covered by the existing integration
 * test suite run against a real device or emulator.
 */
class EditorTogglePersistenceTest {

    @Test
    fun defaultValuesMatchExpectedOnFirstInstall() {
        val defaults = EditorToggles()
        assertFalse(defaults.useWholeSongContext, "Whole song context should default off")
        assertFalse(defaults.isStressIpaEnabled, "Stress IPA should default off")
        assertTrue(defaults.isHighlightEnabled, "Highlight rhymes should default on")
        assertTrue(defaults.isSyllableColoringEnabled, "Syllable coloring should default on")
        assertFalse(defaults.isRhymeHighlightEnabled, "Rhyme highlight should default off")
        assertFalse(defaults.isBeatGridEnabled, "Beat grid should default off")
    }

    @Test
    fun copyPreservesUnchangedFields() {
        val original = EditorToggles()
        val modified = original.copy(useWholeSongContext = true)
        assertTrue(modified.useWholeSongContext)
        // All other fields preserved from defaults.
        assertFalse(modified.isStressIpaEnabled)
        assertTrue(modified.isHighlightEnabled)
        assertTrue(modified.isSyllableColoringEnabled)
        assertFalse(modified.isRhymeHighlightEnabled)
        assertFalse(modified.isBeatGridEnabled)
    }

    @Test
    fun allTogglesOnRoundTrip() {
        // Simulate saving all toggles enabled and reading them back.
        val saved = EditorToggles(
            useWholeSongContext = true,
            isStressIpaEnabled = true,
            isHighlightEnabled = true,
            isSyllableColoringEnabled = true,
            isRhymeHighlightEnabled = true,
            isBeatGridEnabled = true
        )
        // In a real DataStore path each field is stored and reloaded individually;
        // here we verify the data class correctly holds and exposes all values.
        assertTrue(saved.useWholeSongContext)
        assertTrue(saved.isStressIpaEnabled)
        assertTrue(saved.isHighlightEnabled)
        assertTrue(saved.isSyllableColoringEnabled)
        assertTrue(saved.isRhymeHighlightEnabled)
        assertTrue(saved.isBeatGridEnabled)
    }

    @Test
    fun allTogglesOffRoundTrip() {
        val saved = EditorToggles(
            useWholeSongContext = false,
            isStressIpaEnabled = false,
            isHighlightEnabled = false,
            isSyllableColoringEnabled = false,
            isRhymeHighlightEnabled = false,
            isBeatGridEnabled = false
        )
        assertFalse(saved.useWholeSongContext)
        assertFalse(saved.isStressIpaEnabled)
        assertFalse(saved.isHighlightEnabled)
        assertFalse(saved.isSyllableColoringEnabled)
        assertFalse(saved.isRhymeHighlightEnabled)
        assertFalse(saved.isBeatGridEnabled)
    }

    @Test
    fun equalityIsStructural() {
        val a = EditorToggles(useWholeSongContext = true)
        val b = EditorToggles(useWholeSongContext = true)
        assertEquals(a, b)
    }

    @Test
    fun inequalityDetectsChangedField() {
        val a = EditorToggles(isBeatGridEnabled = false)
        val b = EditorToggles(isBeatGridEnabled = true)
        assertTrue(a != b)
    }
}
