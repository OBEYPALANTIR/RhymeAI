import Foundation

// MARK: - OpenUI Lang Component Library

/// Defines a single component in the RhymeAI OpenUI Lang component library.
struct OpenUIComponentSpec: Equatable, Sendable {
    let name: String
    let signature: String
    let parameterNames: [String]
    let description: String
}

/// Songwriting-focused OpenUI Lang component library used to generate the
/// system prompt and map positional AST arguments to named properties.
enum OpenUILibrary {
    static let components: [OpenUIComponentSpec] = [
        // Songwriting Cards & Layouts
        OpenUIComponentSpec(
            name: "Stack",
            signature: "Stack(children: Component[], direction?: \"column\" | \"row\", gap?: \"xs\" | \"sm\" | \"md\" | \"lg\")",
            parameterNames: ["children", "direction", "gap"],
            description: "Flex container stacking children vertically (\"column\", default) or horizontally (\"row\")."
        ),
        OpenUIComponentSpec(
            name: "Card",
            signature: "Card(children: Component[], variant?: \"card\" | \"sunken\" | \"clear\")",
            parameterNames: ["children", "variant"],
            description: "Styled surface container for grouping songwriting analysis or suggestion blocks."
        ),
        OpenUIComponentSpec(
            name: "CardHeader",
            signature: "CardHeader(title: string, subtitle?: string, badge?: string)",
            parameterNames: ["title", "subtitle", "badge"],
            description: "Header row displaying a title, optional subtitle, and optional monospace pill badge."
        ),
        OpenUIComponentSpec(
            name: "TextContent",
            signature: "TextContent(text: string, size?: \"sm\" | \"md\" | \"lg\" | \"caption\")",
            parameterNames: ["text", "size"],
            description: "Editorial text block for brief songwriting notes, meter observations, or section guidance."
        ),
        OpenUIComponentSpec(
            name: "Badge",
            signature: "Badge(label: string, tone?: \"neutral\" | \"accent\" | \"success\" | \"warning\")",
            parameterNames: ["label", "tone"],
            description: "Compact pill badge for rhyme scheme letters, phonetic rhyme family, or section tags."
        ),
        // Interactive Suggestion & Prosody Components
        OpenUIComponentSpec(
            name: "RhymeGroup",
            signature: "RhymeGroup(family: string, children: SuggestionLine[], rhymeType?: string, note?: string)",
            parameterNames: ["family", "children", "rhymeType", "note"],
            description: "Groups related lyric suggestions under a shared phonetic family or thematic angle."
        ),
        OpenUIComponentSpec(
            name: "SuggestionLine",
            signature: "SuggestionLine(text: string, angle?: string, endWord?: string)",
            parameterNames: ["text", "angle", "endWord"],
            description: "Interactive lyric candidate card with Use Line, Keep for Later, syllable count, and prosody preview."
        ),
        OpenUIComponentSpec(
            name: "ProsodyMeter",
            signature: "ProsodyMeter(targetSyllables: number, stressPattern: string, rhymeSchemeLetter: string, sectionName?: string)",
            parameterNames: ["targetSyllables", "stressPattern", "rhymeSchemeLetter", "sectionName"],
            description: "Compact meter and cadence bar summarizing target syllable count, stress pattern, and active rhyme letter."
        ),
        OpenUIComponentSpec(
            name: "ActionChipBar",
            signature: "ActionChipBar(chips: string[], promptLabel?: string)",
            parameterNames: ["chips", "promptLabel"],
            description: "Interactive row of one-tap refinement chips (e.g. \"Tighter meter\", \"Internal rhyme\", \"Darker imagery\") that re-stream tailored suggestions."
        )
    ]

    private static let byName: [String: OpenUIComponentSpec] = Dictionary(
        uniqueKeysWithValues: components.map { ($0.name, $0) }
    )

    static func spec(for name: String) -> OpenUIComponentSpec? {
        byName[name]
    }

