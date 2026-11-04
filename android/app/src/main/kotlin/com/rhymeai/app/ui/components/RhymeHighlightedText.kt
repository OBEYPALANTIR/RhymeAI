package com.rhymeai.app.ui.components

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.OffsetMapping
import androidx.compose.ui.text.input.TransformedText
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.withStyle
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAppAppearance
import com.rhymeai.app.ui.theme.rhymePalette
import com.rhymeai.app.ui.theme.syllableColor
import com.rhymeai.app.util.LyricTokenizer
import com.rhymeai.app.util.PronunciationDictionary
import com.rhymeai.app.util.RhymePhonetics
import com.rhymeai.app.util.SectionMap
import com.rhymeai.app.util.SyllableCounter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private val wordPattern = LyricTokenizer.wordPattern

private data class Token(val text: String, val start: Int, val end: Int)

private data class WordAnalysis(
    val rhymeKeys: List<String>,
    val syllableCount: Int
)

private data class DocumentAnalysisRequest(
    val text: String,
    val rhymeEnabled: Boolean,
    val dictionary: PronunciationDictionary = PronunciationDictionary.shared
)

private data class DocumentAnalysis(
    val tokens: List<Token>,
    val words: List<WordAnalysis>,
    val familyKeys: List<String?>
)

private object WordAnalysisCache {
    private const val CAPACITY = 4096
    private val entries = LinkedHashMap<String, WordAnalysis>()

    private var dictionary: PronunciationDictionary? = null

    fun analysisFor(word: String): WordAnalysis {
        val key = word.lowercase()
        synchronized(entries) {
            // Rhyme keys made before the pronunciation dictionary finished loading used the spelling fallback.
            if (dictionary !== PronunciationDictionary.shared) {
                dictionary = PronunciationDictionary.shared
                entries.clear()
            }
            entries[key]?.let { return it }
        }

        val computed = WordAnalysis(
            rhymeKeys = RhymePhonetics.rhymeKeys(key, maxDepth = 2),
            syllableCount = SyllableCounter.count(key)
        )
        synchronized(entries) {
            entries[key]?.let { return it }
            if (entries.size >= CAPACITY) {
                entries.clear()
            }
            entries[key] = computed
        }
        return computed
    }
}

/** One lyric line's words and their analyses, memoised so an unchanged line is never re-analysed. */
private class LineAnalysis(val tokens: List<Token>, val words: List<WordAnalysis>)

private object LineAnalysisCache {
    private const val CAPACITY = 2048
    private val empty = LineAnalysis(emptyList(), emptyList())
    private val entries = HashMap<String, LineAnalysis>()

    private var dictionary: PronunciationDictionary? = null

    fun analysisFor(line: String): LineAnalysis {
        synchronized(entries) {
            if (dictionary !== PronunciationDictionary.shared) {
                dictionary = PronunciationDictionary.shared
                entries.clear()
            }
            entries[line]?.let { return it }
        }
        val computed = if (SectionMap.headerTitle(line) != null) empty else {
            val tokens = wordPattern.findAll(line).map { Token(it.value, it.range.first, it.range.last + 1) }.toList()
            LineAnalysis(tokens, tokens.map { WordAnalysisCache.analysisFor(it.text) })
        }
        synchronized(entries) {
            if (entries.size >= CAPACITY) entries.clear()
            entries[line] = computed
        }
        return computed
    }
}

private object DocumentAnalysisCache {
    private val lock = Any()
    private var latestRequest: DocumentAnalysisRequest? = null
    private var latestAnalysis: DocumentAnalysis? = null

    fun analysisFor(
        request: DocumentAnalysisRequest,
        build: () -> DocumentAnalysis
    ): DocumentAnalysis {
        synchronized(lock) {
            if (latestRequest == request) {
                latestAnalysis?.let { return it }
            }
        }

        val computed = build()
        synchronized(lock) {
            if (latestRequest == request) {
                latestAnalysis?.let { return it }
            }
            latestRequest = request
            latestAnalysis = computed
        }
        return computed
    }
}

/**
 * The lyric coloured by rhyme family or syllable count. The colouring is built off the main
 * thread for each new text; until it lands, the last colouring is carried across the edit
 * ([shiftAnalysis]), so no frame shows the words uncoloured. A song longer than
 * [DesignTokens.Editor.liveColouringMaxWords] instead shows plain text while typing and is
 * recoloured once typing pauses.
 */
@Composable
internal fun rememberAnalysisText(
    text: String,
    enabled: Boolean,
    syllablesEnabled: Boolean = false,
    wordCount: Int = 0
): AnnotatedString {
    val baseTextColor = MaterialTheme.colorScheme.onBackground
    val isDark = LocalAppAppearance.current.isDark
    val palette = rhymePalette(isDark)

    if ((!enabled && !syllablesEnabled) || text.isEmpty()) {
        return remember(text) { AnnotatedString(text) }
    }

    // Plain only until the first colouring for these settings lands (opening a song, a toggle).
    var latest by remember(baseTextColor, palette, isDark, enabled, syllablesEnabled) {
        mutableStateOf(AnnotatedString(""))
    }
    val live = colouringFollowsEveryKeystroke(wordCount)
    LaunchedEffect(text, baseTextColor, palette, isDark, enabled, syllablesEnabled) {
        if (latest.text == text) return@LaunchedEffect
        if (!live) delay(DesignTokens.Editor.deferredColouringPauseMillis)
        // A newer text cancels this job, so whatever lands is for the text on screen.
        latest = withContext(Dispatchers.Default) {
            buildAnalysisText(
                text = text,
                baseTextColor = baseTextColor,
                rhymePalette = palette,
                isDark = isDark,
                rhymeEnabled = enabled,
                syllablesEnabled = syllablesEnabled
            )
        }
    }
    val current = latest
    return when {
        current.text == text -> current
        current.text.isEmpty() || !live -> remember(text) { AnnotatedString(text) }
        else -> remember(current, text) { shiftAnalysis(current, text) }
    }
}

