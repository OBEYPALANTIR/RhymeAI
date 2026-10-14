package com.rhymeai.app.util

import com.rhymeai.app.SuggestedLine

/**
 * Native Kotlin implementation of OpenUI Lang (`@openuidev/lang-core`):
 * - Component Library definition & schema-driven system prompt generation
 * - Auto-closing streaming lexer & recursive-descent expression parser
 * - Forward-reference resolution and positional-argument materialization into [OpenUIElementNode] trees
 */
data class OpenUIParamSpec(
    val name: String,
    val type: String,
    val required: Boolean = true,
    val description: String = ""
)

data class OpenUIComponentSpec(
    val name: String,
    val params: List<OpenUIParamSpec>,
    val description: String,
    val group: String
) {
    val signature: String
        get() {
            val paramList = params.joinToString(", ") { p ->
                val opt = if (p.required) "" else "?"
                "${p.name}$opt: ${p.type}"
            }
            return "$name($paramList)"
        }
}

data class OpenUIToolSpec(
    val name: String,
    val description: String,
    val inputSignature: String = "",
    val outputSignature: String = "object",
    val defaultJson: String = "{}"
)

sealed class OpenUIValue {
    data class Str(val value: String) : OpenUIValue()
    data class Num(val value: Double) : OpenUIValue()
    data class BoolVal(val value: Boolean) : OpenUIValue()
    data object NullVal : OpenUIValue()
    data class Arr(val items: List<OpenUIValue>) : OpenUIValue()
    data class Obj(val entries: Map<String, OpenUIValue>) : OpenUIValue()
    data class Element(val node: OpenUIElementNode) : OpenUIValue()
    data class StateRef(val name: String) : OpenUIValue()
    data class PropPath(val rootName: String, val path: List<String>) : OpenUIValue()
    data class UnresolvedRef(val name: String) : OpenUIValue()

    fun asString(): String? = when (this) {
        is Str -> value
        is Num -> if (value == value.toLong().toDouble()) value.toLong().toString() else value.toString()
        is BoolVal -> value.toString()
        is StateRef -> "\$$name"
        is PropPath -> (listOf(rootName) + path).joinToString(".")
        else -> null
    }

    fun asElementList(): List<OpenUIElementNode> = when (this) {
        is Arr -> items.mapNotNull { (it as? Element)?.node }
        is Element -> listOf(node)
        else -> emptyList()
    }

    fun asStringList(): List<String> = when (this) {
        is Arr -> items.mapNotNull { it.asString() }
        is Str -> listOf(value)
        else -> emptyList()
    }
}

data class OpenUIElementNode(
    val statementId: String,
    val typeName: String,
    val props: Map<String, OpenUIValue>
) {
    fun stringProp(name: String): String? = props[name]?.asString()
    fun childrenProp(name: String = "children"): List<OpenUIElementNode> =
        props[name]?.asElementList().orEmpty()
    fun stringListProp(name: String): List<String> =
        props[name]?.asStringList().orEmpty()
}

data class OpenUIParseMeta(
    val incomplete: Boolean,
    val unresolved: List<String>,
    val orphaned: List<String>,
    val statementCount: Int,
    val errors: List<String>
)

data class OpenUIParseResult(
    val root: OpenUIElementNode?,
    val meta: OpenUIParseMeta,
    val stateDeclarations: Map<String, OpenUIValue>,
    val extractedSuggestions: List<String>,
    val queries: Map<String, OpenUIElementNode> = emptyMap(),
    val mutations: Map<String, OpenUIElementNode> = emptyMap()
)

data class OpenUIAutoCloseResult(
    val text: String,
    val wasIncomplete: Boolean
)

/**
 * Events emitted by generated UI. [ToAssistant] is OpenUI's `continue_conversation`; the others
 * are this app's custom actions and are performed natively without calling the model.
 */
sealed class OpenUIAction {
    /** [context] is a JSON object string with action context and form values, or null. */
    data class ToAssistant(val message: String, val context: String? = null) : OpenUIAction()
    data class InsertLine(val text: String) : OpenUIAction()
    data class ReplaceLine(val original: String, val replacement: String) : OpenUIAction()
    data class KeepAlternate(val text: String) : OpenUIAction()
    data class SetTheme(val theme: String) : OpenUIAction()
}

/** Minimal JSON encoding for action context and form values sent back to the model. */
fun OpenUIValue.toJson(): String = when (this) {
    is OpenUIValue.Str -> jsonQuote(value)
    is OpenUIValue.Num -> asString() ?: "0"
    is OpenUIValue.BoolVal -> value.toString()
    is OpenUIValue.Arr -> items.joinToString(",", "[", "]") { it.toJson() }
    is OpenUIValue.Obj -> entries.entries.joinToString(",", "{", "}") { (k, v) -> "${jsonQuote(k)}:${v.toJson()}" }
    is OpenUIValue.StateRef -> jsonQuote("\$$name")
    is OpenUIValue.PropPath -> jsonQuote((listOf(rootName) + path).joinToString("."))
    is OpenUIValue.Element, is OpenUIValue.UnresolvedRef, OpenUIValue.NullVal -> "null"
}

internal fun jsonQuote(s: String): String = buildString {
    append('"')
    for (c in s) {
        when (c) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            else -> if (c < ' ') append("\\u%04x".format(c.code)) else append(c)
        }
    }
    append('"')
}

object OpenUILibrary {
    const val ROOT_COMPONENT = "Stack"