    /// Generates the OpenUI Lang specification prompt instructing cloud models
    /// to stream line-first `identifier = Expression` statements starting from `root = Stack([...])`.
    static func generateSystemPrompt(
        requestCount: Int,
        rhymeScheme: String,
        currentLetter: String,
        currentSectionName: String,
        rhymeTypeLabel: String,
        targetSyllables: Int?
    ) -> String {
        let componentSignatures = components.map { spec in
            "- \(spec.signature) — \(spec.description)"
        }.joined(separator: "\n")

        let exampleSyllables = targetSyllables ?? 8
        return """
        You respond in **OpenUI Lang**, a declarative, line-oriented Generative UI language designed for progressive streaming.

        ### OpenUI Lang Grammar Rules
        1. Output ONLY valid OpenUI Lang statements — one `identifier = Expression` assignment per line. Do NOT wrap in markdown explanations or prose outside the code.
        2. The FIRST line MUST be `root = Stack([...])` referencing child identifiers in top-down display order so the UI streams progressively as each subsequent identifier is defined.
        3. Arguments are **positional** (never named `key=value`). Strings use double quotes `"..."`, arrays use `[...]`, numbers are bare literals (`\(exampleSyllables)`).
        4. Every candidate lyric line MUST be defined as its own `SuggestionLine("full lyric line", "creative angle", "endWord")` statement and referenced inside a `RhymeGroup` or `Card`.
        5. Emit a total of \(requestCount) distinct `SuggestionLine` nodes grouped across 2–3 `RhymeGroup` sections so the songwriter can compare angles.
        6. Never include numbering, bullets, or surrounding quotes inside the `SuggestionLine` text string itself.

        ### Available Components (Positional Arguments)
        \(componentSignatures)

        ### Streaming Order Template
        ```openui
        root = Stack([meter, group1, group2, actions])
        meter = ProsodyMeter(\(exampleSyllables), "da-DUM da-DUM", "\(currentLetter)", "\(currentSectionName)")
        group1 = RhymeGroup("Primary Rhyme Angle", [s1, s2, s3], "\(rhymeTypeLabel)", "Matches the stanza cadence")
        s1 = SuggestionLine("First candidate lyric line here", "Direct imagery", "here")
        s2 = SuggestionLine("Second candidate lyric line here", "Internal echo", "here")
        s3 = SuggestionLine("Third candidate lyric line here", "Metaphoric turn", "here")
        group2 = RhymeGroup("Contrast & Cadence", [s4, s5, s6], "\(rhymeTypeLabel)", "Syncopated phrasing")
        s4 = SuggestionLine("Fourth candidate lyric line here", "Vivid verb", "here")
        s5 = SuggestionLine("Fifth candidate lyric line here", "Sensory detail", "here")
        s6 = SuggestionLine("Sixth candidate lyric line here", "Hook-ready phrasing", "here")
        actions = ActionChipBar(["Tighter meter", "More internal rhyme", "Vivid imagery", "Simpler phrasing"], "Refine direction")
        ```
        """
    }

    /// Synthesizes a valid OpenUI Lang element tree from plain suggestion lines
    /// if a cloud model ever falls back to plain text instead of OpenUI Lang.
    static func synthesizeTree(
        lines: [String],
        rhymeLetter: String = "A",
        rhymeTypeLabel: String = "Rhyme",
        sectionName: String = "Verse",
        targetSyllables: Int? = nil
    ) -> OpenUIParseResult {
        guard !lines.isEmpty else {
            return OpenUIParseResult(
                root: nil,
                meta: OpenUIParseMeta(totalStatements: 0, unresolvedRefs: [], errors: []),
                extractedSuggestions: []
            )
        }
        let suggestionNodes = lines.map { line in
            OpenUIElementNode(
                typeName: "SuggestionLine",
                props: [
                    "text": .string(line),
                    "angle": .string(""),
                    "endWord": .string("")
                ]
            )
        }
        let groupNode = OpenUIElementNode(
            typeName: "RhymeGroup",
            props: [
                "family": .string("\(rhymeTypeLabel) Suggestions"),
                "children": .array(suggestionNodes.map { .element($0) }),
                "rhymeType": .string("Scheme \(rhymeLetter)"),
                "note": .string(sectionName)
            ]
        )
        var children: [OpenUINodeValue] = []
        if let targetSyllables, targetSyllables > 0 {
            let meterNode = OpenUIElementNode(
                typeName: "ProsodyMeter",
                props: [
                    "targetSyllables": .number(Double(targetSyllables)),
                    "stressPattern": .string("Target cadence"),
                    "rhymeSchemeLetter": .string(rhymeLetter),
                    "sectionName": .string(sectionName)
                ]
            )
            children.append(.element(meterNode))
        }
        children.append(.element(groupNode))
        children.append(
            .element(
                OpenUIElementNode(
                    typeName: "ActionChipBar",
                    props: [
                        "chips": .array([
                            .string("Tighter meter"),
                            .string("More internal rhyme"),
                            .string("Vivid imagery")
                        ]),
                        "promptLabel": .string("Refine direction")
                    ]
                )
            )
        )
        let rootNode = OpenUIElementNode(
            typeName: "Stack",
            props: [
                "children": .array(children),
                "direction": .string("column"),
                "gap": .string("md")
            ]
        )
        let extracted = lines.map { OpenUISuggestionPayload(text: $0, angle: nil, endWord: nil) }
        return OpenUIParseResult(
            root: rootNode,
            meta: OpenUIParseMeta(totalStatements: lines.count + 2, unresolvedRefs: [], errors: []),
            extractedSuggestions: extracted
        )
    }

