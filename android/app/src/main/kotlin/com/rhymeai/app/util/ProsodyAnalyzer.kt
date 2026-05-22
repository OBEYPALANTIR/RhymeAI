package com.rhymeai.app.util

import java.io.InputStream

data class WordProsody(
    val word: String,
    val normalized: String,
    val syllableCount: Int,
    val stressPattern: List<Int>,
    val ipa: String,
    val isFallback: Boolean
)

data class LineProsody(
    val words: List<WordProsody>,
    val syllableCount: Int,
    val stressPattern: List<Int>,
    val feet: String,
    val ipa: String
)

class PronunciationDictionary private constructor(
    private val entries: Map<String, List<List<String>>>
) {
    fun pronunciations(normalizedWord: String): List<List<String>> = entries[normalizedWord].orEmpty()

    companion object {
        @Volatile
        private var sharedDictionary = PronunciationDictionary(emptyMap())

        val shared: PronunciationDictionary
            get() = sharedDictionary

        fun initialize(inputStream: InputStream) {
            sharedDictionary = inputStream.bufferedReader().useLines { lines ->
                fromLines(lines).also { dictionary ->
                    check(dictionary.entries.isNotEmpty()) { "Pronunciation dictionary is empty" }
                }
            }
        }

        fun fromLines(lines: Sequence<String>): PronunciationDictionary {
            val parsed = mutableMapOf<String, List<List<String>>>()
            lines.forEach { row ->
                if (row.isBlank() || row.startsWith("#")) return@forEach
                val tabIndex = row.indexOf('\t')
                if (tabIndex <= 0) return@forEach

                val word = row.substring(0, tabIndex)
                val variants = row.substring(tabIndex + 1)
                    .split('|')
                    .map { variant -> variant.trim().split(Regex("\\s+")).filter { it.isNotBlank() } }
                    .filter { it.isNotEmpty() }

                if (variants.isNotEmpty()) parsed[word] = variants
            }
            return PronunciationDictionary(parsed)
        }
    }
}

object ProsodyAnalyzer {
    private val wordPattern = Regex("[a-zA-Z']+")
    private val vowels = setOf(
        "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY",
        "OW", "OY", "UH", "UW"
    )
    private val stopwords = setOf(
        "the", "a", "an", "and", "or", "but", "is", "are", "was", "were",
        "be", "to", "of", "in", "on", "at", "by", "for", "with", "as",
        "it", "its", "this", "that", "these", "those", "i", "you", "he",
        "she", "we", "they", "them", "his", "her", "our", "their", "my",
        "do", "does", "did", "have", "has", "had", "not", "if", "so", "no"
    )
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
    private val ipaByPhone = mapOf(
        "AA" to "ɑ",
        "AE" to "æ",
        "AH" to "ʌ",
        "AO" to "ɔ",
        "AW" to "aʊ",
        "AY" to "aɪ",
        "EH" to "ɛ",
        "ER" to "ɝ",
        "EY" to "eɪ",
        "IH" to "ɪ",
        "IY" to "i",
        "OW" to "oʊ",
        "OY" to "ɔɪ",
        "UH" to "ʊ",
        "UW" to "u",
        "B" to "b",
        "CH" to "tʃ",
        "D" to "d",
        "DH" to "ð",
        "F" to "f",
        "G" to "ɡ",
        "HH" to "h",
        "JH" to "dʒ",
        "K" to "k",
        "L" to "l",
        "M" to "m",
        "N" to "n",
        "NG" to "ŋ",
        "P" to "p",
        "R" to "r",
        "S" to "s",
        "SH" to "ʃ",
        "T" to "t",
        "TH" to "θ",
        "V" to "v",
        "W" to "w",
        "Y" to "j",
        "Z" to "z",
        "ZH" to "ʒ"
    )

    fun analyzeWord(
        word: String,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): WordProsody {
        val normalized = normalizeWord(word)
        if (normalized.isEmpty()) {
            return WordProsody(word, normalized, 0, emptyList(), "", isFallback = true)
        }

        val variants = dictionary.pronunciations(normalized)
        if (variants.isEmpty()) {
            val stressPattern = fallbackStressPattern(normalized)
            return WordProsody(
                word = word,
                normalized = normalized,
                syllableCount = stressPattern.size,
                stressPattern = stressPattern,
                ipa = "",
                isFallback = true
            )
        }

        val phones = variants.first()
        val stressPattern = stressPatternForPhones(phones)
        return WordProsody(
            word = word,
            normalized = normalized,
            syllableCount = stressPattern.size,
            stressPattern = stressPattern,
            ipa = ipaForPhones(phones),
            isFallback = false
        )
    }

    fun analyzeLine(
        text: String,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): LineProsody {
        val words = wordPattern.findAll(text).map { analyzeWord(it.value, dictionary) }.toList()
        val stresses = words.flatMap { it.stressPattern }
        return LineProsody(
            words = words,
            syllableCount = words.sumOf { it.syllableCount },
            stressPattern = stresses,
            feet = metricFeet(stresses),
            ipa = words.mapNotNull { it.ipa.ifBlank { it.normalized }.takeIf(String::isNotBlank) }.joinToString(" ")
        )
    }

