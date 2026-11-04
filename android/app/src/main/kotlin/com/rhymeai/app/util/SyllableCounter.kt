package com.rhymeai.app.util

object SyllableCounter {
    private val whitespaceSplitPattern = Regex("\\s+")
    private const val WORD_CACHE_CAPACITY = 8192
    private const val LINE_CACHE_CAPACITY = 2048

    /**
     * One lyric line, counted once. [tokens] holds start, endExclusive and syllables for each
     * alphanumeric word (the editor underlines); a section header line counts as empty.
     */
    class LyricLine internal constructor(val words: Int, val syllables: Int, val tokens: IntArray)

    private val emptyLine = LyricLine(0, 0, IntArray(0))
    private val lock = Any()
    private var cachedDictionary: PronunciationDictionary? = null
    private val wordCounts = HashMap<String, Int>()
    private val lines = HashMap<String, LyricLine>()

    /** Syllables in [word]. One memo, keyed by the normalised word, serves the counter, underlines and colouring. */
    fun count(word: String): Int {
        val key = ProsodyAnalyzer.normalizeWord(word)
        if (key.isEmpty()) return 0
        synchronized(lock) {
            dropIfDictionaryChanged()
            wordCounts[key]?.let { return it }
        }
        val counted = ProsodyAnalyzer.countWord(key)
        synchronized(lock) {
            if (wordCounts.size >= WORD_CACHE_CAPACITY) wordCounts.clear()
            wordCounts[key] = counted
        }
        return counted
    }

    /** The syllables of every word in [text], from the word memo (no stress or IPA work). */
    fun countText(text: String): Int = LyricTokenizer.wordPattern.findAll(text).sumOf { count(it.value) }

    fun wordCount(text: String): Int {
        return text.split(whitespaceSplitPattern).count { it.isNotBlank() }
    }

    /** [line] (no newline) counted once and memoised, so an edit re-counts only the lines it changed. */
    fun lyricLine(line: String): LyricLine {
        synchronized(lock) {
            dropIfDictionaryChanged()
            lines[line]?.let { return it }
        }
        val counted = if (SectionMap.headerTitle(line) != null) emptyLine else {
            val tokens = LyricTokenizer.alphanumericWordPattern.findAll(line).toList()
            val triples = IntArray(tokens.size * 3)
            tokens.forEachIndexed { index, match ->
                triples[index * 3] = match.range.first
                triples[index * 3 + 1] = match.range.last + 1
                triples[index * 3 + 2] = count(match.value)
            }
            LyricLine(wordCount(line), countText(line), triples)
        }
        synchronized(lock) {
            if (lines.size >= LINE_CACHE_CAPACITY) lines.clear()
            lines[line] = counted
        }
        return counted
    }

    /** Calls [action] with each line's start offset in [lyrics] and its memoised count. */
    inline fun forEachLyricLine(lyrics: String, action: (lineStart: Int, line: LyricLine) -> Unit) {
        var lineStart = 0
        while (true) {
            val newline = lyrics.indexOf('\n', lineStart)
            val lineEnd = if (newline < 0) lyrics.length else newline
            action(lineStart, lyricLine(lyrics.substring(lineStart, lineEnd)))
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

    // Counts made before the pronunciation dictionary finished loading used the spelling fallback.
    private fun dropIfDictionaryChanged() {
        val dictionary = PronunciationDictionary.shared
        if (dictionary !== cachedDictionary) {
            cachedDictionary = dictionary
            wordCounts.clear()
            lines.clear()
        }
    }
}
