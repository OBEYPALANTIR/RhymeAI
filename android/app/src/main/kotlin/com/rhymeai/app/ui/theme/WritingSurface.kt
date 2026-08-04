package com.rhymeai.app.ui.theme

import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.rhymeai.app.data.model.AppAppearance

private const val HighTextContrastSetting = "high_text_contrast_enabled"

@Composable
fun Modifier.appWritingSurface(): Modifier {
    val appearance = LocalAppAppearance.current
    val baseColor = MaterialTheme.colorScheme.background
    val context = LocalContext.current
    fun readHighTextContrast(): Boolean =
        Settings.Secure.getInt(context.contentResolver, HighTextContrastSetting, 0) == 1
    var highTextContrastEnabled by remember(context) {
        mutableStateOf(readHighTextContrast())
    }
    DisposableEffect(context) {
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                highTextContrastEnabled = readHighTextContrast()
            }
        }
        context.contentResolver.registerContentObserver(
            Settings.Secure.getUriFor(HighTextContrastSetting),
            false,
            observer
        )
        onDispose { context.contentResolver.unregisterContentObserver(observer) }
    }
    val textureEnabled = !highTextContrastEnabled

    val baseModifier = background(baseColor)
    if (!textureEnabled || appearance != AppAppearance.GRAPHITE) return baseModifier

    return baseModifier.drawWithCache {
        val grain = Path().apply {
            val rowSpacing = 16.dp.toPx()
            val columnSpacing = 22.dp.toPx()
            val markLength = 0.8.dp.toPx()
            var row = 0
            var y = 8.dp.toPx()
            while (y < size.height) {
                var x = (6 + (row % 3) * 5).dp.toPx()
                while (x < size.width) {
                    moveTo(x, y)
                    lineTo(x + markLength, y + markLength * 0.35f)
                    x += columnSpacing
                }
                row += 1
                y += rowSpacing
            }
        }
        onDrawBehind {
            drawPath(
                path = grain,
                color = GraphiteWarmWhite.copy(alpha = 0.018f),
                style = Stroke(width = 0.75.dp.toPx())
            )
        }
    }
}
