package com.rhymeai.app.util

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class DictionaryMemoTest {
    @Test
    fun `a calculation started before the dictionary loaded never lands in the loaded generation`() {
        val empty = Any()
        val loaded = Any()
        var dictionary = empty
        val memo = DictionaryMemo<String>(maxCharacters = 1_000, maxKeyCharacters = 100) { dictionary }

        val result = memo.getOrPut("light") {
            if (dictionary === empty) {
                dictionary = loaded // the dictionary finishes loading while this fallback count runs
                assertEquals("loaded", memo.getOrPut("light") { "loaded" }) // another caller clears and refills
                "fallback" // the stale calculation now tries to publish
            } else {
                "loaded"
            }
        }

        assertEquals("loaded", result)
        assertEquals("loaded", memo.getOrPut("light") { error("expected the loaded result to be kept") })
    }

    @Test
    fun `the memo keeps the most recently used keys within its character budget`() {
        val memo = DictionaryMemo<Int>(maxCharacters = 10, maxKeyCharacters = 5) { Unit }
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
    fun `editing a huge pasted line keeps the line memo under its budget`() {
        val paragraph = "the harbor lights are burning low tonight ".repeat(715) // about 30,000 characters
        repeat(200) { edit -> SyllableCounter.lyricLine(paragraph.dropLast(edit)) }
        val verse = "Every single word I write is just the same ".repeat(35) // about 1,500 characters
        repeat(300) { edit -> SyllableCounter.lyricLine(verse.dropLast(edit)) }
        assertTrue(SyllableCounter.retainedLineCharacters <= 200_000, "kept ${SyllableCounter.retainedLineCharacters} characters")
        assertEquals(SyllableCounter.wordCount(paragraph), SyllableCounter.lyricLine(paragraph).words)
    }
}