    val components: Map<String, OpenUIComponentSpec> = linkedMapOf(
        "Stack" to OpenUIComponentSpec(
            name = "Stack",
            params = listOf(
                OpenUIParamSpec("children", "Component[]", required = true),
                OpenUIParamSpec("direction", "\"column\" | \"row\"", required = false),
                OpenUIParamSpec("gap", "\"xs\" | \"sm\" | \"md\" | \"lg\"", required = false)
            ),
            description = "Root container and flex layout for arranging child components vertically or horizontally.",
            group = "Layout & Cards"
        ),
        "Card" to OpenUIComponentSpec(
            name = "Card",
            params = listOf(
                OpenUIParamSpec("children", "Component[]", required = true),
                OpenUIParamSpec("title", "string", required = false),
                OpenUIParamSpec("subtitle", "string", required = false)
            ),
            description = "Grouped surface card for framing songwriting insights, meter notes, or suggestion groups.",
            group = "Layout & Cards"
        ),
        "CardHeader" to OpenUIComponentSpec(
            name = "CardHeader",
            params = listOf(
                OpenUIParamSpec("title", "string", required = true),
                OpenUIParamSpec("subtitle", "string", required = false),
                OpenUIParamSpec("badge", "string", required = false)
            ),
            description = "Header block with title, optional subtitle, and optional compact status badge.",
            group = "Layout & Cards"
        ),
        "TextContent" to OpenUIComponentSpec(
            name = "TextContent",
            params = listOf(
                OpenUIParamSpec("text", "string", required = true),
                OpenUIParamSpec("tone", "\"default\" | \"muted\" | \"serif\" | \"mono\"", required = false)
            ),
            description = "Text paragraph or brief lyric craft note.",
            group = "Layout & Cards"
        ),
        "Badge" to OpenUIComponentSpec(
            name = "Badge",
            params = listOf(
                OpenUIParamSpec("label", "string", required = true),
                OpenUIParamSpec("variant", "\"neutral\" | \"perfect\" | \"near\" | \"slant\" | \"hook\"", required = false)
            ),
            description = "Compact semantic pill tag for rhyme tier, section, or syllable count.",
            group = "Layout & Cards"
        ),
        "RhymeGroup" to OpenUIComponentSpec(
            name = "RhymeGroup",
            params = listOf(
                OpenUIParamSpec("title", "string", required = true),
                OpenUIParamSpec("suggestions", "Component[]", required = true),
                OpenUIParamSpec("rhymeSound", "string", required = false),
                OpenUIParamSpec("note", "string", required = false)
            ),
            description = "Groups SuggestionLine items by creative angle, imagery direction, or rhyme family.",
            group = "Songwriting & Prosody"
        ),
        "SuggestionLine" to OpenUIComponentSpec(
            name = "SuggestionLine",
            params = listOf(
                OpenUIParamSpec("text", "string", required = true),
                OpenUIParamSpec("angle", "string", required = false),
                OpenUIParamSpec("endWord", "string", required = false)
            ),
            description = "Interactive candidate lyric line with live prosody/rhyme verification, Use line, and Keep actions.",
            group = "Songwriting & Prosody"
        ),
        "ProsodyMeter" to OpenUIComponentSpec(
            name = "ProsodyMeter",
            params = listOf(
                OpenUIParamSpec("line", "string", required = true),
                OpenUIParamSpec("stressPattern", "string", required = false),
                OpenUIParamSpec("cadenceNote", "string", required = false)
            ),
            description = "Meter and stress pattern breakdown for the target anchor line or stanza cadence.",
            group = "Songwriting & Prosody"
        ),
        "ActionChipBar" to OpenUIComponentSpec(
            name = "ActionChipBar",
            params = listOf(
                OpenUIParamSpec("promptLabel", "string", required = true),
                OpenUIParamSpec("actions", "string[]", required = true)
            ),
            description = "Interactive refinement chips that steer the next generative pass (e.g. tighter meter, darker imagery).",
            group = "Songwriting & Prosody"
        ),
        "StanzaMap" to OpenUIComponentSpec(
            name = "StanzaMap",
            params = listOf(
                OpenUIParamSpec("lines", "string[]", required = true),
                OpenUIParamSpec("letters", "string[]", required = true),
                OpenUIParamSpec("note", "string", required = false)
            ),
            description = "Shows lyric lines with their rhyme-scheme letter; lines sharing a letter are coloured as one rhyme family. lines and letters must be equal length.",
            group = "Songwriting & Prosody"
        ),
        // OpenUI chat-library content components
        "Callout" to OpenUIComponentSpec(
            name = "Callout",
            params = listOf(
                OpenUIParamSpec("variant", "\"info\" | \"success\" | \"warning\" | \"error\"", required = true),
                OpenUIParamSpec("title", "string", required = true),
                OpenUIParamSpec("description", "string", required = false)
            ),
            description = "Short highlighted note: a craft observation, a warning about meter, or a confirmation.",
            group = "Content"
        ),
        "TagBlock" to OpenUIComponentSpec(
            name = "TagBlock",
            params = listOf(OpenUIParamSpec("tags", "Tag[]", required = true)),
            description = "Row of small tags, e.g. rhyme words, themes, or labels (at most 8 tags).",
            group = "Content"
        ),
        "Tag" to OpenUIComponentSpec(
            name = "Tag",
            params = listOf(
                OpenUIParamSpec("text", "string", required = true),
                OpenUIParamSpec("variant", "\"neutral\" | \"success\" | \"warning\" | \"error\"", required = false)
            ),
            description = "A single tag inside TagBlock.",
            group = "Content"
        ),
        "ListBlock" to OpenUIComponentSpec(
            name = "ListBlock",
            params = listOf(OpenUIParamSpec("items", "ListItem[]", required = true)),
            description = "Vertical list of short items such as steps, notes, or song-structure parts.",
            group = "Content"
        ),
        "ListItem" to OpenUIComponentSpec(
            name = "ListItem",
            params = listOf(
                OpenUIParamSpec("title", "string", required = true),
                OpenUIParamSpec("subtitle", "string", required = false)
            ),
            description = "One item inside ListBlock.",
            group = "Content"
        ),
        "Separator" to OpenUIComponentSpec(
            name = "Separator",
            params = emptyList(),
            description = "Thin divider between sections of a Card.",
            group = "Content"
        ),
        "Tabs" to OpenUIComponentSpec(
            name = "Tabs",
            params = listOf(OpenUIParamSpec("items", "TabItem[]", required = true)),
            description = "Alternative views of the same answer, e.g. three directions for a chorus.",
            group = "Layout"
        ),
        "TabItem" to OpenUIComponentSpec(
            name = "TabItem",
            params = listOf(
                OpenUIParamSpec("label", "string", required = true),
                OpenUIParamSpec("children", "Component[]", required = true)
            ),
            description = "One tab inside Tabs.",
            group = "Layout"
        ),
        "FollowUpBlock" to OpenUIComponentSpec(
            name = "FollowUpBlock",
            params = listOf(OpenUIParamSpec("items", "FollowUpItem[]", required = true)),
            description = "Suggested next requests, shown at the END of the Card. Tapping one sends its text as the writer's next message.",
            group = "Follow-ups"
        ),
        "FollowUpItem" to OpenUIComponentSpec(
            name = "FollowUpItem",
            params = listOf(OpenUIParamSpec("text", "string", required = true)),
            description = "One follow-up request, written as the writer would say it.",
            group = "Follow-ups"
        ),
        // Actions (spec 1.0). Built-in: @ToAssistant, @Set, @Reset, @Run. Custom: the app's own effects.
        "@ToAssistant" to OpenUIComponentSpec(
            name = "@ToAssistant",
            params = listOf(
                OpenUIParamSpec("message", "string", required = true),
                OpenUIParamSpec("context", "object", required = false)
            ),
            description = "Sends message as the writer's next turn, with context and any form values attached.",
            group = "Actions"
        ),
        "@InsertLine" to OpenUIComponentSpec(
            name = "@InsertLine",
            params = listOf(OpenUIParamSpec("text", "string", required = true)),
            description = "Inserts text as the next lyric line at the writer's cursor.",
            group = "Actions"
        ),
        "@ReplaceLine" to OpenUIComponentSpec(
            name = "@ReplaceLine",
            params = listOf(
                OpenUIParamSpec("original", "string", required = true),
                OpenUIParamSpec("replacement", "string", required = true)
            ),
            description = "Replaces the lyric line whose text exactly equals original with replacement.",
            group = "Actions"
        ),
        "@KeepAlternate" to OpenUIComponentSpec(
            name = "@KeepAlternate",
            params = listOf(OpenUIParamSpec("text", "string", required = true)),
            description = "Saves text to the song notebook's alternates.",
            group = "Actions"
        ),
        "@SetTheme" to OpenUIComponentSpec(
            name = "@SetTheme",
            params = listOf(OpenUIParamSpec("theme", "string", required = true)),
            description = "Sets the song's theme/context.",
            group = "Actions"
        ),
        "@Set" to OpenUIComponentSpec(
            name = "@Set",
            params = listOf(
                OpenUIParamSpec("target", "any", required = true),
                OpenUIParamSpec("value", "any", required = true)
            ),
            description = "Writes a value to a \$state variable.",
            group = "Actions"
        ),
        // Generate-Once, Execute-Locally (Query / Mutation / Reactive Forms & Tables)
        "Query" to OpenUIComponentSpec(
            name = "Query",
            params = listOf(
                OpenUIParamSpec("toolName", "string", required = true),
                OpenUIParamSpec("args", "object", required = false),
                OpenUIParamSpec("defaults", "object", required = false)
            ),
            description = "Fetches data from the local toolProvider without an LLM call.",
            group = "Data & Execution"
        ),
        "Mutation" to OpenUIComponentSpec(
            name = "Mutation",
            params = listOf(
                OpenUIParamSpec("toolName", "string", required = true),
                OpenUIParamSpec("args", "object", required = false)
            ),
            description = "Declares a tool mutation executed when triggered by @Run(mutationRef).",
            group = "Data & Execution"
        ),
        "Action" to OpenUIComponentSpec(
            name = "Action",
            params = listOf(
                OpenUIParamSpec("steps", "Component[]", required = true)
            ),
            description = "Chains runtime steps such as @Run(mutation), @Run(query), and @Reset(\$var).",
            group = "Data & Execution"
        ),
        "@Run" to OpenUIComponentSpec(
            name = "@Run",
            params = listOf(
                OpenUIParamSpec("target", "Component", required = true)
            ),
            description = "Executes a Query or Mutation statement locally via toolProvider.",
            group = "Data & Execution"
        ),
        "@Reset" to OpenUIComponentSpec(
            name = "@Reset",
            params = listOf(
                OpenUIParamSpec("var1", "any", required = true),
                OpenUIParamSpec("var2", "any", required = false),
                OpenUIParamSpec("var3", "any", required = false),
                OpenUIParamSpec("var4", "any", required = false)
            ),
            description = "Resets bound \$variables back to their declared default values.",
            group = "Data & Execution"
        ),
        "Form" to OpenUIComponentSpec(
            name = "Form",
            params = listOf(
                OpenUIParamSpec("name", "string", required = true),
                OpenUIParamSpec("buttons", "Component", required = true),
                OpenUIParamSpec("fields", "Component[]", required = true)
            ),
            description = "Interactive form container binding Input/Select controls and submit Buttons to local \$variables.",
            group = "Forms & Tables"
        ),
        "Buttons" to OpenUIComponentSpec(
            name = "Buttons",
            params = listOf(
                OpenUIParamSpec("children", "Component[]", required = true)
            ),
            description = "Row of interactive Button components.",
            group = "Forms & Tables"
        ),
        "Button" to OpenUIComponentSpec(
            name = "Button",
            params = listOf(
                OpenUIParamSpec("label", "string", required = true),
                OpenUIParamSpec("action", "Component", required = false),
                OpenUIParamSpec("variant", "\"primary\" | \"secondary\"", required = false)
            ),
            description = "Button that dispatches an Action([@Run(...), @Reset(...)]) locally without calling the LLM.",
            group = "Forms & Tables"
        ),
        "FormControl" to OpenUIComponentSpec(
            name = "FormControl",
            params = listOf(
                OpenUIParamSpec("label", "string", required = true),
                OpenUIParamSpec("control", "Component", required = true)
            ),
            description = "Labeled wrapper for an Input or Select form control.",
            group = "Forms & Tables"
        ),
        "Input" to OpenUIComponentSpec(
            name = "Input",
            params = listOf(
                OpenUIParamSpec("name", "string", required = true),
                OpenUIParamSpec("placeholder", "string", required = false),
                OpenUIParamSpec("type", "string", required = false),
                OpenUIParamSpec("rules", "object", required = false),
                OpenUIParamSpec("binding", "any", required = false)
            ),
            description = "Text input bound to a reactive \$variable.",
            group = "Forms & Tables"
        ),
        "Select" to OpenUIComponentSpec(
            name = "Select",
            params = listOf(
                OpenUIParamSpec("name", "string", required = true),
                OpenUIParamSpec("items", "Component[]", required = true),
                OpenUIParamSpec("placeholder", "string", required = false),
                OpenUIParamSpec("rules", "object", required = false),
                OpenUIParamSpec("binding", "any", required = false)
            ),
            description = "Dropdown selector bound to a reactive \$variable.",
            group = "Forms & Tables"
        ),
        "SelectItem" to OpenUIComponentSpec(
            name = "SelectItem",
            params = listOf(
                OpenUIParamSpec("value", "string", required = true),
                OpenUIParamSpec("label", "string", required = true)
            ),
            description = "Option item inside a Select component.",
            group = "Forms & Tables"
        ),
        "Table" to OpenUIComponentSpec(
            name = "Table",
            params = listOf(
                OpenUIParamSpec("columns", "Component[]", required = true)
            ),
            description = "Data table displaying columns bound to Query results (e.g. tickets.rows.title).",
            group = "Forms & Tables"
        ),
        "Col" to OpenUIComponentSpec(
            name = "Col",
            params = listOf(
                OpenUIParamSpec("header", "string", required = true),
                OpenUIParamSpec("data", "any", required = true)
            ),
            description = "Table column binding a header label to a Query column path or value list.",
            group = "Forms & Tables"
        )
    )

