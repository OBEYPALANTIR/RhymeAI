package com.rhymeai.app.ui.components

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.updateTransition
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.withInfiniteAnimationFrameMillis
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.ContentTransform
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.layout.IntrinsicMeasurable
import androidx.compose.ui.layout.IntrinsicMeasureScope
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.Measurable
import androidx.compose.ui.layout.MeasureResult
import androidx.compose.ui.layout.MeasureScope
import androidx.compose.ui.layout.MultiContentMeasurePolicy
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsPropertyKey
import androidx.compose.ui.semantics.SemanticsPropertyReceiver
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.ui.theme.LocalAppAppearance
import com.rhymeai.app.ui.theme.outlineStrongColorFor
import com.rhymeai.app.ui.theme.placeholderColorFor
import com.rhymeai.app.ui.theme.statusWarningColor
import kotlin.math.roundToInt
import kotlinx.coroutines.delay

/** The model row's states, in DESIGN.md's order (Settings › local model rows). */
internal enum class ModelRowKind { NotDownloaded, Starting, Downloading, Paused, Checking, Downloaded, Selected, Stale, Deleting, Freed }

internal enum class ModelRowChip(val label: String) {
    Download("Download"), Pause("Pause"), Resume("Resume"), Use("Use"), Selected("Selected"), Update("Update")
}

internal enum class ModelRowColumn { None, Cancel, Trash, Spinner }

/** How dry the selected chip is, 0 wet ink to 1 the selection fill; read by the motion tests. */
internal val ModelRowChipDryness = SemanticsPropertyKey<Float>("ModelRowChipDryness")
private var SemanticsPropertyReceiver.modelRowChipDryness by ModelRowChipDryness

private val MODEL_ROW_METADATA_LINE_HEIGHT = 16.sp

internal const val MODEL_ROW_WAVE_TAG = "modelRowWave"

internal const val MODEL_ROW_MEMORY_WARNING = "Writes slowly: needs 10 GB"
internal const val MODEL_ROW_EMPTY_NUDGE = "No model on this device yet. Download one and suggestions keep writing offline."

/**
 * Everything a model row shows, derived from the model's state alone so the copy is testable.
 * [warning] is the warning-colour line (with its glyph); [progress] is the share written, null
 * when the line is indeterminate or absent.
 */
internal data class ModelRowState(
    val kind: ModelRowKind,
    val title: String,
    val metadata: String?,
    val warning: String?,
    val progress: Float?,
    val a11yLabel: String,
    val a11yValue: String,
    /** Which download run the line belongs to; a new run's line starts from its own bytes. */
    val lineRun: Int = 0
) {
    val chip: ModelRowChip?
        get() = when (kind) {
            ModelRowKind.NotDownloaded, ModelRowKind.Freed -> ModelRowChip.Download
            ModelRowKind.Starting, ModelRowKind.Downloading -> ModelRowChip.Pause
            ModelRowKind.Paused -> ModelRowChip.Resume
            ModelRowKind.Checking, ModelRowKind.Deleting -> null
            ModelRowKind.Downloaded -> ModelRowChip.Use
            ModelRowKind.Selected -> ModelRowChip.Selected
            ModelRowKind.Stale -> ModelRowChip.Update
        }

    val column: ModelRowColumn
        get() = when (kind) {
            ModelRowKind.NotDownloaded, ModelRowKind.Freed, ModelRowKind.Checking -> ModelRowColumn.None
            ModelRowKind.Starting, ModelRowKind.Downloading, ModelRowKind.Paused -> ModelRowColumn.Cancel
            ModelRowKind.Downloaded, ModelRowKind.Selected, ModelRowKind.Stale -> ModelRowColumn.Trash
            ModelRowKind.Deleting -> ModelRowColumn.Spinner
        }

    val columnLabel: String?
        get() = when (column) {
            ModelRowColumn.None -> null
            ModelRowColumn.Cancel -> "Cancel download of $title"
            ModelRowColumn.Trash -> "Delete $title"
            ModelRowColumn.Spinner -> "Deleting $title"
        }

    /** The progress line is drawn while bytes are coming or being checked. */
    val hasLine: Boolean
        get() = kind == ModelRowKind.Starting || kind == ModelRowKind.Downloading ||
            kind == ModelRowKind.Paused || kind == ModelRowKind.Checking
}

