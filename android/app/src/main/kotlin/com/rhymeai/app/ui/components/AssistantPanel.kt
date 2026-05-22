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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.MainViewModel
import com.rhymeai.app.RhymeContext
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeScheme
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.ui.theme.RhymePalette
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.SyllableBlue
import com.rhymeai.app.ui.theme.SyllableEmerald
import com.rhymeai.app.ui.theme.SyllablePurple
import com.rhymeai.app.ui.theme.SyllableRose
import com.rhymeai.app.util.ProsodyAnalyzer
import com.rhymeai.app.util.SyllableCounter

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AssistantPanel(
    viewModel: MainViewModel,
    rhymeContext: RhymeContext,
    modifier: Modifier = Modifier,
    onSuggestionInserted: () -> Unit = {}
) {
    val colorScheme = MaterialTheme.colorScheme
    val textFieldColors = OutlinedTextFieldDefaults.colors(
        unfocusedBorderColor = colorScheme.outlineVariant,
        focusedBorderColor = colorScheme.primary.copy(alpha = 0.5f),
        unfocusedContainerColor = colorScheme.surfaceContainerLow,
        focusedContainerColor = colorScheme.surfaceContainerLow,
        cursorColor = colorScheme.primary,
        unfocusedTextColor = colorScheme.onSurface,
        focusedTextColor = colorScheme.onSurface,
        unfocusedPlaceholderColor = colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
        focusedPlaceholderColor = colorScheme.onSurfaceVariant.copy(alpha = 0.5f)
    )
    var activeHelp by remember { mutableStateOf<FeatureHelp?>(null) }

    activeHelp?.let { help ->
        FeatureHelpDialog(
            help = help,
            onDismiss = { activeHelp = null }
        )
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
    ) {
        // Context & Theme Section
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DesignTokens.Spacing.lg)
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth(),
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
            }

            OutlinedTextField(
                value = viewModel.theme,
                onValueChange = { viewModel.onThemeChanged(it) },
                enabled = !viewModel.useWholeSongContext,
                placeholder = { Text("What is this song about?", fontSize = 13.sp) },
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp)
                    .height(100.dp),
                colors = textFieldColors,
                shape = RoundedCornerShape(DesignTokens.Radius.lg),
                textStyle = androidx.compose.ui.text.TextStyle(fontSize = 13.sp)
            )
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
                                fontSize = 11.sp,
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
                        .padding(DesignTokens.Spacing.lg)
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
                            "New rhyme sound (or place cursor on a line)",
                            fontStyle = FontStyle.Italic,
                            color = colorScheme.onSurfaceVariant,
                            fontSize = 13.sp
                        )
                    }
                }
            }

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
                                .width(130.dp),
                            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 13.sp, color = colorScheme.onSurface),
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
                                    text = { Text(scheme.label, color = colorScheme.onSurface, fontSize = 13.sp) },
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
                        placeholder = { Text("e.g. AABBCC", fontSize = 13.sp) },
                        modifier = Modifier.fillMaxWidth().height(DesignTokens.Touch.minTarget),
                        colors = textFieldColors,
                        shape = RoundedCornerShape(DesignTokens.Radius.sm),
                        singleLine = true,
                        textStyle = androidx.compose.ui.text.TextStyle(fontSize = 13.sp)
                    )
                }

                // Visual stanza display
                if (viewModel.lyrics.isNotEmpty()) {
                    RhymeSchemeDisplay(
                        rhymeContext = rhymeContext,
                        activeScheme = viewModel.activeRhymeScheme
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

                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    RhymeType.entries.forEachIndexed { index, type ->
                        SegmentedButton(
                            selected = viewModel.rhymeType == type,
                            onClick = { viewModel.rhymeType = type },
                            shape = SegmentedButtonDefaults.itemShape(index, RhymeType.entries.size),
                            colors = SegmentedButtonDefaults.colors(
                                activeContainerColor = colorScheme.primary,
                                activeContentColor = colorScheme.onPrimary,
                                inactiveContainerColor = colorScheme.surfaceContainerLow,
                                inactiveContentColor = colorScheme.onSurfaceVariant,
                                activeBorderColor = colorScheme.primary,
                                inactiveBorderColor = colorScheme.outlineVariant
                            )
                        ) {
                            Text(type.shortLabel(), fontSize = 12.sp)
                        }
                    }
                }
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
                        fontSize = 13.sp,
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

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text("Simple", fontSize = 11.sp, color = colorScheme.onSurfaceVariant.copy(alpha = 0.6f))
                    Text("Moderate", fontSize = 11.sp, color = colorScheme.onSurfaceVariant.copy(alpha = 0.6f))
                    Text("Complex", fontSize = 11.sp, color = colorScheme.onSurfaceVariant.copy(alpha = 0.6f))
                }

                Text(
                    viewModel.rhymeComplexity.description,
                    fontSize = 11.sp,
                    color = colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                    modifier = Modifier.padding(top = DesignTokens.Spacing.xs)
                )
            }

            // Toggles
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                FeatureHelpLabel(
                    text = "Whole Song Context",
                    help = FeatureHelp.WHOLE_SONG_CONTEXT,
                    onHelp = { activeHelp = it },
                    color = colorScheme.onSurfaceVariant
                )
                Switch(
                    checked = viewModel.useWholeSongContext,
                    onCheckedChange = { viewModel.useWholeSongContext = it },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = colorScheme.onPrimary,
                        checkedTrackColor = colorScheme.primary,
                        uncheckedThumbColor = colorScheme.onSurfaceVariant,
                        uncheckedTrackColor = colorScheme.surfaceContainerHighest
                    )
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                FeatureHelpLabel(
                    text = "Stress + IPA",
                    help = FeatureHelp.STRESS_IPA,
                    onHelp = { activeHelp = it },
                    color = colorScheme.onSurfaceVariant
                )
                Switch(
                    checked = viewModel.isStressPreviewEnabled,
                    onCheckedChange = { viewModel.isStressPreviewEnabled = it },
                    modifier = Modifier.semantics { contentDescription = "Toggle Stress + IPA" },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = colorScheme.onPrimary,
                        checkedTrackColor = colorScheme.primary,
                        uncheckedThumbColor = colorScheme.onSurfaceVariant,
                        uncheckedTrackColor = colorScheme.surfaceContainerHighest
                    )
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                FeatureHelpLabel(
                    text = "Highlight Rhymes",
                    help = FeatureHelp.HIGHLIGHT_RHYMES,
                    onHelp = { activeHelp = it },
                    color = colorScheme.onSurfaceVariant
                )
                Switch(
                    checked = viewModel.isHighlightEnabled,
                    onCheckedChange = { viewModel.isHighlightEnabled = it },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = colorScheme.onPrimary,
                        checkedTrackColor = colorScheme.primary,
                        uncheckedThumbColor = colorScheme.onSurfaceVariant,
                        uncheckedTrackColor = colorScheme.surfaceContainerHighest
                    )
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                FeatureHelpLabel(
                    text = "Underline Syllables",
                    help = FeatureHelp.UNDERLINE_SYLLABLES,
                    onHelp = { activeHelp = it },
                    color = colorScheme.onSurfaceVariant
                )
                Switch(
                    checked = viewModel.isSyllableColoringEnabled,
                    onCheckedChange = { viewModel.isSyllableColoringEnabled = it },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = colorScheme.onPrimary,
                        checkedTrackColor = colorScheme.primary,
                        uncheckedThumbColor = colorScheme.onSurfaceVariant,
                        uncheckedTrackColor = colorScheme.surfaceContainerHighest
                    )
                )
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                FeatureHelpLabel(
                    text = "Color Rhymes",
                    help = FeatureHelp.COLOR_RHYMES,
                    onHelp = { activeHelp = it },
                    color = colorScheme.onSurfaceVariant
                )
                Switch(
                    checked = viewModel.isRhymeHighlightEnabled,
                    onCheckedChange = { viewModel.isRhymeHighlightEnabled = it },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = colorScheme.onPrimary,
                        checkedTrackColor = colorScheme.primary,
                        uncheckedThumbColor = colorScheme.onSurfaceVariant,
                        uncheckedTrackColor = colorScheme.surfaceContainerHighest
                    )
                )
            }

            // Suggest button
            Button(
                onClick = { viewModel.getSuggestions() },
                enabled = viewModel.lyrics.isNotEmpty() && !viewModel.isLoading,
                modifier = Modifier.fillMaxWidth().height(DesignTokens.Touch.minTarget),
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
                        modifier = Modifier.size(16.dp),
                        color = colorScheme.onPrimary,
                        strokeWidth = 2.dp
                    )
                    Spacer(Modifier.width(8.dp))
                    Text("Thinking...", fontWeight = FontWeight.Medium)
                } else {
                    Icon(Icons.Default.AutoAwesome, null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Suggest Next Line", fontWeight = FontWeight.Medium)
                }
            }

            // Error message
            viewModel.errorMessage?.let {
                Text(it, color = colorScheme.error, fontSize = 12.sp)
            }

            // Suggestions
            if (viewModel.suggestions.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
                    Text("Suggestions", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = colorScheme.onSurfaceVariant)
                    viewModel.suggestions.forEach { suggestion ->
                        SuggestionCard(
                            suggestion = suggestion,
                            highlightRhyme = viewModel.isHighlightEnabled,
                            showProsody = viewModel.isStressPreviewEnabled,
                            onClick = {
                                viewModel.insertSuggestion(suggestion)
                                onSuggestionInserted()
                            }
                        )
                    }
                }
            }

            Spacer(Modifier.height(DesignTokens.Spacing.xl))

            // Footer
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.Center
            ) {
                Text(
                    "Build ${com.rhymeai.app.BuildConfig.VERSION_NAME} (${com.rhymeai.app.BuildConfig.VERSION_CODE})  \u2022  Product of Tyler Manring",
                    fontSize = 11.sp,
                    color = colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                )
            }

            Spacer(Modifier.height(DesignTokens.Spacing.lg))
        }
    }
}