    private const val DEFAULT_PREAMBLE =
        "You are an AI songwriting assistant that responds using openui-lang, a declarative streaming UI language. Your ENTIRE response must be valid openui-lang code — no markdown, no explanations, no code fences, just openui-lang."

    /** Components advertised by the single-shot next-line suggestion prompt. */
    val SUGGESTION_COMPONENTS: Set<String> = setOf(
        "Stack", "Card", "CardHeader", "TextContent", "Badge",
        "RhymeGroup", "SuggestionLine", "ProsodyMeter", "ActionChipBar"
    )

    /** Components advertised by the conversational agent prompt (OpenUI chat-library shape, root Card). */
    val AGENT_COMPONENTS: Set<String> = setOf(
        "Card", "CardHeader", "TextContent", "Stack", "Separator",
        "RhymeGroup", "SuggestionLine", "ProsodyMeter", "StanzaMap",
        "Callout", "TagBlock", "Tag", "ListBlock", "ListItem", "Tabs", "TabItem",
        "Table", "Col", "Form", "FormControl", "Input", "Select", "SelectItem", "Buttons", "Button",
        "FollowUpBlock", "FollowUpItem"
    )

    /** Actions the agent may use: one built-in that returns to the model, plus the app's own effects. */
    val AGENT_ACTIONS: Set<String> = setOf("@ToAssistant", "@InsertLine", "@ReplaceLine", "@KeepAlternate", "@SetTheme")

    /** Only meaningful with a toolProvider and tool specs. */
    private val TOOL_ONLY_COMPONENTS: Set<String> = setOf(
        "Query", "Mutation", "Action", "Form", "FormControl", "Input", "Select", "SelectItem",
        "Buttons", "Button", "Table", "Col"
    )

    private val SUGGESTION_EXAMPLE = """
root = Stack([meter, group1, group2, chips], "column", "md")
meter = ProsodyMeter("Yellow lights on a midnight road", "da-DUM da-DUM da-DUM da-DUM", "4-beat driving cadence ending on /oʊd/")
group1 = RhymeGroup("Concrete Imagery", [s1, s2, s3], "/oʊd/", "Grounded street-level detail")
s1 = SuggestionLine("Coffee gone cold beside the dashboard glowed", "Sensory detail", "glowed")
s2 = SuggestionLine("Rain-slicked turns where the highway slowed", "Motion", "slowed")
s3 = SuggestionLine("Carrying the weight of a quiet load", "Internal tension", "load")
group2 = RhymeGroup("Emotional Pivot", [s4, s5, s6], "/oʊd/", "Shifts focus inward")
s4 = SuggestionLine("Every mile another promise owed", "Stakes", "owed")
s5 = SuggestionLine("Tracing every crack in the life we chose", "Reflection", "chose")
s6 = SuggestionLine("Still chasing the spark before the circuit blowed", "Urgency", "blowed")
chips = ActionChipBar("Steer direction", ["Tighter meter", "More concrete imagery", "Internal rhyme", "Darker tone"])
""".trim()