/**
 * A catalog model's row. Priority: deleting, then the running download, a paused partial, the
 * space just freed, an installed file (selected, verified, or stale), and otherwise nothing on disk.
 * [fileBytes] is the installed file's size, null when no file has the catalog name.
 */
internal fun catalogModelRowState(
    model: GemmaDownload,
    fileBytes: Long?,
    verified: Boolean,
    selected: Boolean,
    recommended: Boolean,
    needsMoreMemory: Boolean,
    downloading: Boolean = false,
    downloadProgress: Float? = null,
    verifying: Boolean = false,
    pausedBytes: Long? = null,
    deleting: Boolean = false,
    freedBytes: Long? = null,
    downloadRun: Int = 0
): ModelRowState = catalogModelRowCopy(
    model, fileBytes, verified, selected, recommended, needsMoreMemory,
    downloading, downloadProgress, verifying, pausedBytes, deleting, freedBytes
).copy(lineRun = downloadRun)

private fun catalogModelRowCopy(
    model: GemmaDownload,
    fileBytes: Long?,
    verified: Boolean,
    selected: Boolean,
    recommended: Boolean,
    needsMoreMemory: Boolean,
    downloading: Boolean,
    downloadProgress: Float?,
    verifying: Boolean,
    pausedBytes: Long?,
    deleting: Boolean,
    freedBytes: Long?
): ModelRowState {
    val title = model.label
    val catalogSize = formatFileSize(model.expectedBytes)
    val memoryValue = if (needsMoreMemory) ", Writes slowly, needs 10 GB memory" else ""
    val memoryLine = MODEL_ROW_MEMORY_WARNING.takeIf { needsMoreMemory }
    fun of(bytes: Long) = "${formatGigabytes(bytes)} of $catalogSize"
    fun row(kind: ModelRowKind, metadata: String?, label: String, value: String, warning: String? = null, progress: Float? = null) =
        ModelRowState(kind, title, metadata, warning, progress, label, value)

    if (deleting) return row(ModelRowKind.Deleting, "Deleting…", title, "Deleting")
    if (downloading) {
        if (verifying) return row(ModelRowKind.Checking, "Checking the file…", title, "Checking the file", progress = 1f)
        val fraction = downloadProgress?.coerceIn(0f, 1f) ?: 0f
        if (fraction <= 0f) {
            return row(ModelRowKind.Starting, "Starting download…", "Pause download of $title", "Starting download")
        }
        val percent = (fraction * 100f).roundToInt()
        val written = of((fraction.toDouble() * model.expectedBytes).toLong())
        return row(
            ModelRowKind.Downloading, "$written · $percent%",
            "Pause download of $title", "$percent percent, $written", progress = fraction
        )
    }
    if (pausedBytes != null) {
        val written = of(pausedBytes)
        val fraction = (pausedBytes.toFloat() / model.expectedBytes).coerceIn(0f, 1f)
        return row(ModelRowKind.Paused, "Paused · $written", "Resume download of $title", "Paused, $written", progress = fraction)
    }
    if (fileBytes == null) {
        if (freedBytes != null) {
            val freed = "${formatFileSize(freedBytes)} back for your songs"
            return row(ModelRowKind.Freed, freed, "Download $title", freed)
        }
        val parts = listOfNotNull(model.character, catalogSize, "Recommended".takeIf { recommended })
        return row(
            ModelRowKind.NotDownloaded, parts.joinToString(" · "), "Download $title",
            parts.joinToString(", ") + memoryValue, warning = memoryLine
        )
    }
    val onDevice = "${formatFileSize(fileBytes)} on this device"
    return when {
        !verified -> row(ModelRowKind.Stale, null, "Update $title", "Older version on this device", warning = "Older version on this device")
        selected -> row(ModelRowKind.Selected, "In use · $onDevice", title, "In use, $onDevice$memoryValue", warning = memoryLine)
        else -> row(
            ModelRowKind.Downloaded, "${model.character} · $onDevice", "Use $title",
            "${model.character}, $onDevice$memoryValue", warning = memoryLine
        )
    }
}

