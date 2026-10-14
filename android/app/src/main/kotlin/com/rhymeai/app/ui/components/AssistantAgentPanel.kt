package com.rhymeai.app.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.EditNote
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AssistChipDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.MainViewModel
import com.rhymeai.app.RhymeContext
import com.rhymeai.app.data.model.AssistantTurn
import com.rhymeai.app.data.model.RhymeComplexity
import com.rhymeai.app.data.model.RhymeScheme
import com.rhymeai.app.data.model.RhymeType
import com.rhymeai.app.service.AIModel
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.util.OpenUIAction
import com.rhymeai.app.util.OpenUIParser
import com.rhymeai.app.util.RhymeConstraint

/**
 * The assistant as an OpenUI-style agent: a per-song conversation where every reply is a
 * generated interface. Follows the OpenUI AgentInterface shape: header with model switcher,
 * a welcome with starters when the thread is empty, the thread itself, and a composer. Rhyme
 * settings ride along as context chips above the composer instead of a form.
 */
@Composable
fun AssistantAgentPanel(
    viewModel: MainViewModel,
    rhymeContext: RhymeContext,
    modifier: Modifier = Modifier,
    onLyricsChanged: () -> Unit = {}
) {
    val colorScheme = MaterialTheme.colorScheme
    val turns = viewModel.assistantTurns
    val streamingHere = viewModel.assistantBusy && viewModel.assistantStreamingProjectId == viewModel.currentProjectId
    val listState = rememberLazyListState()
    var input by rememberSaveable { mutableStateOf("") }
    val keptAlternates = viewModel.songWorkspace.alternates.mapTo(mutableSetOf()) { it.text.trim() }

    val onAction: (OpenUIAction) -> Unit = { action ->
        viewModel.handleAssistantAction(action)
        if (action is OpenUIAction.InsertLine) onLyricsChanged()
    }
    val send: (String) -> Unit = { message ->
        if (message.isNotBlank() && !viewModel.assistantBusy) {
            viewModel.sendAssistantMessage(message)
            input = ""
        }
    }

    // OpenUI's default "user-message-anchor": when the writer sends, bring their message to the
    // top so the generated reply streams in below it.
    val lastUserIndex = turns.indexOfLast { it.role == AssistantTurn.USER }
    LaunchedEffect(turns.size) {
        if (turns.isNotEmpty() && turns.last().role == AssistantTurn.USER) {
            listState.animateScrollToItem(lastUserIndex + THREAD_LEADING_ITEMS)
        }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .wrapContentWidth(Alignment.CenterHorizontally)
            .widthIn(max = DesignTokens.Drawer.expandedWidth)
            .testTag("assistantAgentPanel")
    ) {
        AgentHeader(viewModel = viewModel, canReset = turns.isNotEmpty() || viewModel.assistantBusy)
        HorizontalDivider(color = colorScheme.outlineVariant)

        LazyColumn(
            state = listState,
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .testTag("assistantThread"),
            contentPadding = PaddingValues(DesignTokens.Spacing.lg),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.lg)
        ) {
            item(key = "beat-grid") {
                if (viewModel.isBeatGridEnabled) BeatGridSection(viewModel)
            }
            if (turns.isEmpty() && !streamingHere) {
                item(key = "welcome") {
                    AgentWelcome(viewModel = viewModel, rhymeContext = rhymeContext, onStarter = send)
                }
            }
            items(turns.size, key = { turns[it].id }) { index ->
                val turn = turns[index]
                if (turn.role == AssistantTurn.USER) {
                    UserTurnBubble(turn)
                } else {
                    val parsed = remember(turn.id) {
                        OpenUIParser.parse(turn.text, rootComponentName = "Card", forceComplete = true)
                    }
                    OpenUIMessageView(
                        parseResult = parsed,
                        rawProgram = turn.text,
                        isStreaming = false,
                        verifiedSuggestions = emptyMap(),
                        highlightRhyme = viewModel.isHighlightEnabled,
                        showProsody = viewModel.isStressPreviewEnabled,
                        keptAlternates = keptAlternates,
                        onAction = onAction,
                        modifier = Modifier.testTag("assistantReply")
                    )
                }
            }
            if (streamingHere) {
                item(key = "streaming") {
                    val streamed = viewModel.assistantStreamingResult
                    if (streamed?.root != null) {
                        OpenUIMessageView(
                            parseResult = streamed,
                            rawProgram = viewModel.assistantStreamingText,
                            isStreaming = true,
                            verifiedSuggestions = emptyMap(),
                            highlightRhyme = viewModel.isHighlightEnabled,
                            showProsody = viewModel.isStressPreviewEnabled,
                            keptAlternates = keptAlternates,
                            onAction = onAction
                        )
                    } else {
                        ThinkingRow()
                    }
                }
            }
            viewModel.assistantNotice?.let { notice ->
                item(key = "notice") {
                    Text(notice, fontSize = 12.sp, color = colorScheme.onSurfaceVariant, modifier = Modifier.testTag("assistantNotice"))
                }
            }
            viewModel.assistantError?.let { error ->
                item(key = "error") {
                    AgentError(
                        message = error,
                        canRetry = !viewModel.assistantBusy && turns.lastOrNull()?.role == AssistantTurn.USER,
                        onRetry = viewModel::retryAssistant
                    )
                }
            }
        }

        HorizontalDivider(color = colorScheme.outlineVariant)
        ContextChips(viewModel = viewModel, rhymeContext = rhymeContext)
        Composer(
            value = input,
            onValueChange = { input = it },
            busy = viewModel.assistantBusy,
            onSend = { send(input) },
            onStop = viewModel::stopAssistant
        )
    }
}