private enum class FeatureLegend {
    SYLLABLES,
    RHYMES
}

private enum class FeatureHelp(
    val title: String,
    val message: String,
    val legend: FeatureLegend? = null
) {
    CONTEXT_THEME(
        "Context & Theme",
        "Adds a short topic or mood for the assistant when Whole Song Context is off. Use it to steer the next line without sending the full lyric."
    ),
    TARGET_LINE(
        "Target Line",
        "The lyric line the assistant is matching. Put the cursor on a line when you want suggestions to rhyme with that exact sound."
    ),
    RHYME_SCHEME(
        "Rhyme Scheme",
        "Chooses the pattern the song should follow. Common patterns like AABB pair nearby lines, while Custom lets you type your own letter pattern."
    ),
    RHYME_DENSITY(
        "Rhyme Density",
        "Controls how tightly the suggestion should rhyme. Perfect is strict, Near gives a little room, and Slant is the most flexible."
    ),
    COMPLEXITY(
        "Complexity",
        "Changes how advanced the generated line should be. Higher complexity leans toward richer wording, multisyllable rhymes, and denser phrasing."
    ),
    WHOLE_SONG_CONTEXT(
        "Whole Song Context",
        "Uses the full current lyric as context so suggestions fit the story, tone, and previous lines. Turning it off uses only the theme and target line."
    ),
    HIGHLIGHT_RHYMES(
        "Highlight Rhymes",
        "Highlights rhyme words in suggestions so matching sounds are easier to spot before you insert a line."
    ),
    UNDERLINE_SYLLABLES(
        "Underline Syllables",
        "Draws colored underlines under words by syllable count. This keeps syllable cues visible while leaving rhyme colors free for rhyme families.",
        FeatureLegend.SYLLABLES
    ),
    STRESS_IPA(
        "Stress + IPA",
        "Shows dictionary-backed syllable stress and IPA previews for the target line and suggestions. Stressed syllables are shown as DA and unstressed syllables as da."
    ),
    COLOR_RHYMES(
        "Color Rhymes",
        "Colors words that share the same rhyme sound. Each color represents a rhyme family, so matching colors should rhyme or echo each other.",
        FeatureLegend.RHYMES
    )
}