/** An imported model's row: the app's own copy, Use or Selected, and Delete. */
internal fun customModelRowState(name: String, fileBytes: Long, selected: Boolean, deleting: Boolean): ModelRowState {
    val onDevice = "${formatFileSize(fileBytes)} on this device"
    return when {
        deleting -> ModelRowState(ModelRowKind.Deleting, name, "Deleting…", null, null, name, "Deleting")
        selected -> ModelRowState(ModelRowKind.Selected, name, "In use · $onDevice", null, null, name, "In use, $onDevice")
        else -> ModelRowState(ModelRowKind.Downloaded, name, "Imported · $onDevice", null, null, "Use $name", "Imported, $onDevice")
    }
}

/**
 * The golden split row: title and metadata take 61.8% of the row, the chip cell and a 55dp
 * action column the rest; 89dp tall in every state at default text size. Title, metadata and
 * chip are one button ([onChip]); the column is a second one ([onColumn]). Nothing in the row
 * moves or resizes between states: labels and glyphs cross-fade in place, the download is a
 * line being written, a delete strikes the title.
 */
@Composable
internal fun ModelRow(
    state: ModelRowState,
    chipEnabled: Boolean,
    columnEnabled: Boolean,
    onChip: () -> Unit,
    onColumn: () -> Unit,
    mainTag: String,
    deleteTag: String,
    modifier: Modifier = Modifier,
    cancelTag: String? = null
) {
    val colors = MaterialTheme.colorScheme
    val appearance = LocalAppAppearance.current
    val animations = LocalAnimationsEnabled.current
    val accessibilitySize = LocalDensity.current.fontScale >= DesignTokens.ModelRow.accessibilityFontScale
    val shape = RoundedCornerShape(DesignTokens.Radius.lg)
    val border by animateColorAsState(
        targetValue = if (state.kind == ModelRowKind.Selected) colors.primary else colors.outlineVariant,
        animationSpec = tween(if (animations) DesignTokens.Motion.feedbackMillis else 0),
        label = "modelRowBorder"
    )
    val motion = rememberModelRowMotion(state, animations)
    val mainEnabled = chipEnabled && state.kind != ModelRowKind.Checking && state.kind != ModelRowKind.Deleting

    BoxWithConstraints(modifier.fillMaxWidth()) {
        val rowWidth = maxWidth
        Row(
            Modifier
                .fillMaxWidth()
                .heightIn(min = DesignTokens.ModelRow.height)
                .height(IntrinsicSize.Min)
                .clip(shape)
                .background(colors.surface)
                .border(1.dp, border, shape)
        ) {
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxHeight()
                    .testTag(mainTag)
                    .clickable(enabled = mainEnabled, role = Role.Button, onClick = onChip)
                    .semantics(mergeDescendants = true) {
                        contentDescription = state.a11yLabel
                        stateDescription = state.a11yValue
                        if (state.kind == ModelRowKind.Selected) selected = true
                        when (state.kind) {
                            ModelRowKind.Starting -> progressBarRangeInfo = ProgressBarRangeInfo.Indeterminate
                            ModelRowKind.Downloading, ModelRowKind.Paused ->
                                progressBarRangeInfo = ProgressBarRangeInfo(state.progress ?: 0f, 0f..1f)
                            else -> Unit
                        }
                    }
            ) {
                val text = @Composable {
                    ModelRowText(
                        state = state,
                        motion = motion,
                        modifier = (if (accessibilitySize) Modifier else Modifier.fillMaxHeight())
                            .padding(
                                start = DesignTokens.Rhythm.standard,
                                end = DesignTokens.Rhythm.tight,
                                top = DesignTokens.Rhythm.related,
                                bottom = DesignTokens.Rhythm.related
                            )
                    )
                }
                val chip = @Composable { ModelRowChipSlot(state.chip, chipEnabled, motion.dry, animations) }
                if (accessibilitySize) {
                    // At accessibility sizes the chip drops under the metadata and the split is dropped.
                    Column(Modifier.padding(bottom = DesignTokens.Rhythm.section)) {
                        text()
                        Box(Modifier.padding(start = DesignTokens.Rhythm.standard)) { chip() }
                    }
                } else {
                    GoldenSplit(rowWidth = rowWidth, text = text, chip = chip, reference = {
                        Box(Modifier.clearAndSetSemantics { }) { ChipBox(ModelRowChip.Download, true, 1f) }
                    })
                }
            }
            ModelRowActionColumn(
                state = state,
                enabled = columnEnabled,
                onClick = onColumn,
                tag = if (state.column == ModelRowColumn.Cancel) cancelTag ?: deleteTag else deleteTag,
                animations = animations
            )
        }
    }
}

