package com.rhymeai.app.ui.components

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.rhymeai.app.data.model.AnalysisPresentation
import com.rhymeai.app.ui.theme.InkUnderlinePattern
import com.rhymeai.app.ui.theme.LocalAnalysisPresentation
import com.rhymeai.app.ui.theme.LocalAppAppearance
import com.rhymeai.app.ui.theme.analysisFontWeight
import com.rhymeai.app.ui.theme.analysisInkPattern
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

@Immutable
data class RhymeUnderlineSpan(
    val start: Int,
    val endExclusive: Int,
    val color: Color,
    val pattern: InkUnderlinePattern
)

@Immutable
data class AnalysisWordWeight(
    val start: Int,
    val endExclusive: Int,
    val weight: FontWeight
)

@Immutable
data class AnalysisTextResult(
    val text: AnnotatedString,
    val rhymeSpans: List<RhymeUnderlineSpan>,
    val wordWeights: List<AnalysisWordWeight>
)

@Composable
fun RhymeHighlightedText(
    text: String,
    enabled: Boolean,
    syllablesEnabled: Boolean = false,
    modifier: Modifier = Modifier,
    style: TextStyle = TextStyle.Default
) {
    val result = rememberAnalysisTextResult(text, enabled, syllablesEnabled)
    var layoutResult by remember { mutableStateOf<TextLayoutResult?>(null) }
    val density = LocalDensity.current
    val strokeWidth = with(density) { 3.dp.toPx() }
    val underlineGap = with(density) { 2.dp.toPx() }

    Text(
        text = result.text,
        modifier = modifier.rhymeUnderlines(
            spans = result.rhymeSpans,
            textLayoutResult = layoutResult,
            underlineGap = underlineGap,
            strokeWidth = strokeWidth
        ),
        style = style,
        onTextLayout = { layoutResult = it }
    )
}

@Composable
internal fun rememberAnalysisTextResult(
    text: String,
    enabled: Boolean,
    syllablesEnabled: Boolean = false
): AnalysisTextResult {
    val baseTextColor = MaterialTheme.colorScheme.onBackground
    val isDark = LocalAppAppearance.current.isDark
    val palette = rhymePalette(isDark)
    val presentation = LocalAnalysisPresentation.current

    if ((!enabled && !syllablesEnabled) || text.isEmpty()) {
        return remember(text) {
            AnalysisTextResult(AnnotatedString(text), emptyList(), emptyList())
        }
    }

    var result by remember(
        text,
        baseTextColor,
        palette,
        isDark,
        presentation,
        enabled,
        syllablesEnabled
    ) {
        mutableStateOf(
            AnalysisTextResult(
                text = AnnotatedString(text),
                rhymeSpans = emptyList(),
                wordWeights = emptyList()
            )
        )
    }
    LaunchedEffect(
        text,
        baseTextColor,
        palette,
        isDark,
        presentation,
        enabled,
        syllablesEnabled
    ) {
        result = withContext(Dispatchers.Default) {
            buildAnalysisText(
                text = text,
                baseTextColor = baseTextColor,
                rhymePalette = palette,
                isDark = isDark,
                presentation = presentation,
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
    presentation: AnalysisPresentation,
    rhymeEnabled: Boolean,
    syllablesEnabled: Boolean
): AnalysisTextResult {
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
    val rhymeSpans = mutableListOf<RhymeUnderlineSpan>()
    val weights = mutableListOf<AnalysisWordWeight>()

    val annotated = buildAnnotatedString {
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
            val tokenStyle = when (presentation) {
                AnalysisPresentation.COLOR -> when {
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
                AnalysisPresentation.INK_MARKS -> {
                    val weight = syllableCount?.let(::analysisFontWeight)
                    if (weight != null) {
                        weights += AnalysisWordWeight(token.start, token.end, weight)
                    }
                    if (rhymeEnabled && familyKey != null) {
                        rhymeSpans += RhymeUnderlineSpan(
                            start = token.start,
                            endExclusive = token.end,
                            color = baseTextColor,
                            pattern = analysisInkPattern(familyKey)
                        )
                    }
                    if (weight == null) {
                        SpanStyle(color = baseTextColor)
                    } else {
                        SpanStyle(color = baseTextColor, fontWeight = weight)
                    }
                }
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

    return AnalysisTextResult(annotated, rhymeSpans, weights)
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