    fun generateSystemPrompt(
        preamble: String = DEFAULT_PREAMBLE,
        additionalRules: List<String> = emptyList(),
        tools: List<OpenUIToolSpec> = emptyList(),
        toolCalls: Boolean = false,
        bindings: Boolean = false,
        componentNames: Set<String> = SUGGESTION_COMPONENTS,
        rootComponent: String = ROOT_COMPONENT,
        actionNames: Set<String> = emptySet(),
        example: String = SUGGESTION_EXAMPLE
    ): String {
        // Data components only work with a toolProvider; advertising them without tools
        // invites the model to invent Query("...") calls that nothing can execute.
        val toolComponentsEnabled = tools.isNotEmpty()
        val advertised = if (toolComponentsEnabled) componentNames + TOOL_ONLY_COMPONENTS else componentNames
        val grouped = components.values
            .filter { !it.name.startsWith("@") && it.name in advertised }
            .groupBy { it.group }
        val catalogLines = buildString {
            appendLine("## Component Library")
            appendLine()
            grouped.forEach { (groupName, specs) ->
                appendLine("### $groupName")
                specs.forEach { spec ->
                    appendLine("- `${spec.signature}` — ${spec.description}")
                }
                appendLine()
            }
        }.trimEnd()

        val actionsSection = if (actionNames.isNotEmpty()) {
            buildString {
                appendLine()
                appendLine()
                appendLine("## Actions")
                appendLine()
                appendLine("Pass an action as a Button's action argument. Use ONLY these:")
                components.values.filter { it.name in actionNames }.forEach { spec ->
                    appendLine("- `${spec.signature}` — ${spec.description}")
                }
            }.trimEnd()
        } else ""

        val rules = mutableListOf(
            "1. Each statement is on its own line: `identifier = Expression`",
            "2. `root` is the entry point — every program must define `root = $rootComponent(...)` first so the UI streams progressively top-down",
            "3. Expressions are: strings (\"...\"), numbers, booleans (true/false), null, arrays ([...]), objects ({...}), or component calls TypeName(arg1, arg2, ...)",
            "4. Use references for readability: define `root = $rootComponent([...])` on the first line, then define each child variable on subsequent lines",
            "5. EVERY variable (except root and \$state) MUST be referenced by at least one parent component. Unreferenced variables are dropped and will NOT render",
            "6. Arguments are POSITIONAL (order matters, not names). Write `Stack([group1, group2], \"column\", \"md\")` NOT `Stack(children: [group1], direction: \"column\")` — colon syntax inside component calls is NOT supported",
            "7. Optional arguments can be omitted from the end; use null to skip an optional argument in the middle",
            "8. Use ONLY the components listed in the Component Library below"
        )
        if (toolComponentsEnabled && bindings) {
            rules.add("Declare mutable reactive state with `\$varName = defaultValue` and bind it to `Input`, `Select`, or `Mutation` args")
        }
        if (toolComponentsEnabled && toolCalls) {
            rules.add("Use `Query(\"tool_name\", args, defaults)` for reads and `Mutation(\"tool_name\", args)` for writes, wired via `Action([@Run(mutation), @Run(query), @Reset(\$var)])`. Dotted paths like `result.rows.title` read Query results")
        }
        rules.addAll(additionalRules)
        val numberedRules = rules.mapIndexed { idx, rule ->
            if (rule.firstOrNull()?.isDigit() == true) rule else "${idx + 1}. $rule"
        } + "- Strings use double quotes with backslash escaping"

        val toolsSection = if (tools.isNotEmpty()) {
            buildString {
                appendLine()
                appendLine("## Available Tools")
                appendLine()
                appendLine("Use these with Query() for read operations or Mutation() for write operations:")
                appendLine()
                tools.forEach { t ->
                    appendLine("- ${t.name}(${t.inputSignature}) -> ${t.outputSignature}")
                    appendLine("  ${t.description}")
                }
                appendLine()
                appendLine("### Default values for Query results")
                tools.forEach { t ->
                    appendLine("- ${t.name}: `${t.defaultJson}`")
                }
            }
        } else ""

        return """
$preamble

## Syntax Rules

${numberedRules.joinToString("\n")}

$catalogLines$actionsSection$toolsSection

## Example (one possible layout — adapt the structure to each request)

$example
""".trimIndent()
    }

    private const val AGENT_PREAMBLE =
        "You are the songwriting assistant inside Writers Block, a lyric-writing app. You reply to the writer with generated interfaces written in openui-lang, a declarative streaming UI language. Your ENTIRE reply must be valid openui-lang — no markdown, no prose outside statements, no code fences."

    private val AGENT_RULES = listOf(
        "Every reply is exactly ONE program whose root is a Card. Its first child is a CardHeader that names what you are answering.",
        "Choose components that fit the request: RhymeGroup with SuggestionLine for candidate lyric lines, StanzaMap for rhyme schemes, ProsodyMeter for meter and stress, Table for comparisons, ListBlock for steps or structure, Callout for one important observation, Tabs for alternative directions. Keep prose short: TextContent of one or two sentences.",
        "Offer candidate lyric lines ONLY as SuggestionLine inside a RhymeGroup. The app adds Use and Keep buttons to every SuggestionLine, so never add your own buttons to insert or keep those lines.",
        "End every Card with a FollowUpBlock of 2 to 4 FollowUpItem, phrased as the writer would ask, specific to this song.",
        "Only add a Button for an action listed under Actions. A Button with @ReplaceLine must copy `original` character for character from the lyrics. Never add buttons for things the app cannot do (export, play audio, open links, share).",
        "If the request is ambiguous or you need details to do it well, ask with a Form instead of guessing: Form(\"details\", Buttons([Button(\"Continue\", @ToAssistant(\"Here are the details\"), \"primary\")]), [field1, field2]) with each field defined as its own FormControl reference. The writer's answers are attached to that message automatically.",
        "Follow the rhyme settings and complexity in Song Context unless the writer asks for something different.",
        "Never mention colours; refer to rhyme families by their letters."
    )

    private val AGENT_EXAMPLE = """
root = Card([header, intro, group1, follow])
header = CardHeader("Next line for Verse 2", "Rhymes with \"road\" · AABB")
intro = TextContent("Two directions: one concrete, one turning inward.", "muted")
group1 = RhymeGroup("Concrete images", [s1, s2, s3], "/oʊd/")
s1 = SuggestionLine("Headlights spill across the empty road", "Image", "road")
s2 = SuggestionLine("Every mile marker feels like something owed", "Stakes", "owed")
s3 = SuggestionLine("Static on the radio, the signal slowed", "Sound", "slowed")
follow = FollowUpBlock([f1, f2, f3])
f1 = FollowUpItem("Make these darker")
f2 = FollowUpItem("Check the meter of this verse")
f3 = FollowUpItem("Turn this into a chorus hook")
""".trim()

    /** Live song state sent with every agent turn, so replies match the writer's current position. */
    data class AgentSongContext(
        val title: String,
        val theme: String,
        val lyrics: String,
        val wholeSong: Boolean,
        val targetLine: String?,
        val currentLetter: String,
        val rhymeScheme: String,
        val sectionName: String,
        val rhymeTypeLabel: String,
        val complexityLabel: String,
        val complexityHint: String
    )

