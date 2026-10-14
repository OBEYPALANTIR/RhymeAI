package com.rhymeai.app.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Code
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.rhymeai.app.SuggestedLine
import com.rhymeai.app.ui.theme.DesignTokens
import com.rhymeai.app.ui.theme.LocalAnimationsEnabled
import com.rhymeai.app.util.OpenUIElementNode
import com.rhymeai.app.util.OpenUIParseResult
import com.rhymeai.app.util.SyllableCounter

import com.rhymeai.app.service.AIModel
import com.rhymeai.app.util.OpenUIAction
import com.rhymeai.app.util.OpenUIValue
import com.rhymeai.app.util.toJson
import com.rhymeai.app.ui.theme.LocalAppAppearance
import com.rhymeai.app.ui.theme.rhymePalette
import com.rhymeai.app.ui.theme.statusErrorColor
import com.rhymeai.app.ui.theme.statusSuccessColor
import com.rhymeai.app.ui.theme.statusWarningColor
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.ScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.foundation.clickable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import kotlinx.coroutines.launch

typealias OpenUIToolProvider = Map<String, suspend (Map<String, Any?>) -> OpenUIValue>

class OpenUIRuntimeState(
    val parseResult: OpenUIParseResult,
    val stateValues: MutableMap<String, OpenUIValue>,
    val queryResults: MutableMap<String, OpenUIValue>,
    val toolProvider: OpenUIToolProvider,
    private val runScope: kotlinx.coroutines.CoroutineScope,
    private val dispatch: (OpenUIAction) -> Unit = {}
) {
    /** Fields the writer has filled in; their values are attached to @ToAssistant as form state. */
    private val userFields = linkedSetOf<String>()

    fun getStateString(varName: String): String {
        val v = stateValues[varName] ?: parseResult.stateDeclarations[varName]
        return v?.asString().orEmpty()
    }

    fun setStateString(varName: String, newValue: String) {
        userFields += varName
        stateValues[varName] = OpenUIValue.Str(newValue)
    }

    suspend fun executeQuery(queryId: String) {
        val queryNode = parseResult.queries[queryId] ?: return
        val toolName = queryNode.stringProp("toolName") ?: return
        val handler = toolProvider[toolName] ?: return
        val argsMap = resolveArgsObject(queryNode.props["args"])
        val result = runCatching { handler(argsMap) }.getOrNull()
        if (result != null) {
            queryResults[queryId] = result
        }
    }

    suspend fun executeMutation(mutationId: String) {
        val mutationNode = parseResult.mutations[mutationId] ?: return
        val toolName = mutationNode.stringProp("toolName") ?: return
        val handler = toolProvider[toolName] ?: return
        val argsMap = resolveArgsObject(mutationNode.props["args"])
        runCatching { handler(argsMap) }
    }

    /** OpenUI default: a Button without an action sends its own label to the assistant. */
    fun sendLabel(label: String) {
        if (label.isNotBlank()) dispatch(OpenUIAction.ToAssistant(label, buildContextJson(null)))
    }

    fun executeActionNode(actionNode: OpenUIElementNode?) {
        if (actionNode == null) return
        val steps = if (actionNode.typeName == "Action") {
            actionNode.childrenProp("steps")
        } else {
            listOf(actionNode)
        }
        runScope.launch {
            for (step in steps) {
                when (step.typeName) {
                    "@Run" -> {
                        val target = (step.props["target"] as? OpenUIValue.Element)?.node
                        if (target != null) {
                            when (target.typeName) {
                                "Mutation" -> executeMutation(target.statementId)
                                "Query" -> executeQuery(target.statementId)
                            }
                        }
                    }
                    "@Reset" -> {
                        for ((_, propVal) in step.props) {
                            if (propVal is OpenUIValue.StateRef) {
                                val defaultVal = parseResult.stateDeclarations[propVal.name] ?: OpenUIValue.Str("")
                                stateValues[propVal.name] = defaultVal
                            }
                        }
                    }
                    "@Set" -> {
                        val target = step.props["target"] as? OpenUIValue.StateRef
                        val value = step.props["value"]
                        if (target != null && value != null) stateValues[target.name] = resolve(value)
                    }
                    "@ToAssistant" -> {
                        val message = resolve(step.props["message"] ?: OpenUIValue.NullVal).asString().orEmpty()
                        if (message.isNotBlank()) {
                            dispatch(OpenUIAction.ToAssistant(message, buildContextJson(step.props["context"])))
                        }
                    }
                    "@InsertLine" -> dispatch(OpenUIAction.InsertLine(propText(step, "text")))
                    "@ReplaceLine" -> dispatch(OpenUIAction.ReplaceLine(propText(step, "original"), propText(step, "replacement")))
                    "@KeepAlternate" -> dispatch(OpenUIAction.KeepAlternate(propText(step, "text")))
                    "@SetTheme" -> dispatch(OpenUIAction.SetTheme(propText(step, "theme")))
                }
            }
        }
    }

    private fun propText(step: OpenUIElementNode, name: String): String =
        resolve(step.props[name] ?: OpenUIValue.NullVal).asString().orEmpty()

    /** Substitutes current $state values for state references. */
    private fun resolve(value: OpenUIValue): OpenUIValue = when (value) {
        is OpenUIValue.StateRef -> stateValues[value.name] ?: parseResult.stateDeclarations[value.name] ?: OpenUIValue.NullVal
        is OpenUIValue.Arr -> OpenUIValue.Arr(value.items.map(::resolve))
        is OpenUIValue.Obj -> OpenUIValue.Obj(value.entries.mapValues { resolve(it.value) })
        else -> value
    }

    /** `{"context": ..., "form": {...}}` with only the parts that exist, or null. */
    private fun buildContextJson(context: OpenUIValue?): String? {
        val parts = LinkedHashMap<String, OpenUIValue>()
        context?.let(::resolve)?.takeUnless { it is OpenUIValue.NullVal }?.let { parts["context"] = it }
        val form = userFields.associateWith { stateValues[it] ?: OpenUIValue.Str("") }
        if (form.isNotEmpty()) parts["form"] = OpenUIValue.Obj(form)
        return if (parts.isEmpty()) null else OpenUIValue.Obj(parts).toJson()
    }

    fun resolveColumnCells(dataProp: OpenUIValue?): List<String> {
        return when (dataProp) {
            is OpenUIValue.PropPath -> {
                val rootObj = queryResults[dataProp.rootName]
                    ?: parseResult.queries[dataProp.rootName]?.props?.get("defaults")
                    ?: return emptyList()
                extractPathStrings(rootObj, dataProp.path)
            }
            is OpenUIValue.Arr -> dataProp.items.mapNotNull { it.asString() }
            else -> emptyList()
        }
    }

    private fun extractPathStrings(current: OpenUIValue, path: List<String>): List<String> {
        if (path.isEmpty()) {
            return listOfNotNull(current.asString())
        }
        val head = path.first()
        val tail = path.drop(1)
        return when (current) {
            is OpenUIValue.Obj -> {
                val next = current.entries[head] ?: return emptyList()
                extractPathStrings(next, tail)
            }
            is OpenUIValue.Arr -> {
                current.items.flatMap { item -> extractPathStrings(item, path) }
            }
            else -> emptyList()
        }
    }

    private fun resolveArgsObject(raw: OpenUIValue?): Map<String, Any?> {
        val obj = raw as? OpenUIValue.Obj ?: return emptyMap()
        val result = LinkedHashMap<String, Any?>()
        for ((k, v) in obj.entries) {
            result[k] = when (v) {
                is OpenUIValue.StateRef -> getStateString(v.name)
                is OpenUIValue.Str -> v.value
                is OpenUIValue.Num -> v.value
                is OpenUIValue.BoolVal -> v.value
                else -> v.asString()
            }
        }
        return result
    }
}