@Composable
fun ProsodyPreview(
    text: String,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    val prosody = remember(text) { ProsodyAnalyzer.analyzeLine(text) }
    if (prosody.syllableCount == 0) return

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(2.dp)
    ) {
        if (prosody.feet.isNotBlank()) {
            Text(
                prosody.feet,
                fontFamily = FontFamily.Monospace,
                fontSize = 11.sp,
                lineHeight = 15.sp,
                color = colorScheme.onSurfaceVariant.copy(alpha = 0.72f)
            )
        }
        if (prosody.ipa.isNotBlank()) {
            Text(
                "/${prosody.ipa}/",
                fontFamily = FontFamily.Monospace,
                fontSize = 11.sp,
                lineHeight = 15.sp,
                color = colorScheme.onSurfaceVariant.copy(alpha = 0.56f)
            )
        }
    }
}

@Composable
private fun FeatureHelpLabel(
    text: String,
    help: FeatureHelp,
    onHelp: (FeatureHelp) -> Unit,
    color: Color,
    fontSizeSp: Int = 13,
    fontWeight: FontWeight = FontWeight.Medium
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
    ) {
        Text(
            text = text,
            fontSize = fontSizeSp.sp,
            fontWeight = fontWeight,
            color = color
        )
        HelpButton(
            onClick = { onHelp(help) },
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            contentDescription = "$text help"
        )
    }
}