    fun generateAgentSystemPrompt(song: AgentSongContext): String {
        val base = generateSystemPrompt(
            preamble = AGENT_PREAMBLE,
            additionalRules = AGENT_RULES,
            componentNames = AGENT_COMPONENTS,
            rootComponent = "Card",
            actionNames = AGENT_ACTIONS,
            example = AGENT_EXAMPLE
        )
        val lyricsLabel = if (song.wholeSong) "Full lyrics" else "Lyrics excerpt (writer shares only the current line)"
        val target = song.targetLine?.let { "\"$it\" (the next line should rhyme with it)" }
            ?: "none — the next line opens a new rhyme sound"
        return """
$base

## Song Context

Title: ${song.title.ifBlank { "Untitled" }}
Theme: ${song.theme.ifBlank { "not set" }}
Current section: ${song.sectionName}
Rhyme scheme: ${song.rhymeScheme} (next line is letter ${song.currentLetter})
Rhyme anchor: $target
Rhyme type: ${song.rhymeTypeLabel}
Complexity: ${song.complexityLabel}. ${song.complexityHint}
$lyricsLabel:
${"\"\"\""}
${song.lyrics.ifBlank { "(no lyrics yet)" }}
${"\"\"\""}
""".trimIndent()
    }

    /**
     * Synthesizes a valid OpenUI tree from verified [SuggestedLine] items when needed
     * (e.g., when wrapping plain-line streams or building a structured view from verified lines).
     */
    fun synthesizeTree(
        suggestions: List<SuggestedLine>,
        targetLine: String?,
        rhymeTypeLabel: String,
        schemeLabel: String,
        sectionLabel: String
    ): OpenUIElementNode {
        val children = mutableListOf<OpenUIValue>()

        if (!targetLine.isNullOrBlank()) {
            val prosody = ProsodyAnalyzer.analyzeLine(targetLine)
            val stressStr = if (prosody.feet.isNotEmpty()) prosody.feet else "${prosody.syllableCount} syllables"
            val ipaNote = if (prosody.ipa.isNotEmpty()) "/${prosody.ipa}/ · $schemeLabel · $sectionLabel" else "$schemeLabel · $sectionLabel"
            children += OpenUIValue.Element(
                OpenUIElementNode(
                    statementId = "meter",
                    typeName = "ProsodyMeter",
                    props = mapOf(
                        "line" to OpenUIValue.Str(targetLine),
                        "stressPattern" to OpenUIValue.Str(stressStr),
                        "cadenceNote" to OpenUIValue.Str(ipaNote)
                    )
                )
            )
        }

        val primary = suggestions.take(3)
        val secondary = suggestions.drop(3)

        if (primary.isNotEmpty()) {
            children += OpenUIValue.Element(
                buildSynthesizedGroup(
                    id = "group1",
                    title = "$rhymeTypeLabel Matches",
                    note = "Primary $sectionLabel directions",
                    lines = primary,
                    startIndex = 1
                )
            )
        }
        if (secondary.isNotEmpty()) {
            children += OpenUIValue.Element(
                buildSynthesizedGroup(
                    id = "group2",
                    title = "Alternate Angles",
                    note = "Contrasting imagery & cadence",
                    lines = secondary,
                    startIndex = primary.size + 1
                )
            )
        }

        children += OpenUIValue.Element(
            OpenUIElementNode(
                statementId = "chips",
                typeName = "ActionChipBar",
                props = mapOf(
                    "promptLabel" to OpenUIValue.Str("Refine with OpenUI"),
                    "actions" to OpenUIValue.Arr(
                        listOf(
                            OpenUIValue.Str("Tighter meter"),
                            OpenUIValue.Str("More concrete imagery"),
                            OpenUIValue.Str("Internal rhyme"),
                            OpenUIValue.Str("Fresh angle")
                        )
                    )
                )
            )
        )

        return OpenUIElementNode(
            statementId = "root",
            typeName = ROOT_COMPONENT,
            props = mapOf(
                "children" to OpenUIValue.Arr(children),
                "direction" to OpenUIValue.Str("column"),
                "gap" to OpenUIValue.Str("md")
            )
        )
    }

