package com.rhymeai.app.util

import com.rhymeai.app.data.model.RhymeType
import kotlin.math.abs

/**
 * Deterministic rhyme constraints for AI suggestions. LLMs cannot see
 * phonetics through their tokens, so we pin line endings to dictionary-backed
 * rhyme words up front and verify/rank the over-generated output afterwards.
 */
object RhymeConstraint {
    private val wordPattern = LyricTokenizer.wordPattern
    private val normalizedLinePattern = Regex("[^a-z0-9]+")

    fun lineEndWord(line: String): String {
        val lastWord = wordPattern.findAll(line).lastOrNull()?.value ?: return ""
        return ProsodyAnalyzer.normalizeWord(lastWord)
    }

    fun candidateEndWords(
        targetWord: String,
        rhymeType: RhymeType,
        limit: Int = 12,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): List<String> {
        val matches = ProsodyAnalyzer.findRhymes(targetWord, dictionary = dictionary)
        if (matches.isEmpty) return emptyList()
        // Perfect requests stay strict; looser types may pad with near rhymes.
        // Each pool is already frequency-ranked by findRhymes; we simply
        // concatenate pools in priority order (perfect/multi before near).
        val pools = when (rhymeType) {
            RhymeType.PERFECT -> listOf(matches.perfect, matches.multi)
            RhymeType.NEAR, RhymeType.SLANT -> listOf(matches.perfect, matches.multi, matches.near)
        }
        val normalizedTarget = ProsodyAnalyzer.normalizeWord(targetWord)
        val ordered = LinkedHashSet<String>()
        pools.forEach { pool ->
            pool.forEach { word ->
                if (word != normalizedTarget) ordered += word
            }
        }
        return ordered.take(limit)
    }

    fun rhymeTier(
        line: String,
        targetWord: String,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): Int = rhymeTier(
        line, targetWord, ProsodyAnalyzer.findRhymes(targetWord, dictionary = dictionary), dictionary
    )

    fun rhymeTier(
        line: String,
        targetWord: String,
        matches: RhymeMatches,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): Int {
        val listedTier = rhymeTier(line, matches)
        if (listedTier > 0) return listedTier

        val endWord = lineEndWord(line)
        val target = ProsodyAnalyzer.normalizeWord(targetWord)
        if (endWord == target || dictionary.pronunciations(endWord).isEmpty() ||
            dictionary.pronunciations(target).isEmpty()
        ) return 0

        // Display pools are capped; absence from them is not a phonetic miss.
        // Require dictionary pronunciations so spelling fallbacks cannot certify a rhyme.
        val targetKeys = ProsodyAnalyzer.rhymeKeys(target, maxDepth = 1, dictionary = dictionary)
        val endKeys = ProsodyAnalyzer.rhymeKeys(endWord, maxDepth = 1, dictionary = dictionary)
        return if (endKeys.any { it in targetKeys }) 2 else 0
    }

    // Display-pool membership only; validation callers should also supply the target word.
    fun rhymeTier(line: String, matches: RhymeMatches): Int {
        val endWord = lineEndWord(line)
        if (endWord.isEmpty()) return 0
        return when {
            endWord in matches.perfect || endWord in matches.multi -> 2
            endWord in matches.near -> 1
            else -> 0
        }
    }

    // rhymeType mirrors the iOS contract signature; tier ranking is type-independent.
    @Suppress("UNUSED_PARAMETER")
    fun filterAndRank(
        lines: List<String>,
        targetLine: String,
        rhymeType: RhymeType,
        want: Int,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): List<String> {
        if (lines.isEmpty() || want <= 0) return emptyList()

        val seen = mutableSetOf<String>()
        val unique = lines.filter { line ->
            val key = normalizedLinePattern.replace(line.lowercase().trim(), "")
            key.isNotEmpty() && seen.add(key)
        }
        if (unique.isEmpty()) return emptyList()

        val targetWord = lineEndWord(targetLine)
        val matches = ProsodyAnalyzer.findRhymes(targetWord, dictionary = dictionary)
        val targetSyllables = ProsodyAnalyzer.analyzeLine(targetLine, dictionary).syllableCount

        data class Ranked(val line: String, val tier: Int, val syllableGap: Int, val index: Int)
        val ranked = unique.mapIndexed { index, line ->
            Ranked(
                line = line,
                tier = rhymeTier(line, targetWord, matches, dictionary),
                syllableGap = abs(ProsodyAnalyzer.analyzeLine(line, dictionary).syllableCount - targetSyllables),
                index = index
            )
        }

        val chosen = ranked
            .filter { it.tier > 0 }
            .sortedWith(compareByDescending<Ranked> { it.tier }.thenBy { it.syllableGap }.thenBy { it.index })
            .take(want)
            .map { it.line }
            .toMutableList()

        // Never starve the caller: pad with non-rhyming lines in arrival order.
        if (chosen.size < want) {
            val alreadyChosen = chosen.toSet()
            unique.forEach { line ->
                if (chosen.size < want && line !in alreadyChosen) chosen += line
            }
        }
        return chosen
    }
}
