package com.rhymeai.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import com.rhymeai.app.ui.theme.DesignTokens

private val VisibleTrackHeight = 42.dp

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
    val density = LocalDensity.current
    var trackWidthPx by remember { mutableIntStateOf(0) }
    val segmentWidth = if (trackWidthPx > 0) {
        with(density) { (trackWidthPx.toFloat() / labels.size).toDp() }
    } else {
        0.dp
    }
    // Frequent controls, including keyboard selection, update as one immediate state.
    val pillOffset = segmentWidth * selectedIndex
    val startRadius = if (selectedIndex == 0) DesignTokens.Radius.pill else 0.dp
    val endRadius = if (selectedIndex == labels.lastIndex) DesignTokens.Radius.pill else 0.dp
    val pillShape = RoundedCornerShape(
        topStart = startRadius,
        bottomStart = startRadius,
        topEnd = endRadius,
        bottomEnd = endRadius
    )

    Box(
        modifier = modifier
            .height(DesignTokens.Touch.minTarget)
            .onSizeChanged { trackWidthPx = it.width }
    ) {
        Box(
            modifier = Modifier
                .align(Alignment.Center)
                .fillMaxWidth()
                .height(VisibleTrackHeight)
                .clip(shape)
                .background(colorScheme.surfaceContainerLow)
                .border(1.dp, colorScheme.outlineVariant, shape)
        ) {
            if (segmentWidth > 0.dp) {
                Box(
                    Modifier
                        .offset(x = pillOffset)
                        .width(segmentWidth)
                        .fillMaxHeight()
                        .clip(pillShape)
                        .background(colorScheme.primary)
                )
                for (i in 1 until labels.size) {
                    Box(
                        Modifier
                            .offset(x = segmentWidth * i - 0.5.dp)
                            .width(1.dp)
                            .fillMaxHeight()
                            .background(colorScheme.outlineVariant)
                    )
                }
            }
        }
        Row(Modifier.fillMaxSize().selectableGroup()) {
            labels.forEachIndexed { index, label ->
                val selected = index == selectedIndex
                val textColor = if (selected) colorScheme.onPrimary else colorScheme.onSurfaceVariant
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxHeight()
                        .clip(shape)
                        .selectable(
                            selected = selected,
                            role = Role.RadioButton,
                            onClick = { onSelect(index) }
                        ),
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