    private fun buildSynthesizedGroup(
        id: String,
        title: String,
        note: String,
        lines: List<SuggestedLine>,
        startIndex: Int
    ): OpenUIElementNode {
        val items = lines.mapIndexed { idx, line ->
            val endWord = RhymeConstraint.lineEndWord(line.text)
            val tierAngle = when {
                line.isHook -> "Chorus hook"
                line.rhymeTier == 2 -> "Perfect match"
                line.rhymeTier == 1 -> "Near vowel"
                line.rhymeTier == 3 -> "Slant cadence"
                else -> "Lyric option"
            }
            OpenUIValue.Element(
                OpenUIElementNode(
                    statementId = "s${startIndex + idx}",
                    typeName = "SuggestionLine",
                    props = mapOf(
                        "text" to OpenUIValue.Str(line.text),
                        "angle" to OpenUIValue.Str(tierAngle),
                        "endWord" to OpenUIValue.Str(endWord)
                    )
                )
            )
        }
        return OpenUIElementNode(
            statementId = id,
            typeName = "RhymeGroup",
            props = mapOf(
                "title" to OpenUIValue.Str(title),
                "suggestions" to OpenUIValue.Arr(items),
                "note" to OpenUIValue.Str(note)
            )
        )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Streaming Parser & Auto-Closer
// ─────────────────────────────────────────────────────────────────────────────

class OpenUIStreamingParser(
    private val rootComponentName: String = OpenUILibrary.ROOT_COMPONENT
) {
    private var lastRawText: String = ""

    fun set(streamedText: String, isComplete: Boolean = false): OpenUIParseResult {
        lastRawText = streamedText
        return OpenUIParser.parse(
            input = streamedText,
            rootComponentName = rootComponentName,
            forceComplete = isComplete
        )
    }

    fun reset() {
        lastRawText = ""
    }
}

object OpenUIParser {

    /**
     * Auto-closes unclosed strings and brackets/parentheses/braces so partial
     * streaming chunks can be parsed into a live component tree at any byte offset.
     */
    fun autoClose(input: String): OpenUIAutoCloseResult {
        val stack = ArrayDeque<Char>()
        var inStr: Char? = null
        var esc = false

        for (i in input.indices) {
            val c = input[i]
            if (esc) {
                esc = false
                continue
            }
            if (c == '\\' && inStr != null) {
                esc = true
                continue
            }
            if (inStr != null) {
                if (c == inStr) inStr = null
                continue
            }
            if (c == '"' || c == '\'') {
                inStr = c
                continue
            }
            when (c) {
                '(', '[', '{' -> stack.addLast(c)
                ')' -> if (stack.lastOrNull() == '(') stack.removeLast()
                ']' -> if (stack.lastOrNull() == '[') stack.removeLast()
                '}' -> if (stack.lastOrNull() == '{') stack.removeLast()
            }
        }

        val wasIncomplete = inStr != null || stack.isNotEmpty()
        if (!wasIncomplete) {
            return OpenUIAutoCloseResult(input, false)
        }

        val sb = StringBuilder(input)
        if (inStr != null) {
            if (esc) sb.append('\\')
            sb.append(inStr)
        }

        // Trim trailing comma or colon before closing open brackets
        while (sb.isNotEmpty() && (sb.last() == ',' || sb.last() == ':' || sb.last() == ' ' || sb.last() == '\t')) {
            val ch = sb.last()
            if (ch == ',' || ch == ':') {
                sb.deleteCharAt(sb.length - 1)
                break
            }
            sb.deleteCharAt(sb.length - 1)
        }

        while (stack.isNotEmpty()) {
            val open = stack.removeLast()
            val close = when (open) {
                '(' -> ')'
                '[' -> ']'
                '{' -> '}'
                else -> ')'
            }
            sb.append(close)
        }

        return OpenUIAutoCloseResult(sb.toString(), true)
    }

    internal sealed class ASTExpr {
        data class StrLit(val value: String) : ASTExpr()
        data class NumLit(val value: Double) : ASTExpr()
        data class BoolLit(val value: Boolean) : ASTExpr()
        data object NullLit : ASTExpr()
        data class Ref(val name: String) : ASTExpr()
        data class PropAccess(val rootName: String, val path: List<String>) : ASTExpr()
        data class StateVar(val name: String) : ASTExpr()
        data class ArrayLit(val items: List<ASTExpr>) : ASTExpr()
        data class ObjectLit(val entries: Map<String, ASTExpr>) : ASTExpr()
        data class CompCall(val name: String, val args: List<ASTExpr>) : ASTExpr()
    }

    internal data class ParsedStatement(
        val id: String,
        val rawLhs: String,
        val rawLine: String,
        val isState: Boolean,
        val expr: ASTExpr
    )

    /**
     * Merges an incremental OpenUI Lang patch into an existing OpenUI Lang program.
     * Existing queries, state declarations (`$var`), and component definitions stay intact,
     * updated statements replace previous definitions in-place, `id = null` deletes a statement,
     * and unreachable statements are garbage-collected.
     */
    fun mergeStatements(
        existing: String,
        patch: String,
        rootId: String = "root"
    ): String {
        val existingStmts = parseRawStatementList(stripMarkdownFences(existing))
        val patchStmts = parseRawStatementList(stripMarkdownFences(patch))
        if (existingStmts.isEmpty()) return patchStmts.joinToString("\n") { it.rawLine }
        if (patchStmts.isEmpty()) return existing.trim()

        val merged = LinkedHashMap<String, ParsedStatement>()
        for (stmt in existingStmts) {
            merged[stmt.rawLhs] = stmt
        }
        for (stmt in patchStmts) {
            if (stmt.expr is ASTExpr.NullLit) {
                merged.remove(stmt.rawLhs)
            } else {
                merged[stmt.rawLhs] = stmt
            }
        }

        // Determine reachable statements starting from rootId (plus all $state declarations)
        val reachable = mutableSetOf<String>()
        fun markReachable(lhsKey: String) {
            if (!reachable.add(lhsKey)) return
            val stmt = merged[lhsKey] ?: merged[lhsKey.removePrefix("$")] ?: return
            fun walk(e: ASTExpr) {
                when (e) {
                    is ASTExpr.Ref -> {
                        if (e.name in merged) markReachable(e.name)
                    }
                    is ASTExpr.PropAccess -> {
                        if (e.rootName in merged) markReachable(e.rootName)
                    }
                    is ASTExpr.StateVar -> {
                        val stateKey = "\$${e.name}"
                        if (stateKey in merged) markReachable(stateKey)
                    }
                    is ASTExpr.ArrayLit -> e.items.forEach(::walk)
                    is ASTExpr.ObjectLit -> e.entries.values.forEach(::walk)
                    is ASTExpr.CompCall -> e.args.forEach(::walk)
                    else -> {}
                }
            }
            walk(stmt.expr)
        }

        if (rootId in merged) {
            markReachable(rootId)
            // Keep any $state declaration that was already present in existing or patch
            for (key in merged.keys) {
                if (key.startsWith("$")) {
                    markReachable(key)
                }
            }
            return merged.values
                .filter { it.rawLhs in reachable }
                .joinToString("\n") { it.rawLine }
        }

        return merged.values.joinToString("\n") { it.rawLine }
    }

    private fun parseRawStatementList(cleaned: String): List<ParsedStatement> {
        if (cleaned.isBlank()) return emptyList()
        val rawStatements = splitLogicalStatements(cleaned)
        val list = mutableListOf<ParsedStatement>()
        for (rawLine in rawStatements) {
            val trimmed = rawLine.trim()
            if (trimmed.isEmpty() || trimmed.startsWith("//") || trimmed.startsWith("#")) continue
            val eqIdx = findAssignmentEquals(trimmed)
            if (eqIdx <= 0) continue
            val lhs = trimmed.substring(0, eqIdx).trim()
            val rhsRaw = trimmed.substring(eqIdx + 1).trim()
            if (!isValidIdentifier(lhs) || rhsRaw.isEmpty()) continue
            val autoClosed = autoClose(rhsRaw)
            val isState = lhs.startsWith("$")
            val id = if (isState) lhs.drop(1) else lhs
            val expr = runCatching { ExprTokenParser(autoClosed.text).parseExpr() }.getOrNull()
            if (expr != null) {
                list += ParsedStatement(
                    id = id,
                    rawLhs = lhs,
                    rawLine = "$lhs = ${autoClosed.text}",
                    isState = isState,
                    expr = expr
                )
            }
        }
        return list
    }

    fun parse(
        input: String,
        rootComponentName: String = OpenUILibrary.ROOT_COMPONENT,
        forceComplete: Boolean = false
    ): OpenUIParseResult {
        val cleaned = stripMarkdownFences(input)
        if (cleaned.isBlank()) {
            return OpenUIParseResult(
                root = null,
                meta = OpenUIParseMeta(
                    incomplete = !forceComplete,
                    unresolved = emptyList(),
                    orphaned = emptyList(),
                    statementCount = 0,
                    errors = emptyList()
                ),
                stateDeclarations = emptyMap(),
                extractedSuggestions = emptyList()
            )
        }

        val rawStatements = splitLogicalStatements(cleaned)
        val stmtMap = LinkedHashMap<String, ParsedStatement>()
        val errors = mutableListOf<String>()
        var anyIncomplete = false

        for (rawLine in rawStatements) {
            val trimmed = rawLine.trim()
            if (trimmed.isEmpty() || trimmed.startsWith("//") || trimmed.startsWith("#")) continue
            val eqIdx = findAssignmentEquals(trimmed)
            if (eqIdx <= 0) {
                continue
            }
            val lhs = trimmed.substring(0, eqIdx).trim()
            val rhsRaw = trimmed.substring(eqIdx + 1).trim()
            if (!isValidIdentifier(lhs)) continue
            if (rhsRaw.isEmpty()) {
                anyIncomplete = true
                continue
            }

            val autoClosed = autoClose(rhsRaw)
            if (autoClosed.wasIncomplete) {
                anyIncomplete = true
            }

            val isState = lhs.startsWith("$")
            val id = if (isState) lhs.drop(1) else lhs
            try {
                val parser = ExprTokenParser(autoClosed.text)
                val expr = parser.parseExpr()
                if (expr != null) {
                    stmtMap[lhs] = ParsedStatement(
                        id = id,
                        rawLhs = lhs,
                        rawLine = "$lhs = ${autoClosed.text}",
                        isState = isState,
                        expr = expr
                    )
                }
            } catch (e: Exception) {
                errors += "Parse error in `$lhs`: ${e.message}"
            }
        }

        val stateDecls = LinkedHashMap<String, OpenUIValue>()
        val valueStmts = LinkedHashMap<String, ASTExpr>()
        for ((_, stmt) in stmtMap) {
            if (stmt.isState) {
                stateDecls[stmt.id] = materialize(
                    expr = stmt.expr,
                    syms = emptyMap(),
                    stateDecls = stateDecls,
                    visited = mutableSetOf(),
                    unresolved = mutableListOf(),
                    unreached = mutableSetOf(),
                    errors = errors,
                    preserveStateRefs = false
                )
            } else {
                valueStmts[stmt.id] = stmt.expr
            }
        }

        // Determine entry statement (`root` or first statement calling rootComponentName)
        val entryId = when {
            "root" in valueStmts -> "root"
            else -> valueStmts.entries.firstOrNull { (_, expr) ->
                expr is ASTExpr.CompCall && expr.name == rootComponentName
            }?.key ?: valueStmts.keys.firstOrNull()
        }

        val unresolved = mutableListOf<String>()
        val unreached = valueStmts.keys.toMutableSet()
        val rootNode: OpenUIElementNode? = if (entryId != null) {
            unreached.remove(entryId)
            val rootVal = materialize(
                expr = valueStmts.getValue(entryId),
                syms = valueStmts,
                stateDecls = stateDecls,
                visited = mutableSetOf(entryId),
                unresolved = unresolved,
                unreached = unreached,
                errors = errors,
                statementId = entryId,
                preserveStateRefs = true
            )
            (rootVal as? OpenUIValue.Element)?.node
        } else {
            null
        }

        // Extract Query() and Mutation() nodes so the runtime can execute them via toolProvider
        val queries = LinkedHashMap<String, OpenUIElementNode>()
        val mutations = LinkedHashMap<String, OpenUIElementNode>()
        for ((id, expr) in valueStmts) {
            if (expr is ASTExpr.CompCall && (expr.name == "Query" || expr.name == "Mutation")) {
                unreached.remove(id)
                val materialized = materialize(
                    expr = expr,
                    syms = valueStmts,
                    stateDecls = stateDecls,
                    visited = mutableSetOf(id),
                    unresolved = unresolved,
                    unreached = unreached,
                    errors = errors,
                    statementId = id,
                    preserveStateRefs = true
                )
                val elem = (materialized as? OpenUIValue.Element)?.node
                if (elem != null) {
                    if (expr.name == "Query") {
                        queries[id] = elem
                    } else {
                        mutations[id] = elem
                    }
                }
            }
        }

        // Extract SuggestionLine texts in declaration order (even if parent hasn't closed yet)
        val extractedSuggestions = extractSuggestionLines(valueStmts, stateDecls)

        return OpenUIParseResult(
            root = rootNode,
            meta = OpenUIParseMeta(
                incomplete = if (forceComplete) false else anyIncomplete,
                unresolved = unresolved.distinct(),
                orphaned = unreached.toList(),
                statementCount = stmtMap.size,
                errors = errors
            ),
            stateDeclarations = stateDecls,
            extractedSuggestions = extractedSuggestions,
            queries = queries,
            mutations = mutations
        )
    }

    private fun extractSuggestionLines(
        valueStmts: Map<String, ASTExpr>,
        stateDecls: Map<String, OpenUIValue>
    ): List<String> {
        val results = mutableListOf<String>()
        val seen = mutableSetOf<String>()

        fun visitExpr(expr: ASTExpr) {
            when (expr) {
                is ASTExpr.CompCall -> {
                    if (expr.name == "SuggestionLine" && expr.args.isNotEmpty()) {
                        val firstArg = expr.args[0]
                        val text = when (firstArg) {
                            is ASTExpr.StrLit -> firstArg.value.trim()
                            is ASTExpr.Ref -> (valueStmts[firstArg.name] as? ASTExpr.StrLit)?.value?.trim()
                            is ASTExpr.StateVar -> stateDecls[firstArg.name]?.asString()?.trim()
                            else -> null
                        }
                        if (!text.isNullOrEmpty() && seen.add(text.lowercase())) {
                            results += text
                        }
                    }
                    expr.args.forEach(::visitExpr)
                }
                is ASTExpr.ArrayLit -> expr.items.forEach(::visitExpr)
                is ASTExpr.ObjectLit -> expr.entries.values.forEach(::visitExpr)
                else -> {}
            }
        }

        valueStmts.values.forEach(::visitExpr)
        return results
    }

    private fun materialize(
        expr: ASTExpr,
        syms: Map<String, ASTExpr>,
        stateDecls: Map<String, OpenUIValue>,
        visited: MutableSet<String>,
        unresolved: MutableList<String>,
        unreached: MutableSet<String>,
        errors: MutableList<String>,
        statementId: String = "",
        preserveStateRefs: Boolean = false
    ): OpenUIValue {
        return when (expr) {
            is ASTExpr.StrLit -> OpenUIValue.Str(expr.value)
            is ASTExpr.NumLit -> OpenUIValue.Num(expr.value)
            is ASTExpr.BoolLit -> OpenUIValue.BoolVal(expr.value)
            is ASTExpr.NullLit -> OpenUIValue.NullVal
            is ASTExpr.StateVar -> {
                if (preserveStateRefs) {
                    OpenUIValue.StateRef(expr.name)
                } else {
                    stateDecls[expr.name] ?: OpenUIValue.StateRef(expr.name)
                }
            }
            is ASTExpr.PropAccess -> {
                unreached.remove(expr.rootName)
                if (expr.rootName !in syms && expr.rootName !in stateDecls) {
                    unresolved += expr.rootName
                }
                OpenUIValue.PropPath(expr.rootName, expr.path)
            }
            is ASTExpr.Ref -> {
                if (expr.name in visited) {
                    unresolved += expr.name
                    errors += "Circular reference to `${expr.name}`"
                    OpenUIValue.UnresolvedRef(expr.name)
                } else {
                    val target = syms[expr.name]
                    if (target == null) {
                        unresolved += expr.name
                        OpenUIValue.UnresolvedRef(expr.name)
                    } else {
                        unreached.remove(expr.name)
                        visited.add(expr.name)
                        try {
                            materialize(
                                expr = target,
                                syms = syms,
                                stateDecls = stateDecls,
                                visited = visited,
                                unresolved = unresolved,
                                unreached = unreached,
                                errors = errors,
                                statementId = expr.name,
                                preserveStateRefs = preserveStateRefs
                            )
                        } finally {
                            visited.remove(expr.name)
                        }
                    }
                }
            }
            is ASTExpr.ArrayLit -> {
                val materializedItems = expr.items.mapNotNull { item ->
                    val v = materialize(
                        item,
                        syms,
                        stateDecls,
                        visited,
                        unresolved,
                        unreached,
                        errors,
                        preserveStateRefs = preserveStateRefs
                    )
                    if (v is OpenUIValue.UnresolvedRef) null else v
                }
                OpenUIValue.Arr(materializedItems)
            }
            is ASTExpr.ObjectLit -> {
                val map = LinkedHashMap<String, OpenUIValue>()
                for ((k, v) in expr.entries) {
                    map[k] = materialize(
                        v,
                        syms,
                        stateDecls,
                        visited,
                        unresolved,
                        unreached,
                        errors,
                        preserveStateRefs = preserveStateRefs
                    )
                }
                OpenUIValue.Obj(map)
            }
            is ASTExpr.CompCall -> {
                val spec = OpenUILibrary.components[expr.name]
                val props = LinkedHashMap<String, OpenUIValue>()
                if (spec != null) {
                    for (i in expr.args.indices) {
                        val paramName = spec.params.getOrNull(i)?.name ?: "arg$i"
                        props[paramName] = materialize(
                            expr = expr.args[i],
                            syms = syms,
                            stateDecls = stateDecls,
                            visited = visited,
                            unresolved = unresolved,
                            unreached = unreached,
                            errors = errors,
                            preserveStateRefs = preserveStateRefs
                        )
                    }
                } else {
                    errors += "Unknown component `${expr.name}`"
                    for (i in expr.args.indices) {
                        props["arg$i"] = materialize(
                            expr = expr.args[i],
                            syms = syms,
                            stateDecls = stateDecls,
                            visited = visited,
                            unresolved = unresolved,
                            unreached = unreached,
                            errors = errors,
                            preserveStateRefs = preserveStateRefs
                        )
                    }
                }
                OpenUIValue.Element(
                    OpenUIElementNode(
                        statementId = statementId.ifEmpty { expr.name.lowercase() },
                        typeName = expr.name,
                        props = props
                    )
                )
            }
        }
    }

    private fun stripMarkdownFences(raw: String): String {
        val lines = raw.lines()
        return lines.filterNot { line ->
            val t = line.trim()
            t.startsWith("```")
        }.joinToString("\n")
    }

    /**
     * Splits input into logical statements. If a line has unclosed parens/brackets
     * and the next line is NOT a new `identifier = ...` assignment, merges them.
     */
    private fun splitLogicalStatements(input: String): List<String> {
        val result = mutableListOf<String>()
        val current = StringBuilder()

        for (rawLine in input.lines()) {
            val trimmed = rawLine.trim()
            if (trimmed.isEmpty()) continue
            val eqIdx = findAssignmentEquals(trimmed)
            val startsNewAssignment = eqIdx > 0 &&
                isValidIdentifier(trimmed.substring(0, eqIdx).trim())

            if (startsNewAssignment && current.isNotEmpty()) {
                result += current.toString()
                current.setLength(0)
            }
            if (current.isNotEmpty()) {
                current.append(' ')
            }
            current.append(trimmed)
        }
        if (current.isNotEmpty()) {
            result += current.toString()
        }
        return result
    }

    private fun findAssignmentEquals(line: String): Int {
        var inStr: Char? = null
        var esc = false
        var depth = 0
        for (i in line.indices) {
            val c = line[i]
            if (esc) {
                esc = false
                continue
            }
            if (c == '\\' && inStr != null) {
                esc = true
                continue
            }
            if (inStr != null) {
                if (c == inStr) inStr = null
                continue
            }
            if (c == '"' || c == '\'') {
                inStr = c
                continue
            }
            when (c) {
                '(', '[', '{' -> depth++
                ')', ']', '}' -> if (depth > 0) depth--
                '=' -> if (depth == 0) {
                    val prev = line.getOrNull(i - 1)
                    val next = line.getOrNull(i + 1)
                    if (prev != '=' && prev != '!' && prev != '<' && prev != '>' && next != '=') {
                        return i
                    }
                }
            }
        }
        return -1
    }

    private fun isValidIdentifier(s: String): Boolean {
        if (s.isEmpty()) return false
        val body = if (s.startsWith("$")) s.drop(1) else s
        if (body.isEmpty()) return false
        if (!body[0].isLetter() && body[0] != '_') return false
        return body.all { it.isLetterOrDigit() || it == '_' }
    }

    private class ExprTokenParser(private val text: String) {
        private var pos = 0

        fun parseExpr(): ASTExpr? {
            skipWhitespace()
            if (pos >= text.length) return null
            return when (val c = text[pos]) {
                '"', '\'' -> parseString(c)
                '[' -> parseArray()
                '{' -> parseObject()
                '$' -> parseStateVar()
                '-', in '0'..'9' -> parseNumber()
                '@' -> parseIdentifierOrCall()
                else -> if (c.isLetter() || c == '_') parseIdentifierOrCall() else null
            }
        }

        private fun skipWhitespace() {
            while (pos < text.length && (text[pos].isWhitespace() || text[pos] == ',')) {
                pos++
            }
        }

        private fun skipSpacesOnly() {
            while (pos < text.length && text[pos].isWhitespace()) {
                pos++
            }
        }

        private fun parseString(quote: Char): ASTExpr.StrLit {
            pos++ // skip opening quote
            val sb = StringBuilder()
            var esc = false
            while (pos < text.length) {
                val c = text[pos++]
                if (esc) {
                    when (c) {
                        'n' -> sb.append('\n')
                        't' -> sb.append('\t')
                        'r' -> sb.append('\r')
                        '"' -> sb.append('"')
                        '\'' -> sb.append('\'')
                        '\\' -> sb.append('\\')
                        else -> sb.append(c)
                    }
                    esc = false
                } else if (c == '\\') {
                    esc = true
                } else if (c == quote) {
                    break
                } else {
                    sb.append(c)
                }
            }
            return ASTExpr.StrLit(sb.toString())
        }

        private fun parseArray(): ASTExpr.ArrayLit {
            pos++ // skip '['
            val items = mutableListOf<ASTExpr>()
            while (pos < text.length) {
                skipWhitespace()
                if (pos >= text.length || text[pos] == ']') {
                    if (pos < text.length) pos++
                    break
                }
                val startPos = pos
                val item = parseExpr()
                if (item != null) {
                    items += item
                } else if (pos == startPos) {
                    pos++
                }
            }
            return ASTExpr.ArrayLit(items)
        }

        private fun parseObject(): ASTExpr.ObjectLit {
            pos++ // skip '{'
            val entries = LinkedHashMap<String, ASTExpr>()
            while (pos < text.length) {
                skipWhitespace()
                if (pos >= text.length || text[pos] == '}') {
                    if (pos < text.length) pos++
                    break
                }
                val startPos = pos
                val key = if (text[pos] == '"' || text[pos] == '\'') {
                    parseString(text[pos]).value
                } else {
                    readIdentifier()
                }
                skipSpacesOnly()
                if (pos < text.length && text[pos] == ':') {
                    pos++
                }
                val value = parseExpr()
                if (key.isNotEmpty() && value != null) {
                    entries[key] = value
                } else if (pos == startPos) {
                    pos++
                }
            }
            return ASTExpr.ObjectLit(entries)
        }

        private fun parseStateVar(): ASTExpr.StateVar {
            pos++ // skip '$'
            val name = readIdentifier()
            return ASTExpr.StateVar(name)
        }

        private fun parseNumber(): ASTExpr {
            val start = pos
            if (text[pos] == '-') pos++
            while (pos < text.length && (text[pos].isDigit() || text[pos] == '.')) {
                pos++
            }
            val raw = text.substring(start, pos)
            val num = raw.toDoubleOrNull() ?: 0.0
            return ASTExpr.NumLit(num)
        }

        private fun parseIdentifierOrCall(): ASTExpr {
            val ident = readIdentifier()
            skipSpacesOnly()
            if (pos < text.length && text[pos] == '(') {
                pos++ // skip '('
                val args = mutableListOf<ASTExpr>()
                while (pos < text.length) {
                    skipWhitespace()
                    if (pos >= text.length || text[pos] == ')') {
                        if (pos < text.length) pos++
                        break
                    }
                    val startPos = pos
                    val arg = parseExpr()
                    // Support tolerant parsing if a model accidentally writes `param: value`
                    skipSpacesOnly()
                    if (arg is ASTExpr.Ref && pos < text.length && text[pos] == ':') {
                        pos++ // skip ':'
                        val actualVal = parseExpr()
                        if (actualVal != null) {
                            args += actualVal
                        }
                    } else if (arg != null) {
                        args += arg
                    } else if (pos == startPos) {
                        pos++
                    }
                }
                return ASTExpr.CompCall(ident, args)
            }
            // Check for dotted property access: `tickets.rows.title`
            if (pos < text.length && text[pos] == '.') {
                val path = mutableListOf<String>()
                while (pos < text.length && text[pos] == '.') {
                    pos++ // skip '.'
                    val segment = readIdentifier()
                    if (segment.isNotEmpty()) {
                        path += segment
                    } else {
                        break
                    }
                }
                if (path.isNotEmpty()) {
                    return ASTExpr.PropAccess(ident, path)
                }
            }
            return when (ident) {
                "true" -> ASTExpr.BoolLit(true)
                "false" -> ASTExpr.BoolLit(false)
                "null" -> ASTExpr.NullLit
                else -> ASTExpr.Ref(ident)
            }
        }

        private fun readIdentifier(): String {
            val start = pos
            if (pos < text.length && text[pos] == '@') {
                pos++
            }
            while (pos < text.length && (text[pos].isLetterOrDigit() || text[pos] == '_')) {
                pos++
            }
            return text.substring(start, pos)
        }
    }
}
