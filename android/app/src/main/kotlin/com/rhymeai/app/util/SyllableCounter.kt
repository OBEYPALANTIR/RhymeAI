package com.rhymeai.app.util

object SyllableCounter {
    private val whitespaceSplitPattern = Regex("\\s+")
    // Bounded by characters, not entries: one huge pasted paragraph edited repeatedly must not pile up.
    private const val MEMO_CHARACTERS = 200_000
    private const val MAX_MEMO_LINE_CHARACTERS = 2_000
    private const val MAX_MEMO_WORD_CHARACTERS = 64

    /**
     * One lyric line, counted once. [tokens] holds start, endExclusive and syllables for each
     * alphanumeric word (the editor underlines); a section header line counts as empty.
     */
    class LyricLine internal constructor(val words: Int, val syllables: Int, val tokens: IntArray)

    private val emptyLine = LyricLine(0, 0, IntArray(0))
    private val wordCounts = pronunciationMemo<Int>(MEMO_CHARACTERS, MAX_MEMO_WORD_CHARACTERS)
    private val lines = pronunciationMemo<LyricLine>(MEMO_CHARACTERS, MAX_MEMO_LINE_CHARACTERS)

    /** Characters of lyric lines the per-line memo currently keeps. */
    internal val retainedLineCharacters: Int get() = lines.retainedCharacters

    /** Syllables in [word]. One memo, keyed by the normalised word, serves the counter, underlines and colouring. */
    fun count(word: String): Int {
        val key = ProsodyAnalyzer.normalizeWord(word)
        if (key.isEmpty()) return 0
        return wordCounts.getOrPut(key) { dictionary -> ProsodyAnalyzer.countWord(key, dictionary) }
    }

    /** The syllables of every word in [text], from the word memo (no stress or IPA work). */
    fun countText(text: String): Int = LyricTokenizer.wordPattern.findAll(text).sumOf { count(it.value) }

    fun wordCount(text: String): Int {
        return text.split(whitespaceSplitPattern).count { it.isNotBlank() }
    }

    /**
     * [line] (no newline) counted once and memoised, so an edit re-counts only the lines it changed.
     * [index] (the line's position in the lyric) lets a very long line keep its latest count.
     */
    fun lyricLine(line: String, index: Int = -1): LyricLine = lines.getOrPut(line, index) {
        if (SectionMap.headerTitle(line) != null) emptyLine else {
            val tokens = LyricTokenizer.alphanumericWordPattern.findAll(line).toList()
            val triples = IntArray(tokens.size * 3)
            tokens.forEachIndexed { index, match ->
                triples[index * 3] = match.range.first
                triples[index * 3 + 1] = match.range.last + 1
                triples[index * 3 + 2] = count(match.value)
            }
            LyricLine(wordCount(line), countText(line), triples)
        }
    }

    /** Calls [action] with each line's start offset in [lyrics] and its memoised count. */
    inline fun forEachLyricLine(lyrics: String, action: (lineStart: Int, line: LyricLine) -> Unit) {
        var lineStart = 0
        var index = 0
        while (true) {
            val newline = lyrics.indexOf('\n', lineStart)
            val lineEnd = if (newline < 0) lyrics.length else newline
            action(lineStart, lyricLine(lyrics.substring(lineStart, lineEnd), index++))
            if (newline < 0) return
            lineStart = newline + 1
        }
    }

    fun lyricSyllableCount(lyrics: String): Int {
        var total = 0
        forEachLyricLine(lyrics) { _, line -> total += line.syllables }
        return total
    }

    fun lyricWordCount(lyrics: String): Int {
        var total = 0
        forEachLyricLine(lyrics) { _, line -> total += line.words }
        return total
    }
}
