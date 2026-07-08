package com.rhymeai.app.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.util.RhymeMatches
import com.rhymeai.app.util.WordProsody
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class, ExperimentalComposeUiApi::class, androidx.compose.foundation.ExperimentalFoundationApi::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun WordInspectorSheet(
    word: String,
    prosody: WordProsody?,
    matches: RhymeMatches?,
    synonyms: List<String>,
    synonymsLoading: Boolean,
    synonymsError: String?,
    onReplace: (String) -> Unit,
    onRetrySynonyms: () -> Unit,
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val clipboard = LocalClipboardManager.current
    val haptic = LocalHapticFeedback.current
    var visible by remember { mutableStateOf(false) }
    var hasEntered by remember { mutableStateOf(false) }

    fun requestDismiss() {
        if (!visible) return
        visible = false
    }

    LaunchedEffect(Unit) {
        visible = true
        hasEntered = true
    }

    LaunchedEffect(visible) {
        if (hasEntered && !visible) {
            delay(DesignTokens.Motion.dismissMillis.toLong())
            onDismiss()
        }
    }

    Dialog(
        onDismissRequest = { requestDismiss() },
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false
        )
    ) {
        EdgeToEdgeDialogEffect()
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = DesignTokens.Spacing.lg)
        ) {
            AnimatedVisibility(
                visible = visible,
                enter = fadeIn(
                    animationSpec = tween(
                        durationMillis = DesignTokens.Motion.standardMillis,
                        easing = DesignTokens.Motion.emphasizedEasing
                    )
                ) + slideInVertically(
                    animationSpec = tween(
                        durationMillis = DesignTokens.Motion.standardMillis,
                        easing = DesignTokens.Motion.emphasizedEasing
                    ),
                    initialOffsetY = { it }
                ),
                exit = fadeOut(
                    animationSpec = tween(
                        durationMillis = DesignTokens.Motion.dismissMillis,
                        easing = DesignTokens.Motion.exitEasing
                    )
                ) + slideOutVertically(
                    animationSpec = tween(
                        durationMillis = DesignTokens.Motion.dismissMillis,
                        easing = DesignTokens.Motion.exitEasing
                    ),
                    targetOffsetY = { it }
                ),
                modifier = Modifier.align(Alignment.BottomCenter)
            ) {
                BottomSafeActionArea(
                    modifier = Modifier.fillMaxWidth(),
                    extra = DesignTokens.Spacing.xxl
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 560.dp)
                            .background(colorScheme.surfaceContainerLow, RoundedCornerShape(DesignTokens.Radius.xxl))
                            .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.xxl))
                            .padding(DesignTokens.Spacing.lg)
                            .testTag("wordInspectorSheet")
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                            ) {
                                Icon(
                                    Icons.Default.Search,
                                    contentDescription = null,
                                    tint = colorScheme.primary,
                                    modifier = Modifier.size(20.dp)
                                )
                                Text(
                                    "Word inspector",
                                    fontSize = 14.sp,
                                    color = colorScheme.onSurfaceVariant,
                                    fontWeight = FontWeight.Medium
                                )
                            }
                            IconButton(onClick = { requestDismiss() }) {
                                Icon(
                                    Icons.Default.Close,
                                    contentDescription = "Close",
                                    tint = colorScheme.onSurfaceVariant
                                )
                            }
                        }

                        Spacer(Modifier.height(DesignTokens.Spacing.sm))

                        Text(
                            text = word,
                            fontSize = 32.sp,
                            fontFamily = FontFamily.Serif,
                            fontWeight = FontWeight.Bold,
                            color = colorScheme.onSurface
                        )

                        val syllables = prosody?.syllableCount ?: 0
                        val ipa = prosody?.ipa.orEmpty()
                        val stressPattern = prosody?.stressPattern.orEmpty()
                        Spacer(Modifier.height(DesignTokens.Spacing.xs))
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                        ) {
                            if (ipa.isNotEmpty()) {
                                Text(
                                    "/$ipa/",
                                    fontFamily = FontFamily.Monospace,
                                    fontSize = DesignTokens.Typography.caption,
                                    color = colorScheme.onSurfaceVariant
                                )
                            }
                            if (syllables > 0) {
                                Text(
                                    "$syllables ${if (syllables == 1) "syllable" else "syllables"}",
                                    fontSize = 12.sp,
                                    color = colorScheme.onSurfaceVariant
                                )
                            }
                            StressDots(stressPattern)
                        }

                        Spacer(Modifier.height(DesignTokens.Spacing.md))

                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .verticalScroll(rememberScrollState())
                        ) {
                            val perfect = matches?.perfect.orEmpty()
                            val multi = matches?.multi.orEmpty()
                            val near = matches?.near.orEmpty()

                            ResultsSection(
                                title = "Perfect rhymes",
                                empty = "No perfect rhymes in dictionary.",
                                items = perfect,
                                onTap = { onReplace(it) },
                                onLongPress = { value ->
                                    clipboard.setText(AnnotatedString(value))
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                }
                            )

                            Spacer(Modifier.height(DesignTokens.Spacing.md))

                            ResultsSection(
                                title = "Multi-syllabic rhymes",
                                empty = "No multi-syllabic matches.",
                                items = multi,
                                onTap = { onReplace(it) },
                                onLongPress = { value ->
                                    clipboard.setText(AnnotatedString(value))
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                }
                            )

                            Spacer(Modifier.height(DesignTokens.Spacing.md))

                            ResultsSection(
                                title = "Near rhymes",
                                empty = "No near rhymes found.",
                                items = near,
                                onTap = { onReplace(it) },
                                onLongPress = { value ->
                                    clipboard.setText(AnnotatedString(value))
                                    haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                }
                            )

                            Spacer(Modifier.height(DesignTokens.Spacing.md))

                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    "Synonyms",
                                    fontSize = DesignTokens.Typography.caption,
                                    fontWeight = FontWeight.SemiBold,
                                    color = colorScheme.onSurface
                                )
                                if (synonymsLoading) {
                                    CircularProgressIndicator(
                                        modifier = Modifier.size(14.dp),
                                        strokeWidth = 1.5.dp,
                                        color = colorScheme.primary
                                    )
                                } else if (synonymsError != null) {
                                    TextButton(onClick = onRetrySynonyms) {
                                        Icon(
                                            Icons.Default.Refresh,
                                            contentDescription = null,
                                            modifier = Modifier.size(14.dp)
                                        )
                                        Spacer(Modifier.size(4.dp))
                                        Text("Retry", fontSize = 12.sp)
                                    }
                                }
                            }

                            Spacer(Modifier.height(DesignTokens.Spacing.xs))

                            if (synonymsError != null) {
                                Text(
                                    synonymsError,
                                    fontSize = 12.sp,
                                    color = colorScheme.error
                                )
                            } else if (synonyms.isEmpty() && !synonymsLoading) {
                                Text(
                                    "No synonyms yet.",
                                    fontSize = 12.sp,
                                    color = colorScheme.onSurfaceVariant
                                )
                            } else if (synonyms.isNotEmpty()) {
                                FlowRow(
                                    horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs),
                                    verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
                                ) {
                                    synonyms.forEach { syn ->
                                        ResultChip(
                                            label = syn,
                                            onTap = { onReplace(syn) },
                                            onLongPress = {
                                                clipboard.setText(AnnotatedString(syn))
                                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                            }
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

@Composable
private fun StressDots(stressPattern: List<Int>) {
    if (stressPattern.isEmpty()) return
    val colorScheme = MaterialTheme.colorScheme
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp)
    ) {
        stressPattern.forEach { stress ->
            val (sizeDp, alpha) = when (stress) {
                1 -> 8.dp to 1.0f
                2 -> 6.dp to 0.7f
                else -> 4.dp to 0.4f
            }
            Box(
                modifier = Modifier
                    .size(sizeDp)
                    .background(
                        colorScheme.primary.copy(alpha = alpha),
                        CircleShape
                    )
            )
        }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class, androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
private fun ResultsSection(
    title: String,
    empty: String,
    items: List<String>,
    onTap: (String) -> Unit,
    onLongPress: (String) -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    Text(
        title,
        fontSize = DesignTokens.Typography.caption,
        fontWeight = FontWeight.SemiBold,
        color = colorScheme.onSurface
    )
    Spacer(Modifier.height(DesignTokens.Spacing.xs))
    if (items.isEmpty()) {
        Text(empty, fontSize = 12.sp, color = colorScheme.onSurfaceVariant)
        return
    }
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
    ) {
        items.forEach { item ->
            ResultChip(label = item, onTap = { onTap(item) }, onLongPress = { onLongPress(item) })
        }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ResultChip(
    label: String,
    onTap: () -> Unit,
    onLongPress: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    Box(
        modifier = Modifier
            .background(
                colorScheme.surfaceContainerHigh,
                RoundedCornerShape(DesignTokens.Radius.pill)
            )
            .border(
                1.dp,
                colorScheme.primary.copy(alpha = 0.24f),
                RoundedCornerShape(DesignTokens.Radius.pill)
            )
            .combinedClickable(
                onClick = onTap,
                onLongClick = onLongPress
            )
            .padding(horizontal = 12.dp, vertical = 6.dp)
    ) {
        Text(
            label,
            fontSize = DesignTokens.Typography.caption,
            color = colorScheme.onSurface
        )
    }
}
