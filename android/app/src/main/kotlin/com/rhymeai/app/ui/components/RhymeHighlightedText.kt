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
import com.rhymeai.app.ui.theme.LocalAppAppearance
import com.rhymeai.app.ui.theme.rhymePalette
import com.rhymeai.app.ui.theme.syllableColor
import com.rhymeai.app.util.LyricTokenizer
import com.rhymeai.app.util.RhymePhonetics
import com.rhymeai.app.util.SectionMap
import com.rhymeai.app.util.SyllableCounter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private val wordPattern = LyricTokenizer.wordPattern

private data class Token(val text: String, val start: Int, val end: Int)

private data class WordAnalysis(
    val rhymeKeys: List<String>,
    val syllableCount: Int
)

private data class DocumentAnalysisRequest(
    val text: String,
    val rhymeEnabled: Boolean
)

private data class DocumentAnalysis(
    val tokens: List<Token>,
    val words: List<WordAnalysis>,
    val familyKeys: List<String?>
)

private object WordAnalysisCache {
    private const val CAPACITY = 4096
    private val entries = LinkedHashMap<String, WordAnalysis>()

    fun analysisFor(word: String): WordAnalysis {
        val key = word.lowercase()
        synchronized(entries) {
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

@Composable
internal fun rememberAnalysisText(
    text: String,
    enabled: Boolean,
    syllablesEnabled: Boolean = false
): AnnotatedString {
    val baseTextColor = MaterialTheme.colorScheme.onBackground
    val isDark = LocalAppAppearance.current.isDark
    val palette = rhymePalette(isDark)

    if ((!enabled && !syllablesEnabled) || text.isEmpty()) {
        return remember(text) { AnnotatedString(text) }
    }

    var result by remember(text, baseTextColor, palette, isDark, enabled, syllablesEnabled) {
        mutableStateOf(AnnotatedString(text))
    }
    LaunchedEffect(text, baseTextColor, palette, isDark, enabled, syllablesEnabled) {
        result = withContext(Dispatchers.Default) {
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
    return result
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
        val headerRanges = SectionMap.headerRanges(text)
        val tokens = wordPattern.findAll(text)
            .filterNot { match ->
                SectionMap.intersectsHeader(match.range, headerRanges)
            }
            .map { Token(it.value, it.range.first, it.range.last + 1) }
            .toList()
        val analyses = tokens.map { WordAnalysisCache.analysisFor(it.text) }
        val keysPerToken = if (rhymeEnabled) {
            analyses.map(WordAnalysis::rhymeKeys)
        } else {
            List(tokens.size) { emptyList() }
        }
        val occurrences = mutableMapOf<String, Int>()
        keysPerToken.flatten().forEach { key -> occurrences[key] = (occurrences[key] ?: 0) + 1 }
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
        tokens.forEachIndexed { index, token ->
            if (token.start > cursor) {
                withStyle(SpanStyle(color = baseTextColor)) {
                    append(text.substring(cursor, token.start))
                }
            }

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
                else -> SpanStyle(color = baseTextColor)
            }
            withStyle(tokenStyle) { append(token.text) }
            cursor = token.end
        }
        if (cursor < text.length) {
            withStyle(SpanStyle(color = baseTextColor)) {
                append(text.substring(cursor))
            }
        }
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