/**
 * Lays the text column at round(row width × 0.618) and centres the chip in the rest of the
 * main button. When the widest chip ([reference]) would not fit beside it, the text gives
 * way first, so the chip cell never squeezes and the split does not change with the label.
 */
@Composable
private fun GoldenSplit(rowWidth: Dp, text: @Composable () -> Unit, chip: @Composable () -> Unit, reference: @Composable () -> Unit) {
    Layout(contents = listOf(text, chip, reference), measurePolicy = remember(rowWidth) { GoldenSplitPolicy(rowWidth) })
}

private class GoldenSplitPolicy(private val rowWidth: Dp) : MultiContentMeasurePolicy {
    private fun Density.textWidth(available: Int, chipWidth: Int): Int =
        minOf((rowWidth.toPx() * DesignTokens.Phi.inverse).roundToInt(), available - chipWidth).coerceAtLeast(0)

    override fun MeasureScope.measure(measurables: List<List<Measurable>>, constraints: Constraints): MeasureResult {
        val (textMeasurables, chipMeasurables, referenceMeasurables) = measurables
        val chipPlaceable = chipMeasurables.first().measure(Constraints())
        val widestChip = maxOf(referenceMeasurables.first().measure(Constraints()).width, chipPlaceable.width)
        val textWidth = textWidth(constraints.maxWidth, widestChip)
        val textPlaceable = textMeasurables.first().measure(
            Constraints(textWidth, textWidth, constraints.minHeight, constraints.maxHeight)
        )
        val height = maxOf(textPlaceable.height, chipPlaceable.height, constraints.minHeight)
        return layout(constraints.maxWidth, height) {
            textPlaceable.place(0, (height - textPlaceable.height) / 2)
            val cellWidth = constraints.maxWidth - textWidth
            chipPlaceable.place(textWidth + (cellWidth - chipPlaceable.width) / 2, (height - chipPlaceable.height) / 2)
        }
    }

    // The row sizes itself from these (IntrinsicSize.Min), so they follow the same split.
    override fun IntrinsicMeasureScope.minIntrinsicHeight(measurables: List<List<IntrinsicMeasurable>>, width: Int): Int =
        splitHeight(measurables, width)

    override fun IntrinsicMeasureScope.maxIntrinsicHeight(measurables: List<List<IntrinsicMeasurable>>, width: Int): Int =
        splitHeight(measurables, width)

    private fun IntrinsicMeasureScope.splitHeight(measurables: List<List<IntrinsicMeasurable>>, width: Int): Int {
        val (text, chip, reference) = measurables
        val widestChip = maxOf(reference.first().maxIntrinsicWidth(Constraints.Infinity), chip.first().maxIntrinsicWidth(Constraints.Infinity))
        return maxOf(text.first().minIntrinsicHeight(textWidth(width, widestChip)), chip.first().minIntrinsicHeight(Constraints.Infinity))
    }
}