/** Items before the first turn in the LazyColumn (beat grid slot, plus welcome when empty). */
private const val THREAD_LEADING_ITEMS = 1

@Composable
private fun AgentHeader(viewModel: MainViewModel, canReset: Boolean) {
    val colorScheme = MaterialTheme.colorScheme
    var modelMenu by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = DesignTokens.Spacing.lg, end = DesignTokens.Spacing.sm),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text("Assistant", style = MaterialTheme.typography.titleMedium, color = colorScheme.onSurface)
            Box {
                TextButton(
                    onClick = { modelMenu = true },
                    contentPadding = PaddingValues(horizontal = 0.dp),
                    modifier = Modifier
                        .heightIn(min = DesignTokens.Touch.minTarget)
                        .testTag("assistantModelSwitcher")
                        .semantics { contentDescription = "Model: ${viewModel.selectedModel.displayName}. Change model" }
                ) {
                    Text(
                        "${viewModel.selectedProvider.displayName} · ${viewModel.selectedModel.displayName}",
                        fontSize = 12.sp,
                        color = colorScheme.onSurfaceVariant
                    )
                    Icon(Icons.Default.KeyboardArrowDown, contentDescription = null, tint = colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
                }
                DropdownMenu(expanded = modelMenu, onDismissRequest = { modelMenu = false }) {
                    AIModel.modelsForProvider(viewModel.selectedProvider).forEach { model ->
                        DropdownMenuItem(
                            text = {
                                Text(
                                    model.displayName,
                                    fontWeight = if (model == viewModel.selectedModel) FontWeight.SemiBold else FontWeight.Normal,
                                    fontSize = 14.sp
                                )
                            },
                            onClick = {
                                modelMenu = false
                                viewModel.saveModel(model)
                            }
                        )
                    }
                }
            }
        }
        IconButton(
            onClick = viewModel::clearAssistantConversation,
            enabled = canReset,
            modifier = Modifier
                .size(DesignTokens.Touch.minTarget)
                .testTag("assistantNewConversation")
        ) {
            Icon(Icons.Default.EditNote, contentDescription = "New conversation", tint = colorScheme.onSurfaceVariant)
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun AgentWelcome(
    viewModel: MainViewModel,
    rhymeContext: RhymeContext,
    onStarter: (String) -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    val hasLyrics = viewModel.lyrics.isNotBlank()
    val anchorWord = rhymeContext.targetLine?.let { RhymeConstraint.lineEndWord(it) }?.takeIf { it.isNotBlank() }
    val section = rhymeContext.currentSection.displayName
    val starters = buildList {
        if (hasLyrics) {
            add("Suggest my next line" to "Suggest options for my next line.")
            anchorWord?.let { add("Rhymes for \u201c$it\u201d" to "Find rhymes for \"$it\" that fit this song.") }
            add("Check the meter" to "Check the meter and stress of this $section.")
            add("Map the rhyme scheme" to "Map the rhyme scheme of this $section.")
            add("Write a chorus hook" to "Help me write a chorus hook from what I have.")
        } else {
            add("Find a theme" to "Help me find a theme for a new song.")
            add("Give me an opening line" to "Give me a few strong opening lines to start a song.")
            add("Plan the structure" to "Suggest a song structure I could follow.")
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("assistantWelcome"),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)
    ) {
        Text("What are you working on?", style = MaterialTheme.typography.titleLarge, color = colorScheme.onSurface)
        Text(
            "Ask for lines, rhymes or feedback. Replies arrive as interactive cards you can use straight in your song.",
            style = MaterialTheme.typography.bodyMedium,
            color = colorScheme.onSurfaceVariant
        )
        if (hasLyrics) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(colorScheme.surfaceContainer, RoundedCornerShape(DesignTokens.Radius.md))
                    .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.md))
                    .padding(DesignTokens.Spacing.md),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
            ) {
                Text(
                    "$section · next line is ${rhymeContext.currentLetter} in ${viewModel.activeRhymeScheme}",
                    fontSize = 12.sp,
                    color = colorScheme.onSurfaceVariant
                )
                Text(
                    rhymeContext.targetLine?.let { "Rhymes with \u201c$it\u201d" } ?: "Opens a new rhyme sound",
                    fontFamily = FontFamily.Serif,
                    fontStyle = FontStyle.Italic,
                    fontSize = 14.sp,
                    color = colorScheme.onSurface
                )
            }
            RhymeSchemeDisplay(rhymeContext = rhymeContext, activeScheme = viewModel.activeRhymeScheme)
        }
        FlowRow(
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
            verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
        ) {
            starters.forEach { (label, prompt) ->
                OutlinedButton(
                    onClick = { onStarter(prompt) },
                    modifier = Modifier
                        .heightIn(min = DesignTokens.Touch.minTarget)
                        .testTag("assistantStarter"),
                    shape = RoundedCornerShape(DesignTokens.Radius.pill),
                    border = BorderStroke(1.dp, colorScheme.outlineVariant)
                ) {
                    Text(label, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                }
            }
        }
    }
}

