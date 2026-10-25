package com.rhymeai.app.ui.components

import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.ContentTransform
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextFieldColors
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.data.sync.BackupArchive
import com.rhymeai.app.data.sync.BackupProbe
import com.rhymeai.app.data.sync.BackupStatus
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled

const val BACKUP_FOOTER =
    "Songs, trash and recordings are backed up to your Google Drive's private app storage. API keys are never included."

data class BackupSectionState(
    val status: BackupStatus = BackupStatus.NotConnected,
    val notice: String? = null,
    val busyLabel: String? = null,
    val legacyBackupPresent: Boolean = false,
    val migrationInProgress: Boolean = false,
    val migrationError: String? = null
)

class BackupSectionActions(
    val onConnect: () -> Unit = {},
    val onDisconnect: () -> Unit = {},
    val onBackUpNow: () -> Unit = {},
    val onRestore: () -> Unit = {},
    val onMigrate: (String) -> Unit = {},
    val exportFileName: () -> String = { "WritersBlock-backup.zip" },
    val onExport: (Uri) -> Unit = {},
    val onImport: (Uri) -> Unit = {}
)

/** Rows in the shared order: status, Connect/Disconnect, Back up now, Restore, Export, Import. */
@Composable
internal fun BackupSection(
    state: BackupSectionState,
    actions: BackupSectionActions,
    statusLine: String,
    subtleColor: Color,
    textFieldColors: TextFieldColors
) {
    val colorScheme = MaterialTheme.colorScheme
    val animationsEnabled = LocalAnimationsEnabled.current
    val connected = state.status !is BackupStatus.NotConnected
    val working = state.status is BackupStatus.BackingUp || state.busyLabel != null
    // shortcut: "just now" is read off the shared status copy (relativeTime, under 60 s); pass nowMillis in if a second reader needs it.
    val statusLook = BackupStatusLook(
        line = statusLine,
        justBackedUp = state.status is BackupStatus.Connected && statusLine.contains("just now"),
        failed = state.status is BackupStatus.Failed
    )
    var showMigration by remember { mutableStateOf(false) }
    val exportLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument(BackupArchive.MIME_TYPE)
    ) { uri -> uri?.let(actions.onExport) }
    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(actions.onImport)
    }

    if (showMigration && state.legacyBackupPresent) {
        MigrationDialog(
            inProgress = state.migrationInProgress,
            error = state.migrationError,
            textFieldColors = textFieldColors,
            onMigrate = actions.onMigrate,
            onDismiss = { showMigration = false }
        )
    }

    Column(
        modifier = Modifier.fillMaxWidth().padding(top = DesignTokens.Spacing.sm),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        // Status text and glyph cross-fade in place: in on the state tier, out on the dismiss tier.
        // Each frame draws only from its own target, so the leaving line keeps its glyph and colour.
        StatusSwap(target = statusLook, animationsEnabled = animationsEnabled, label = "backupStatus") { look ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (look.justBackedUp) {
                    // Success at 80% on the canvas is fine for a glyph; the text stays in ink.
                    Icon(
                        Icons.Default.CheckCircle,
                        contentDescription = null,
                        tint = colorScheme.tertiary.copy(alpha = 0.8f),
                        modifier = Modifier.size(14.dp).testTag("backup_status_check")
                    )
                    Spacer(Modifier.width(6.dp))
                }
                Text(
                    look.line,
                    fontSize = 13.sp,
                    color = if (look.failed) colorScheme.error else colorScheme.onSurface,
                    modifier = Modifier.testTag("backup_status")
                )
            }
        }
        if (state.status is BackupStatus.Failed) {
            BackupRow("Retry", "backup_retry", enabled = !working, onClick = actions.onBackUpNow)
        }
        if (connected) {
            BackupRow("Disconnect", "backup_disconnect", enabled = !working, onClick = actions.onDisconnect)
        } else {
            BackupRow("Connect Google Drive", "backup_connect", enabled = !working, onClick = actions.onConnect)
        }
        BackupRow(
            "Back up now", "backup_now", enabled = connected && !working, onClick = actions.onBackUpNow,
            progressLabel = if (state.status is BackupStatus.BackingUp) state.busyLabel ?: "Backing up…" else null
        )
        BackupRow("Restore from backup", "backup_restore", enabled = connected && !working, onClick = actions.onRestore)
        if (connected && state.legacyBackupPresent) {
            BackupRow(
                "Migrate older encrypted backup…", "backup_migrate", enabled = !working,
                onClick = { showMigration = true }
            )
        }
        BackupRow(
            "Export all songs…", "backup_export", enabled = !working,
            onClick = { exportLauncher.launch(actions.exportFileName()) }
        )
        BackupRow(
            "Import from file…", "backup_import", enabled = !working,
            onClick = { importLauncher.launch(arrayOf(BackupArchive.MIME_TYPE, "application/json", "application/octet-stream")) }
        )
        state.busyLabel?.takeIf { state.status !is BackupStatus.BackingUp }?.let {
            Text(it, fontSize = 12.sp, color = subtleColor)
        }
        state.notice?.let {
            Text(it, fontSize = 12.sp, color = subtleColor, lineHeight = 16.sp, modifier = Modifier.testTag("backup_notice"))
        }
        Text(BACKUP_FOOTER, fontSize = 12.sp, color = subtleColor, lineHeight = 16.sp)
    }
}