@Composable
private fun ModelRowText(state: ModelRowState, motion: ModelRowMotion, modifier: Modifier) {
    val colors = MaterialTheme.colorScheme
    val warningColor = statusWarningColor(LocalAppAppearance.current.isDark)
    var titleLayout by remember { mutableStateOf<TextLayoutResult?>(null) }
    Column(modifier, verticalArrangement = Arrangement.Center) {
        Text(
            state.title,
            style = MaterialTheme.typography.titleMedium,
            color = colors.onSurface,
            onTextLayout = { titleLayout = it },
            modifier = Modifier.strike(colors.onSurfaceVariant, motion) { titleLayout }
        )
        Spacer(Modifier.height(DesignTokens.Spacing.xs))
        // Two metadata lines are always reserved, so the title holds still while the copy changes;
        // the download wave sits in the second, a φ step (8dp) under the one-line progress copy.
        val metadataTransition = updateTransition(state, label = "modelRowMetadata")
        val metadata = @Composable {
            metadataTransition.AnimatedContent(
                contentKey = { it.kind },
                transitionSpec = { modelRowSwap(motion.animations) },
                contentAlignment = Alignment.TopStart
            ) { shown -> ModelRowMetadata(shown, colors.onSurfaceVariant, warningColor) }
        }
        val wave = @Composable {
            ModelRowWave(
                motion = motion,
                ink = colors.onSurface,
                trackInk = placeholderColorFor(LocalAppAppearance.current),
                modifier = Modifier
            )
        }
        // The copy the row is moving to, measured as text so the wave sits under it even on the
        // frame the state changes (the cross-fading copy above holds both states' copy).
        val measurer = rememberTextMeasurer()
        // Resolved the way Text resolves the copy's style, so both measure the same.
        val copyStyle = LocalTextStyle.current.merge(TextStyle(fontSize = DesignTokens.Typography.caption, lineHeight = MODEL_ROW_METADATA_LINE_HEIGHT))
        val density = LocalDensity.current
        val reserved = with(density) { MODEL_ROW_METADATA_LINE_HEIGHT.roundToPx() * 2 }
        val warningInset = with(density) { (12.dp + 3.dp).roundToPx() }
        fun copyHeight(shown: ModelRowState, width: Int): Int {
            fun measure(text: String, w: Int) = measurer.measure(text, copyStyle, constraints = Constraints(maxWidth = w.coerceAtLeast(1))).size.height
            return (shown.metadata?.let { measure(it, width) } ?: 0) + (shown.warning?.let { measure(it, width - warningInset) } ?: 0)
        }
        // The copy still fading out while the metadata cross-fades, if it is another state's.
        val outgoing = metadataTransition.currentState.takeIf { it.kind != state.kind }
        Layout(
            contents = listOf(metadata, wave),
            measurePolicy = remember(state, outgoing, reserved, copyStyle, measurer) {
                MetadataWavePolicy(
                    hasLine = state.hasLine,
                    reserved = reserved,
                    copyHeight = { width -> copyHeight(state, width) },
                    outgoingHeight = outgoing?.let { leaving -> { width -> copyHeight(leaving, width) } }
                )
            }
        )
    }
}

@Composable
private fun ModelRowMetadata(shown: ModelRowState, ink: Color, warningColor: Color) {
    Column {
        shown.metadata?.let {
            Text(it, fontSize = DesignTokens.Typography.caption, lineHeight = MODEL_ROW_METADATA_LINE_HEIGHT, color = ink)
        }
        shown.warning?.let {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.WarningAmber, null, tint = warningColor, modifier = Modifier.size(12.dp))
                Spacer(Modifier.width(3.dp))
                Text(it, fontSize = DesignTokens.Typography.caption, lineHeight = MODEL_ROW_METADATA_LINE_HEIGHT, color = warningColor)
            }
        }
    }
}

/**
 * Two metadata lines are always reserved, so the title holds still while the copy changes.
 * The wave goes a φ step (8dp) under the progress copy: at default size that copy is one
 * line and the wave fills the second reserved line; when large text wraps it, the wave
 * follows it down, measured in the same pass so no frame resizes the row. The wave is left
 * out of any frame where it would cross copy: while taller outgoing copy is still fading
 * (it arrives once the cross-fade ends), and while it fades out under taller incoming copy.
 */
private class MetadataWavePolicy(
    private val hasLine: Boolean,
    private val reserved: Int,
    private val copyHeight: (width: Int) -> Int,
    private val outgoingHeight: ((width: Int) -> Int)?
) : MultiContentMeasurePolicy {
    private fun Density.waveTop(copyHeight: Int) = copyHeight + DesignTokens.ModelRow.waveGap.roundToPx()

    override fun MeasureScope.measure(measurables: List<List<Measurable>>, constraints: Constraints): MeasureResult {
        val (metadata, wave) = measurables
        val loose = constraints.copy(minWidth = 0, minHeight = 0, maxHeight = Constraints.Infinity)
        val metadataPlaceable = metadata.first().measure(loose)
        val probeHeight = copyHeight(constraints.maxWidth)
        val wavePlaceable = wave.first().measure(Constraints.fixedWidth(constraints.maxWidth))
        // With no line the wave rests (fading, then invisible) one line down, where it last was.
        val copyAbove = if (hasLine) probeHeight else reserved / 2
        val waveTop = waveTop(copyAbove)
        val clear = (hasLine || probeHeight <= copyAbove) &&
            (outgoingHeight == null || outgoingHeight.invoke(constraints.maxWidth) <= copyAbove)
        val height = maxOf(reserved, metadataPlaceable.height, if (hasLine) waveTop + wavePlaceable.height else 0)
        return layout(constraints.maxWidth, height) {
            metadataPlaceable.place(0, 0)
            if (clear) wavePlaceable.place(0, waveTop)
        }
    }

    override fun IntrinsicMeasureScope.minIntrinsicHeight(measurables: List<List<IntrinsicMeasurable>>, width: Int): Int =
        intrinsicHeight(measurables, width)

    override fun IntrinsicMeasureScope.maxIntrinsicHeight(measurables: List<List<IntrinsicMeasurable>>, width: Int): Int =
        intrinsicHeight(measurables, width)

    private fun IntrinsicMeasureScope.intrinsicHeight(measurables: List<List<IntrinsicMeasurable>>, width: Int): Int {
        val (metadata, wave) = measurables
        val withWave = if (hasLine) waveTop(copyHeight(width)) + wave.first().minIntrinsicHeight(width) else 0
        return maxOf(reserved, metadata.first().minIntrinsicHeight(width), withWave)
    }
}

