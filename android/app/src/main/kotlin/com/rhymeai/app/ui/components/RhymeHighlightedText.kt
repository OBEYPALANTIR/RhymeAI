package com.rhymeai.app.ui.components

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
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
import com.rhymeai.app.util.SyllableCounter

private val wordPattern = LyricTokenizer.wordPattern

private data class Token(val text: String, val start: Int, val end: Int)

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
    val baseTextColor = MaterialTheme.colorScheme.onBackground
    val isDark = LocalAppAppearance.current.isDark
    val palette = rhymePalette(isDark)
    val presentation = LocalAnalysisPresentation.current

    if ((!enabled && !syllablesEnabled) || text.isEmpty()) {
        Text(text = text, modifier = modifier, style = style, color = baseTextColor)
        return
    }

    val result = remember(
        text,
        baseTextColor,
        palette,
        isDark,
        presentation,
        enabled,
        syllablesEnabled
    ) {
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

internal fun buildAnalysisText(
    text: String,
    baseTextColor: Color,
    rhymePalette: List<Color>,
    isDark: Boolean,
    presentation: AnalysisPresentation,
    rhymeEnabled: Boolean,
    syllablesEnabled: Boolean
): AnalysisTextResult {
    val tokens = wordPattern.findAll(text)
        .map { Token(it.value, it.range.first, it.range.last + 1) }
        .toList()
    val keysPerToken = if (rhymeEnabled) {
        tokens.map { RhymePhonetics.rhymeKeys(it.text, maxDepth = 2) }
    } else {
        List(tokens.size) { emptyList() }
    }
    val occurrences = mutableMapOf<String, Int>()
    keysPerToken.flatten().forEach { key -> occurrences[key] = (occurrences[key] ?: 0) + 1 }
    val familyKeys = keysPerToken.map { keys -> keys.lastOrNull { (occurrences[it] ?: 0) >= 2 } }
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
                SyllableCounter.count(token.text)
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
