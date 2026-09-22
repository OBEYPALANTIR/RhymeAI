package com.rhymeai.app.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.data.model.SONG_TEMPLATES
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.appWritingSurface
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TemplatesDialog(
    onSelectTemplate: (name: String, theme: String, lyrics: String) -> Unit,
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var isClosing by remember { mutableStateOf(false) }
    var didFinish by remember { mutableStateOf(false) }
    var pendingAction by remember { mutableStateOf<(() -> Unit)?>(null) }

    fun finishClose() {
        if (didFinish) return
        didFinish = true
        // Unmount independently of the host's asynchronous save/apply result.
        onDismiss()
        pendingAction?.invoke()
    }

    fun closeSheet(afterClose: (() -> Unit)? = null) {
        if (isClosing || didFinish) return
        pendingAction = afterClose
        isClosing = true
        scope.launch {
            try {
                sheetState.hide()
            } finally {
                if (!sheetState.isVisible) finishClose()
                else isClosing = false
            }
        }
    }

    // The native sheet owns scrim, drag, Back, insets and system motion scaling.
    ModalBottomSheet(
        onDismissRequest = ::finishClose,
        sheetState = sheetState,
        sheetMaxWidth = DesignTokens.Drawer.expandedWidth,
        shape = RoundedCornerShape(topStart = DesignTokens.Radius.sheet, topEnd = DesignTokens.Radius.sheet),
        containerColor = colorScheme.background
    ) {
        Column(modifier = Modifier.fillMaxWidth().appWritingSurface()) {
            // Header
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(DesignTokens.Spacing.lg),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(
                    modifier = Modifier.weight(1f),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                ) {
                    Icon(Icons.Default.GridView, null, tint = colorScheme.primary, modifier = Modifier.size(20.dp))
                    Text("Choose a Template", fontWeight = FontWeight.Medium, fontSize = 18.sp, color = colorScheme.onSurface)
                }
                IconButton(onClick = { closeSheet() }) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = colorScheme.onSurfaceVariant)
                }
            }

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f, fill = false)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = DesignTokens.Spacing.lg)
                    .padding(bottom = DesignTokens.Spacing.lg),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)
            ) {
                SONG_TEMPLATES.forEach { template ->
                    OutlinedCard(
                        onClick = { closeSheet { onSelectTemplate(template.name, template.theme, template.lyrics) } },
                        enabled = !isClosing,
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(min = DesignTokens.Touch.minTarget),
                        shape = RoundedCornerShape(DesignTokens.Radius.lg),
                        colors = CardDefaults.outlinedCardColors(
                            containerColor = colorScheme.surfaceContainer,
                            contentColor = colorScheme.onSurface
                        ),
                        border = BorderStroke(1.dp, colorScheme.outlineVariant)
                    ) {
                        Column(modifier = Modifier.padding(DesignTokens.Spacing.lg)) {
                            Text(
                                template.name,
                                fontWeight = FontWeight.Medium,
                                fontSize = 16.sp,
                                color = colorScheme.onSurface
                            )
                            Text(
                                template.theme,
                                fontSize = DesignTokens.Typography.caption,
                                color = colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(top = DesignTokens.Spacing.xs)
                            )
                        }
                    }
                }
            }
        }
    }
}