@Composable
private fun ModelRowChipSlot(chip: ModelRowChip?, enabled: Boolean, dry: () -> Float, animations: Boolean) {
    AnimatedContent(
        targetState = chip,
        transitionSpec = { modelRowSwap(animations) },
        contentAlignment = Alignment.Center,
        label = "modelRowChip"
    ) { shown ->
        if (shown != null) ChipBox(shown, enabled, if (shown == ModelRowChip.Selected) dry() else 1f)
    }
}

/** The chip: outlined for an action; the selected chip is wet ink at [dry] 0 and the selection fill at 1. */
@Composable
private fun ChipBox(chip: ModelRowChip, enabled: Boolean, dry: Float) {
    val colors = MaterialTheme.colorScheme
    val selected = chip == ModelRowChip.Selected
    val drying = dry.coerceIn(0f, 1f)
    val fill = if (selected) lerp(colors.primary, colors.surfaceContainerHighest, drying) else Color.Transparent
    // The label switches from on-primary to ink at the drying's halfway point.
    val label = if (selected && drying < 0.5f) colors.onPrimary else colors.onSurface
    val outline = outlineStrongColorFor(LocalAppAppearance.current)
    val chipShape = RoundedCornerShape(DesignTokens.Radius.sm)
    Box(
        Modifier
            .then(if (selected) Modifier.semantics { modelRowChipDryness = drying } else Modifier)
            .height(DesignTokens.ModelRow.chipHeight)
            .alpha(if (enabled || selected) 1f else 0.38f)
            .clip(chipShape)
            .background(fill)
            .then(if (selected) Modifier else Modifier.border(1.dp, outline, chipShape))
            .padding(horizontal = DesignTokens.Rhythm.tight),
        contentAlignment = Alignment.Center
    ) {
        Text(chip.label, fontSize = DesignTokens.Typography.caption, lineHeight = 16.sp, fontWeight = FontWeight.Medium, color = label)
    }
}

@Composable
private fun ModelRowActionColumn(state: ModelRowState, enabled: Boolean, onClick: () -> Unit, tag: String, animations: Boolean) {
    val colors = MaterialTheme.colorScheme
    val column = state.column
    val control = column == ModelRowColumn.Cancel || column == ModelRowColumn.Trash
    Box(
        Modifier
            .width(DesignTokens.ModelRow.column)
            .fillMaxHeight()
            .then(
                if (control) {
                    Modifier
                        .testTag(tag)
                        .clickable(enabled = enabled, role = Role.Button, onClick = onClick)
                        .semantics { contentDescription = state.columnLabel.orEmpty() }
                } else {
                    Modifier
                }
            ),
        contentAlignment = Alignment.Center
    ) {
        AnimatedContent(
            targetState = column,
            transitionSpec = { modelRowSwap(animations) },
            contentAlignment = Alignment.Center,
            label = "modelRowColumn"
        ) { shown ->
            val tint = colors.onSurfaceVariant.copy(alpha = if (enabled) 1f else 0.38f)
            when (shown) {
                ModelRowColumn.Trash -> Icon(Icons.Outlined.Delete, null, tint = tint, modifier = Modifier.size(DesignTokens.ModelRow.glyph))
                ModelRowColumn.Cancel -> Icon(Icons.Default.Close, null, tint = tint, modifier = Modifier.size(DesignTokens.ModelRow.glyph))
                ModelRowColumn.Spinner -> Box(
                    Modifier.clearAndSetSemantics {
                        contentDescription = "Deleting ${state.title}"
                        liveRegion = LiveRegionMode.Polite
                    }
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(DesignTokens.Indicator.spinnerMd),
                        color = colors.onSurfaceVariant,
                        strokeWidth = 2.dp
                    )
                }
                ModelRowColumn.None -> Unit
            }
        }
    }
}

