package com.rhymeai.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.ui.theme.Indigo400
import com.rhymeai.app.util.SyllableCounter

private val lastWordPattern = Regex("(.*?)(\\b\\w+\\b)([^\\w]*)\$")

@Composable
fun SuggestionCard(
    suggestion: String,
    highlightRhyme: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .background(Color.White.copy(alpha = 0.05f), RoundedCornerShape(12.dp))
            .border(1.dp, Color.White.copy(alpha = 0.05f), RoundedCornerShape(12.dp))
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        // Suggestion text with optional rhyme highlight
        val annotated = if (highlightRhyme) {
            val match = lastWordPattern.find(suggestion)
            if (match != null) {
                buildAnnotatedString {
                    withStyle(SpanStyle(color = Color.White.copy(alpha = 0.9f))) {
                        append(match.groupValues[1])
                    }
                    withStyle(SpanStyle(
                        color = Indigo400.copy(alpha = 0.8f),
                        fontWeight = FontWeight.Medium,
                        textDecoration = TextDecoration.Underline
                    )) {
                        append(match.groupValues[2])
                    }
                    withStyle(SpanStyle(color = Color.White.copy(alpha = 0.9f))) {
                        append(match.groupValues[3])
                    }
                }
            } else {
                buildAnnotatedString {
                    withStyle(SpanStyle(color = Color.White.copy(alpha = 0.9f))) {
                        append(suggestion)
                    }
                }
            }
        } else {
            buildAnnotatedString {
                withStyle(SpanStyle(color = Color.White.copy(alpha = 0.9f))) {
                    append(suggestion)
                }
            }
        }

        Text(
            text = annotated,
            fontFamily = FontFamily.Serif,
            fontSize = 14.sp,
            lineHeight = 20.sp,
            modifier = Modifier.weight(1f)
        )

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            // Syllable count badge
            Box(
                modifier = Modifier
                    .background(Color.White.copy(alpha = 0.05f), RoundedCornerShape(6.dp))
                    .padding(horizontal = 8.dp, vertical = 4.dp)
            ) {
                Text(
                    text = "${SyllableCounter.countText(suggestion)}",
                    fontFamily = FontFamily.Monospace,
                    fontSize = 11.sp,
                    color = Color.White.copy(alpha = 0.4f)
                )
            }
            Icon(
                Icons.Default.ChevronRight,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.2f),
                modifier = Modifier.padding(start = 4.dp)
            )
        }
    }
}
