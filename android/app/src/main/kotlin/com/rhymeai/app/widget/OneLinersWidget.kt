package com.rhymeai.app.widget

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.Button
import androidx.glance.ButtonDefaults
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.LocalSize
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.action.clickable
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import com.rhymeai.app.MainActivity
import com.rhymeai.app.data.model.AppAppearance
import com.rhymeai.app.data.model.OneLinersSnapshot
import com.rhymeai.app.data.repository.OneLinersStore
import com.rhymeai.app.ui.navigation.OneLinerAction
import com.rhymeai.app.ui.theme.colorSchemeFor
import com.rhymeai.app.ui.theme.recordingAccentColor
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json

/** Home screen widget: the count and newest lines from the store's snapshot, with Record and Type. */
class OneLinersWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Responsive(setOf(SMALL, MEDIUM))

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val first = read(context)
        provideContent {
            // Glance keeps a session running for 45 s after it first draws, and updateAll only recomposes
            // it, never calling provideGlance again, so each refresh re-reads the snapshot here.
            val version by refreshes.collectAsState()
            val snapshot by produceState(first, version) { value = read(context) }
            Content(context, snapshot)
        }
    }

    private suspend fun read(context: Context): OneLinersSnapshot? = withContext(Dispatchers.IO) {
        runCatching {
            Json { ignoreUnknownKeys = true }.decodeFromString<OneLinersSnapshot>(OneLinersStore.snapshotFile(context).readText())
        }.getOrNull()
    }

    @Composable
    private fun Content(context: Context, snapshot: OneLinersSnapshot?) {
        val appearance = AppAppearance.fromStorage(snapshot?.appearance)
        val scheme = colorSchemeFor(appearance)
        val ink = ColorProvider(scheme.onBackground)
        val secondary = ColorProvider(scheme.onSurfaceVariant)
        val medium = LocalSize.current.width >= MEDIUM.width
        val count = snapshot?.count ?: 0
        Column(
            GlanceModifier.fillMaxSize().background(scheme.background).cornerRadius(12.dp).padding(13.dp)
                .clickable(actionStartActivity(intent(context, OneLinerAction.OPEN)))
        ) {
            Text("One Liners", style = TextStyle(color = ink, fontSize = 15.sp, fontWeight = FontWeight.Medium))
            Text(if (count == 1) "1 line" else "$count lines", style = TextStyle(color = secondary, fontSize = 12.sp))
            Spacer(GlanceModifier.height(8.dp))
            val lines = snapshot?.lines.orEmpty().take(if (medium) OneLinersSnapshot.LINE_LIMIT else 1)
            if (lines.isEmpty()) {
                Text("Catch a line before it slips away.", style = TextStyle(color = secondary, fontSize = 13.sp), maxLines = 2)
            }
            lines.forEach { line ->
                Text(line.text.ifEmpty { "Voice line" }, style = TextStyle(color = ink, fontSize = 13.sp), maxLines = if (medium) 1 else 2)
            }
            Spacer(GlanceModifier.defaultWeight())
            Row(GlanceModifier.fillMaxWidth()) {
                Button(
                    text = "Record",
                    onClick = actionStartActivity(intent(context, OneLinerAction.RECORD)),
                    colors = ButtonDefaults.buttonColors(
                        backgroundColor = ColorProvider(recordingAccentColor(appearance.isDark)),
                        contentColor = ColorProvider(scheme.background)
                    )
                )
                Spacer(GlanceModifier.width(8.dp))
                Button(
                    text = "Type",
                    onClick = actionStartActivity(intent(context, OneLinerAction.TYPE)),
                    colors = ButtonDefaults.buttonColors(
                        backgroundColor = ColorProvider(scheme.surfaceContainer),
                        contentColor = ink
                    )
                )
            }
        }
    }

    companion object {
        val SMALL = DpSize(110.dp, 110.dp)
        val MEDIUM = DpSize(250.dp, 110.dp)

        fun intent(context: Context, action: OneLinerAction): Intent =
            Intent(Intent.ACTION_VIEW, Uri.parse(action.link), context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        /** Bumped on every refresh, so a session still running reads the new snapshot. */
        private val refreshes = MutableStateFlow(0)

        suspend fun refresh(context: Context) {
            refreshes.update { it + 1 }
            OneLinersWidget().updateAll(context)
        }
    }
}

class OneLinersWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = OneLinersWidget()
}