    /// Synthesizes an interactive OpenUI Lang workspace program and parsed element tree
    /// when a cloud provider is active and waiting for the user's first generation or
    /// custom refinement directive.
    static func synthesizeWorkspaceResult(
        providerName: String,
        modelName: String,
        targetLine: String?,
        targetSyllables: Int? = nil,
        rhymeLetter: String = "A",
        rhymeTypeLabel: String = "End",
        sectionName: String = "Verse"
    ) -> (rawCode: String, result: OpenUIParseResult) {
        let safeSyllables = (targetSyllables ?? 0) > 0 ? (targetSyllables ?? 8) : 8
        let targetNote: String
        if let targetLine, !targetLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            targetNote = "Matching \"\(targetLine.replacingOccurrences(of: "\"", with: "'"))\""
        } else {
            targetNote = "Ready to stream structured \(rhymeTypeLabel.lowercased()) rhymes for \(sectionName)"
        }
        let dsl = """
        root = Stack([header, meter, guideCard, actions], "column", "md")
        header = CardHeader("\(providerName) · \(modelName)", "\(targetNote)", "sparkles")
        meter = ProsodyMeter(\(safeSyllables), "Interactive OpenUI cadence", "\(rhymeLetter)", "\(sectionName)")
        guideCard = Card([guideText, badgeRow], "elevated")
        guideText = TextContent("OpenUI Generative UI is active. Tap Suggest Rhymes, pick a steering chip below, or type a custom direction to stream live components.", "small")
        badgeRow = Stack([b1, b2, b3], "row", "sm")
        b1 = Badge("Scheme \(rhymeLetter)", "accent")
        b2 = Badge("\(rhymeTypeLabel) rhyme", "neutral")
        b3 = Badge("\(safeSyllables) syl target", "success")
        actions = ActionChipBar(["Tighter meter", "Internal rhyme", "Vivid imagery", "Anthemic hook", "Darker metaphor"], "Launch or steer with OpenUI")
        """
        return (dsl, OpenUIParser.parse(dsl))
    }
}

// MARK: - Materialized Element Tree & Values

