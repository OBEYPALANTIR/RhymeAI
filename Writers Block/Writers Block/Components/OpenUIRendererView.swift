import SwiftUI

struct OpenUIAssistantSectionView: View {
    @Environment(\.appAppearanceStyle) private var appearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let parseResult: OpenUIParseResult
    let rawCode: String
    let providerName: String
    var modelName: String = ""
    var availableModels: [AIModel] = []
    var onSelectModel: ((AIModel) -> Void)? = nil
    let isStreaming: Bool
    let verifiedSuggestions: [String: SuggestedLine]
    let highlightRhyme: Bool
    let showProsody: Bool
    let isKept: (String) -> Bool
    let onKeep: (String) -> Void
    let onUse: (String) -> Void
    let onActionChipSelected: (String) -> Void

    @State private var showInspector = false
    @State private var customDirective = ""

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.md) {
            headerBar

            if !availableModels.isEmpty, let onSelectModel {
                HStack(spacing: RhymeAITokens.Spacing.xs) {
                    Text("Active Model:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Menu {
                        ForEach(availableModels, id: \.self) { model in
                            Button {
                                onSelectModel(model)
                            } label: {
                                Label(
                                    "\(model.displayName) — \(model.subtitle)",
                                    systemImage: model.displayName == modelName ? "checkmark" : "sparkles"
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: RhymeAITokens.Spacing.xxs) {
                            Text(modelName.isEmpty ? providerName : modelName)
                                .font(.caption.weight(.semibold))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(appearance.palette.action)
                        .padding(.horizontal, RhymeAITokens.Spacing.sm)
                        .padding(.vertical, RhymeAITokens.Spacing.xxs)
                        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.pill, tint: appearance.palette.action, fallbackOpacity: 0.12)
                    }
                    .accessibilityIdentifier("openUIModelSelectorButton")
                    Spacer()
                }
            }

            if showInspector && !rawCode.isEmpty {
                OpenUILangInspectorView(
                    rawCode: rawCode,
                    unresolvedCount: parseResult.meta.unresolvedRefs.count,
                    statementCount: parseResult.meta.totalStatements
                )
            }

            if let root = parseResult.root {
                OpenUINodeRendererView(
                    node: root,
                    verifiedSuggestions: verifiedSuggestions,
                    highlightRhyme: highlightRhyme,
                    showProsody: showProsody,
                    isStreaming: isStreaming,
                    isKept: isKept,
                    onKeep: onKeep,
                    onUse: onUse,
                    onActionChipSelected: onActionChipSelected
                )
            }

            HStack(spacing: RhymeAITokens.Spacing.xs) {
                TextField("Steer OpenUI (e.g., internal rhymes, darker imagery…)", text: $customDirective)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .padding(.horizontal, RhymeAITokens.Spacing.sm)
                    .padding(.vertical, RhymeAITokens.Spacing.xs)
                    .liquidGlassSurface(
                        cornerRadius: RhymeAITokens.Radius.sm,
                        tint: .white.opacity(0.04),
                        interactive: true,
                        fallbackOpacity: 0.06
                    )
                    .accessibilityIdentifier("openUISteerInput")

                Button("Steer") {
                    let trimmed = customDirective.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onActionChipSelected(trimmed)
                    customDirective = ""
                }
                .buttonStyle(.borderedProminent)
                .tint(appearance.palette.action)
                .controlSize(.small)
                .disabled(isStreaming || customDirective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("openUISteerSubmitButton")
            }

            if !parseResult.meta.unresolvedRefs.isEmpty && isStreaming {
                HStack(spacing: RhymeAITokens.Spacing.xs) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Resolving \(parseResult.meta.unresolvedRefs.count) component\(parseResult.meta.unresolvedRefs.count == 1 ? "" : "s")…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.top, RhymeAITokens.Spacing.xxs)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openUIAssistantSection")
    }

    private var headerBar: some View {
        HStack(spacing: RhymeAITokens.Spacing.sm) {
            if isStreaming {
                ProgressView()
                    .controlSize(.small)
                    .tint(appearance.palette.action)
            } else {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(appearance.palette.action)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    modelName.isEmpty
                        ? "\(providerName) · OpenUI Generative UI"
                        : "\(providerName) · \(modelName) · OpenUI"
                )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(
                    isStreaming
                        ? "Streaming live OpenUI Lang (\(parseResult.meta.totalStatements) statements)…"
                        : "Live Generative UI · tap chips or steer below"
                )
                .font(.caption.italic())
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                withRhymeAnimation(RhymeAITokens.Motion.state, reduceMotion: reduceMotion) {
                    showInspector.toggle()
                }
            } label: {
                Label(showInspector ? "Hide DSL" : "Inspect", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.caption.monospaced())
                    .padding(.horizontal, RhymeAITokens.Spacing.xs)
                    .padding(.vertical, RhymeAITokens.Spacing.xxs)
                    .frame(minHeight: RhymeAITokens.Touch.minimum)
            }
            .buttonStyle(.rhymePress)
            .accessibilityIdentifier("openUIInspectButton")
        }
    }
}

private struct OpenUILangInspectorView: View {
    let rawCode: String
    let unresolvedCount: Int
    let statementCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
            HStack {
                Text("openui-lang · \(statementCount) statements")
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if unresolvedCount > 0 {
                    Text("\(unresolvedCount) pending refs")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Text(rawCode.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.caption2.monospaced())
                .foregroundStyle(.primary.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(RhymeAITokens.Spacing.sm)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.sm, fallbackOpacity: 0.08)
        .accessibilityIdentifier("openUILangInspector")
    }
}

struct OpenUINodeRendererView: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let node: OpenUIElementNode
    let verifiedSuggestions: [String: SuggestedLine]
    let highlightRhyme: Bool
    let showProsody: Bool
    let isStreaming: Bool
    let isKept: (String) -> Bool
    let onKeep: (String) -> Void
    let onUse: (String) -> Void
    let onActionChipSelected: (String) -> Void

    var body: some View {
        switch node.typeName {
        case "Stack":
            renderStack
        case "Card":
            renderCard
        case "CardHeader":
            renderCardHeader
        case "TextContent":
            renderTextContent
        case "Badge":
            renderBadge
        case "ProsodyMeter":
            renderProsodyMeter
        case "RhymeGroup":
            renderRhymeGroup
        case "SuggestionLine":
            renderSuggestionLine
        case "ActionChipBar":
            renderActionChipBar
        default:
            renderFallbackContainer
        }
    }

    @ViewBuilder
    private var renderStack: some View {
        let direction = (node.stringProp("direction") ?? node.stringProp("arg1") ?? "column").lowercased()
        let gapToken = (node.stringProp("gap") ?? node.stringProp("arg2") ?? "md").lowercased()
        let spacing = spacingForToken(gapToken)
        let children = node.childrenProp("children").isEmpty ? node.childrenProp("arg0") : node.childrenProp("children")

        if direction == "row" {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                        childView(child)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    childView(child)
                }
            }
        }
    }

    @ViewBuilder
    private var renderCard: some View {
        let variant = (node.stringProp("variant") ?? node.stringProp("arg1") ?? "card").lowercased()
        let children = node.childrenProp("children").isEmpty ? node.childrenProp("arg0") : node.childrenProp("children")
        let opacity: Double = variant == "clear" ? 0.02 : (variant == "sunken" ? 0.04 : 0.06)

        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                childView(child)
            }
        }
        .padding(RhymeAITokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, fallbackOpacity: opacity)
    }

    @ViewBuilder
    private var renderCardHeader: some View {
        let title = node.stringProp("title") ?? node.stringProp("arg0") ?? ""
        let subtitle = node.stringProp("subtitle") ?? node.stringProp("arg1")
        let badge = node.stringProp("badge") ?? node.stringProp("arg2")

        HStack(alignment: .center, spacing: RhymeAITokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                if !title.isEmpty {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let badge, !badge.isEmpty {
                OpenUIBadgePillView(label: badge, tone: "neutral")
            }
        }
    }

    @ViewBuilder
    private var renderTextContent: some View {
        let text = node.stringProp("text") ?? node.stringProp("arg0") ?? ""
        let size = (node.stringProp("size") ?? node.stringProp("arg1") ?? "md").lowercased()
        if !text.isEmpty {
            Text(text)
                .font(size == "lg" ? .body.weight(.medium) : (size == "sm" || size == "caption" ? .caption : .subheadline))
                .foregroundStyle(size == "sm" || size == "caption" ? .secondary : .primary)
        }
    }

    @ViewBuilder
    private var renderBadge: some View {
        let label = node.stringProp("label") ?? node.stringProp("arg0") ?? ""
        let tone = node.stringProp("tone") ?? node.stringProp("arg1") ?? "neutral"
        if !label.isEmpty {
            OpenUIBadgePillView(label: label, tone: tone)
        }
    }

    @ViewBuilder
    private var renderProsodyMeter: some View {
        // Support both schemas:
        // (targetSyllables, stressPattern, rhymeSchemeLetter, sectionName)
        // OR (targetLine, targetSyllables, rhymeType, schemeLetter, section)
        let firstString = node.stringProp("targetSyllables") ?? node.stringProp("arg0") ?? ""
        let targetSyllables = node.intProp("targetSyllables")
            ?? node.intProp("arg1")
            ?? Int(firstString.filter(\.isNumber))
            ?? (firstString.isEmpty ? 0 : SyllableCounter.countText(firstString))
        let stressOrRhyme = node.stringProp("stressPattern") ?? node.stringProp("arg2") ?? "Cadence"
        let letter = node.stringProp("rhymeSchemeLetter") ?? node.stringProp("arg3") ?? "A"
        let section = node.stringProp("sectionName") ?? node.stringProp("arg4") ?? ""

        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
            HStack(spacing: RhymeAITokens.Spacing.xs) {
                OpenUIBadgePillView(label: "Scheme \(letter)", tone: "accent")
                if !stressOrRhyme.isEmpty {
                    OpenUIBadgePillView(label: stressOrRhyme, tone: "neutral")
                }
                if !section.isEmpty {
                    OpenUIBadgePillView(label: section, tone: "neutral")
                }
                Spacer()
                if targetSyllables > 0 {
                    Text("\(targetSyllables) syl target")
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(RhymeAITokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.sm, fallbackOpacity: 0.06)
        .accessibilityIdentifier("openUIProsodyMeter")
    }

    @ViewBuilder
    private var renderRhymeGroup: some View {
        let title = node.stringProp("family") ?? node.stringProp("title") ?? node.stringProp("arg0") ?? "Rhyme Angle"
        // Children may be at arg1 (`children: SuggestionLine[]`) or arg2 (`suggestions: SuggestionLine[]`)
        let rawChildren: [OpenUIElementNode] = {
            let byChildren = node.childrenProp("children")
            if !byChildren.isEmpty { return byChildren }
            let bySuggestions = node.childrenProp("suggestions")
            if !bySuggestions.isEmpty { return bySuggestions }
            let byArg1 = node.childrenProp("arg1")
            if !byArg1.isEmpty { return byArg1 }
            return node.childrenProp("arg2")
        }()
        let badge = node.stringProp("rhymeType") ?? node.stringProp("rhymeSound") ?? node.stringProp("arg2") ?? node.stringProp("arg1") ?? ""
        let note = node.stringProp("note") ?? node.stringProp("arg3") ?? ""

        VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
            HStack(alignment: .center, spacing: RhymeAITokens.Spacing.xs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !badge.isEmpty {
                    OpenUIBadgePillView(label: badge, tone: "neutral")
                }
            }

            if rawChildren.isEmpty && isStreaming {
                Text("Streaming lyric lines for this group…")
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
                    ForEach(Array(rawChildren.enumerated()), id: \.offset) { _, child in
                        childView(child)
                    }
                }
            }
        }
        .padding(RhymeAITokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.md, fallbackOpacity: 0.05)
    }

    @ViewBuilder
    private var renderSuggestionLine: some View {
        let rawText = (node.stringProp("text") ?? node.stringProp("arg0") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let angle = (node.stringProp("angle") ?? node.stringProp("arg1") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let endWord = (node.stringProp("endWord") ?? node.stringProp("arg2") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !rawText.isEmpty {
            let verified = verifiedSuggestions[rawText.lowercased()]
            let displayLine = verified?.text ?? rawText

            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
                if !angle.isEmpty || !endWord.isEmpty {
                    HStack {
                        if !angle.isEmpty {
                            Text(angle)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !endWord.isEmpty {
                            Text("· \(endWord)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, RhymeAITokens.Spacing.xxs)
                }

                SuggestionCardView(
                    suggestion: displayLine,
                    rhymeTier: verified?.tier ?? 0,
                    isHookRepeat: verified?.isHookRepeat ?? false,
                    highlightRhyme: highlightRhyme,
                    showProsody: showProsody,
                    onUse: { onUse(displayLine) },
                    onKeep: { onKeep(displayLine) },
                    isKept: isKept(displayLine)
                )
            }
        }
    }

    @ViewBuilder
    private var renderActionChipBar: some View {
        let rawChips = node.props["chips"]?.asArray() ?? node.props["arg0"]?.asArray() ?? []
        let chips = rawChips.compactMap { $0.asString()?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let label = node.stringProp("promptLabel") ?? node.stringProp("arg1") ?? "Refine next-line direction"

        if !chips.isEmpty {
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xs) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: RhymeAITokens.Spacing.xs) {
                        ForEach(chips, id: \.self) { chip in
                            Button {
                                onActionChipSelected(chip)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                        .font(.caption2)
                                    Text(chip)
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, RhymeAITokens.Spacing.sm)
                                .padding(.vertical, RhymeAITokens.Spacing.xs)
                                .frame(minHeight: RhymeAITokens.Touch.minimum)
                            }
                            .buttonStyle(.bordered)
                            .tint(appearance.palette.action)
                            .disabled(isStreaming)
                            .accessibilityIdentifier("openUIActionChip_\(chip)")
                        }
                    }
                }
            }
            .accessibilityIdentifier("openUIActionChipBar")
        }
    }

    @ViewBuilder
    private var renderFallbackContainer: some View {
        let children = node.childrenProp("children").isEmpty ? node.childrenProp("arg0") : node.childrenProp("children")
        if !children.isEmpty {
            VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.sm) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in
                    childView(child)
                }
            }
        } else if let text = node.stringProp("text") ?? node.stringProp("title") ?? node.stringProp("arg0"), !text.isEmpty {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }

    private func childView(_ child: OpenUIElementNode) -> AnyView {
        AnyView(
            OpenUINodeRendererView(
                node: child,
                verifiedSuggestions: verifiedSuggestions,
                highlightRhyme: highlightRhyme,
                showProsody: showProsody,
                isStreaming: isStreaming,
                isKept: isKept,
                onKeep: onKeep,
                onUse: onUse,
                onActionChipSelected: onActionChipSelected
            )
        )
    }

    private func spacingForToken(_ token: String) -> CGFloat {
        switch token {
        case "xs": return RhymeAITokens.Spacing.xxs
        case "sm": return RhymeAITokens.Spacing.xs
        case "lg": return RhymeAITokens.Spacing.lg
        default: return RhymeAITokens.Spacing.sm
        }
    }
}

private struct OpenUIBadgePillView: View {
    @Environment(\.appAppearanceStyle) private var appearance

    let label: String
    let tone: String

    var body: some View {
        Text(label)
            .font(.caption2.monospaced().weight(.medium))
            .foregroundStyle(tone == "accent" ? appearance.palette.action : .secondary)
            .padding(.horizontal, RhymeAITokens.Spacing.xs)
            .padding(.vertical, 3)
            .liquidGlassSurface(cornerRadius: RhymeAITokens.Radius.xs, fallbackOpacity: 0.08)
    }
}
