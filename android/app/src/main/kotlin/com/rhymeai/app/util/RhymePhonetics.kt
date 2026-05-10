package com.rhymeai.app.util

object RhymePhonetics {
    private val vowelLetters = setOf('a', 'e', 'i', 'o', 'u')

    private val substitutions = listOf(
        "tion" to "shn",
        "sion" to "shn",
        "cion" to "shn",
        "cian" to "shn",
        "tial" to "shl",
        "cial" to "shl",
        "ough" to "of",
        "augh" to "af",
        "eigh" to "ay",
        "ight" to "ite",
        "ph" to "f",
        "ck" to "k",
        "qu" to "kw",
        "wh" to "w",
        "x" to "ks"
    )

    private val stopwords = setOf(
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were",
        "be", "to", "of", "in", "on", "at", "by", "for", "with", "as",
        "it", "its", "this", "that", "these", "those", "i", "you", "he",
        "she", "we", "they", "them", "his", "her", "our", "their", "my",
        "do", "does", "did", "have", "has", "had", "not", "if", "so", "no"
    )

    fun rhymeKeys(word: String, maxDepth: Int = 2): List<String> {
        val cleaned = normalize(word) ?: return emptyList()
        if (cleaned in stopwords) return emptyList()
        val phonetic = applyPhonetics(cleaned)
        val vowelGroupStarts = vowelGroupStarts(phonetic)
        if (vowelGroupStarts.isEmpty()) return emptyList()

        val keys = mutableListOf<String>()
        val depthMax = minOf(maxDepth, vowelGroupStarts.size)
        for (depth in 1..depthMax) {
            val start = vowelGroupStarts[vowelGroupStarts.size - depth]
            keys += phonetic.substring(start)
        }
        return keys
    }

    private fun normalize(word: String): String? {
        val w = word.lowercase().filter { it.isLetter() }
        if (w.length < 2) return null
        return w
    }

    private fun applyPhonetics(input: String): String {
        var w = input
        for ((from, to) in substitutions) {
            if (w.contains(from)) w = w.replace(from, to)
        }
        if (w.length > 2 && w.endsWith("e") && !w.endsWith("le") &&
            w.dropLast(1).any { isVowelChar(it, atStart = false) }) {
            w = w.dropLast(1)
        }
        return w
    }

    private fun vowelGroupStarts(w: String): List<Int> {
        val starts = mutableListOf<Int>()
        var inGroup = false
        for (i in w.indices) {
            val v = isVowelChar(w[i], atStart = i == 0)
            if (v && !inGroup) starts += i
            inGroup = v
        }
        return starts
    }

    private fun isVowelChar(c: Char, atStart: Boolean): Boolean {
        if (c in vowelLetters) return true
        if (c == 'y') return !atStart
        return false
    }
}
