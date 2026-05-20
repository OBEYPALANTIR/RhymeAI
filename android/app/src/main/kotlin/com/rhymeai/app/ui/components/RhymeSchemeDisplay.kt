package com.rhymeai.app.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.RhymeContext

@Composable
fun RhymeSchemeDisplay(
    rhymeContext: RhymeContext,
    activeScheme: String,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    val schemeLetters = activeScheme.toList()
    if (schemeLetters.isEmpty() || rhymeContext.stanzaLines.isEmpty()) return

    Surface(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(max = 160.dp),
        shape = RoundedCornerShape(12.dp),
        color = colorScheme.surfaceContainer,
        contentColor = colorScheme.onSurface,
        border = BorderStroke(1.dp, colorScheme.outlineVariant)
    ) {
        Column(
            modifier = Modifier
                .padding(12.dp)
                .verticalScroll(rememberScrollState())
        ) {
            rhymeContext.stanzaLines.forEachIndexed { i, line ->
                val letter = schemeLetters[i % schemeLetters.size].toString()
                val isCurrent = i == rhymeContext.currentLineIndex
                val alpha = if (isCurrent) 1f else 0.65f

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 1.dp)
                ) {
                    Text(
                        text = letter,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Bold,
                        fontSize = 12.sp,
                        color = if (isCurrent) colorScheme.primary else colorScheme.onSurfaceVariant,
                        modifier = Modifier.width(16.dp)
                    )
                    Spacer(Modifier.width(12.dp))
                    if (line.isNotEmpty()) {
                        Text(
                            text = line,
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                            color = colorScheme.onSurface.copy(alpha = alpha),
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    } else if (isCurrent) {
                        Text(
                            text = "Typing here...",
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                            fontStyle = FontStyle.Italic,
                            color = colorScheme.onSurfaceVariant
                        )
                    }
                }
            }
        }
    }
}
