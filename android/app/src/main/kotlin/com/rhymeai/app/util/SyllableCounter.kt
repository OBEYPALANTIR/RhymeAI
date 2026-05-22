package com.rhymeai.app.util

object SyllableCounter {
    private val whitespaceSplitPattern = Regex("\\s+")

    fun count(word: String): Int = ProsodyAnalyzer.countWord(word)

    fun countText(text: String): Int = ProsodyAnalyzer.countText(text)

    fun wordCount(text: String): Int {
        return text.split(whitespaceSplitPattern).count { it.isNotBlank() }
    }
}
