package com.rhymeai.app.util

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame
import kotlin.test.assertTrue

class DictionaryMemoTest {
    private class Dictionary(val name: String)

    private val empty = Dictionary("empty")
    private val loaded = Dictionary("loaded")

    @Test
    fun `a calculation started before the dictionary loaded never lands in the loaded generation`() {
        var dictionary = empty
        val memo = DictionaryMemo<Dictionary, String>(maxCharacters = 1_000, maxKeyCharacters = 100) { dictionary }

        val result = memo.getOrPut("light") { against ->
            if (against === empty) {
                dictionary = loaded // the dictionary finishes loading while this fallback count runs
                assertEquals("loaded", memo.getOrPut("light") { it.name }) // another caller clears and refills
            }
            against.name // the stale calculation then tries to publish
        }

        assertEquals("loaded", result)
        assertEquals("loaded", memo.getOrPut("light") { error("expected the loaded result to be kept") })
    }

    @Test
    fun `a dictionary that loads as the result is stored cannot adopt the stale result`() {
        // The dictionary turns over between the generation checks at publish time.
        var reads = 0
        val memo = DictionaryMemo<Dictionary, String>(maxCharacters = 1_000, maxKeyCharacters = 100) {
            if (++reads <= 2) empty else loaded
        }
        var computed = 0
        memo.getOrPut("light") { against -> computed++; against.name }

        assertEquals("loaded", memo.getOrPut("light") { against -> computed++; against.name })
        assertEquals(2, computed)
        assertEquals("loaded", memo.getOrPut("light") { error("expected the loaded result to be kept") })
    }

    @Test
    fun `the memo keeps the most recently used keys within its character budget`() {
        val memo = DictionaryMemo<Dictionary, Int>(maxCharacters = 10, maxKeyCharacters = 5) { loaded }
        var computed = 0
        fun get(key: String) = memo.getOrPut(key) { ++computed }

        get("aaaa"); get("bbbb"); get("aaaa"); get("cccc") // "bbbb" is the least recently used
        assertEquals(8, memo.retainedCharacters)
        val before = computed
        get("aaaa"); get("cccc")
        assertEquals(before, computed)
        get("bbbb")
        assertEquals(before + 1, computed)
        get("toolongkey")
        assertTrue(memo.retainedCharacters <= 10)
    }

    @Test
    fun `an unchanged long line is computed once while other lines change`() {
        val memo = DictionaryMemo<Dictionary, Int>(maxCharacters = 200_000, maxKeyCharacters = 2_000) { loaded }
        val longLine = "x".repeat(3_000)
        var longComputed = 0
        repeat(100) { edit ->
            memo.getOrPut("short line $edit", slot = 0) { 0 }
            memo.getOrPut(longLine, slot = 1) { ++longComputed }
        }
        assertEquals(1, longComputed)
        memo.getOrPut(longLine.dropLast(1), slot = 1) { ++longComputed }
        assertEquals(2, longComputed) // a changed long line replaces its slot's version
        assertTrue(memo.retainedCharacters < 3_000) // the long line is not held in the bounded part
    }

    @Test
    fun `editing a huge pasted line keeps the line memo under its budget and reuses the unchanged one`() {
        val paragraph = "the harbor lights are burning low tonight ".repeat(715) // about 30,000 characters
        repeat(200) { edit -> SyllableCounter.lyricLine(paragraph.dropLast(edit), index = 3) }
        val verse = "Every single word I write is just the same ".repeat(35) // about 1,500 characters
        repeat(300) { edit -> SyllableCounter.lyricLine(verse.dropLast(edit)) }
        assertTrue(SyllableCounter.retainedLineCharacters <= 200_000, "kept ${SyllableCounter.retainedLineCharacters} characters")

        val song = "Every single word\n$paragraph\nlast line"
        val first = mutableListOf<SyllableCounter.LyricLine>()
        SyllableCounter.forEachLyricLine(song) { _, line -> first += line }
        val again = mutableListOf<SyllableCounter.LyricLine>()
        SyllableCounter.forEachLyricLine(song.replace("last line", "last lines")) { _, line -> again += line }
        assertSame(first[1], again[1])
        assertEquals(SyllableCounter.wordCount(paragraph), again[1].words)
    }
}
