package com.rhymeai.app.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun TemplatesDialog(
    onSelectTemplate: (name: String, theme: String, lyrics: String) -> Unit,
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val animationsEnabled = LocalAnimationsEnabled.current
    val scope = rememberCoroutineScope()
    var visible by remember { mutableStateOf(false) }
    var isClosing by remember { mutableStateOf(false) }

    // Modal motion: the card scales in from its resting point instead of just
    // appearing, and plays the faster dismiss tier on the way out.
    fun requestDismiss() {
        if (isClosing) return
        isClosing = true
        visible = false
        scope.launch {
            delay(if (animationsEnabled) DesignTokens.Motion.dismissMillis.toLong() else 0L)
            onDismiss()
        }
    }

    LaunchedEffect(Unit) { visible = true }

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
        val scrimAlpha = animateFloatAsState(
            targetValue = if (visible) 0.42f else 0f,
            animationSpec = if (animationsEnabled) {
                tween(
                    if (visible) DesignTokens.Motion.standardMillis else DesignTokens.Motion.dismissMillis,
                    easing = if (visible) DesignTokens.Motion.standardEasing else DesignTokens.Motion.exitEasing
                )
            } else {
                snap()
            },
            label = "templatesScrim"
        )
        Box(
            modifier = Modifier
                .fillMaxSize()
                // drawBehind: the fading scrim invalidates only the draw phase
                // instead of recomposing the dialog every animation frame.
                .drawBehind { drawRect(Color.Black.copy(alpha = scrimAlpha.value)) }
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null
                ) { requestDismiss() }
                .padding(DesignTokens.Spacing.xl)
                .bottomSafeActionPadding(extra = DesignTokens.Spacing.lg),
            contentAlignment = Alignment.Center
        ) {
            AnimatedVisibility(
                visible = visible,
                enter = fadeIn(animationSpec = tween(if (animationsEnabled) DesignTokens.Motion.standardMillis else 0, easing = DesignTokens.Motion.standardEasing)) +
                    scaleIn(initialScale = 0.92f, animationSpec = if (animationsEnabled) DesignTokens.Motion.standardSpring() else tween(0)),
                exit = fadeOut(animationSpec = tween(if (animationsEnabled) DesignTokens.Motion.dismissMillis else 0, easing = DesignTokens.Motion.exitEasing)) +
                    scaleOut(targetScale = 0.95f, animationSpec = tween(if (animationsEnabled) DesignTokens.Motion.dismissMillis else 0, easing = DesignTokens.Motion.exitEasing))
            ) {
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .widthIn(max = DesignTokens.Drawer.expandedWidth)
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null
                    ) { /* consume so card taps don't dismiss */ },
                shape = RoundedCornerShape(DesignTokens.Radius.xxl),
                color = colorScheme.surfaceContainerLow,
                contentColor = colorScheme.onSurface,
                tonalElevation = 6.dp,
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
