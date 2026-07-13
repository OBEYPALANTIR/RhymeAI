package com.rhymeai.app.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.util.ProsodyAnalyzer
import com.rhymeai.app.ui.theme.LocalAppAppearance
import com.rhymeai.app.ui.theme.subtleColorFor

@Composable
fun ProsodyPreview(
    text: String,
    modifier: Modifier = Modifier
) {
    val supportColor = subtleColorFor(LocalAppAppearance.current)
    val prosody = remember(text) { ProsodyAnalyzer.analyzeLine(text) }
    if (prosody.syllableCount == 0) return

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        if (prosody.feet.isNotBlank()) {
            Text(
                prosody.feet,
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                lineHeight = 16.sp,
                color = supportColor
            )
        }
        if (prosody.ipa.isNotBlank()) {
            Text(
                "/${prosody.ipa}/",
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                lineHeight = 16.sp,
                color = supportColor
            )
        }
    }
}