@Composable
private fun BackupRow(
    label: String,
    tag: String,
    enabled: Boolean,
    onClick: () -> Unit,
    progressLabel: String? = null
) {
    val animationsEnabled = LocalAnimationsEnabled.current
    OutlinedButton(
        onClick = onClick,
        enabled = enabled,
        modifier = Modifier.fillMaxWidth().heightIn(min = DesignTokens.Touch.minTarget).testTag(tag),
        shape = RoundedCornerShape(DesignTokens.Radius.lg)
    ) {
        // The progress indicator and its label leave on the dismiss tier; the resting label arrives on the state tier.
        StatusSwap(target = progressLabel, animationsEnabled = animationsEnabled, label = "backupRowLabel") { progress ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (progress != null) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        color = MaterialTheme.colorScheme.primary,
                        strokeWidth = 2.dp
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(progress, fontSize = DesignTokens.Typography.caption)
                } else {
                    Text(label, fontSize = DesignTokens.Typography.caption)
                }
            }
        }
    }
}

private data class BackupStatusLook(val line: String, val justBackedUp: Boolean, val failed: Boolean)

/** Cross-fades [content] when [target] changes (in 260 ms, out 160 ms); with animations removed it swaps in one frame. */
@Composable
private fun <T> StatusSwap(target: T, animationsEnabled: Boolean, label: String, content: @Composable (T) -> Unit) {
    if (!animationsEnabled) {
        content(target)
        return
    }
    AnimatedContent(
        targetState = target,
        transitionSpec = {
            // No size transform: the row takes the new width at once, so the arriving text is never clipped.
            ContentTransform(
                targetContentEnter = fadeIn(tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing)),
                initialContentExit = fadeOut(tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing)),
                sizeTransform = null
            )
        },
        label = label
    ) { content(it) }
}

@Composable
private fun MigrationDialog(
    inProgress: Boolean,
    error: String?,
    textFieldColors: TextFieldColors,
    onMigrate: (String) -> Unit,
    onDismiss: () -> Unit
) {
    var passphrase by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = { if (!inProgress) onDismiss() },
        title = { Text("Migrate older encrypted backup") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Enter the passphrase you used for Drive backup once. It is used to move that backup to the new format and is not stored.")
                OutlinedTextField(
                    value = passphrase,
                    onValueChange = { passphrase = it },
                    placeholder = { Text("Passphrase") },
                    singleLine = true,
                    enabled = !inProgress,
                    visualTransformation = PasswordVisualTransformation(),
                    colors = textFieldColors,
                    modifier = Modifier.fillMaxWidth().testTag("backup_migrate_passphrase")
                )
                error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp) }
            }
        },
        confirmButton = {
            TextButton(onClick = { onMigrate(passphrase) }, enabled = !inProgress && passphrase.isNotBlank()) {
                Text(if (inProgress) "Migrating…" else "Migrate")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss, enabled = !inProgress) { Text("Cancel") }
        }
    )
}

/** "Restore your songs?" after connecting, or at launch with an empty library. Never restores by itself. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RestoreOfferSheet(offer: BackupProbe, onRestore: () -> Unit, onNotNow: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onNotNow, modifier = Modifier.testTag("restore_offer_sheet")) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DesignTokens.Spacing.xl)
                .navigationBarsPadding()
                .padding(bottom = DesignTokens.Spacing.xl),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)
        ) {
            Text("Restore your songs?", style = MaterialTheme.typography.titleLarge)
            Text(restoreOfferBody(offer))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md, Alignment.End)
            ) {
                TextButton(onClick = onNotNow, modifier = Modifier.testTag("restore_offer_not_now")) { Text("Not now") }
                Button(onClick = onRestore, modifier = Modifier.testTag("restore_offer_restore")) { Text("Restore") }
            }
        }
    }
}

internal fun restoreOfferBody(offer: BackupProbe): String {
    val songs = if (offer.projectCount == 1) "1 song" else "${offer.projectCount} songs"
    val recordings = if (offer.recordingCount == 1) "1 recording" else "${offer.recordingCount} recordings"
    return "We found $songs and $recordings in your Google Drive backup."
}