/// Materialized OpenUI node value produced after resolving references.
indirect enum OpenUINodeValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([OpenUINodeValue])
    case object([String: OpenUINodeValue])
    case element(OpenUIElementNode)
    case unresolvedRef(String)

    func asString() -> String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value == value.rounded(), !value.isInfinite, !value.isNaN {
                return String(Int(value))
            }
            return String(value)
        case .bool(let value):
            return String(value)
        default:
            return nil
        }
    }

    func asInt() -> Int? {
        switch self {
        case .number(let value):
            return Int(value)
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    func asArray() -> [OpenUINodeValue] {
        switch self {
        case .array(let items):
            return items
        case .element:
            return [self]
        default:
            return []
        }
    }
}

/// A resolved UI element in the OpenUI Lang tree.
struct OpenUIElementNode: Equatable, Sendable {
    let typeName: String
    let props: [String: OpenUINodeValue]
    let partial: Bool

    init(typeName: String, props: [String: OpenUINodeValue], partial: Bool = false) {
        self.typeName = typeName
        self.props = props
        self.partial = partial
    }

    func stringProp(_ name: String) -> String? {
        props[name]?.asString()
    }

    func intProp(_ name: String) -> Int? {
        props[name]?.asInt()
    }

    func childrenProp(_ name: String = "children") -> [OpenUIElementNode] {
        guard let raw = props[name] else { return [] }
        switch raw {
        case .array(let items):
            return items.compactMap {
                if case .element(let el) = $0 { return el }
                return nil
            }
        case .element(let el):
            return [el]
        default:
            return []
        }
    }
}

struct OpenUISuggestionPayload: Equatable, Sendable {
    let text: String
    let angle: String?
    let endWord: String?
}

struct OpenUIParseMeta: Equatable, Sendable {
    let totalStatements: Int
    let unresolvedRefs: [String]
    let errors: [String]
}

struct OpenUIParseResult: Equatable, Sendable {
    let root: OpenUIElementNode?
    let meta: OpenUIParseMeta
    let extractedSuggestions: [OpenUISuggestionPayload]
}

// MARK: - Internal AST

private indirect enum OpenUIAstNode {
    case stringLiteral(String)
    case numberLiteral(Double)
    case boolLiteral(Bool)
    case nullLiteral
    case arrayLiteral([OpenUIAstNode])
    case objectLiteral([(String, OpenUIAstNode)])
    case reference(String)
    case componentCall(String, [OpenUIAstNode])
}

// MARK: - OpenUI Lang Streaming Parser

/// Progressive streaming parser for OpenUI Lang (`@openuidev/lang-core` specification).
///
/// Supports:
/// - Line-by-line `identifier = Expression` statements
/// - Forward references (`root = Stack([meter, group1])` before `meter` or `group1` arrive)
/// - Automatic bracket and string closing (`autoClose`) so incomplete chunks render live
/// - Positional argument mapping onto `OpenUILibrary` schemas
enum OpenUIParser {

    /// Strips optional markdown code fences (` ```openui `, ` ```openui-lang `, ` ``` `)
    /// from streamed or complete model output.
    static func stripFences(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        var cleaned: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") {
                continue
            }
            cleaned.append(line)
        }
        return cleaned.joined(separator: "\n")
    }

    /// Auto-closes unclosed string literals, parentheses, brackets, and braces
    /// on incomplete streamed chunks so partial AST statements can be evaluated.
    static func autoClose(_ input: String) -> String {
        var inString = false
        var escaped = false
        var stack: [Character] = []

        for ch in input {
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" && inString {
                escaped = true
                continue
            }
            if ch == "\"" {
                inString.toggle()
                continue
            }
            if inString { continue }

            switch ch {
            case "(":
                stack.append(")")
            case "[":
                stack.append("]")
            case "{":
                stack.append("}")
            case ")", "]", "}":
                if stack.last == ch {
                    stack.removeLast()
                }
            default:
                break
            }
        }

        if !inString && stack.isEmpty {
            return input
        }

        var result = input
        if inString {
            if escaped {
                result.append("\\")
            }
            result.append("\"")
        }
        // Trim a dangling comma or colon right before auto-closing brackets
        let trimmedEnd = result.replacingOccurrences(
            of: "\\s+$",
            with: "",
            options: .regularExpression
        )
        if !stack.isEmpty && (trimmedEnd.hasSuffix(",") || trimmedEnd.hasSuffix(":")) {
            result = String(trimmedEnd.dropLast())
        }
        for closer in stack.reversed() {
            result.append(closer)
        }
        return result
    }

    /// Splits OpenUI Lang source into logical `identifier = Expression` statements.
    /// Multi-line arrays or component calls stay grouped until bracket depth returns to 0.
    private static func splitStatements(_ source: String) -> [String] {
        var statements: [String] = []
        var current = ""
        var depth = 0
        var inString = false
        var escaped = false

        for ch in source {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inString {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "\"" {
                inString.toggle()
                current.append(ch)
                continue
            }
            if !inString {
                switch ch {
                case "(", "[", "{":
                    depth += 1
                    current.append(ch)
                case ")", "]", "}":
                    depth = max(0, depth - 1)
                    current.append(ch)
                case "\n", "\r":
                    if depth == 0 {
                        let stmt = current.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !stmt.isEmpty && !stmt.hasPrefix("#") && !stmt.hasPrefix("//") {
                            statements.append(stmt)
                        }
                        current.removeAll(keepingCapacity: true)
                    } else {
                        current.append(" ")
                    }
                default:
                    current.append(ch)
                }
            } else {
                if ch == "\n" || ch == "\r" {
                    current.append(" ")
                } else {
                    current.append(ch)
                }
            }
        }

        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty && !remaining.hasPrefix("#") && !remaining.hasPrefix("//") {
            statements.append(remaining)
        }
        return statements
    }

    /// Parses a complete or partial OpenUI Lang program into an `OpenUIParseResult`.
    static func parse(_ rawInput: String) -> OpenUIParseResult {
        let stripped = stripFences(rawInput)
        let closed = autoClose(stripped)
        let rawStatements = splitStatements(closed)

        var symbolTable: [String: OpenUIAstNode] = [:]
        var statementOrder: [String] = []
        var errors: [String] = []

        for rawStmt in rawStatements {
            guard let eqIndex = findTopLevelEquals(rawStmt) else {
                continue
            }
            let lhs = String(rawStmt[..<eqIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = String(rawStmt[rawStmt.index(after: eqIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidIdentifier(lhs), !rhs.isEmpty else {
                continue
            }
            let closedRhs = autoClose(rhs)
            var parser = ExpressionParser(source: closedRhs)
            if let ast = parser.parseExpression() {
                symbolTable[lhs] = ast
                if !statementOrder.contains(lhs) {
                    statementOrder.append(lhs)
                }
            } else {
                errors.append("Failed to parse statement '\(lhs)'")
            }
        }

        if symbolTable.isEmpty {
            return OpenUIParseResult(
                root: nil,
                meta: OpenUIParseMeta(totalStatements: 0, unresolvedRefs: [], errors: errors),
                extractedSuggestions: []
            )
        }

        var unresolvedRefs: [String] = []
        let rootId: String?
        if symbolTable["root"] != nil {
            rootId = "root"
        } else {
            rootId = statementOrder.first { id in
                if case .componentCall = symbolTable[id] { return true }
                return false
            }
        }

        func materialize(_ node: OpenUIAstNode, visited: Set<String>) -> OpenUINodeValue {
            switch node {
            case .stringLiteral(let value):
                return .string(value)
            case .numberLiteral(let value):
                return .number(value)
            case .boolLiteral(let value):
                return .bool(value)
            case .nullLiteral:
                return .null
            case .arrayLiteral(let items):
                let resolved = items.compactMap { item -> OpenUINodeValue? in
                    let val = materialize(item, visited: visited)
                    if case .unresolvedRef = val { return nil }
                    return val
                }
                return .array(resolved)
            case .objectLiteral(let entries):
                var map: [String: OpenUINodeValue] = [:]
                for (k, v) in entries {
                    map[k] = materialize(v, visited: visited)
                }
                return .object(map)
            case .reference(let name):
                if visited.contains(name) {
                    errors.append("Circular reference involving '\(name)'")
                    return .unresolvedRef(name)
                }
                guard let target = symbolTable[name] else {
                    if !unresolvedRefs.contains(name) {
                        unresolvedRefs.append(name)
                    }
                    return .unresolvedRef(name)
                }
                return materialize(target, visited: visited.union([name]))
            case .componentCall(let typeName, let args):
                let spec = OpenUILibrary.spec(for: typeName)
                var props: [String: OpenUINodeValue] = [:]
                if let spec {
                    for (index, arg) in args.enumerated() {
                        let key = index < spec.parameterNames.count ? spec.parameterNames[index] : "arg\(index)"
                        props[key] = materialize(arg, visited: visited)
                    }
                } else {
                    for (index, arg) in args.enumerated() {
                        props["arg\(index)"] = materialize(arg, visited: visited)
                    }
                }
                return .element(
                    OpenUIElementNode(
                        typeName: typeName,
                        props: props,
                        partial: args.isEmpty && spec != nil && !spec!.parameterNames.isEmpty
                    )
                )
            }
        }

        let rootElement: OpenUIElementNode?
        if let rootId, let rootAst = symbolTable[rootId] {
            if case .element(let el) = materialize(rootAst, visited: [rootId]) {
                rootElement = el
            } else {
                rootElement = nil
            }
        } else {
            rootElement = nil
        }

        var extractedSuggestions: [OpenUISuggestionPayload] = []
        var seenSuggestions = Set<String>()

        func collectSuggestionsFromElement(_ el: OpenUIElementNode) {
            if el.typeName == "SuggestionLine" {
                let text = el.stringProp("text")?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? el.stringProp("arg0")?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? ""
                if !text.isEmpty, seenSuggestions.insert(text.lowercased()).inserted {
                    extractedSuggestions.append(
                        OpenUISuggestionPayload(
                            text: text,
                            angle: el.stringProp("angle")?.takeIfNotBlank(),
                            endWord: el.stringProp("endWord")?.takeIfNotBlank()
                        )
                    )
                }
            }
            for (_, propVal) in el.props {
                switch propVal {
                case .element(let child):
                    collectSuggestionsFromElement(child)
                case .array(let items):
                    for item in items {
                        if case .element(let child) = item {
                            collectSuggestionsFromElement(child)
                        }
                    }
                default:
                    break
                }
            }
        }

        if let rootElement {
            collectSuggestionsFromElement(rootElement)
        }
        // Also collect any SuggestionLine statements defined before their parent group is wired
        for id in statementOrder {
            if let ast = symbolTable[id], case .componentCall(let typeName, _) = ast, typeName == "SuggestionLine" {
                if case .element(let materialized) = materialize(ast, visited: [id]) {
                    collectSuggestionsFromElement(materialized)
                }
            }
        }

        return OpenUIParseResult(
            root: rootElement,
            meta: OpenUIParseMeta(
                totalStatements: symbolTable.count,
                unresolvedRefs: unresolvedRefs,
                errors: errors
            ),
            extractedSuggestions: extractedSuggestions
        )
    }

    private static func findTopLevelEquals(_ stmt: String) -> String.Index? {
        var inString = false
        var escaped = false
        var depth = 0
        for idx in stmt.indices {
            let ch = stmt[idx]
            if escaped {
                escaped = false
                continue
            }
            if ch == "\\" && inString {
                escaped = true
                continue
            }
            if ch == "\"" {
                inString.toggle()
                continue
            }
            if !inString {
                switch ch {
                case "(", "[", "{":
                    depth += 1
                case ")", "]", "}":
                    depth = max(0, depth - 1)
                case "=":
                    if depth == 0 { return idx }
                default:
                    break
                }
            }
        }
        return nil
    }

    private static func isValidIdentifier(_ candidate: String) -> Bool {
        guard let first = candidate.first, first.isLetter || first == "_" else { return false }
        return candidate.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

private extension String {
    func takeIfNotBlank() -> String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Stateful streaming parser wrapper that accumulates token chunks and re-evaluates
/// the OpenUI Lang tree incrementally.
final class OpenUIStreamingParser {
    private var buffer = ""

    var rawBuffer: String { buffer }

    @discardableResult
    func push(_ chunk: String) -> OpenUIParseResult {
        buffer.append(chunk)
        return OpenUIParser.parse(buffer)
    }

    func getResult() -> OpenUIParseResult {
        OpenUIParser.parse(buffer)
    }

    func reset() {
        buffer.removeAll()
    }
}

// MARK: - Recursive-Descent Expression Parser

private struct ExpressionParser {
    private let chars: [Character]
    private var pos: Int = 0

    init(source: String) {
        self.chars = Array(source)
    }

    mutating func parseExpression() -> OpenUIAstNode? {
        skipWhitespace()
        guard pos < chars.count else { return nil }
        let ch = chars[pos]
        if ch == "\"" {
            return parseString()
        } else if ch == "[" {
            return parseArray()
        } else if ch == "{" {
            return parseObject()
        } else if ch == "-" || ch.isNumber {
            return parseNumber()
        } else if ch == "$" {
            pos += 1
            let ident = readIdentifier()
            return .stringLiteral("$\(ident)")
        } else if ch.isLetter || ch == "_" {
            return parseIdentifierOrCall()
        }
        return nil
    }

    private mutating func parseString() -> OpenUIAstNode? {
        guard pos < chars.count, chars[pos] == "\"" else { return nil }
        pos += 1 // skip opening quote
        var out = ""
        while pos < chars.count {
            let ch = chars[pos]
            pos += 1
            if ch == "\\" {
                if pos < chars.count {
                    let esc = chars[pos]
                    pos += 1
                    switch esc {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "n": out.append("\n")
                    case "r": out.append("\r")
                    case "t": out.append("\t")
                    default: out.append(esc)
                    }
                }
            } else if ch == "\"" {
                break
            } else {
                out.append(ch)
            }
        }
        return .stringLiteral(out)
    }

    private mutating func parseNumber() -> OpenUIAstNode? {
        let start = pos
        if pos < chars.count, chars[pos] == "-" { pos += 1 }
        var hasDigits = false
        while pos < chars.count, chars[pos].isNumber {
            pos += 1
            hasDigits = true
        }
        if pos < chars.count, chars[pos] == "." {
            pos += 1
            while pos < chars.count, chars[pos].isNumber {
                pos += 1
                hasDigits = true
            }
        }
        guard hasDigits else { return nil }
        let slice = String(chars[start..<pos])
        let value = Double(slice) ?? 0.0
        return .numberLiteral(value)
    }

    private mutating func parseArray() -> OpenUIAstNode? {
        guard pos < chars.count, chars[pos] == "[" else { return nil }
        pos += 1 // skip '['
        var items: [OpenUIAstNode] = []
        while pos < chars.count {
            skipWhitespace()
            if pos >= chars.count { break }
            if chars[pos] == "]" {
                pos += 1
                break
            }
            if chars[pos] == "," {
                pos += 1
                continue
            }
            if let expr = parseExpression() {
                items.append(expr)
            } else {
                advanceToNextDelimiter(stopAtClose: "]")
            }
        }
        return .arrayLiteral(items)
    }

    private mutating func parseObject() -> OpenUIAstNode? {
        guard pos < chars.count, chars[pos] == "{" else { return nil }
        pos += 1 // skip '{'
        var entries: [(String, OpenUIAstNode)] = []
        while pos < chars.count {
            skipWhitespace()
            if pos >= chars.count { break }
            if chars[pos] == "}" {
                pos += 1
                break
            }
            if chars[pos] == "," {
                pos += 1
                continue
            }
            let key: String
            if chars[pos] == "\"" {
                if case .stringLiteral(let s) = parseString() {
                    key = s
                } else {
                    key = ""
                }
            } else {
                key = readIdentifier()
            }
            skipWhitespace()
            if pos < chars.count, chars[pos] == ":" || chars[pos] == "=" {
                pos += 1
            }
            if let valExpr = parseExpression(), !key.isEmpty {
                entries.append((key, valExpr))
            } else if key.isEmpty {
                advanceToNextDelimiter(stopAtClose: "}")
            }
        }
        return .objectLiteral(entries)
    }

    private mutating func parseIdentifierOrCall() -> OpenUIAstNode? {
        let ident = readIdentifier()
        guard !ident.isEmpty else { return nil }
        skipWhitespace()
        if pos < chars.count, chars[pos] == "(" {
            pos += 1 // skip '('
            var args: [OpenUIAstNode] = []
            while pos < chars.count {
                skipWhitespace()
                if pos >= chars.count { break }
                if chars[pos] == ")" {
                    pos += 1
                    break
                }
                if chars[pos] == "," {
                    pos += 1
                    continue
                }
                let savedPos = pos
                if chars[pos].isLetter {
                    let maybeKey = readIdentifier()
                    skipWhitespace()
                    if pos < chars.count, chars[pos] == ":" || chars[pos] == "=" {
                        pos += 1
                    } else {
                        pos = savedPos
                        _ = maybeKey
                    }
                }
                if let arg = parseExpression() {
                    args.append(arg)
                } else {
                    advanceToNextDelimiter(stopAtClose: ")")
                }
            }
            return .componentCall(ident, args)
        }
        switch ident {
        case "true":
            return .boolLiteral(true)
        case "false":
            return .boolLiteral(false)
        case "null":
            return .nullLiteral
        default:
            return .reference(ident)
        }
    }

    private mutating func readIdentifier() -> String {
        let start = pos
        while pos < chars.count, chars[pos].isLetter || chars[pos].isNumber || chars[pos] == "_" {
            pos += 1
        }
        return String(chars[start..<pos])
    }

    private mutating func skipWhitespace() {
        while pos < chars.count, chars[pos].isWhitespace {
            pos += 1
        }
    }

    private mutating func advanceToNextDelimiter(stopAtClose: Character) {
        while pos < chars.count, chars[pos] != ",", chars[pos] != stopAtClose {
            pos += 1
        }
    }
}