private val LocalOpenUIRuntime = compositionLocalOf<OpenUIRuntimeState?> { null }

/** Component types that are runtime wiring (referenced through props), never rendered on their own. */
private val NON_VISUAL_OPENUI_TYPES = setOf(
    "Query", "Mutation", "Action", "@Run", "@Reset", "@Set", "@ToAssistant", "@InsertLine",
    "@ReplaceLine", "@KeepAlternate", "@SetTheme", "Col", "SelectItem"
)

/** Dispatches generated-UI events to the host. */
internal val LocalOpenUIActionHandler = compositionLocalOf<(OpenUIAction) -> Unit> { {} }

/** False while a message is still streaming: OpenUI keeps interactions off until the program is complete. */
internal val LocalOpenUIInteractive = compositionLocalOf { true }

/**
 * Renders one generated assistant reply (an OpenUI Lang program). Each message gets its own
 * runtime so `$state` and form values are scoped to that program, as in the OpenUI spec.
 * Shows a plain-text fallback when the model ignored the format, and a Source toggle with any
 * parse issues once streaming has finished.
 */
@Composable
fun OpenUIMessageView(
    parseResult: OpenUIParseResult,
    rawProgram: String,
    isStreaming: Boolean,
    verifiedSuggestions: Map<String, SuggestedLine>,
    highlightRhyme: Boolean,
    showProsody: Boolean,
    keptAlternates: Set<String>,
    onAction: (OpenUIAction) -> Unit,
    modifier: Modifier = Modifier,
    toolProvider: OpenUIToolProvider? = null
) {
    val colorScheme = MaterialTheme.colorScheme
    val animationsEnabled = LocalAnimationsEnabled.current
    val effectiveTools = toolProvider ?: emptyMap()
    val currentOnAction by rememberUpdatedState(onAction)
    val stateValues = remember(parseResult.stateDeclarations) {
        mutableStateMapOf<String, OpenUIValue>().apply { putAll(parseResult.stateDeclarations) }
    }
    val queryResults = remember(parseResult.queries) {
        mutableStateMapOf<String, OpenUIValue>().apply {
            for ((id, qNode) in parseResult.queries) {
                qNode.props["defaults"]?.let { put(id, it) }
            }
        }
    }
    val scope = rememberCoroutineScope()
    val runtime = remember(parseResult, effectiveTools) {
        OpenUIRuntimeState(
            parseResult = parseResult,
            stateValues = stateValues,
            queryResults = queryResults,
            toolProvider = effectiveTools,
            runScope = scope,
            dispatch = { currentOnAction(it) }
        )
    }
    // Spec: queries run when streaming ends, never mid-stream.
    LaunchedEffect(parseResult.queries, effectiveTools, isStreaming) {
        if (!isStreaming) {
            for (queryId in parseResult.queries.keys) runtime.executeQuery(queryId)
        }
    }
    var showSource by remember { mutableStateOf(false) }
    val root = parseResult.root

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
    ) {
        when {
            root != null -> CompositionLocalProvider(
                LocalOpenUIRuntime provides runtime,
                LocalOpenUIActionHandler provides { action -> currentOnAction(action) },
                LocalOpenUIInteractive provides !isStreaming
            ) {
                OpenUINodeRenderer(
                    node = root,
                    verifiedSuggestions = verifiedSuggestions,
                    highlightRhyme = highlightRhyme,
                    showProsody = showProsody,
                    keptAlternates = keptAlternates,
                    onUseSuggestion = { currentOnAction(OpenUIAction.InsertLine(it)) },
                    onKeepSuggestion = { currentOnAction(OpenUIAction.KeepAlternate(it)) },
                    onActionChipSelected = { currentOnAction(OpenUIAction.ToAssistant(it)) }
                )
            }
            !isStreaming && rawProgram.isNotBlank() && parseResult.meta.statementCount == 0 -> Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.lg))
                    .padding(DesignTokens.Spacing.md)
                    .testTag("openUIPlainTextReply"),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
            ) {
                Text(
                    "Replied in plain text instead of a generated interface.",
                    fontSize = 12.sp,
                    color = colorScheme.onSurfaceVariant
                )
                Text(rawProgram.trim(), fontSize = 14.sp, lineHeight = 20.sp, color = colorScheme.onSurface)
            }
        }

        if (!isStreaming && rawProgram.isNotBlank() && parseResult.meta.statementCount > 0) {
            val issues = parseResult.meta.errors.size
            TextButton(
                onClick = { showSource = !showSource },
                modifier = Modifier
                    .heightIn(min = DesignTokens.Touch.minTarget)
                    .testTag("openUISourceToggle")
            ) {
                androidx.compose.material3.Icon(Icons.Default.Code, contentDescription = null, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text(
                    text = when {
                        showSource -> "Hide source"
                        issues > 0 -> "Source · $issues issue${if (issues == 1) "" else "s"}"
                        else -> "Source"
                    },
                    fontSize = 12.sp,
                    color = if (issues > 0 && !showSource) colorScheme.error else colorScheme.onSurfaceVariant
                )
            }
            AnimatedVisibility(
                visible = showSource,
                enter = if (animationsEnabled) {
                    expandVertically(tween(DesignTokens.Motion.feedbackMillis, easing = DesignTokens.Motion.standardEasing), expandFrom = Alignment.Top)
                } else EnterTransition.None,
                exit = if (animationsEnabled) {
                    shrinkVertically(tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing), shrinkTowards = Alignment.Top)
                } else ExitTransition.None
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(colorScheme.surfaceContainerLow, RoundedCornerShape(DesignTokens.Radius.md))
                        .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.md))
                        .padding(DesignTokens.Spacing.md)
                        .testTag("openUILangInspector"),
                    verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
                ) {
                    parseResult.meta.errors.forEach { err ->
                        Text("⚠ $err", fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = colorScheme.error)
                    }
                    Text(
                        text = rawProgram.trim(),
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                        lineHeight = 17.sp,
                        color = colorScheme.onSurface
                    )
                }
            }
        }
    }
}

