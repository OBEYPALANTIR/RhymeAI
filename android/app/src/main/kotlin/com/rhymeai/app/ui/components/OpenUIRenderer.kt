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
import com.rhymeai.app.util.OpenUIValue
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.foundation.clickable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.rememberCoroutineScope
import kotlinx.coroutines.launch

typealias OpenUIToolProvider = Map<String, suspend (Map<String, Any?>) -> OpenUIValue>

class OpenUIRuntimeState(
    val parseResult: OpenUIParseResult,
    val stateValues: MutableMap<String, OpenUIValue>,
    val queryResults: MutableMap<String, OpenUIValue>,
    val toolProvider: OpenUIToolProvider,
    private val runScope: kotlinx.coroutines.CoroutineScope
) {
    fun getStateString(varName: String): String {
        val v = stateValues[varName] ?: parseResult.stateDeclarations[varName]
        return v?.asString().orEmpty()
    }

    fun setStateString(varName: String, newValue: String) {
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
                }
            }
        }
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
private val NON_VISUAL_OPENUI_TYPES = setOf("Query", "Mutation", "Action", "@Run", "@Reset", "Col", "SelectItem")

@Composable
fun OpenUIAssistantSection(
    parseResult: OpenUIParseResult,
    rawOpenUICode: String,
    providerName: String,
    isStreaming: Boolean,
    verifiedSuggestions: Map<String, SuggestedLine>,
    highlightRhyme: Boolean,
    showProsody: Boolean,
    keptAlternates: Set<String>,
    onUseSuggestion: (String) -> Unit,
    onKeepSuggestion: (String) -> Unit,
    onActionChipSelected: (String) -> Unit,
    selectedModel: AIModel? = null,
    availableModels: List<AIModel> = emptyList(),
    onSelectModel: ((AIModel) -> Unit)? = null,
    toolProvider: OpenUIToolProvider? = null,
    onGenerate: (() -> Unit)? = null,
    notice: String? = null,
    modifier: Modifier = Modifier
) {
    val colorScheme = MaterialTheme.colorScheme
    val animationsEnabled = LocalAnimationsEnabled.current
    var showInspector by remember { mutableStateOf(false) }
    var modelMenuExpanded by remember { mutableStateOf(false) }
    var steeringInput by remember { mutableStateOf("") }
    val effectiveTools = toolProvider ?: emptyMap()
    val stateValues = remember(parseResult.stateDeclarations) {
        mutableStateMapOf<String, OpenUIValue>().apply {
            putAll(parseResult.stateDeclarations)
        }
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
            runScope = scope
        )
    }

    LaunchedEffect(parseResult.queries, effectiveTools) {
        for (queryId in parseResult.queries.keys) {
            runtime.executeQuery(queryId)
        }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(colorScheme.surfaceContainer, RoundedCornerShape(DesignTokens.Radius.lg))
            .border(1.dp, colorScheme.primary.copy(alpha = 0.35f), RoundedCornerShape(DesignTokens.Radius.lg))
            .padding(DesignTokens.Spacing.md)
            .testTag("openUIAssistantSection"),
        verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.md)
    ) {
        // OpenUI Cloud Generative UI header bar with live Model Selector & Inspect toggle
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm),
                modifier = Modifier.weight(1f)
            ) {
                IconOrSpinner(isStreaming = isStreaming)
                Column {
                    Text(
                        text = "$providerName · OpenUI Generative UI",
                        fontSize = DesignTokens.Typography.caption,
                        fontWeight = FontWeight.SemiBold,
                        color = colorScheme.onSurface
                    )
                    Text(
                        text = when {
                            isStreaming -> "Streaming openui-lang (${parseResult.meta.statementCount} statements)..."
                            parseResult.root == null -> "Nothing generated yet"
                            parseResult.meta.errors.isNotEmpty() ->
                                "Generated · ${parseResult.meta.statementCount} statements · ${parseResult.meta.errors.size} issue(s), tap Inspect"
                            else -> "Generated · ${parseResult.meta.statementCount} statements"
                        },
                        fontSize = 12.sp,
                        color = colorScheme.onSurfaceVariant,
                        fontStyle = FontStyle.Italic
                    )
                }
            }

            if (rawOpenUICode.isNotBlank()) {
                TextButton(
                    onClick = { showInspector = !showInspector },
                    modifier = Modifier
                        .heightIn(min = DesignTokens.Touch.minTarget)
                        .testTag("openUIInspectButton")
                ) {
                    androidx.compose.material3.Icon(
                        Icons.Default.Code,
                        contentDescription = null,
                        modifier = Modifier.size(16.dp)
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        text = if (showInspector) "Hide Lang" else "Inspect",
                        fontSize = 12.sp
                    )
                }
            }
        }

        // Inline Model Picker row inside the OpenUI Studio so user can switch 3.8 Flash / 4 Argon / GPT-6 / Claude 5.5 anytime
        if (selectedModel != null && availableModels.isNotEmpty() && onSelectModel != null) {
            Box(modifier = Modifier.fillMaxWidth()) {
                Surface(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { modelMenuExpanded = true }
                        .testTag("openUIModelSelector"),
                    shape = RoundedCornerShape(DesignTokens.Radius.md),
                    color = colorScheme.surfaceContainerHigh,
                    border = BorderStroke(1.dp, colorScheme.outlineVariant)
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = DesignTokens.Spacing.md, vertical = DesignTokens.Spacing.sm),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = "Active Cloud Model",
                                fontSize = 11.sp,
                                color = colorScheme.onSurfaceVariant
                            )
                            Text(
                                text = "${selectedModel.displayName} (${selectedModel.id})",
                                fontSize = 13.sp,
                                fontWeight = FontWeight.Medium,
                                color = colorScheme.onSurface
                            )
                        }
                        androidx.compose.material3.Icon(
                            Icons.Default.KeyboardArrowDown,
                            contentDescription = "Change model",
                            tint = colorScheme.primary,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }

                DropdownMenu(
                    expanded = modelMenuExpanded,
                    onDismissRequest = { modelMenuExpanded = false }
                ) {
                    availableModels.forEach { model ->
                        DropdownMenuItem(
                            text = {
                                Column {
                                    Text(
                                        text = model.displayName,
                                        fontWeight = if (model == selectedModel) FontWeight.SemiBold else FontWeight.Normal,
                                        fontSize = 14.sp
                                    )
                                    Text(
                                        text = model.id,
                                        fontSize = 11.sp,
                                        color = colorScheme.onSurfaceVariant
                                    )
                                }
                            },
                            onClick = {
                                modelMenuExpanded = false
                                onSelectModel(model)
                            }
                        )
                    }
                }
            }
        }

        AnimatedVisibility(
            visible = showInspector && rawOpenUICode.isNotBlank(),
            enter = if (animationsEnabled) {
                expandVertically(
                    tween(DesignTokens.Motion.feedbackMillis, easing = DesignTokens.Motion.standardEasing),
                    expandFrom = Alignment.Top
                )
            } else {
                EnterTransition.None
            },
            exit = if (animationsEnabled) {
                shrinkVertically(
                    tween(DesignTokens.Motion.dismissMillis, easing = DesignTokens.Motion.exitEasing),
                    shrinkTowards = Alignment.Top
                )
            } else {
                ExitTransition.None
            }
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(colorScheme.surfaceContainerLow, RoundedCornerShape(DesignTokens.Radius.md))
                    .border(1.dp, colorScheme.outlineVariant, RoundedCornerShape(DesignTokens.Radius.md))
                    .padding(DesignTokens.Spacing.md)
                    .testTag("openUILangInspector")
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.xs)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = "openui-lang stream",
                            fontFamily = FontFamily.Monospace,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            color = colorScheme.onSurfaceVariant
                        )
                        if (parseResult.meta.unresolved.isNotEmpty()) {
                            Text(
                                text = "Resolving: ${parseResult.meta.unresolved.joinToString(", ")}",
                                fontFamily = FontFamily.Monospace,
                                fontSize = 11.sp,
                                color = colorScheme.onSurfaceVariant
                            )
                        }
                    }
                    parseResult.meta.errors.forEach { err ->
                        Text(
                            text = "⚠ $err",
                            fontFamily = FontFamily.Monospace,
                            fontSize = 11.sp,
                            color = colorScheme.error
                        )
                    }
                    Text(
                        text = rawOpenUICode.trim(),
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.sp,
                        lineHeight = 17.sp,
                        color = colorScheme.onSurface
                    )
                }
            }
        }

        notice?.let {
            Text(
                text = it,
                fontSize = 12.sp,
                color = colorScheme.onSurfaceVariant,
                modifier = Modifier.testTag("openUINotice")
            )
        }

        // Render the live OpenUI ElementNode tree
        val rootNode = parseResult.root
        if (rootNode == null) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("openUIEmptyState"),
                verticalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
            ) {
                Text(
                    text = if (isStreaming) "Waiting for the model to start the layout…" else "No generated UI yet",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium,
                    color = colorScheme.onSurface
                )
                if (!isStreaming) {
                    Text(
                        text = if (onGenerate != null) {
                            "The model will build the layout for your current line: rhyme groups, meter, and next steps."
                        } else {
                            "Write a line in the editor first, then generate."
                        },
                        fontSize = 12.sp,
                        color = colorScheme.onSurfaceVariant
                    )
                    if (onGenerate != null) {
                        Button(
                            onClick = onGenerate,
                            modifier = Modifier
                                .heightIn(min = DesignTokens.Touch.minTarget)
                                .testTag("openUIGenerateButton"),
                            shape = RoundedCornerShape(DesignTokens.Radius.md)
                        ) {
                            Text("Generate", fontSize = 13.sp, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            }
        } else {
            CompositionLocalProvider(LocalOpenUIRuntime provides runtime) {
                OpenUINodeRenderer(
                    node = rootNode,
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

        // Custom OpenUI Steering Composer
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DesignTokens.Spacing.sm)
        ) {
            OutlinedTextField(
                value = steeringInput,
                onValueChange = { steeringInput = it },
                placeholder = {
                    Text(
                        "Steer OpenUI (e.g., midnight highway imagery)...",
                        fontSize = 12.sp
                    )
                },
                singleLine = true,
                modifier = Modifier
                    .weight(1f)
                    .testTag("openUISteeringInput"),
                shape = RoundedCornerShape(DesignTokens.Radius.md),
                colors = OutlinedTextFieldDefaults.colors(
                    unfocusedContainerColor = colorScheme.surfaceContainerLow,
                    focusedContainerColor = colorScheme.surfaceContainerLow
                ),
                textStyle = androidx.compose.ui.text.TextStyle(fontSize = 13.sp, color = colorScheme.onSurface)
            )
            OutlinedButton(
                onClick = {
                    val directive = steeringInput.trim()
                    if (directive.isNotEmpty()) {
                        onActionChipSelected(directive)
                        steeringInput = ""
                    } else {
                        onActionChipSelected("Fresh creative angle")
                    }
                },
                enabled = !isStreaming,
                modifier = Modifier
                    .heightIn(min = DesignTokens.Touch.minTarget)
                    .testTag("openUISteerButton"),
                shape = RoundedCornerShape(DesignTokens.Radius.md)
            ) {
                Text("Steer", fontSize = 12.sp, fontWeight = FontWeight.Medium)
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
            if (variant == "secondary") {
                OutlinedButton(
                    onClick = { runtime?.executeActionNode(actionNode) },
                    modifier = modifier.heightIn(min = DesignTokens.Touch.minTarget),
                    shape = RoundedCornerShape(DesignTokens.Radius.md)
                ) {
                    Text(label, fontSize = 13.sp, fontWeight = FontWeight.Medium)
                }
            } else {
                Button(
                    onClick = { runtime?.executeActionNode(actionNode) },
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