@Composable
private fun UserTurnBubble(turn: AssistantTurn) {
    val colorScheme = MaterialTheme.colorScheme
    Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
        Column(
            modifier = Modifier
                .widthIn(max = 320.dp)
                .background(colorScheme.surfaceContainerHigh, RoundedCornerShape(DesignTokens.Radius.lg))
                .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.lg))
                .padding(horizontal = DesignTokens.Spacing.md, vertical = DesignTokens.Spacing.sm)
                .testTag("assistantUserTurn"),
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            Text(turn.text, fontSize = 14.sp, lineHeight = 20.sp, color = colorScheme.onSurface)
            if (turn.context?.contains("\"form\"") == true) {
                Text("Sent with your answers", fontSize = 11.sp, color = colorScheme.onSurfaceVariant)
            }
        }
    }
}

@Composable
private fun ThinkingRow() {
    val colorScheme = MaterialTheme.colorScheme
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
        modifier = Modifier
            .heightIn(min = DesignTokens.Touch.minTarget)
            .testTag("assistantThinking")
    ) {
        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp, color = colorScheme.onSurfaceVariant)
        Text("Thinking…", fontSize = 13.sp, color = colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun AgentError(message: String, canRetry: Boolean, onRetry: () -> Unit) {
    val colorScheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .border(1.dp, colorScheme.error.copy(alpha = 0.6f), RoundedCornerShape(DesignTokens.Radius.md))
            .padding(start = DesignTokens.Spacing.md, end = DesignTokens.Spacing.xs)
            .testTag("assistantError"),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(message, fontSize = 13.sp, color = colorScheme.error, modifier = Modifier.weight(1f).padding(vertical = DesignTokens.Spacing.sm))
        if (canRetry) {
            TextButton(onClick = onRetry, modifier = Modifier.heightIn(min = DesignTokens.Touch.minTarget)) {
                Text("Retry", fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

/** Rhyme settings as compact chips: they travel with every message as song context. */
@Composable
private fun ContextChips(viewModel: MainViewModel, rhymeContext: RhymeContext) {
    var themeDialog by remember { mutableStateOf(false) }
    var customSchemeDialog by remember { mutableStateOf(false) }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = DesignTokens.Spacing.lg, vertical = DesignTokens.Spacing.xs)
            .testTag("assistantContextChips"),
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
        verticalAlignment = Alignment.CenterVertically
    ) {
        ContextChip(
            label = if (viewModel.theme.isBlank()) "Theme" else "Theme: ${viewModel.theme.take(24)}${if (viewModel.theme.length > 24) "…" else ""}",
            onClick = { themeDialog = true },
            description = "Song theme"
        )
        MenuChip(
            label = "Scheme ${viewModel.activeRhymeScheme}",
            options = RhymeScheme.entries.map { it.label },
            onSelect = { index ->
                val scheme = RhymeScheme.entries[index]
                viewModel.rhymeScheme = scheme
                if (scheme == RhymeScheme.CUSTOM) customSchemeDialog = true
            },
            description = "Rhyme scheme"
        )
        MenuChip(
            label = viewModel.rhymeType.displayName,
            options = RhymeType.entries.map { it.displayName },
            onSelect = { viewModel.rhymeType = RhymeType.entries[it] },
            description = "Rhyme type"
        )
        MenuChip(
            label = viewModel.rhymeComplexity.label,
            options = RhymeComplexity.entries.map { "${it.label} · ${it.description}" },
            onSelect = { viewModel.rhymeComplexity = RhymeComplexity.entries[it] },
            description = "Complexity"
        )
        ContextChip(
            label = if (viewModel.useWholeSongContext) "Sharing whole song" else "Sharing current line",
            onClick = { viewModel.saveUseWholeSongContext(!viewModel.useWholeSongContext) },
            description = "Song context sharing"
        )
    }

    if (themeDialog) {
        TextEntryDialog(
            title = "Song theme",
            initial = viewModel.theme,
            placeholder = "What is this song about?",
            onDismiss = { themeDialog = false },
            onConfirm = {
                viewModel.onThemeChanged(it.trim())
                themeDialog = false
            }
        )
    }
    if (customSchemeDialog) {
        TextEntryDialog(
            title = "Custom rhyme scheme",
            initial = viewModel.customRhymeScheme,
            placeholder = "e.g. AABBCC",
            onDismiss = { customSchemeDialog = false },
            onConfirm = {
                viewModel.customRhymeScheme = it.uppercase().filter { c -> c.isLetter() }
                customSchemeDialog = false
            }
        )
    }
}

@Composable
private fun ContextChip(label: String, onClick: () -> Unit, description: String) {
    val colorScheme = MaterialTheme.colorScheme
    AssistChip(
        onClick = onClick,
        label = { Text(label, fontSize = 12.sp, maxLines = 1) },
        shape = RoundedCornerShape(DesignTokens.Radius.pill),
        colors = AssistChipDefaults.assistChipColors(labelColor = colorScheme.onSurface),
        border = AssistChipDefaults.assistChipBorder(enabled = true, borderColor = colorScheme.outlineVariant),
        modifier = Modifier.semantics { contentDescription = "$description: $label" }
    )
}

@Composable
private fun MenuChip(label: String, options: List<String>, onSelect: (Int) -> Unit, description: String) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        val colorScheme = MaterialTheme.colorScheme
        AssistChip(
            onClick = { expanded = true },
            label = { Text(label, fontSize = 12.sp, maxLines = 1) },
            trailingIcon = { Icon(Icons.Default.KeyboardArrowDown, contentDescription = null, modifier = Modifier.size(16.dp)) },
            shape = RoundedCornerShape(DesignTokens.Radius.pill),
            colors = AssistChipDefaults.assistChipColors(labelColor = colorScheme.onSurface, trailingIconContentColor = colorScheme.onSurfaceVariant),
            border = AssistChipDefaults.assistChipBorder(enabled = true, borderColor = colorScheme.outlineVariant),
            modifier = Modifier.semantics { contentDescription = "$description: $label" }
        )
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEachIndexed { index, option ->
                DropdownMenuItem(
                    text = { Text(option, fontSize = 14.sp) },
                    onClick = {
                        expanded = false
                        onSelect(index)
                    }
                )
            }
        }
    }
}

