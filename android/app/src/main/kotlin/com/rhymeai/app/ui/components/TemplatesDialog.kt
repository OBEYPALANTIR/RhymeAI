package com.rhymeai.app.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogWindowProvider
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rhymeai.app.data.model.SONG_TEMPLATES
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.ui.theme.appWritingSurface

@Composable
fun TemplatesDialog(
    onSelectTemplate: (name: String, theme: String, lyrics: String) -> Unit,
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val animationsEnabled = LocalAnimationsEnabled.current
    val pageTransition = remember { MutableTransitionState(false).apply { targetState = true } }
    var isClosing by remember { mutableStateOf(false) }

    fun requestDismiss() {
        if (isClosing) return
        isClosing = true
        pageTransition.targetState = false
    }

    LaunchedEffect(pageTransition.isIdle, pageTransition.currentState, isClosing) {
        if (isClosing && pageTransition.isIdle && !pageTransition.currentState) {
            onDismiss()
        }
    }

    Dialog(
        onDismissRequest = ::requestDismiss,
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false
        )
    ) {
        EdgeToEdgeDialogEffect()
        // The window-level dim vanishes in a single frame at teardown, which
        // reads as a pop no matter how the card animates. Draw the scrim
        // ourselves so it fades with the card; the window dim is disabled.
        val dialogWindow = (LocalView.current.parent as? DialogWindowProvider)?.window
        SideEffect { dialogWindow?.setDimAmount(0f) }
        AnimatedVisibility(
            visibleState = pageTransition,
            enter = fadeIn(animationSpec = tween(if (animationsEnabled) DesignTokens.Motion.pageFadeMillis else 0, easing = DesignTokens.Motion.standardEasing)),
            exit = fadeOut(animationSpec = tween(if (animationsEnabled) DesignTokens.Motion.pageFadeMillis else 0, easing = DesignTokens.Motion.exitEasing))
        ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .drawBehind { drawRect(Color.Black.copy(alpha = 0.42f)) }
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null
                ) { requestDismiss() }
                .padding(DesignTokens.Spacing.xl)
                .bottomSafeActionPadding(extra = DesignTokens.Spacing.lg),
            contentAlignment = Alignment.Center
        ) {
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .widthIn(max = DesignTokens.Drawer.expandedWidth)
                    .clip(RoundedCornerShape(DesignTokens.Radius.xxl))
                    .appWritingSurface()
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null
                    ) { /* consume so card taps don't dismiss */ },
                shape = RoundedCornerShape(DesignTokens.Radius.xxl),
                color = Color.Transparent,
                contentColor = colorScheme.onSurface,
                tonalElevation = 0.dp,
                border = BorderStroke(1.dp, colorScheme.outlineVariant)
            ) {
                Column(modifier = Modifier.fillMaxWidth()) {
                // Header
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(DesignTokens.Spacing.lg),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                    ) {
                        Icon(Icons.Default.GridView, null, tint = colorScheme.primary, modifier = Modifier.size(20.dp))
                        Text("Choose a Template", fontWeight = FontWeight.Medium, fontSize = 18.sp, color = colorScheme.onSurface)
                    }
                    IconButton(onClick = ::requestDismiss) {
                        Icon(Icons.Default.Close, contentDescription = "Close", tint = colorScheme.onSurfaceVariant)
                    }
                }

                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DesignTokens.Spacing.lg)
                        .padding(bottom = DesignTokens.Spacing.lg),
                    verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)
                ) {
                    SONG_TEMPLATES.forEach { template ->
                        OutlinedCard(
                            onClick = { onSelectTemplate(template.name, template.theme, template.lyrics) },
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
        }
    }
}
