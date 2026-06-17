package com.rhymeai.app.ui.components

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import com.rhymeai.app.ui.theme.rhymePalette
import com.rhymeai.app.util.RhymePhonetics
import kotlin.math.absoluteValue

private val wordPattern = Regex("[a-zA-Z']+")

private data class Token(val text: String, val start: Int, val end: Int)

@Composable
fun RhymeHighlightedText(
    text: String,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    style: TextStyle = TextStyle.Default
) {
    val baseTextColor = MaterialTheme.colorScheme.onBackground
    val palette = rhymePalette(isSystemInDarkTheme())

    if (!enabled || text.isEmpty()) {
        Text(text = text, modifier = modifier, style = style, color = baseTextColor)
        return
    }

    val tokens = wordPattern.findAll(text)
        .map { Token(it.value, it.range.first, it.range.last + 1) }
        .toList()

    val keysPerToken = tokens.map { RhymePhonetics.rhymeKeys(it.text, maxDepth = 2) }

    val keyOccurrences = mutableMapOf<String, Int>()
    for (keys in keysPerToken) {
        for (k in keys) keyOccurrences[k] = (keyOccurrences[k] ?: 0) + 1
    }

    val familyKeyPerToken: List<String?> = keysPerToken.map { keys ->
        keys.lastOrNull { (keyOccurrences[it] ?: 0) >= 2 }
    }

    val annotated = buildAnnotatedString {
        var cursor = 0
        for ((i, tok) in tokens.withIndex()) {
            if (tok.start > cursor) {
                withStyle(SpanStyle(color = baseTextColor)) {
                    append(text.substring(cursor, tok.start))
                }
            }
            val familyKey = familyKeyPerToken[i]
            if (familyKey != null) {
                withStyle(
                    SpanStyle(
                        color = colorFor(familyKey, palette),
                        fontWeight = FontWeight.SemiBold
                    )
                ) {
                    append(tok.text)
                }
            } else {
                withStyle(SpanStyle(color = baseTextColor)) {
                    append(tok.text)
                }
            }
            cursor = tok.end
        }
        if (cursor < text.length) {
            withStyle(SpanStyle(color = baseTextColor)) {
                append(text.substring(cursor))
            }
        }
    }

    Text(text = annotated, modifier = modifier, style = style)
}

private fun colorFor(familyKey: String, palette: List<Color>): Color {
    val idx = (familyKey.hashCode().absoluteValue) % palette.size
    return palette[idx]
}
