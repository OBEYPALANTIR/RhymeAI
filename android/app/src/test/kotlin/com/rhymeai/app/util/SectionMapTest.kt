package com.rhymeai.app.util

import com.rhymeai.app.data.model.SongSection
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SectionMapTest {

    // --- Header recognition ---

    @Test
    fun bracketed_headers_are_parsed() {
        val map = SectionMap.parse("[Verse]\nLine one\n[Chorus]\nHook line")
        val sections = map.allSections
        assertEquals(2, sections.size)
        assertEquals(SongSection.VERSE, sections[0].type)
        assertEquals(SongSection.CHORUS, sections[1].type)
    }

    @Test
    fun bare_headers_are_parsed() {
        val map = SectionMap.parse("verse\nLine one\nchorus\nHook line")
        val sections = map.allSections
        assertTrue(sections.any { it.type == SongSection.VERSE }, "Expected VERSE")
        assertTrue(sections.any { it.type == SongSection.CHORUS }, "Expected CHORUS")
    }

    @Test
    fun numbered_bare_headers_are_parsed() {
        val map = SectionMap.parse("verse 1\nLine one\nverse 2\nLine two")
        val sections = map.allSections
        val verses = sections.filter { it.type == SongSection.VERSE }
        assertEquals(2, verses.size)
        assertEquals(1, verses[0].ordinal)
        assertEquals(2, verses[1].ordinal)
    }

    @Test
    fun bracketed_numbered_headers_are_parsed() {
        val map = SectionMap.parse("[Verse 1]\nA\n[Verse 2]\nB\n[Chorus]\nC")
        val verses = map.allSections.filter { it.type == SongSection.VERSE }
        assertEquals(2, verses.size)
        assertEquals(1, verses[0].ordinal)
        assertEquals(2, verses[1].ordinal)
    }

    @Test
    fun hook_header_maps_to_chorus_type() {
        val map = SectionMap.parse("[Hook]\nHook line")
        val sections = map.allSections.filter { it.type == SongSection.CHORUS }
        assertTrue(sections.isNotEmpty(), "Hook should map to CHORUS")
    }

    @Test
    fun hook_and_chorus_share_one_ordinal_counter() {
        // [Chorus] is ordinal 1, [Hook] is ordinal 2 — they share the CHORUS counter.
        val map = SectionMap.parse("[Chorus]\nA\n[Hook]\nB")
        val chorus = map.allSections.filter { it.type == SongSection.CHORUS }
        assertEquals(2, chorus.size)
        assertEquals(1, chorus[0].ordinal)
        assertEquals(2, chorus[1].ordinal)
    }

    @Test
    fun bridge_header_maps_to_bridge_type() {
        val map = SectionMap.parse("[Bridge]\nContrast")
        assertTrue(map.allSections.any { it.type == SongSection.BRIDGE })
    }

    @Test
    fun pre_chorus_header_maps_to_unknown_not_chorus() {
        val map = SectionMap.parse("[Pre-Chorus]\nBuild up")
        assertTrue(map.allSections.any { it.type == SongSection.UNKNOWN })
        assertTrue(map.allSections.none { it.type == SongSection.CHORUS })
    }

    // --- Implicit first section ---

    @Test
    fun lines_before_first_header_form_implicit_first_section() {
        val lyrics = "Preamble line one\nPreamble line two\n[Verse]\nVerse content"
        val map = SectionMap.parse(lyrics)
        // First section is the implicit UNKNOWN preamble.
        assertEquals(SongSection.UNKNOWN, map.allSections.first().type)
        assertEquals(1, map.allSections.first().ordinal)
    }

    @Test
    fun no_implicit_section_when_document_starts_with_header() {
        val lyrics = "[Verse]\nFirst line"
        val map = SectionMap.parse(lyrics)
        // The document starts at a header; first section should be VERSE.
        assertEquals(SongSection.VERSE, map.allSections.first().type)
    }

    @Test
    fun empty_lyrics_produce_single_unknown_section() {
        val map = SectionMap.parse("")
        assertEquals(1, map.allSections.size)
        assertEquals(SongSection.UNKNOWN, map.allSections.first().type)
    }

    // --- sectionAt ---

    @Test
    fun sectionAt_returns_correct_section_for_line_in_verse() {
        val lyrics = "[Verse]\nLine 0\nLine 1\n[Chorus]\nHook"
        val map = SectionMap.parse(lyrics)
        // Line index 1 is "Line 0" inside the Verse section.
        assertEquals(SongSection.VERSE, map.sectionAt(1).type)
    }

    @Test
    fun sectionAt_returns_correct_section_for_line_in_chorus() {
        val lyrics = "[Verse]\nLine 0\nLine 1\n[Chorus]\nHook"
        val map = SectionMap.parse(lyrics)
        // "[Chorus]" is at line 3; "Hook" is at line 4.
        assertEquals(SongSection.CHORUS, map.sectionAt(4).type)
    }

    @Test
    fun sectionAt_returns_first_section_for_pre_header_line() {
        val lyrics = "Preamble\n[Verse]\nContent"
        val map = SectionMap.parse(lyrics)
        // Line 0 is "Preamble", which is before the first header.
        assertEquals(SongSection.UNKNOWN, map.sectionAt(0).type)
    }

    // --- Ordinals ---

    @Test
    fun ordinals_are_one_based_per_type() {
        val lyrics = "[Verse]\nA\n[Chorus]\nB\n[Verse]\nC\n[Chorus]\nD"
        val map = SectionMap.parse(lyrics)
        val verses = map.allSections.filter { it.type == SongSection.VERSE }
        val choruses = map.allSections.filter { it.type == SongSection.CHORUS }
        assertEquals(listOf(1, 2), verses.map { it.ordinal })
        assertEquals(listOf(1, 2), choruses.map { it.ordinal })
    }

    // --- Inline content should NOT be treated as headers ---

    @Test
    fun lyric_line_containing_bridge_word_is_not_a_header() {
        val lyrics = "[Verse]\nMeet me at the bridge tonight\nand stay"
        val map = SectionMap.parse(lyrics)
        // Only one section: the Verse.
        assertTrue(map.allSections.none { it.type == SongSection.BRIDGE },
            "Lyric line containing 'bridge' must not be parsed as a Bridge header")
    }
}