/** Whether a lyric of [wordCount] words is recoloured on every keystroke or only after a pause. */
internal fun colouringFollowsEveryKeystroke(wordCount: Int): Boolean =
    wordCount <= DesignTokens.Editor.liveColouringMaxWords

/**
 * [previous] colouring carried onto [text] across the one edit between them: styles before the
 * edit stay, styles after it shift by its length change, a word spanning the edit keeps its colour.
 */
internal fun shiftAnalysis(previous: AnnotatedString, text: String): AnnotatedString {
    val edit = TextEdit(previous.text, text)
    val oldTailStart = previous.text.length - edit.suffix
    fun start(offset: Int) = when {
        offset >= oldTailStart -> offset + edit.delta
        offset <= edit.prefix -> offset
        else -> edit.newEnd
    }
    fun end(offset: Int) = when {
        offset <= edit.prefix -> offset
        offset >= oldTailStart -> offset + edit.delta
        else -> edit.prefix
    }
    val spans = previous.spanStyles.mapNotNull { range ->
        val from = start(range.start)
        val to = end(range.end)
        if (from < to) AnnotatedString.Range(range.item, from, to) else null
    }
    return AnnotatedString(text, spans)
}

internal fun buildAnalysisText(
    text: String,
    baseTextColor: Color,
    rhymePalette: List<Color>,
    isDark: Boolean,
    rhymeEnabled: Boolean,
    syllablesEnabled: Boolean
): AnnotatedString {
    val documentAnalysis = DocumentAnalysisCache.analysisFor(
        DocumentAnalysisRequest(text = text, rhymeEnabled = rhymeEnabled)
    ) {
        val tokens = ArrayList<Token>()
        val analyses = ArrayList<WordAnalysis>()
        var lineStart = 0
        while (true) {
            val newline = text.indexOf('\n', lineStart)
            val lineEnd = if (newline < 0) text.length else newline
            val line = LineAnalysisCache.analysisFor(text.substring(lineStart, lineEnd))
            line.tokens.forEach { tokens += Token(it.text, lineStart + it.start, lineStart + it.end) }
            analyses += line.words
            if (newline < 0) break
            lineStart = newline + 1
        }
        val keysPerToken = if (rhymeEnabled) {
            analyses.map(WordAnalysis::rhymeKeys)
        } else {
            List(tokens.size) { emptyList() }
        }
        val occurrences = mutableMapOf<String, Int>()
        keysPerToken.forEach { keys -> keys.forEach { key -> occurrences[key] = (occurrences[key] ?: 0) + 1 } }
        DocumentAnalysis(
            tokens = tokens,
            words = analyses,
            familyKeys = keysPerToken.map { keys ->
                keys.lastOrNull { (occurrences[it] ?: 0) >= 2 }
            }
        )
    }
    val tokens = documentAnalysis.tokens
    val analyses = documentAnalysis.words
    val familyKeys = documentAnalysis.familyKeys
    val familyColors = assignRhymeFamilyColors(familyKeys, rhymePalette)

    return buildAnnotatedString {
        var cursor = 0
        // Only coloured words carry a style; the rest takes the field's own colour ([baseTextColor]).
        // Every span makes each glyph-position query on the laid-out lyric slower.
        tokens.forEachIndexed { index, token ->
            if (token.start > cursor) append(text, cursor, token.start)

            val syllableCount = if (syllablesEnabled) {
                analyses[index].syllableCount
            } else {
                null
            }
            val familyKey = familyKeys[index]
            // Rhyme colouring owns the word colour when it is on; the syllable cue then moves
            // to the underline drawn by the editor, so the foreground is never double-claimed.
            val tokenStyle = when {
                rhymeEnabled && familyKey != null -> SpanStyle(
                    color = familyColors.getValue(familyKey),
                    fontWeight = FontWeight.SemiBold
                )
                !rhymeEnabled && syllablesEnabled -> SpanStyle(
                    color = syllableColor(requireNotNull(syllableCount), isDark),
                    fontWeight = FontWeight.SemiBold
                )
                else -> null
            }
            if (tokenStyle == null) append(token.text) else withStyle(tokenStyle) { append(token.text) }
            cursor = token.end
        }
        if (cursor < text.length) append(text, cursor, text.length)
    }
}

/**
 * Draws the analysed lyric inside the editor field. Offsets map one to one, so the
 * cursor and any selection sit on the coloured words instead of replacing them.
 */
internal fun lyricAnalysisTransformation(
    active: Boolean,
    analysed: AnnotatedString
): VisualTransformation = VisualTransformation { source ->
    val transformed = if (active && analysed.text == source.text) analysed else source
    TransformedText(transformed, OffsetMapping.Identity)
}

internal fun assignRhymeFamilyColors(
    familyKeys: List<String?>,
    palette: List<Color>
): Map<String, Color> {
    require(palette.isNotEmpty())
    val assignments = linkedMapOf<String, Color>()
    familyKeys.forEach { key ->
        if (key != null && key !in assignments) {
            assignments[key] = palette[assignments.size % palette.size]
        }
    }
    return assignments
}
