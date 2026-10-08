package com.rhymeai.app.util

import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeType
import kotlin.math.abs

/**
 * Deterministic rhyme constraints for AI suggestions. LLMs cannot see
 * phonetics through their tokens, so we pin line endings to dictionary-backed
 * rhyme words up front and verify/rank the over-generated output afterwards.
 */
object RhymeConstraint {
    private val wordPattern = LyricTokenizer.wordPattern

    /** A Simple list keeps only one-syllable words unless fewer than this many
     *  exist, in which case the remaining words follow in their original order
     *  (some anchors, "arrival" for one, have no one-syllable rhyme at all). */
    const val SIMPLE_MIN_MONOSYLLABLES = 6

    fun lineEndWord(line: String): String {
        val lastWord = wordPattern.findAll(line).lastOrNull()?.value ?: return ""
        return ProsodyAnalyzer.normalizeWord(lastWord)
    }

    /** Allowed ending words for a target word, best rhymes first; empty when
     *  the dictionary doesn't know the word. [complexity] shapes the list the
     *  prompt sends (see [levelEndWords]); MODERATE is the frequency order. */
    fun candidateEndWords(
        targetWord: String,
        rhymeType: RhymeType,
        limit: Int = 12,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared,
        wordFrequency: WordFrequency = WordFrequency.shared,
        complexity: RhymeComplexity = RhymeComplexity.MODERATE
    ): List<String> {
        val matches = ProsodyAnalyzer.findRhymes(targetWord, dictionary = dictionary, wordFrequency = wordFrequency)
        if (matches.isEmpty) return emptyList()
        // Each mode returns only its named phonetic relation, as on iOS. Perfect
        // keeps the exact and multisyllabic pools; Near and Slant are exclusive
        // and already ranked by findRhymes.
        val pools = when (rhymeType) {
            RhymeType.PERFECT -> listOf(matches.perfect, matches.multi)
            RhymeType.NEAR -> listOf(matches.near)
            RhymeType.SLANT -> listOf(matches.slant)
        }
        val normalizedTarget = ProsodyAnalyzer.normalizeWord(targetWord)
        val ordered = LinkedHashSet<String>()
        pools.forEach { pool ->
            pool.forEach { word ->
                if (word != normalizedTarget) ordered += word
            }
        }
        return levelEndWords(ordered.toList(), complexity, limit, dictionary)
    }

    /** The complexity level's view of a relation's ranked candidates, cut to
     *  [limit]. COMPLEX puts words of two or more syllables first, then the
     *  rest, each group keeping its frequency order (a stable partition).
     *  SIMPLE keeps one-syllable words only, unless fewer than
     *  [SIMPLE_MIN_MONOSYLLABLES] exist, when the remaining words follow in
     *  their original order. MODERATE is unchanged. Syllables come from
     *  [ProsodyAnalyzer.analyzeWord] with the same dictionary, so iOS and the
     *  eval's `scoring.level_end_words` build identical lists. */
    fun levelEndWords(
        ordered: List<String>,
        complexity: RhymeComplexity,
        limit: Int,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): List<String> {
        if (complexity == RhymeComplexity.MODERATE) return ordered.take(limit)
        val syllables = ordered.associateWith { ProsodyAnalyzer.analyzeWord(it, dictionary).syllableCount }
        return when (complexity) {
            RhymeComplexity.COMPLEX -> {
                val (multi, rest) = ordered.partition { syllables.getValue(it) >= 2 }
                (multi + rest).take(limit)
            }
            RhymeComplexity.SIMPLE -> {
                val (mono, rest) = ordered.partition { syllables.getValue(it) == 1 }
                if (mono.size >= SIMPLE_MIN_MONOSYLLABLES) mono.take(limit) else (mono + rest).take(limit)
            }
            RhymeComplexity.MODERATE -> ordered.take(limit)
        }
    }