/** Out on the 160ms dismiss tier, in on the 260ms state tier, opacity only, in place. */
private fun modelRowSwap(animations: Boolean) = ContentTransform(
    targetContentEnter = fadeIn(tween(if (animations) DesignTokens.Motion.standardMillis else 0, easing = DesignTokens.Motion.standardEasing)),
    initialContentExit = fadeOut(tween(if (animations) DesignTokens.Motion.dismissMillis else 0, easing = DesignTokens.Motion.exitEasing)),
    sizeTransform = null
)

/** The row's drawn motion, read in the draw phase so it never recomposes the row. */
private class ModelRowMotion(
    val animations: Boolean,
    val ghost: () -> Boolean,
    val written: () -> Float,
    val ghostProgress: () -> Float,
    val lineAlpha: () -> Float,
    val strike: () -> Float,
    val strikeAlpha: () -> Float,
    val dry: () -> Float
)

@Composable
private fun rememberModelRowMotion(state: ModelRowState, animations: Boolean): ModelRowMotion {
    val deleting = state.kind == ModelRowKind.Deleting
    val selected = state.kind == ModelRowKind.Selected
    val ghost = state.kind == ModelRowKind.Starting
    // The line keeps its last mode while it fades out.
    val lastGhost = remember { mutableStateOf(ghost) }
    SideEffect { if (state.hasLine) lastGhost.value = ghost }

    val lineAlpha = remember { Animatable(if (state.hasLine) 1f else 0f) }
    val written = remember { Animatable(state.progress ?: 0f) }
    val strike = remember { Animatable(if (deleting) 1f else 0f) }
    val strikeAlpha = remember { Animatable(if (deleting) 1f else 0f) }
    // A row that opens already selected is dry; only a selection made here goes through the wet beat.
    val dry = remember { Animatable(if (selected) 1f else 0f) }
    val ghostClock = remember { mutableLongStateOf(0L) }

    LaunchedEffect(state.hasLine, animations) {
        if (state.hasLine) {
            // A new run starts from its own bytes, even if the last one's line had not finished leaving.
            if (lineAlpha.value < 1f) written.snapTo(state.progress ?: 0f)
            lineAlpha.snapTo(1f)
        } else {
            // Cancel and Checking → Downloaded: the line leaves on the dismiss tier, then resets.
            if (animations) lineAlpha.animateTo(0f, tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing))
            else lineAlpha.snapTo(0f)
            written.snapTo(0f)
        }
    }
    // A new run (Resume after a Cancel, say) restarts the stroke from its own bytes.
    val firstRun = remember { state.lineRun }
    LaunchedEffect(state.lineRun) {
        if (state.lineRun != firstRun) written.snapTo(state.progress ?: 0f)
    }
    LaunchedEffect(state.progress, animations) {
        val target = state.progress ?: return@LaunchedEffect
        // The written part follows the bytes and never moves backwards.
        val next = maxOf(written.value, target)
        if (animations) written.animateTo(next, tween(DesignTokens.Motion.feedbackMillis)) else written.snapTo(next)
    }
    if (ghost && animations) {
        LaunchedEffect(Unit) {
            val start = withInfiniteAnimationFrameMillis { it }
            while (true) withInfiniteAnimationFrameMillis { ghostClock.longValue = it - start }
        }
    }
    LaunchedEffect(deleting, animations) {
        if (deleting) {
            strikeAlpha.snapTo(1f)
            if (animations && strike.value < 1f) {
                strike.animateTo(1f, tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing))
            } else {
                strike.snapTo(1f)
            }
        } else {
            if (animations) strikeAlpha.animateTo(0f, tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing))
            else strikeAlpha.snapTo(0f)
            strike.snapTo(0f)
        }
    }
    LaunchedEffect(selected, animations) {
        when {
            !selected -> dry.snapTo(0f)
            dry.value >= 1f -> Unit
            !animations -> dry.snapTo(1f)
            else -> {
                // The Use-line beat: wet ink held 2.0s, then it dries on the settle spring.
                dry.snapTo(0f)
                delay(2_000)
                dry.animateTo(1f, DesignTokens.Motion.settleSpring())
            }
        }
    }
    return ModelRowMotion(
        animations = animations,
        ghost = { lastGhost.value },
        written = { written.value },
        ghostProgress = {
            if (animations) SuggestionPlaceholderMotion.singleLineProgress(ghostClock.longValue)
            else SuggestionPlaceholderMotion.STILL_FRAME.second
        },
        lineAlpha = { lineAlpha.value },
        strike = { strike.value },
        strikeAlpha = { strikeAlpha.value },
        dry = { dry.value }
    )
}

