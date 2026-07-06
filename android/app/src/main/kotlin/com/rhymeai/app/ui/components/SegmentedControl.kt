package com.rhymeai.app.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import androidx.compose.animation.core.animateDpAsState

// Structural: matches the 40dp height of the M3 SegmentedButton rows this control replaces.
private val TrackHeight = 40.dp

/**
 * Single-choice segmented control with centered labels (no leading checkmark)
 * and a selection pill that slides toward the tapped segment instead of
 * swapping colors in place. Shared by every segmented picker in the app.
 */
@Composable
fun SlidingSegmentedControl(
    labels: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    fontSize: TextUnit = DesignTokens.Typography.caption
) {
    if (labels.isEmpty()) return
    val colorScheme = MaterialTheme.colorScheme
    val shape = RoundedCornerShape(DesignTokens.Radius.pill)
    val animationsEnabled = LocalAnimationsEnabled.current
    val density = LocalDensity.current
    var trackWidthPx by remember { mutableIntStateOf(0) }
    val segmentWidth = if (trackWidthPx > 0) {
        with(density) { (trackWidthPx.toFloat() / labels.size).toDp() }
    } else {
        0.dp
    }
    val pillOffset by animateDpAsState(
        targetValue = segmentWidth * selectedIndex,
        animationSpec = if (animationsEnabled) DesignTokens.Motion.standardSpring() else snap(),
        label = "segmentedPillOffset"
    )

    Box(
        modifier = modifier
            .height(TrackHeight)
            .clip(shape)
            .background(colorScheme.surfaceContainerLow)
            .border(1.dp, colorScheme.outlineVariant, shape)
            .onSizeChanged { trackWidthPx = it.width }
    ) {
        if (segmentWidth > 0.dp) {
            Box(
                Modifier
                    .offset(x = pillOffset)
                    .width(segmentWidth)
                    .fillMaxHeight()
                    .clip(shape)
                    .background(colorScheme.primary)
            )
        }
        Row(Modifier.fillMaxSize().selectableGroup()) {
            labels.forEachIndexed { index, label ->
                val selected = index == selectedIndex
                val textColor by animateColorAsState(
                    targetValue = if (selected) colorScheme.onPrimary else colorScheme.onSurfaceVariant,
                    animationSpec = if (animationsEnabled) {
                        tween<Color>(DesignTokens.Motion.feedbackMillis, easing = DesignTokens.Motion.standardEasing)
                    } else {
                        snap()
                    },
                    label = "segmentedTextColor"
                )
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .clip(shape)
                        .selectable(
                            selected = selected,
                            role = Role.RadioButton,
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null
                        ) { onSelect(index) },
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        text = label,
                        fontSize = fontSize,
                        color = textColor,
                        maxLines = 1
                    )
                }
            }
        }
    }
}
