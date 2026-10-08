package com.rhymeai.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.IconButton
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.MainViewModel
import com.rhymeai.app.R
import com.rhymeai.app.RhymeContext
import com.rhymeai.app.SuggestedLine
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeScheme
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAppAppearance
import com.rhymeai.app.ui.theme.outlineStrongColorFor
import com.rhymeai.app.ui.theme.placeholderColorFor
import com.rhymeai.app.ui.theme.subtleColorFor
import com.rhymeai.app.util.BeatGrid
import com.rhymeai.app.util.SyllableCounter

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AssistantPanel(
    viewModel: MainViewModel,
    rhymeContext: RhymeContext,
    modifier: Modifier = Modifier,
    onSuggestionInserted: () -> Unit = {},
    onModelSetup: () -> Unit = { viewModel.showSettingsDialog = true }
) {
    val colorScheme = MaterialTheme.colorScheme
    val appearance = LocalAppAppearance.current
    val placeholderColor = placeholderColorFor(appearance)
    val subtleColor = subtleColorFor(appearance)
    val outlineStrongColor = outlineStrongColorFor(appearance)
    val textFieldColors = OutlinedTextFieldDefaults.colors(
        unfocusedBorderColor = outlineStrongColor,
        focusedBorderColor = colorScheme.primary,
        unfocusedContainerColor = colorScheme.surfaceContainerLow,
        focusedContainerColor = colorScheme.surfaceContainerLow,
        cursorColor = colorScheme.primary,
        unfocusedTextColor = colorScheme.onSurface,
        focusedTextColor = colorScheme.onSurface,
        unfocusedPlaceholderColor = placeholderColor,
        focusedPlaceholderColor = placeholderColor
    )
    var activeHelp by remember { mutableStateOf<FeatureHelp?>(null) }
    var contextExpanded by remember { mutableStateOf(false) }
    var rhymeOptionsExpanded by remember { mutableStateOf(false) }
    val animationsEnabled = com.rhymeai.app.ui.theme.LocalAnimationsEnabled.current

    activeHelp?.let { help ->
        FeatureHelpDialog(
            help = help,
            onDismiss = { activeHelp = null }
        )
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .wrapContentWidth(Alignment.CenterHorizontally)
            .widthIn(max = DesignTokens.Drawer.expandedWidth)
    ) {
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
        ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DesignTokens.Spacing.lg)
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { contextExpanded = !contextExpanded }
                    .heightIn(min = DesignTokens.Touch.minTarget),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Icon(Icons.Default.Edit, null, tint = colorScheme.primary, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                FeatureHelpLabel(
                    text = "Context & Theme",
                    help = FeatureHelp.CONTEXT_THEME,
                    onHelp = { activeHelp = it },
                    color = colorScheme.onSurface,
                    fontSizeSp = 16,
                    fontWeight = FontWeight.Medium
                )
                Spacer(Modifier.weight(1f))
                Text(
                    if (viewModel.theme.isBlank()) "Optional" else viewModel.theme,
                    maxLines = 1,
                    fontSize = 12.sp,
                    color = colorScheme.onSurfaceVariant,
                    modifier = Modifier.widthIn(max = 140.dp)
                )
                Icon(
                    Icons.Default.KeyboardArrowDown,
                    contentDescription = if (contextExpanded) "Collapse context and theme" else "Expand context and theme",
                    tint = colorScheme.onSurfaceVariant,
                    modifier = Modifier.rotate(if (contextExpanded) 180f else 0f)
                )
            }

            AnimatedVisibility(
                visible = contextExpanded,
                enter = if (animationsEnabled) expandVertically(tween(DesignTokens.Motion.feedbackMillis, easing = DesignTokens.Motion.standardEasing), expandFrom = Alignment.Top) else EnterTransition.None,
                exit = if (animationsEnabled) shrinkVertically(tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing), shrinkTowards = Alignment.Top) else ExitTransition.None
            ) {
                OutlinedTextField(
                    value = viewModel.theme,
                    onValueChange = { viewModel.onThemeChanged(it) },
                    placeholder = { Text("What is this song about?", fontSize = DesignTokens.Typography.caption) },
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = 8.dp)
                        .heightIn(min = 84.dp),
                    colors = textFieldColors,
                    shape = RoundedCornerShape(DesignTokens.Radius.lg),
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = DesignTokens.Typography.caption)
                )
            }
        }

        // Divider
        Box(Modifier.fillMaxWidth().height(1.dp).background(colorScheme.outlineVariant))

        // Main controls
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DesignTokens.Spacing.lg),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.lg)
        ) {
            // Target Line
            Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                    ) {
                        Icon(Icons.AutoMirrored.Filled.Notes, null, tint = colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
                        FeatureHelpLabel(
                            text = "Target Line",
                            help = FeatureHelp.TARGET_LINE,
                            onHelp = { activeHelp = it },
                            color = colorScheme.onSurfaceVariant
                        )
                    }
                    if (rhymeContext.targetLine != null) {
                        Box(
                            modifier = Modifier
                                .background(colorScheme.surfaceContainerHigh, RoundedCornerShape(DesignTokens.Radius.xs))
                                .padding(horizontal = DesignTokens.Spacing.sm, vertical = DesignTokens.Spacing.xs)
                        ) {
                            Text(
                                "${SyllableCounter.countText(rhymeContext.targetLine)} syllables",
                                fontFamily = FontFamily.Monospace,
                                fontSize = 12.sp,
                                color = colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(colorScheme.surfaceContainer, RoundedCornerShape(DesignTokens.Radius.sm))
                        .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.sm))
                        .padding(DesignTokens.Spacing.md)
                ) {
                    if (rhymeContext.targetLine != null) {
                        Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
                            Text(
                                "\"${rhymeContext.targetLine}\"",
                                fontFamily = FontFamily.Serif,
                                fontStyle = FontStyle.Italic,
                                color = colorScheme.onSurface,
                                fontSize = 14.sp
                            )
                            if (viewModel.isStressPreviewEnabled) {
                                ProsodyPreview(text = rhymeContext.targetLine)
                            }
                        }
                    } else {
                        Text(
                            "New rhyme sound: no earlier line to match",
                            fontStyle = FontStyle.Italic,
                            color = colorScheme.onSurfaceVariant,
                            fontSize = DesignTokens.Typography.caption
                        )
                    }
                }
            }

            // Rhyme options — scheme, density, and complexity live behind one
            // disclosure so the panel leads with the writing flow; the header
            // summary keeps the current tuning visible while collapsed.
            Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { rhymeOptionsExpanded = !rhymeOptionsExpanded }
                        .heightIn(min = DesignTokens.Touch.minTarget),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        "Rhyme Options",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        color = colorScheme.onSurfaceVariant,
                        modifier = Modifier.weight(1f)
                    )
                    Text(
                        "${viewModel.rhymeScheme.label} \u00b7 ${viewModel.rhymeType.shortLabel()} \u00b7 ${viewModel.rhymeComplexity.label}",
                        fontSize = 12.sp,
                        color = colorScheme.primary,
                        fontWeight = FontWeight.Medium
                    )
                    val chevronRotation by animateFloatAsState(
                        targetValue = if (rhymeOptionsExpanded) 180f else 0f,
                        animationSpec = if (animationsEnabled) {
                            tween(DesignTokens.Motion.feedbackMillis, easing = DesignTokens.Motion.standardEasing)
                        } else {
                            snap()
                        },
                        label = "rhymeOptionsChevron"
                    )
                    Icon(
                        Icons.Default.KeyboardArrowDown,
                        contentDescription = if (rhymeOptionsExpanded) "Collapse rhyme options" else "Expand rhyme options",
                        tint = colorScheme.onSurfaceVariant,
                        modifier = Modifier.rotate(chevronRotation)
                    )
                }

                AnimatedVisibility(
                    visible = rhymeOptionsExpanded,
                    enter = if (animationsEnabled) {
                        expandVertically(animationSpec = DesignTokens.Motion.standardSpring(), expandFrom = Alignment.Top)
                    } else {
                        EnterTransition.None
                    },
                    exit = if (animationsEnabled) {
                        shrinkVertically(animationSpec = tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing), shrinkTowards = Alignment.Top)
                    } else {
                        ExitTransition.None
                    }
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.lg)) {
                    // Rhyme Scheme
                    Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            FeatureHelpLabel(
                                text = "Rhyme Scheme",
                                help = FeatureHelp.RHYME_SCHEME,
                                onHelp = { activeHelp = it },
                                color = colorScheme.onSurfaceVariant
                            )

                            var expanded by remember { mutableStateOf(false) }
                            ExposedDropdownMenuBox(
                                expanded = expanded,
                                onExpandedChange = { expanded = !expanded }
                            ) {
                                OutlinedTextField(
                                    value = viewModel.rhymeScheme.label,
                                    onValueChange = {},
                                    readOnly = true,
                                    modifier = Modifier
                                        .menuAnchor(MenuAnchorType.PrimaryNotEditable)
                                        .widthIn(min = 130.dp),
                                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = DesignTokens.Typography.caption, color = colorScheme.onSurface),
                                    trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
                                    colors = textFieldColors,
                                    shape = RoundedCornerShape(DesignTokens.Radius.sm),
                                    singleLine = true
                                )
                                ExposedDropdownMenu(
                                    expanded = expanded,
                                    onDismissRequest = { expanded = false },
                                    containerColor = colorScheme.surfaceContainerHigh
                                ) {
                                    RhymeScheme.entries.forEach { scheme ->
                                        DropdownMenuItem(
                                            text = { Text(scheme.label, color = colorScheme.onSurface, fontSize = DesignTokens.Typography.caption) },
                                            onClick = {
                                                viewModel.rhymeScheme = scheme
                                                expanded = false
                                            }
                                        )
                                    }
                                }
                            }
                        }

                        if (viewModel.rhymeScheme == RhymeScheme.CUSTOM) {
                            OutlinedTextField(
                                value = viewModel.customRhymeScheme,
                                onValueChange = { viewModel.customRhymeScheme = it.uppercase().filter { c -> c.isLetter() } },
                                placeholder = { Text("e.g. AABBCC", fontSize = DesignTokens.Typography.caption) },
                                modifier = Modifier.fillMaxWidth().height(DesignTokens.Touch.minTarget),
                                colors = textFieldColors,
                                shape = RoundedCornerShape(DesignTokens.Radius.sm),
                                singleLine = true,
                                textStyle = androidx.compose.ui.text.TextStyle(fontSize = DesignTokens.Typography.caption)
                            )
                        }
                    }

                    // Rhyme Type
                    Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
                        FeatureHelpLabel(
                            text = "Rhyme Density",
                            help = FeatureHelp.RHYME_DENSITY,
                            onHelp = { activeHelp = it },
                            color = colorScheme.onSurfaceVariant
                        )

                        SlidingSegmentedControl(
                            labels = RhymeType.entries.map { it.shortLabel() },
                            selectedIndex = RhymeType.entries.indexOf(viewModel.rhymeType),
                            onSelect = { viewModel.rhymeType = RhymeType.entries[it] },
                            modifier = Modifier.fillMaxWidth(),
                            fontSize = 12.sp
                        )
                    }

                    // Rhyme Complexity Slider
                    Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            FeatureHelpLabel(
                                text = "Complexity",
                                help = FeatureHelp.COMPLEXITY,
                                onHelp = { activeHelp = it },
                                color = colorScheme.onSurfaceVariant
                            )
                            Text(
                                viewModel.rhymeComplexity.label,
                                fontSize = DesignTokens.Typography.caption,
                                fontWeight = FontWeight.Medium,
                                color = colorScheme.primary
                            )
                        }

                        Slider(
                            value = viewModel.rhymeComplexity.level.toFloat(),
                            onValueChange = { value ->
                                viewModel.rhymeComplexity = RhymeComplexity.entries.first { it.level == value.toInt() }
                            },
                            valueRange = 0f..2f,
                            steps = 1,
                            colors = SliderDefaults.colors(
                                thumbColor = colorScheme.primary,
                                activeTrackColor = colorScheme.primary,
                                inactiveTrackColor = colorScheme.outlineVariant
                            ),
                            modifier = Modifier.fillMaxWidth()
                        )

                        Text(
                            viewModel.rhymeComplexity.description,
                            fontSize = 12.sp,
                            color = subtleColor,
                            modifier = Modifier.padding(top = DesignTokens.Spacing.xs)
                        )
                    }

                    }
                }

                // Visual stanza display stays visible: it is feedback on the
                // lyrics, not a tuning control.
                if (viewModel.lyrics.isNotEmpty()) {
                    RhymeSchemeDisplay(
                        rhymeContext = rhymeContext,
                        activeScheme = viewModel.activeRhymeScheme
                    )
                }
            }

            if (viewModel.selectedProvider == com.rhymeai.app.service.AIProvider.LOCAL) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Local AI · ${viewModel.localReadinessLabel}", style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                    if (viewModel.localReady) {
                        TextButton(onClick = onModelSetup) { Text("Manage model") }
                    }
                }
                if (viewModel.localModelError != null) {
                    Text("Your model could not load. Open model setup to retry or choose another.", style = MaterialTheme.typography.bodySmall, color = colorScheme.error)
                }
            }

            // Error message
            viewModel.errorMessage?.let {
                Text(it, color = colorScheme.error, fontSize = 12.sp)
            }

            // Suggestions. Slots open as skeleton cards the moment a request
            // starts; each one cross-fades into its card as that line streams
            // in, and any slot still empty when generation stops collapses.
            val isWriting = viewModel.isLoading
            val slotCount = SuggestionPlaceholders.slotCount(isWriting, viewModel.suggestions.size)
            // AnimatedVisibility keeps the section composed through its exit, so
            // a request that ends with no lines still plays the 160ms collapse
            // instead of vanishing with its slots.
            AnimatedVisibility(
                visible = slotCount > 0,
                enter = if (animationsEnabled) {
                    fadeIn(tween(DesignTokens.Motion.standardMillis, easing = DesignTokens.Motion.standardEasing)) +
                        expandVertically(DesignTokens.Motion.standardSpring(), expandFrom = Alignment.Top)
                } else {
                    EnterTransition.None
                },
                exit = if (animationsEnabled) {
                    fadeOut(tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing)) +
                        shrinkVertically(tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing), shrinkTowards = Alignment.Top)
                } else {
                    ExitTransition.None
                }
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                    ) {
                        Text(stringResource(R.string.assistant_suggestions_header), fontSize = DesignTokens.Typography.caption, fontWeight = FontWeight.Medium, color = colorScheme.onSurfaceVariant)
                        if (isWriting) {
                            val writingLabel = stringResource(R.string.assistant_suggestions_writing_a11y)
                            Text(
                                stringResource(R.string.assistant_suggestions_writing),
                                fontSize = 12.sp,
                                color = subtleColor,
                                modifier = Modifier
                                    .testTag("suggestionsWriting")
                                    .semantics {
                                        liveRegion = LiveRegionMode.Polite
                                        contentDescription = writingLabel
                                    }
                            )
                        }
                    }
                    Text(
                        stringResource(R.string.assistant_suggestions_caveat),
                        fontSize = 12.sp,
                        color = colorScheme.onSurfaceVariant,
                        fontStyle = FontStyle.Italic
                    )
                    // Keep at least the reserved slots in the tree so an empty
                    // one can play its collapse instead of vanishing.
                    for (slot in 0 until maxOf(slotCount, SuggestionPlaceholders.VISIBLE_SLOTS)) {
                        key(slot) {
                            SuggestionSlot(
                                line = viewModel.suggestions.getOrNull(slot),
                                pending = isWriting && slot < SuggestionPlaceholders.VISIBLE_SLOTS,
                                skeletonVariant = slot
                            ) { suggestedLine ->
                                SuggestionCard(
                                    suggestion = suggestedLine.text,
                                    rhymeTier = suggestedLine.rhymeTier,
                                    isHook = suggestedLine.isHook,
                                    highlightRhyme = viewModel.isHighlightEnabled,
                                    showProsody = viewModel.isStressPreviewEnabled,
                                    onKeep = { viewModel.keepAlternate(suggestedLine.text) },
                                    isKept = viewModel.songWorkspace.alternates.any { it.text == suggestedLine.text.trim() },
                                    onUse = {
                                        viewModel.insertSuggestion(suggestedLine.text)
                                        onSuggestionInserted()
                                    }
                                )
                            }
                        }
                    }
                }
            }

            // Tempo control + per-line grid — shown only when Beat Grid is enabled (toggled in Settings).
            if (viewModel.isBeatGridEnabled) {
                // Tap-tempo state: keep the last 4 tap timestamps in memory.
                var tapTimestamps by remember { mutableStateOf(emptyList<Long>()) }

                // BPM stepper row with tap-tempo button.
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        "BPM",
                        fontSize = DesignTokens.Typography.caption,
                        fontWeight = androidx.compose.ui.text.font.FontWeight.Medium,
                        color = colorScheme.onSurfaceVariant
                    )

                    Row(
                        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        // Tap-tempo button
                        IconButton(
                            onClick = {
                                val now = System.currentTimeMillis()
                                val updated = (tapTimestamps + now).takeLast(5)
                                tapTimestamps = updated
                                BeatGrid.tapTempoBpm(updated)?.let { viewModel.beatGridBpm = it }
                            },
                            modifier = Modifier.semantics { contentDescription = "Tap tempo" }
                        ) {
                            Icon(
                                Icons.Default.MusicNote,
                                contentDescription = null,
                                tint = colorScheme.primary,
                                modifier = Modifier.size(18.dp)
                            )
                        }

                        // Stepper: decrement
                        TextButton(
                            onClick = { viewModel.beatGridBpm = (viewModel.beatGridBpm - 1).coerceAtLeast(40) },
                            modifier = Modifier.semantics { contentDescription = "Decrease BPM" }
                        ) { Text("−", fontSize = 16.sp) }

                        Text(
                            "${viewModel.beatGridBpm}",
                            fontSize = 15.sp,
                            fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
                            color = colorScheme.onSurface,
                            modifier = Modifier.width(42.dp),
                            textAlign = androidx.compose.ui.text.style.TextAlign.Center
                        )

                        // Stepper: increment
                        TextButton(
                            onClick = { viewModel.beatGridBpm = (viewModel.beatGridBpm + 1).coerceAtMost(220) },
                            modifier = Modifier.semantics { contentDescription = "Increase BPM" }
                        ) { Text("+", fontSize = 16.sp) }
                    }
                }

                // BPM slider 40–220
                Slider(
                    value = viewModel.beatGridBpm.toFloat(),
                    onValueChange = { viewModel.beatGridBpm = it.toInt() },
                    valueRange = 40f..220f,
                    colors = SliderDefaults.colors(
                        thumbColor = colorScheme.primary,
                        activeTrackColor = colorScheme.primary,
                        inactiveTrackColor = colorScheme.outlineVariant
                    ),
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics { contentDescription = "BPM, ${viewModel.beatGridBpm}" }
                )

                // Per-line beat strip
                if (viewModel.lyrics.isNotEmpty()) {
                    BeatGridPreview(
                        lyrics = viewModel.lyrics,
                        bpm = viewModel.beatGridBpm
                    )
                }
            }

            Spacer(Modifier.height(DesignTokens.Spacing.lg))
        }
        }

        val setupModel = !viewModel.isLoading &&
            viewModel.selectedProvider == com.rhymeai.app.service.AIProvider.LOCAL &&
            !viewModel.localReady
        // When writing ends with at least one line, the spinner bursts into
        // ink: the panel's one celebratory beat. Stop and errors do not burst.
        var spinnerCenter by remember { mutableStateOf<Offset?>(null) }
        var barCoordinates by remember { mutableStateOf<LayoutCoordinates?>(null) }
        var stopRequested by remember { mutableStateOf(false) }
        var inkBurst by remember { mutableIntStateOf(0) }
        LaunchedEffect(Unit) {
            var wasLoading = viewModel.isLoading
            snapshotFlow { viewModel.isLoading }.collect { loading ->
                if (wasLoading && !loading && !stopRequested && viewModel.suggestions.isNotEmpty() && viewModel.errorMessage == null) {
                    inkBurst++
                }
                wasLoading = loading
            }
        }
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .onGloballyPositioned { barCoordinates = it }
        ) {
            Button(
                onClick = {
                    when {
                        setupModel -> onModelSetup()
                        viewModel.isLoading -> {
                            stopRequested = true
                            viewModel.cancelSuggestions()
                        }
                        else -> {
                            stopRequested = false
                            viewModel.getSuggestions()
                        }
                    }
                },
                enabled = setupModel || viewModel.isLoading || viewModel.lyrics.isNotEmpty(),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DesignTokens.Spacing.lg, vertical = DesignTokens.Spacing.sm)
                    .height(DesignTokens.Touch.minTarget)
                    .testTag("assistantPrimaryAction"),
                shape = RoundedCornerShape(DesignTokens.Radius.lg),
                colors = ButtonDefaults.buttonColors(
                    containerColor = colorScheme.primary,
                    contentColor = colorScheme.onPrimary,
                    disabledContainerColor = colorScheme.surfaceVariant,
                    disabledContentColor = colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
                )
            ) {
                if (viewModel.isLoading) {
                    CircularProgressIndicator(
                        modifier = Modifier
                            .size(DesignTokens.Indicator.spinnerMd)
                            .onGloballyPositioned { spinner ->
                                barCoordinates?.let { bar ->
                                    spinnerCenter = bar.localPositionOf(spinner, Offset(spinner.size.width / 2f, spinner.size.height / 2f))
                                }
                            },
                        color = colorScheme.onPrimary,
                        strokeWidth = 2.dp
                    )
                    Spacer(Modifier.width(8.dp))
                } else if (!setupModel) {
                    Icon(Icons.Default.AutoAwesome, null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                }
                Text(
                    when {
                        setupModel -> stringResource(R.string.assistant_set_up_model)
                        viewModel.isLoading -> stringResource(R.string.assistant_stop)
                        else -> stringResource(R.string.assistant_suggest_next_line)
                    },
                    fontWeight = FontWeight.Medium
                )
            }
            InkBurst(
                trigger = inkBurst,
                origin = spinnerCenter,
                color = colorScheme.onSurface,
                modifier = Modifier.matchParentSize()
            )
        }
    }
}

private fun RhymeType.shortLabel(): String = when (this) {
    RhymeType.PERFECT -> "Perfect"
    RhymeType.NEAR -> "Near"
    RhymeType.SLANT -> "Slant"
}