@Composable
private fun HelpButton(
    onClick: () -> Unit,
    tint: Color,
    contentDescription: String
) {
    IconButton(
        onClick = onClick,
        modifier = Modifier
            .size(DesignTokens.Touch.minTarget)
            .semantics { this.contentDescription = contentDescription }
    ) {
        Icon(
            imageVector = Icons.AutoMirrored.Outlined.HelpOutline,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(20.dp)
        )
    }
}

@Composable
private fun FeatureHelpDialog(
    help: FeatureHelp,
    onDismiss: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme

    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = colorScheme.surfaceContainerHigh,
        titleContentColor = colorScheme.onSurface,
        textContentColor = colorScheme.onSurfaceVariant,
        title = {
            Text(help.title, fontWeight = FontWeight.SemiBold)
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)) {
                Text(help.message, fontSize = 14.sp, lineHeight = 20.sp)

                when (help.legend) {
                    FeatureLegend.SYLLABLES -> SyllableLegend()
                    FeatureLegend.RHYMES -> RhymeLegend()
                    null -> Unit
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) {
                Text("Got it")
            }
        }
    )
}

@Composable
private fun SyllableLegend() {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Underline colors", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurface)
        LegendRow(color = SyllableEmerald, label = "1 syllable")
        LegendRow(color = SyllableBlue, label = "2 syllables")
        LegendRow(color = SyllablePurple, label = "3 syllables")
        LegendRow(color = SyllableRose, label = "4+ syllables")
    }
}

@Composable
private fun RhymeLegend() {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("Rhyme colors", fontSize = 13.sp, fontWeight = FontWeight.Medium, color = MaterialTheme.colorScheme.onSurface)
        Text(
            "Matching colors belong to the same rhyme family. New rhyme families get the next available color.",
            fontSize = 12.sp,
            lineHeight = 17.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            RhymePalette.take(6).forEach { color ->
                Box(
                    modifier = Modifier
                        .size(18.dp)
                        .background(color, CircleShape)
                        .border(1.dp, MaterialTheme.colorScheme.outlineVariant, CircleShape)
                )
            }
        }
    }
}

@Composable
private fun LegendRow(
    color: Color,
    label: String
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        Box(
            modifier = Modifier
                .width(26.dp)
                .height(4.dp)
                .background(color, RoundedCornerShape(50))
        )
        Text(label, fontSize = 12.sp, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private fun RhymeType.shortLabel(): String = when (this) {
    RhymeType.PERFECT -> "Perfect"
    RhymeType.NEAR -> "Near"
    RhymeType.SLANT -> "Slant"
}