/**
 * The download line under the progress copy: one even wave (constant amplitude and
 * wavelength, one stroke) across the text column. The written share is in ink and the rest
 * in placeholder ink; while the length is not known yet the ghost's one-line loop writes it.
 */
@Composable
private fun ModelRowWave(motion: ModelRowMotion, ink: Color, trackInk: Color, modifier: Modifier) {
    Spacer(
        modifier
            .fillMaxWidth()
            .height(DesignTokens.ModelRow.waveHeight)
            .testTag(MODEL_ROW_WAVE_TAG)
            .drawWithCache {
                val path = evenWavePath(size.width, DesignTokens.ModelRow.wavePeriod.toPx(), size.height)
                val measure = PathMeasure().apply { setPath(path, false) }
                val drawn = Path()
                val stroke = Stroke(width = SuggestionPlaceholderMotion.STROKE_WIDTH_DP.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
                onDrawBehind {
                    val alpha = motion.lineAlpha()
                    if (alpha <= 0f || size.width <= 0f) return@onDrawBehind
                    val fraction = if (motion.ghost()) motion.ghostProgress() else motion.written()
                    drawPath(path, trackInk, alpha = alpha, style = stroke)
                    drawSegment(measure, drawn, fraction, ink, alpha, stroke)
                }
            }
    )
}

/** A sine wave from x = 0 to [width]: one crest and trough every [period], filling [height]. */
internal fun evenWavePath(width: Float, period: Float, height: Float): Path = Path().apply {
    val amplitude = height / 2f
    val steps = (width / 2f).toInt().coerceAtLeast(1)
    for (i in 0..steps) {
        val x = width * i / steps
        val y = amplitude - amplitude * kotlin.math.sin(2.0 * Math.PI * x / period).toFloat()
        if (i == 0) moveTo(x, y) else lineTo(x, y)
    }
}

/** The delete strike: the same wave across the title's first line, tip first, in secondary ink. */
private fun Modifier.strike(color: Color, motion: ModelRowMotion, layout: () -> TextLayoutResult?): Modifier = drawWithCache {
    val text = layout()
    val waveHeight = DesignTokens.ModelRow.waveHeight.toPx()
    val stroke = Stroke(width = SuggestionPlaceholderMotion.STROKE_WIDTH_DP.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
    val left = text?.getLineLeft(0) ?: 0f
    val width = text?.let { it.getLineRight(0) - left } ?: 0f
    val centre = text?.let { (it.getLineTop(0) + it.getLineBottom(0)) / 2f } ?: 0f
    val path = evenWavePath(width.coerceAtLeast(0f), DesignTokens.ModelRow.wavePeriod.toPx(), waveHeight)
    val measure = PathMeasure().apply { setPath(path, false) }
    val drawn = Path()
    onDrawWithContent {
        drawContent()
        val alpha = motion.strikeAlpha()
        if (alpha <= 0f || width <= 0f) return@onDrawWithContent
        translate(left, centre - waveHeight / 2f) { drawSegment(measure, drawn, motion.strike(), color, alpha, stroke) }
    }
}

private fun DrawScope.drawSegment(measure: PathMeasure, drawn: Path, fraction: Float, color: Color, alpha: Float, stroke: Stroke) {
    if (fraction <= 0f) return
    drawn.reset()
    measure.getSegment(0f, measure.length * fraction.coerceIn(0f, 1f), drawn, true)
    drawPath(drawn, color, alpha = alpha, style = stroke)
}