@Composable
private fun IconOrSpinner(isStreaming: Boolean) {
    val colorScheme = MaterialTheme.colorScheme
    if (isStreaming) {
        CircularProgressIndicator(
            modifier = Modifier.size(16.dp),
            color = colorScheme.primary,
            strokeWidth = 2.dp
        )
    } else {
        androidx.compose.material3.Icon(
            Icons.Default.AutoAwesome,
            contentDescription = null,
            tint = colorScheme.primary,
            modifier = Modifier.size(16.dp)
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun OpenUINodeRenderer(
    node: OpenUIElementNode,
    verifiedSuggestions: Map<String, SuggestedLine>,
    highlightRhyme: Boolean,
    showProsody: Boolean,
    keptAlternates: Set<String>,
    onUseSuggestion: (String) -> Unit,
    onKeepSuggestion: (String) -> Unit,
    onActionChipSelected: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    val runtime = LocalOpenUIRuntime.current
    val interactive = LocalOpenUIInteractive.current

    when (node.typeName) {
        "Stack" -> {
            val direction = node.stringProp("direction") ?: "column"
            val gap = resolveGap(node.stringProp("gap"))
            val children = node.childrenProp("children")
            if (direction.equals("row", ignoreCase = true)) {
                FlowRow(
                    modifier = modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(gap),
                    verticalArrangement = Arrangement.spacedBy(gap)
                ) {
                    children.forEach { child ->
                        OpenUINodeRenderer(
                            node = child,
                            verifiedSuggestions = verifiedSuggestions,
                            highlightRhyme = highlightRhyme,
                            showProsody = showProsody,
                            keptAlternates = keptAlternates,
                            onUseSuggestion = onUseSuggestion,
                            onKeepSuggestion = onKeepSuggestion,
                            onActionChipSelected = onActionChipSelected
                        )
                    }
                }
            } else {
                Column(
                    modifier = modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(gap)
                ) {
                    children.forEach { child ->
                        OpenUINodeRenderer(
                            node = child,
                            verifiedSuggestions = verifiedSuggestions,
                            highlightRhyme = highlightRhyme,
                            showProsody = showProsody,
                            keptAlternates = keptAlternates,
                            onUseSuggestion = onUseSuggestion,
                            onKeepSuggestion = onKeepSuggestion,
                            onActionChipSelected = onActionChipSelected
                        )
                    }
                }
            }
        }

        "Card" -> {
            val title = node.stringProp("title")
            val subtitle = node.stringProp("subtitle")
            val children = node.childrenProp("children")
            OutlinedCard(
                modifier = modifier.fillMaxWidth(),
                shape = RoundedCornerShape(DesignTokens.Radius.lg),
                colors = CardDefaults.outlinedCardColors(
                    containerColor = colorScheme.surfaceContainerLow,
                    contentColor = colorScheme.onSurface
                ),
                border = BorderStroke(1.dp, colorScheme.outlineVariant)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(DesignTokens.Spacing.lg),
                    verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                ) {
                    if (!title.isNullOrBlank()) {
                        Text(
                            text = title,
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Medium,
                            color = colorScheme.onSurface
                        )
                    }
                    if (!subtitle.isNullOrBlank()) {
                        Text(
                            text = subtitle,
                            fontSize = 12.sp,
                            color = colorScheme.onSurfaceVariant
                        )
                    }
                    children.forEach { child ->
                        OpenUINodeRenderer(
                            node = child,
                            verifiedSuggestions = verifiedSuggestions,
                            highlightRhyme = highlightRhyme,
                            showProsody = showProsody,
                            keptAlternates = keptAlternates,
                            onUseSuggestion = onUseSuggestion,
                            onKeepSuggestion = onKeepSuggestion,
                            onActionChipSelected = onActionChipSelected
                        )
                    }
                }
            }
        }

        "CardHeader" -> {
            val title = node.stringProp("title").orEmpty()
            val subtitle = node.stringProp("subtitle")
            val badge = node.stringProp("badge")
            Row(
                modifier = modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(2.dp)
                ) {
                    Text(
                        text = title,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Medium,
                        color = colorScheme.onSurface
                    )
                    if (!subtitle.isNullOrBlank()) {
                        Text(
                            text = subtitle,
                            fontSize = 12.sp,
                            color = colorScheme.onSurfaceVariant
                        )
                    }
                }
                if (!badge.isNullOrBlank()) {
                    OpenUIBadgePill(label = badge, variant = "neutral")
                }
            }
        }

        "TextContent" -> {
            val text = node.stringProp("text").orEmpty()
            val tone = node.stringProp("tone") ?: "default"
            if (text.isNotBlank()) {
                Text(
                    text = text,
                    fontFamily = when (tone) {
                        "serif" -> FontFamily.Serif
                        "mono" -> FontFamily.Monospace
                        else -> FontFamily.Default
                    },
                    fontStyle = if (tone == "serif") FontStyle.Italic else FontStyle.Normal,
                    fontSize = if (tone == "muted") 12.sp else 14.sp,
                    lineHeight = 20.sp,
                    color = if (tone == "muted") colorScheme.onSurfaceVariant else colorScheme.onSurface,
                    modifier = modifier
                )
            }
        }

        "Badge" -> {
            val label = node.stringProp("label").orEmpty()
            val variant = node.stringProp("variant") ?: "neutral"
            if (label.isNotBlank()) {
                OpenUIBadgePill(label = label, variant = variant, modifier = modifier)
            }
        }

        "ProsodyMeter" -> {
            val line = node.stringProp("line").orEmpty()
            val stressPattern = node.stringProp("stressPattern")
            val cadenceNote = node.stringProp("cadenceNote")
            if (line.isNotBlank()) {
                Box(
                    modifier = modifier
                        .fillMaxWidth()
                        .background(colorScheme.surfaceContainerLow, RoundedCornerShape(DesignTokens.Radius.md))
                        .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.md))
                        .padding(DesignTokens.Spacing.md)
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = "Prosody & Cadence Anchor",
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Medium,
                                color = colorScheme.onSurfaceVariant
                            )
                            OpenUIBadgePill(
                                label = "${SyllableCounter.countText(line)} syl",
                                variant = "neutral"
                            )
                        }
                        Text(
                            text = "\"$line\"",
                            fontFamily = FontFamily.Serif,
                            fontStyle = FontStyle.Italic,
                            fontSize = 14.sp,
                            color = colorScheme.onSurface
                        )
                        ProsodyPreview(text = line)
                        if (!stressPattern.isNullOrBlank() || !cadenceNote.isNullOrBlank()) {
                            Text(
                                text = listOfNotNull(
                                    stressPattern?.takeIf { it.isNotBlank() },
                                    cadenceNote?.takeIf { it.isNotBlank() }
                                ).joinToString(" · "),
                                fontFamily = FontFamily.Monospace,
                                fontSize = 12.sp,
                                color = colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }
            }
        }

        "RhymeGroup" -> {
            val title = node.stringProp("title").orEmpty()
            val rhymeSound = node.stringProp("rhymeSound")
            val note = node.stringProp("note")
            val suggestions = node.childrenProp("suggestions")
            Column(
                modifier = modifier
                    .fillMaxWidth()
                    .background(colorScheme.surfaceContainerLow, RoundedCornerShape(DesignTokens.Radius.lg))
                    .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.lg))
                    .padding(DesignTokens.Spacing.md),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        if (title.isNotBlank()) {
                            Text(
                                text = title,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.Medium,
                                color = colorScheme.onSurface
                            )
                        }
                        if (!note.isNullOrBlank()) {
                            Text(
                                text = note,
                                fontSize = 12.sp,
                                color = colorScheme.onSurfaceVariant
                            )
                        }
                    }
                    if (!rhymeSound.isNullOrBlank()) {
                        OpenUIBadgePill(label = rhymeSound, variant = "neutral")
                    }
                }

                suggestions.forEach { child ->
                    OpenUINodeRenderer(
                        node = child,
                        verifiedSuggestions = verifiedSuggestions,
                        highlightRhyme = highlightRhyme,
                        showProsody = showProsody,
                        keptAlternates = keptAlternates,
                        onUseSuggestion = onUseSuggestion,
                        onKeepSuggestion = onKeepSuggestion,
                        onActionChipSelected = onActionChipSelected
                    )
                }
            }
        }

        "SuggestionLine" -> {
            val rawText = node.stringProp("text")?.trim().orEmpty()
            val angle = node.stringProp("angle")?.trim()
            if (rawText.isNotEmpty()) {
                val verified = verifiedSuggestions[rawText.lowercase()]
                Column(
                    modifier = modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    if (!angle.isNullOrBlank()) {
                        Text(
                            text = angle,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Medium,
                            color = colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = 4.dp)
                        )
                    }
                    SuggestionCard(
                        suggestion = rawText,
                        rhymeTier = verified?.rhymeTier ?: 0,
                        isHook = verified?.isHook ?: false,
                        highlightRhyme = highlightRhyme,
                        showProsody = showProsody,
                        onKeep = { onKeepSuggestion(rawText) },
                        isKept = rawText in keptAlternates,
                        onUse = { onUseSuggestion(rawText) }
                    )
                }
            }
        }

        "ActionChipBar" -> {
            val promptLabel = node.stringProp("promptLabel").orEmpty()
            val actions = node.stringListProp("actions")
            if (actions.isNotEmpty()) {
                Column(
                    modifier = modifier.fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
                ) {
                    if (promptLabel.isNotBlank()) {
                        Text(
                            text = promptLabel,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            color = colorScheme.onSurfaceVariant
                        )
                    }
                    FlowRow(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
                        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
                    ) {
                        actions.forEach { actionLabel ->
                            OutlinedButton(
                                onClick = { onActionChipSelected(actionLabel) },
                                enabled = interactive,
                                modifier = Modifier.heightIn(min = DesignTokens.Touch.minTarget),
                                shape = RoundedCornerShape(DesignTokens.Radius.lg),
                                border = BorderStroke(1.dp, colorScheme.outlineVariant)
                            ) {
                                Text(
                                    text = actionLabel,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Medium
                                )
                            }
                        }
                    }
                }
            }
        }

        "Form" -> {
            val fields = node.childrenProp("fields")
            val buttonsNode = (node.props["buttons"] as? OpenUIValue.Element)?.node
            Column(
                modifier = modifier
                    .fillMaxWidth()
                    .background(colorScheme.surfaceContainerLow, RoundedCornerShape(DesignTokens.Radius.lg))
                    .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.lg))
                    .padding(DesignTokens.Spacing.md),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
            ) {
                fields.forEach { field ->
                    OpenUINodeRenderer(
                        node = field,
                        verifiedSuggestions = verifiedSuggestions,
                        highlightRhyme = highlightRhyme,
                        showProsody = showProsody,
                        keptAlternates = keptAlternates,
                        onUseSuggestion = onUseSuggestion,
                        onKeepSuggestion = onKeepSuggestion,
                        onActionChipSelected = onActionChipSelected
                    )
                }
                if (buttonsNode != null) {
                    OpenUINodeRenderer(
                        node = buttonsNode,
                        verifiedSuggestions = verifiedSuggestions,
                        highlightRhyme = highlightRhyme,
                        showProsody = showProsody,
                        keptAlternates = keptAlternates,
                        onUseSuggestion = onUseSuggestion,
                        onKeepSuggestion = onKeepSuggestion,
                        onActionChipSelected = onActionChipSelected
                    )
                }
            }
        }

        "FormControl" -> {
            val label = node.stringProp("label").orEmpty()
            val control = (node.props["control"] as? OpenUIValue.Element)?.node
            Column(
                modifier = modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(4.dp)
            ) {
                if (label.isNotBlank()) {
                    Text(
                        text = label,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        color = colorScheme.onSurfaceVariant
                    )
                }
                if (control != null) {
                    OpenUINodeRenderer(
                        node = control,
                        verifiedSuggestions = verifiedSuggestions,
                        highlightRhyme = highlightRhyme,
                        showProsody = showProsody,
                        keptAlternates = keptAlternates,
                        onUseSuggestion = onUseSuggestion,
                        onKeepSuggestion = onKeepSuggestion,
                        onActionChipSelected = onActionChipSelected
                    )
                }
            }
        }

        "Input" -> {
            val name = node.stringProp("name").orEmpty()
            val placeholder = node.stringProp("placeholder").orEmpty()
            val bindingVar = (node.props["binding"] as? OpenUIValue.StateRef)?.name ?: name
            val currentValue = runtime?.getStateString(bindingVar).orEmpty()
            OutlinedTextField(
                value = currentValue,
                onValueChange = { runtime?.setStateString(bindingVar, it) },
                placeholder = if (placeholder.isNotBlank()) {
                    { Text(placeholder, fontSize = 12.sp) }
                } else null,
                singleLine = true,
                modifier = modifier.fillMaxWidth(),
                shape = RoundedCornerShape(DesignTokens.Radius.md)
            )
        }

        "Select" -> {
            val name = node.stringProp("name").orEmpty()
            val items = node.childrenProp("items")
            val bindingVar = (node.props["binding"] as? OpenUIValue.StateRef)?.name ?: name
            val currentValue = runtime?.getStateString(bindingVar).orEmpty()
            var expanded by remember { mutableStateOf(false) }
            val currentLabel = items.firstOrNull {
                it.stringProp("value") == currentValue
            }?.stringProp("label") ?: currentValue.ifEmpty { node.stringProp("placeholder") ?: "Select" }

            Box(modifier = modifier.fillMaxWidth()) {
                OutlinedButton(
                    onClick = { expanded = true },
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(min = DesignTokens.Touch.minTarget),
                    shape = RoundedCornerShape(DesignTokens.Radius.md)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(currentLabel, fontSize = 13.sp)
                        androidx.compose.material3.Icon(
                            Icons.Default.KeyboardArrowDown,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                }
                DropdownMenu(
                    expanded = expanded,
                    onDismissRequest = { expanded = false }
                ) {
                    items.forEach { itemNode ->
                        val itemVal = itemNode.stringProp("value").orEmpty()
                        val itemLabel = itemNode.stringProp("label") ?: itemVal
                        DropdownMenuItem(
                            text = { Text(itemLabel, fontSize = 13.sp) },
                            onClick = {
                                expanded = false
                                runtime?.setStateString(bindingVar, itemVal)
                            }
                        )
                    }
                }
            }
        }

        "Buttons" -> {
            val children = node.childrenProp("children")
            FlowRow(
                modifier = modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
            ) {
                children.forEach { btn ->
                    OpenUINodeRenderer(
                        node = btn,
                        verifiedSuggestions = verifiedSuggestions,
                        highlightRhyme = highlightRhyme,
                        showProsody = showProsody,
                        keptAlternates = keptAlternates,
                        onUseSuggestion = onUseSuggestion,
                        onKeepSuggestion = onKeepSuggestion,
                        onActionChipSelected = onActionChipSelected
                    )
                }
            }
        }

        "Button" -> {
            val label = node.stringProp("label").orEmpty()
            val variant = node.stringProp("variant") ?: "primary"
            val actionNode = (node.props["action"] as? OpenUIValue.Element)?.node
            val onClick: () -> Unit = {
                if (actionNode != null) runtime?.executeActionNode(actionNode) else runtime?.sendLabel(label)
            }
            if (variant == "secondary" || variant == "tertiary") {
                OutlinedButton(
                    onClick = onClick,
                    enabled = interactive,
                    modifier = modifier.heightIn(min = DesignTokens.Touch.minTarget),
                    shape = RoundedCornerShape(DesignTokens.Radius.md)
                ) {
                    Text(label, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                }
            } else {
                Button(
                    onClick = onClick,
                    enabled = interactive,
                    modifier = modifier.heightIn(min = DesignTokens.Touch.minTarget),
                    shape = RoundedCornerShape(DesignTokens.Radius.md)
                ) {
                    Text(label, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                }
            }
        }

        "Table" -> {
            val columns = node.childrenProp("columns")
            if (columns.isNotEmpty()) {
                val headers = columns.map { it.stringProp("header").orEmpty() }
                val colCells = columns.map { colNode ->
                    runtime?.resolveColumnCells(colNode.props["data"]).orEmpty()
                }
                val rowCount = colCells.maxOfOrNull { it.size } ?: 0
                Column(
                    modifier = modifier
                        .fillMaxWidth()
                        .background(colorScheme.surfaceContainerLow, RoundedCornerShape(DesignTokens.Radius.md))
                        .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.md))
                        .padding(DesignTokens.Spacing.md),
                    verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                    ) {
                        headers.forEach { header ->
                            Text(
                                text = header,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = colorScheme.onSurfaceVariant,
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }
                    for (r in 0 until rowCount) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 2.dp),
                            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
                        ) {
                            for (c in columns.indices) {
                                Text(
                                    text = colCells[c].getOrNull(r).orEmpty(),
                                    fontSize = 13.sp,
                                    color = colorScheme.onSurface,
                                    modifier = Modifier.weight(1f)
                                )
                            }
                        }
                    }
                }
            }
        }

        "Callout" -> {
            val variant = node.stringProp("variant") ?: "info"
            val title = node.stringProp("title").orEmpty()
            val description = node.stringProp("description")
            val isDark = LocalAppAppearance.current.isDark
            val accent = when (variant) {
                "success" -> statusSuccessColor(isDark)
                "warning" -> statusWarningColor(isDark)
                "error" -> statusErrorColor(isDark)
                else -> colorScheme.onSurfaceVariant
            }
            Row(
                modifier = modifier
                    .fillMaxWidth()
                    .background(colorScheme.surfaceContainer, RoundedCornerShape(DesignTokens.Radius.md))
                    .border(1.dp, accent.copy(alpha = 0.6f), RoundedCornerShape(DesignTokens.Radius.md))
                    .padding(DesignTokens.Spacing.md)
                    .semantics(mergeDescendants = true) {},
                horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
            ) {
                Box(
                    Modifier
                        .padding(top = 4.dp)
                        .size(8.dp)
                        .background(accent, RoundedCornerShape(4.dp))
                )
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    if (title.isNotBlank()) {
                        Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = colorScheme.onSurface)
                    }
                    if (!description.isNullOrBlank()) {
                        Text(description, fontSize = 13.sp, lineHeight = 18.sp, color = colorScheme.onSurfaceVariant)
                    }
                }
            }
        }

        "TagBlock" -> {
            val tags = node.childrenProp("tags")
            FlowRow(
                modifier = modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
            ) {
                tags.forEach { tag ->
                    OpenUINodeRenderer(
                        node = tag,
                        verifiedSuggestions = verifiedSuggestions,
                        highlightRhyme = highlightRhyme,
                        showProsody = showProsody,
                        keptAlternates = keptAlternates,
                        onUseSuggestion = onUseSuggestion,
                        onKeepSuggestion = onKeepSuggestion,
                        onActionChipSelected = onActionChipSelected
                    )
                }
            }
        }

        "Tag" -> {
            val text = node.stringProp("text").orEmpty()
            if (text.isNotBlank()) {
                val isDark = LocalAppAppearance.current.isDark
                val tint = when (node.stringProp("variant")) {
                    "success" -> statusSuccessColor(isDark)
                    "warning" -> statusWarningColor(isDark)
                    "error" -> statusErrorColor(isDark)
                    else -> null
                }
                Surface(
                    modifier = modifier,
                    shape = RoundedCornerShape(DesignTokens.Radius.xs),
                    color = colorScheme.surfaceContainerHigh,
                    contentColor = tint ?: colorScheme.onSurfaceVariant,
                    border = tint?.let { BorderStroke(1.dp, it.copy(alpha = 0.6f)) }
                ) {
                    Text(
                        text = text,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium,
                        modifier = Modifier.padding(horizontal = DesignTokens.Spacing.sm, vertical = DesignTokens.Spacing.xs)
                    )
                }
            }
        }

        "ListBlock" -> {
            val items = node.childrenProp("items")
            Column(
                modifier = modifier
                    .fillMaxWidth()
                    .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.md))
            ) {
                items.forEachIndexed { index, item ->
                    if (index > 0) HorizontalDivider(color = colorScheme.outlineVariant)
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = DesignTokens.Spacing.md, vertical = DesignTokens.Spacing.sm),
                        verticalArrangement = Arrangement.spacedBy(2.dp)
                    ) {
                        Text(item.stringProp("title").orEmpty(), fontSize = 14.sp, color = colorScheme.onSurface)
                        item.stringProp("subtitle")?.takeIf { it.isNotBlank() }?.let {
                            Text(it, fontSize = 12.sp, color = colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }

        "Separator" -> HorizontalDivider(modifier = modifier, color = colorScheme.outlineVariant)

        "Tabs" -> {
            val tabs = node.childrenProp("items")
            if (tabs.isNotEmpty()) {
                var selected by remember(node.statementId, tabs.size) { mutableIntStateOf(0) }
                val current = selected.coerceIn(0, tabs.lastIndex)
                Column(modifier = modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)) {
                    ScrollableTabRow(
                        selectedTabIndex = current,
                        edgePadding = 0.dp,
                        containerColor = colorScheme.surface,
                        contentColor = colorScheme.onSurface,
                        divider = { HorizontalDivider(color = colorScheme.outlineVariant) }
                    ) {
                        tabs.forEachIndexed { index, tab ->
                            Tab(
                                selected = index == current,
                                onClick = { selected = index },
                                modifier = Modifier.heightIn(min = DesignTokens.Touch.minTarget),
                                text = { Text(tab.stringProp("label").orEmpty(), fontSize = 13.sp, fontWeight = FontWeight.Medium) }
                            )
                        }
                    }
                    tabs[current].childrenProp("children").forEach { child ->
                        OpenUINodeRenderer(
                            node = child,
                            verifiedSuggestions = verifiedSuggestions,
                            highlightRhyme = highlightRhyme,
                            showProsody = showProsody,
                            keptAlternates = keptAlternates,
                            onUseSuggestion = onUseSuggestion,
                            onKeepSuggestion = onKeepSuggestion,
                            onActionChipSelected = onActionChipSelected
                        )
                    }
                }
            }
        }

        "FollowUpBlock" -> {
            val items = node.childrenProp("items").mapNotNull { it.stringProp("text")?.takeIf(String::isNotBlank) }
            if (items.isNotEmpty()) {
                val handler = LocalOpenUIActionHandler.current
                Column(
                    modifier = modifier
                        .fillMaxWidth()
                        .testTag("openUIFollowUps"),
                    verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
                ) {
                    Text("Next", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = colorScheme.onSurfaceVariant)
                    FlowRow(
                        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
                        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
                    ) {
                        items.forEach { text ->
                            OutlinedButton(
                                onClick = { handler(OpenUIAction.ToAssistant(text)) },
                                enabled = interactive,
                                modifier = Modifier.heightIn(min = DesignTokens.Touch.minTarget),
                                shape = RoundedCornerShape(DesignTokens.Radius.pill),
                                border = BorderStroke(1.dp, colorScheme.outlineVariant)
                            ) {
                                Text(text, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                            }
                        }
                    }
                }
            }
        }

        "StanzaMap" -> {
            val lines = node.stringListProp("lines")
            val letters = node.stringListProp("letters")
            val note = node.stringProp("note")
            val palette = rhymePalette(LocalAppAppearance.current.isDark)
            val letterOrder = letters.map { it.trim().uppercase() }.filter { it.isNotEmpty() }.distinct()
            Column(
                modifier = modifier
                    .fillMaxWidth()
                    .background(colorScheme.surfaceContainerLow, RoundedCornerShape(DesignTokens.Radius.md))
                    .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.md))
                    .padding(DesignTokens.Spacing.md)
                    .testTag("openUIStanzaMap"),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
            ) {
                lines.forEachIndexed { index, line ->
                    val letter = letters.getOrNull(index)?.trim()?.uppercase().orEmpty()
                    val familyIndex = letterOrder.indexOf(letter)
                    val familyColor = if (familyIndex >= 0) palette[familyIndex % palette.size] else colorScheme.onSurfaceVariant
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .semantics(mergeDescendants = true) {
                                contentDescription = if (letter.isNotEmpty()) "Rhyme $letter: $line" else line
                            },
                        horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = letter.ifEmpty { "–" },
                            fontFamily = FontFamily.Monospace,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold,
                            color = familyColor,
                            modifier = Modifier.width(20.dp)
                        )
                        Text(
                            text = line,
                            fontFamily = FontFamily.Serif,
                            fontSize = 14.sp,
                            color = colorScheme.onSurface
                        )
                    }
                }
                if (!note.isNullOrBlank()) {
                    Text(note, fontSize = 12.sp, color = colorScheme.onSurfaceVariant)
                }
            }
        }

        in NON_VISUAL_OPENUI_TYPES -> Unit

        else -> {
            val childNodes = node.props.values.flatMap { it.asElementList() }
            Column(
                modifier = modifier
                    .fillMaxWidth()
                    .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.md))
                    .padding(DesignTokens.Spacing.sm)
                    .testTag("openUIUnsupportedComponent"),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)
            ) {
                Text(
                    text = "Unsupported component: ${node.typeName}",
                    fontFamily = FontFamily.Monospace,
                    fontSize = 11.sp,
                    color = colorScheme.onSurfaceVariant
                )
                childNodes.forEach { child ->
                    OpenUINodeRenderer(
                        node = child,
                        verifiedSuggestions = verifiedSuggestions,
                        highlightRhyme = highlightRhyme,
                        showProsody = showProsody,
                        keptAlternates = keptAlternates,
                        onUseSuggestion = onUseSuggestion,
                        onKeepSuggestion = onKeepSuggestion,
                        onActionChipSelected = onActionChipSelected
                    )
                }
            }
        }
    }
}

@Composable
private fun OpenUIBadgePill(
    label: String,
    variant: String,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    val isAccent = variant in setOf("perfect", "near", "slant", "hook")
    Surface(
        modifier = modifier,
        shape = RoundedCornerShape(DesignTokens.Radius.xs),
        color = if (isAccent) colorScheme.tertiaryContainer else colorScheme.surfaceContainerHigh,
        contentColor = if (isAccent) colorScheme.onTertiaryContainer else colorScheme.onSurfaceVariant
    ) {
        Text(
            text = label,
            fontFamily = FontFamily.Monospace,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(
                horizontal = DesignTokens.Spacing.sm,
                vertical = DesignTokens.Spacing.xs
            )
        )
    }
}

private fun resolveGap(gap: String?): Dp = when (gap?.lowercase()) {
    "xs" -> DesignTokens.Spacing.xs
    "sm" -> DesignTokens.Spacing.sm
    "lg" -> DesignTokens.Spacing.lg
    else -> DesignTokens.Spacing.md
}