    fun countWord(word: String): Int = analyzeWord(word).syllableCount

    fun countText(text: String): Int = analyzeLine(text).syllableCount

    fun rhymeKeys(
        word: String,
        maxDepth: Int = 2,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): List<String> {
        val normalized = normalizeWord(word)
        if (normalized.length < 2 || normalized in stopwords) return emptyList()

        val variants = dictionary.pronunciations(normalized)
        if (variants.isEmpty()) return fallbackRhymeKeys(normalized, maxDepth)

        return variants
            .flatMap { rhymeKeysForPhones(it, maxDepth) }
            .distinct()
    }

    fun metricFeet(stressPattern: List<Int>): String {
        return stressPattern
            .map { stress -> if (stress == 0) "da" else "ˈDA" }
            .chunked(2)
            .joinToString(" | ") { it.joinToString(" ") }
    }

    fun normalizeWord(word: String): String {
        return word.lowercase()
            .filter { it in 'a'..'z' || it == '\'' }
            .trim('\'')
    }

    private fun basePhone(phone: String): String = phone.replace(Regex("[0-2]$"), "")

    private fun stressForPhone(phone: String): Int? {
        val last = phone.lastOrNull() ?: return null
        return last.digitToIntOrNull()?.takeIf { it in 0..2 }
    }

    private fun stressPatternForPhones(phones: List<String>): List<Int> {
        return phones.mapNotNull(::stressForPhone)
    }

    private fun ipaForPhones(phones: List<String>): String {
        val vowelIndexes = phones.mapIndexedNotNull { index, phone ->
            index.takeIf { basePhone(phone) in vowels }
        }
        val markers = mutableMapOf<Int, String>()

        vowelIndexes.forEachIndexed { vowelIndex, phoneIndex ->
            val stress = stressForPhone(phones[phoneIndex])
            if (stress == null || stress == 0) return@forEachIndexed
            val previousVowel = vowelIndexes.getOrNull(vowelIndex - 1)
            val onsetIndex = if (previousVowel == null) 0 else previousVowel + 1
            markers[onsetIndex] = if (stress == 1) "ˈ" else "ˌ"
        }

        return phones.mapIndexed { index, phone ->
            (markers[index] ?: "") + ipaForPhone(phone)
        }.joinToString("")
    }

    private fun ipaForPhone(phone: String): String {
        val base = basePhone(phone)
        val stress = stressForPhone(phone)
        if (base == "AH" && stress == 0) return "ə"
        if (base == "ER" && stress == 0) return "ɚ"
        return ipaByPhone[base] ?: base.lowercase()
    }

    private fun fallbackStressPattern(word: String): List<Int> {
        val count = fallbackSyllableCount(word)
        if (count == 0) return emptyList()
        return List(count) { index -> if (index == 0) 1 else 0 }
    }

    private fun fallbackSyllableCount(word: String): Int {
        val w = normalizeWord(word)
        if (w.isEmpty()) return 0
        if (w.length <= 2) return 1

        var count = 0
        var prevVowel = false
        val vowelLetters = "aeiouy"

        for (ch in w) {
            val isVowel = ch in vowelLetters
            if (isVowel && !prevVowel) count++
            prevVowel = isVowel
        }

        if (w.endsWith("e") && !w.endsWith("le") && count > 1) count--
        if (w.endsWith("les") && w.length > 4 && count > 1) count--
        if (w.endsWith("es") && !w.endsWith("ses") && !w.endsWith("zes") && count > 1) count--
        if (w.endsWith("ed") && !w.endsWith("ted") && !w.endsWith("ded") && count > 1) count--

        return maxOf(count, 1)
    }

    private fun fallbackRhymeKeys(word: String, maxDepth: Int): List<String> {
        var phonetic = normalizeWord(word)
        if (phonetic.length < 2 || phonetic in stopwords) return emptyList()

        substitutions.forEach { (from, to) ->
            phonetic = phonetic.replace(from, to)
        }
        if (phonetic.length > 2 && phonetic.endsWith("e") && !phonetic.endsWith("le")) {
            phonetic = phonetic.dropLast(1)
        }

        val starts = mutableListOf<Int>()
        var inGroup = false
        phonetic.forEachIndexed { index, ch ->
            val isVowel = ch in "aeiou" || (ch == 'y' && index > 0)
            if (isVowel && !inGroup) starts += index
            inGroup = isVowel
        }

        return starts.takeLast(maxDepth).asReversed().map { start -> phonetic.substring(start) }
    }

    private fun rhymeKeysForPhones(phones: List<String>, maxDepth: Int): List<String> {
        val vowelIndexes = phones.mapIndexedNotNull { index, phone ->
            index.takeIf { basePhone(phone) in vowels }
        }
        if (vowelIndexes.isEmpty()) return emptyList()

        val stressed = vowelIndexes.filter { index -> (stressForPhone(phones[index]) ?: 0) > 0 }
        val anchors = if (stressed.isNotEmpty()) stressed else vowelIndexes
        return anchors
            .takeLast(maxDepth)
            .asReversed()
            .map { index -> phones.drop(index).joinToString(" ") { basePhone(it) } }
    }
}
