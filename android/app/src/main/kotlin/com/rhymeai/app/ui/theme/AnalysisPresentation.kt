package com.rhymeai.app.ui.theme

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.text.font.FontWeight
import com.rhymeai.app.data.model.AnalysisPresentation

enum class InkUnderlinePattern { SOLID, DASHED, DOTTED, DASH_DOT }

fun analysisInkPattern(familyKey: String): InkUnderlinePattern {
    var hash = -3750763034362895579L
    familyKey.encodeToByteArray().forEach { byte ->
        hash = hash xor (byte.toLong() and 0xff)
        hash *= 1099511628211L
    }
    return InkUnderlinePattern.entries[(hash.toULong() % 4u).toInt()]
}

fun analysisFontWeight(syllableCount: Int): FontWeight = when (syllableCount) {
    0, 1 -> FontWeight.Normal
    2 -> FontWeight.Medium
    3 -> FontWeight.SemiBold
    else -> FontWeight.Bold
}

val LocalAnalysisPresentation = staticCompositionLocalOf { AnalysisPresentation.COLOR }
