package com.rhymeai.app.ui.components

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle

private val lastWordPattern = Regex("(.*?)(\\b\\w+\\b)([^\\w]*)\$")

/**
 * Marks the line's last word as the rhyme being matched: [color], semibold, underlined.
 * The rest of the line is left unstyled so it takes the Text's own colour.
 */
internal fun rhymeMatchAnnotated(text: String, color: Color): AnnotatedString {
    val match = lastWordPattern.find(text) ?: return AnnotatedString(text)
    return buildAnnotatedString {
        append(match.groupValues[1])
        // Compose has no separate underline colour, so the underline is full-strength [color].
        withStyle(SpanStyle(color = color, fontWeight = FontWeight.SemiBold, textDecoration = TextDecoration.Underline)) {
            append(match.groupValues[2])
        }
        append(match.groupValues[3])
    }
}
