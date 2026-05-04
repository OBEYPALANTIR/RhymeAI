package com.rhymeai.app.ui.components

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import com.rhymeai.app.ui.theme.SyllableBlue
import com.rhymeai.app.ui.theme.SyllableEmerald
import com.rhymeai.app.ui.theme.SyllablePurple
import com.rhymeai.app.ui.theme.SyllableRose
import com.rhymeai.app.util.SyllableCounter

private val wordPattern = Regex("[a-zA-Z0-9']+")

fun syllableColor(count: Int): Color = when (count) {
    1 -> SyllableEmerald
    2 -> SyllableBlue
    3 -> SyllablePurple
    else -> SyllableRose
}

@Composable
fun SyllableColoredText(
    text: String,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    style: TextStyle = TextStyle.Default
) {
    if (!enabled || text.isEmpty()) {
        Text(
            text = text,
            modifier = modifier,
            style = style,
            color = Color.White.copy(alpha = 0.9f)
        )
        return
    }

    val annotated = buildAnnotatedString {
        var lastIndex = 0
        wordPattern.findAll(text).forEach { match ->
            // Append non-word text before this match
            if (match.range.first > lastIndex) {
                withStyle(SpanStyle(color = Color.White.copy(alpha = 0.9f))) {
                    append(text.substring(lastIndex, match.range.first))
                }
            }
            // Append the word with syllable color
            val word = match.value
            val count = SyllableCounter.count(word)
            withStyle(SpanStyle(color = syllableColor(count))) {
                append(word)
            }
            lastIndex = match.range.last + 1
        }
        // Append remaining text
        if (lastIndex < text.length) {
            withStyle(SpanStyle(color = Color.White.copy(alpha = 0.9f))) {
                append(text.substring(lastIndex))
            }
        }
    }

    Text(
        text = annotated,
        modifier = modifier,
        style = style
    )
}