    /** 3 = slant rhyme, 2 = perfect/multi rhyme, 1 = near rhyme, 0 = miss.
     *  Classified from every pronunciation of both words; mirrors iOS. */
    fun rhymeTier(
        line: String,
        targetWord: String,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): Int {
        val endWord = lineEndWord(line)
        if (endWord.isEmpty()) return 0
        return when (ProsodyAnalyzer.rhymeRelation(endWord, targetWord, dictionary)) {
            RhymeType.PERFECT -> 2
            RhymeType.NEAR -> 1
            RhymeType.SLANT -> 3
            null -> 0
        }
    }

    /** Dedupe, admit only the requested verified relation, then rank by
     *  syllable distance to the target line and arrival order. Mirrors iOS:
     *  lines that miss the relation are dropped, never used as padding. */
    fun filterAndRank(
        lines: List<String>,
        targetLine: String,
        rhymeType: RhymeType,
        want: Int,
        dictionary: PronunciationDictionary = PronunciationDictionary.shared
    ): List<String> {
        if (want <= 0 || lines.isEmpty()) return emptyList()
        // Unknown target word: the prompt was never constrained, so there is
        // nothing to verify against — keep arrival order.
        val filter = RhymeLineFilter.create(targetLine, rhymeType, dictionary)
            ?: return dedupe(lines).take(want)
        return filter.rank(lines, want)
    }

    /** Same normalization the suggestion stream uses for dedupe keys. */
    fun dedupeKey(line: String): String = line.lowercase().filter(Char::isLetterOrDigit)

    fun dedupe(lines: List<String>): List<String> {
        val seen = HashSet<String>()
        return lines.filter { line ->
            val key = dedupeKey(line)
            key.isEmpty() || seen.add(key)
        }
    }
}

/** Per-request rhyme verifier; mirrors iOS `RhymeLineFilter`. */
class RhymeLineFilter private constructor(
    private val targetSyllables: Int,
    private val targetWord: String,
    val rhymeType: RhymeType,
    private val dictionary: PronunciationDictionary
) {
    /** The tier when [line] ends in the requested relation, else 0. */
    fun tier(line: String): Int {
        val tier = RhymeConstraint.rhymeTier(line, targetWord, dictionary)
        val wanted = when (rhymeType) {
            RhymeType.PERFECT -> 2
            RhymeType.NEAR -> 1
            RhymeType.SLANT -> 3
        }
        return if (tier == wanted) tier else 0
    }

    /** Requested-relation lines only, closest syllable count first, then arrival order. */
    fun rank(lines: List<String>, want: Int): List<String> {
        if (want <= 0 || lines.isEmpty()) return emptyList()
        data class Scored(val line: String, val tier: Int, val syllableDistance: Int, val index: Int)
        val seen = HashSet<String>()
        val scored = ArrayList<Scored>()
        lines.forEachIndexed { index, line ->
            val key = RhymeConstraint.dedupeKey(line)
            if (key.isNotEmpty() && !seen.add(key)) return@forEachIndexed
            scored += Scored(line, tier(line), abs(SyllableCounter.countText(line) - targetSyllables), index)
        }
        return scored
            .filter { it.tier > 0 }
            .sortedWith(
                compareByDescending<Scored> { it.tier }.thenBy { it.syllableDistance }.thenBy { it.index }
            )
            .take(want)
            .map { it.line }
    }

    companion object {
        /** Null exactly when the prompt would not be constrained, so an
         *  unconstrained generation is never filtered. */
        fun create(
            targetLine: String?,
            rhymeType: RhymeType,
            dictionary: PronunciationDictionary = PronunciationDictionary.shared
        ): RhymeLineFilter? {
            if (targetLine.isNullOrBlank()) return null
            val targetWord = RhymeConstraint.lineEndWord(targetLine)
            if (targetWord.isEmpty()) return null
            if (RhymeConstraint.candidateEndWords(targetWord, rhymeType, dictionary = dictionary).isEmpty()) return null
            return RhymeLineFilter(SyllableCounter.countText(targetLine), targetWord, rhymeType, dictionary)
        }
    }
}