@Composable
private fun TextEntryDialog(
    title: String,
    initial: String,
    placeholder: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit
) {
    var value by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            OutlinedTextField(
                value = value,
                onValueChange = { value = it },
                placeholder = { Text(placeholder) },
                modifier = Modifier.fillMaxWidth()
            )
        },
        confirmButton = { TextButton(onClick = { onConfirm(value) }) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } }
    )
}

@Composable
private fun Composer(
    value: String,
    onValueChange: (String) -> Unit,
    busy: Boolean,
    onSend: () -> Unit,
    onStop: () -> Unit
) {
    val colorScheme = MaterialTheme.colorScheme
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = DesignTokens.Spacing.lg, end = DesignTokens.Spacing.md, top = DesignTokens.Spacing.xs, bottom = DesignTokens.Spacing.sm),
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
    ) {
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            placeholder = { Text("Ask for lines, rhymes, feedback…", fontSize = 14.sp) },
            maxLines = 4,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { if (!busy) onSend() }),
            shape = RoundedCornerShape(DesignTokens.Radius.lg),
            colors = OutlinedTextFieldDefaults.colors(
                unfocusedContainerColor = colorScheme.surfaceContainerLow,
                focusedContainerColor = colorScheme.surfaceContainerLow,
                unfocusedBorderColor = colorScheme.outlineVariant,
                focusedBorderColor = colorScheme.primary
            ),
            modifier = Modifier
                .weight(1f)
                .testTag("assistantComposer")
        )
        if (busy) {
            FilledIconButton(
                onClick = onStop,
                modifier = Modifier
                    .size(DesignTokens.Touch.minTarget)
                    .testTag("assistantStop"),
                shape = CircleShape
            ) {
                Icon(Icons.Default.Stop, contentDescription = "Stop generating")
            }
        } else {
            FilledIconButton(
                onClick = onSend,
                enabled = value.isNotBlank(),
                modifier = Modifier
                    .size(DesignTokens.Touch.minTarget)
                    .testTag("assistantSend"),
                shape = CircleShape,
                colors = IconButtonDefaults.filledIconButtonColors(
                    containerColor = colorScheme.primary,
                    contentColor = colorScheme.onPrimary
                )
            ) {
                Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send")
            }
        }
    }
}
