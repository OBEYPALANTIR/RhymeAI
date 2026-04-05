package com.rhymeai.app.util

object SyllableCounter {
    fun count(word: String): Int {
        val w = word.lowercase().trim()
        if (w.isEmpty()) return 0
        if (w.length <= 2) return 1

        var count = 0
        var prevVowel = false
        val vowels = "aeiouy"

        for (ch in w) {
            val isVowel = ch in vowels
            if (isVowel && !prevVowel) count++
            prevVowel = isVowel
        }

        // Silent 'e' at end
        if (w.endsWith("e") && !w.endsWith("le") && count > 1) count--
        // Common suffix adjustments
        if (w.endsWith("les") && w.length > 4) count--
        if (w.endsWith("es") && !w.endsWith("ses") && !w.endsWith("zes") && count > 1) count--
        if (w.endsWith("ed") && !w.endsWith("ted") && !w.endsWith("ded") && count > 1) count--

        return maxOf(count, 1)
    }

    fun countText(text: String): Int {
        return text.split(Regex("[^a-zA-Z']+"))
            .filter { it.isNotBlank() }
            .sumOf { count(it) }
    }

    fun wordCount(text: String): Int {
        return text.split(Regex("\\s+")).count { it.isNotBlank() }
    }
}
