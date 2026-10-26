import SwiftUI

/// What one local-model row shows in Settings › On-Device, for a catalog download or an
/// imported custom model. Built from the download manager's state by `catalog` / `custom`;
/// drawn by `ModelRowView`. Android mirror: `ModelRow` in `SettingsDialog.kt`.
struct ModelRowContent: Equatable {
    enum Chip: String {
        case download = "Download", pause = "Pause", resume = "Resume"
        case use = "Use", selected = "Selected", update = "Update"
    }

    enum Column: Equatable { case empty, cancel, trash, spinner }

    /// The download line: the ghost loop while no bytes have come, else written to a fraction.
    enum Line: Equatable { case none, ghost, written(Double) }

    var title: String
    var metadata: String
    /// The whole metadata is a warning (a stale file), drawn in the warning colour with its glyph.
    var metadataIsWarning = false
    /// A warning on its own line under the metadata (the memory gate).
    var warning: String?
    var chip: Chip?
    var column: Column = .empty
    var line: Line = .none
    var strike = false
    var isSelected = false
    /// False while checking or deleting: the row is not a button then.
    var isEnabled = true
    var accessibilityLabel: String
    var accessibilityValue: String
    var updatesFrequently = false

    static let memoryWarning = "Writes slowly: needs 10 GB"

    /// Everything about one entry the row depends on, read from the manager.
    struct Facts: Equatable {
        var bytesOnDisk: Int64?
        var isInstalled = false
        var isSelected = false
        var isActive = false
        var isVerifying = false
        var receivedBytes: Int64 = 0
        var pausedBytes: Int64?
        var isDeleting = false
        var freedBytes: Int64?
        var needsMoreMemory = false
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "1.47 of 3.43 GB"; the unit is said once when both sides share it.
    static func progress(_ received: Int64, of total: Int64) -> String {
        let part = size(received)
        let whole = size(total)
        let unit = whole.split(separator: " ").last.map(String.init) ?? ""
        if !unit.isEmpty, part.hasSuffix(" \(unit)") {
            return "\(part.dropLast(unit.count + 1)) of \(whole)"
        }
        return "\(part) of \(whole)"
    }

    static func catalog(_ option: GGUFDownloadOption, facts: Facts) -> ModelRowContent {
        let title = option.title
        let total = size(facts.bytesOnDisk ?? option.expectedBytes)
        let gate = facts.needsMoreMemory ? memoryWarning : nil
        let gateValue = facts.needsMoreMemory ? ", Writes slowly, needs 10 GB memory" : ""
        if facts.isDeleting {
            return ModelRowContent(title: title, metadata: "Deleting…", column: .spinner, strike: true,
                                   isEnabled: false, accessibilityLabel: title, accessibilityValue: "Deleting")
        }
        if facts.isActive, facts.isVerifying {
            return ModelRowContent(title: title, metadata: "Checking the file…", line: .written(1), isEnabled: false,
                                   accessibilityLabel: title, accessibilityValue: "Checking the file")
        }
        if facts.isActive, facts.receivedBytes <= 0 {
            return ModelRowContent(title: title, metadata: "Starting download…", chip: .pause, column: .cancel, line: .ghost,
                                   accessibilityLabel: "Pause download of \(title)", accessibilityValue: "Starting download",
                                   updatesFrequently: true)
        }
        if facts.isActive {
            let fraction = min(1, Double(facts.receivedBytes) / Double(option.expectedBytes))
            let percent = Int(fraction * 100)
            let done = progress(facts.receivedBytes, of: option.expectedBytes)
            return ModelRowContent(title: title, metadata: "\(done) · \(percent)%", chip: .pause, column: .cancel,
                                   line: .written(fraction), accessibilityLabel: "Pause download of \(title)",
                                   accessibilityValue: "\(percent) percent, \(done)", updatesFrequently: true)
        }
        if let paused = facts.pausedBytes {
            let done = progress(paused, of: option.expectedBytes)
            return ModelRowContent(title: title, metadata: "Paused · \(done)", chip: .resume, column: .cancel,
                                   line: .written(min(1, Double(paused) / Double(option.expectedBytes))),
                                   accessibilityLabel: "Resume download of \(title)", accessibilityValue: "Paused, \(done)",
                                   updatesFrequently: true)
        }
        if let freed = facts.freedBytes, facts.bytesOnDisk == nil {
            let line = "\(size(freed)) back for your songs"
            return ModelRowContent(title: title, metadata: line, chip: .download,
                                   accessibilityLabel: "Download \(title)", accessibilityValue: line)
        }
        if facts.isInstalled, facts.isSelected {
            return ModelRowContent(title: title, metadata: "In use · \(total) on this device", warning: gate, chip: .selected,
                                   column: .trash, isSelected: true, accessibilityLabel: title,
                                   accessibilityValue: "In use, \(total) on this device\(gateValue)")
        }
        if facts.isInstalled {
            return ModelRowContent(title: title, metadata: "\(option.character) · \(total) on this device", warning: gate,
                                   chip: .use, column: .trash, accessibilityLabel: "Use \(title)",
                                   accessibilityValue: "\(option.character), \(total) on this device\(gateValue)")
        }
        if facts.bytesOnDisk != nil {
            return ModelRowContent(title: title, metadata: "Older version on this device", metadataIsWarning: true,
                                   chip: .update, column: .trash, accessibilityLabel: "Update \(title)",
                                   accessibilityValue: "Older version on this device")
        }
        let recommended = option.isRecommended ? " · Recommended" : ""
        return ModelRowContent(title: title, metadata: "\(option.character) · \(total)\(recommended)", warning: gate,
                               chip: .download, accessibilityLabel: "Download \(title)",
                               accessibilityValue: "\(option.character), \(total)\(option.isRecommended ? ", Recommended" : "")\(gateValue)")
    }

    static func custom(_ model: GGUFCustomModel, facts: Facts) -> ModelRowContent {
        let title = model.displayName
        let total = size(facts.bytesOnDisk ?? 0)
        if facts.isDeleting {
            return ModelRowContent(title: title, metadata: "Deleting…", column: .spinner, strike: true,
                                   isEnabled: false, accessibilityLabel: title, accessibilityValue: "Deleting")
        }
        if facts.isSelected {
            return ModelRowContent(title: title, metadata: "In use · \(total) on this device", chip: .selected,
                                   column: .trash, isSelected: true, accessibilityLabel: title,
                                   accessibilityValue: "In use, \(total) on this device")
        }
        return ModelRowContent(title: title, metadata: "Imported · \(total) on this device", chip: .use, column: .trash,
                               accessibilityLabel: "Use \(title)", accessibilityValue: "Imported, \(total) on this device")
    }

    /// The confirmation's message; the in-use sentence only when the model is selected.
    static func deleteMessage(bytes: Int64, isCustom: Bool, inUse: Bool) -> String {
        "Frees \(size(bytes)) on this device. You can \(isCustom ? "import" : "download") it again later."
            + (inUse ? " It's in use now; on-device suggestions stop until you choose another model." : "")
    }
}

/// The row's motion decisions, so the Reduce Motion fallbacks are explicit.
enum ModelRowMotion {
    /// The ghost line's progress: the suggestion ghost's loop on one line, or its still
    /// frame (drawn 60% along) under Reduce Motion.
    static func ghostProgress(elapsed: TimeInterval, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? SuggestionInkLineMotion.stillProgress.second : SuggestionInkLineMotion.singleLineProgress(elapsed: elapsed)
    }

    /// Choosing a model shows wet ink first unless Reduce Motion goes straight to the dry chip.
    static func beginsWet(reduceMotion: Bool) -> Bool { !reduceMotion }

    /// How far the strike is drawn when it appears: whole at once under Reduce Motion.
    static func strikeStart(reduceMotion: Bool) -> CGFloat { reduceMotion ? 1 : 0 }

    /// How long the wet chip holds before it dries: the Use-line highlight's hold.
    static let wetHold = EditorViewConstants.InsertionHighlight.holdDuration

    /// One even wave across `width`: a sine with one crest and trough every `period`, filling
    /// `height`, so every crest has the same height and spacing (Android `evenWavePath`).
    static func evenWavePoints(width: CGFloat, period: CGFloat = RhymeAITokens.ModelRow.wavePeriod,
                               height: CGFloat = RhymeAITokens.ModelRow.waveHeight) -> [CGPoint] {
        guard width > 0, period > 0 else { return [] }
        let steps = max(1, Int(width / 2))
        return (0...steps).map { step in
            let x = width * CGFloat(step) / CGFloat(steps)
            return CGPoint(x: x, y: height / 2 - height / 2 * sin(2 * .pi * x / period))
        }
    }
}

/// Text column at the major golden share of the row (61.8%), the chip centred in the rest
/// beside the 55pt column the caller adds. The text gives way first: the chip's cell never
/// gets narrower than the chip. One subview (accessibility sizes, chip moved under the
/// metadata) takes the whole width. The height is the row's 89 unless the text needs more.
private struct ModelRowSplit: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let textWidth = textWidth(in: width, subviews: subviews)
        let textHeight = subviews.first?.sizeThatFits(ProposedViewSize(width: textWidth, height: nil)).height ?? 0
        return CGSize(width: width, height: max(RhymeAITokens.ModelRow.height, textHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let textWidth = textWidth(in: bounds.width, subviews: subviews)
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: textWidth, height: bounds.height))
        guard subviews.count > 1 else { return }
        let cell = bounds.width - textWidth
        let chip = subviews[1].sizeThatFits(ProposedViewSize(width: cell, height: nil))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + textWidth + (cell - chip.width) / 2, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: cell, height: nil)
        )
    }

    private func textWidth(in width: CGFloat, subviews: Subviews) -> CGFloat {
        guard subviews.count > 1 else { return width }
        let row = width + RhymeAITokens.ModelRow.column
        let chip = subviews[1].sizeThatFits(.unspecified).width
        return max(0, min((row * RhymeAITokens.inversePhi).rounded(), width - chip))
    }
}

/// The row's even wave, drawn tip first to `progress` (the download line, the strike).
private struct ModelRowWave: Shape {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addLines(ModelRowMotion.evenWavePoints(width: rect.width, height: rect.height))
        return path.offsetBy(dx: rect.minX, dy: rect.minY).trimmedPath(from: 0, to: progress)
    }
}

struct ModelRowView: View {
    @Environment(\.appAppearanceStyle) private var appearance
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let content: ModelRowContent
    /// Off while another download, a pause, a check or a delete holds the manager.
    var isEnabled = true
    var isColumnEnabled = true
    /// Just chosen: the Selected chip shows wet ink until it dries.
    var isWet = false
    let identifier: String
    let columnIdentifier: String
    let action: () -> Void
    let columnAction: () -> Void

    private typealias Tokens = RhymeAITokens.ModelRow
    @State private var strikeDrawn: CGFloat = 0
    @State private var strikeOpacity: Double = 0

    var body: some View {
        let palette = appearance.palette
        let stacked = dynamicTypeSize.isAccessibilitySize
        let shape = RoundedRectangle(cornerRadius: RhymeAITokens.Radius.lg, style: .continuous)
        HStack(spacing: 0) {
            Button(action: action) {
                ModelRowSplit {
                    textColumn(stacked: stacked)
                    if !stacked { chipCell }
                }
            }
            .buttonStyle(.rhymePress)
            .disabled(!isEnabled || !content.isEnabled)
            .accessibilityLabel(content.accessibilityLabel)
            .accessibilityValue(content.accessibilityValue)
            .accessibilityAddTraits(content.isSelected ? .isSelected : [])
            .accessibilityAddTraits(content.updatesFrequently ? .updatesFrequently : [])
            .accessibilityIdentifier(identifier)

            column
        }
        // The column takes the row's full height (a 55 × 89 target), whatever the text needs.
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: Tokens.height)
        .background(palette.surface, in: shape)
        .overlay {
            shape.strokeBorder(content.isSelected ? palette.primaryInk : palette.outline, lineWidth: 1)
                .rhymeAnimation(RhymeAITokens.Motion.feedback, value: content.isSelected)
        }
        .accessibilityElement(children: .contain)
        .coordinateSpace(.named(identifier))
    }

    // MARK: Text column

    private func textColumn(stacked: Bool) -> some View {
        let palette = appearance.palette
        return VStack(alignment: .leading, spacing: RhymeAITokens.Spacing.xxs) {
            Text(content.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.primaryInk)
                .textRenderer(ModelRowStrikeRenderer(drawn: strikeDrawn, opacity: strikeOpacity, ink: palette.secondaryInk))
                .onAppear { if content.strike { beginStrike() } }
                .onChange(of: content.strike) { _, struck in struck ? beginStrike() : endStrike() }
                .modelRowProbe(identifier, "title")
            ZStack(alignment: .topLeading) {
                // Reserved whatever the state: two caption lines, or one line with the wave a φ
                // step under it, so the title holds still while the copy changes.
                Text(verbatim: " \n ").font(.caption).hidden()
                VStack(spacing: Tokens.waveGap) {
                    Text(verbatim: " ").font(.caption)
                    Color.clear.frame(height: Tokens.waveHeight)
                }
                .hidden()
                // The wave is laid out under the copy, so copy that wraps (large text) pushes it,
                // and anything below it, down rather than under it.
                VStack(alignment: .leading, spacing: Tokens.waveGap) {
                    metadata
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modelRowProbe(identifier, "metadata")
                    if content.line != .none {
                        progressLine.transition(.opacity)
                    }
                }
                .rhymeAnimation(RhymeAITokens.Motion.dismiss, value: content.line == .none)
            }
            if stacked, content.chip != nil {
                chipCell
                    .padding(.top, RhymeAITokens.Spacing.xxs)
                    .modelRowProbe(identifier, "chip")
            }
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, RhymeAITokens.Rhythm.standard)
        .padding(.trailing, RhymeAITokens.Rhythm.tight)
        .padding(.vertical, RhymeAITokens.Rhythm.related)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var metadata: some View {
        let palette = appearance.palette
        return VStack(alignment: .leading, spacing: 0) {
            // New copy fades in on the state tier and the old fades out on the dismiss tier.
            ZStack(alignment: .topLeading) {
                Group {
                    if content.metadataIsWarning {
                        warningLabel(content.metadata)
                    } else {
                        Text(content.metadata).foregroundStyle(palette.secondaryInk)
                    }
                }
                .id(content.metadata)
                .transition(swap)
            }
            .rhymeAnimation(RhymeAITokens.Motion.state, value: content.metadata)
            if let warning = content.warning {
                warningLabel(warning)
            }
        }
        .font(.caption)
    }

    private func warningLabel(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
        }
        .labelStyle(ModelRowWarningLabelStyle())
        .foregroundStyle(appearance.palette.warning)
    }

    /// The download wave under the progress copy, across the text column: one even wave whose
    /// written share is primary ink and the rest placeholder ink; while no bytes have come the
    /// ghost's one-line loop writes it. Hidden from assistive technology; the row's value
    /// carries progress.
    private var progressLine: some View {
        let palette = appearance.palette
        return ZStack {
            ModelRowWave(progress: 1)
                .stroke(palette.placeholder, style: Self.waveStroke)
            switch content.line {
            case .ghost:
                ModelRowGhostLine(ink: palette.primaryInk)
            case .written(let fraction):
                ModelRowWrittenLine(fraction: CGFloat(fraction), ink: palette.primaryInk)
            case .none:
                EmptyView()
            }
        }
        .frame(height: Tokens.waveHeight)
        .frame(maxWidth: .infinity)
        .modelRowProbe(identifier, "wave")
        .accessibilityHidden(true)
    }

    /// The strike draws tip first on the state tier, or whole at once under Reduce Motion.
    private func beginStrike() {
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) {
            strikeOpacity = 1
            strikeDrawn = ModelRowMotion.strikeStart(reduceMotion: reduceMotion)
        }
        withRhymeAnimation(RhymeAITokens.Motion.state, reduceMotion: reduceMotion) { strikeDrawn = 1 }
    }

    /// It leaves on the dismiss tier, or in one frame under Reduce Motion.
    private func endStrike() {
        guard !reduceMotion else {
            strikeOpacity = 0
            strikeDrawn = 0
            return
        }
        withAnimation(RhymeAITokens.Motion.dismiss) { strikeOpacity = 0 } completion: { strikeDrawn = 0 }
    }

    static let waveStroke = StrokeStyle(lineWidth: SuggestionInkLineMotion.strokeWidth, lineCap: .round, lineJoin: .round)

    // MARK: Chip

    private var chipCell: some View {
        ZStack {
            if let chip = content.chip {
                Text(chip.rawValue)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.opacity)
                    .padding(.horizontal, RhymeAITokens.Rhythm.tight)
                    .frame(minHeight: Tokens.chipHeight)
                    .modifier(ModelRowChipInk(
                        chip: chip,
                        wetness: chip == .selected && isWet ? 1 : 0,
                        palette: appearance.palette
                    ))
                    .transition(swap)
            }
        }
        .rhymeAnimation(RhymeAITokens.Motion.state, value: content.chip)
        .accessibilityHidden(true)
    }

    // MARK: Column

    @ViewBuilder
    private var column: some View {
        let palette = appearance.palette
        ZStack {
            switch content.column {
            case .empty:
                Color.clear
            case .cancel:
                columnButton(systemImage: "xmark", label: "Cancel download of \(content.title)")
            case .trash:
                columnButton(systemImage: "trash", label: "Delete \(content.title)")
            case .spinner:
                // The status element spans the column, like the buttons it replaces.
                Color.clear
                    .overlay { ProgressView().controlSize(.small).tint(palette.secondaryInk) }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Deleting \(content.title)")
                    .accessibilityAddTraits(.updatesFrequently)
                    .transition(swap)
            }
        }
        .frame(width: Tokens.column)
        .frame(maxHeight: .infinity)
        .rhymeAnimation(RhymeAITokens.Motion.state, value: content.column)
    }

    private func columnButton(systemImage: String, label: String) -> some View {
        Button(action: columnAction) {
            Image(systemName: systemImage)
                .font(.system(size: Tokens.glyph))
                .foregroundStyle(appearance.palette.secondaryInk)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.rhymePress)
        .disabled(!isColumnEnabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(columnIdentifier)
        .transition(swap)
    }

    /// A chip or glyph arriving fades in on the state tier and one leaving fades out on the
    /// dismiss tier, in place; one frame under Reduce Motion.
    private var swap: AnyTransition {
        reduceMotion ? .identity : .asymmetric(
            insertion: .opacity.animation(RhymeAITokens.Motion.state),
            removal: .opacity.animation(RhymeAITokens.Motion.dismiss)
        )
    }
}

/// Glyph beside the text's first line, 4pt apart, so a wrapped warning hangs under its words.
private struct ModelRowWarningLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: RhymeAITokens.Spacing.xxs) {
            configuration.icon
            configuration.title
        }
    }
}

/// Outlined action chip; the Selected chip is wet ink (1) drying to the selection fill (0),
/// its label flipping from on-primary to ink at the halfway point.
private struct ModelRowChipInk: ViewModifier, Animatable {
    let chip: ModelRowContent.Chip
    var wetness: Double
    let palette: AppAppearancePalette

    var animatableData: Double {
        get { wetness }
        set { wetness = newValue }
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: RhymeAITokens.Radius.sm, style: .continuous)
        if chip == .selected {
            content
                .foregroundStyle(wetness > 0.5 ? palette.onAction : palette.primaryInk)
                .background(palette.selectionTint.mix(with: palette.primaryInk, by: wetness), in: shape)
        } else {
            content
                .foregroundStyle(palette.primaryInk)
                .overlay { shape.strokeBorder(palette.outlineStrong, lineWidth: 1) }
        }
    }
}

/// The written share of the download line. Each step forward is drawn on the feedback tier;
/// a step back (a resume that restarted lower) is shown at once, never animated backwards.
private struct ModelRowWrittenLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: CGFloat
    let ink: Color
    @State private var shown: CGFloat?

    var body: some View {
        ModelRowWave(progress: shown ?? fraction)
            .stroke(ink, style: ModelRowView.waveStroke)
            .onChange(of: fraction) { old, new in
                if new > old {
                    withRhymeAnimation(RhymeAITokens.Motion.feedback, reduceMotion: reduceMotion) { shown = new }
                } else {
                    var jump = Transaction(animation: nil)
                    jump.disablesAnimations = true
                    withTransaction(jump) { shown = new }
                }
            }
    }
}

/// The ghost loop on one line, on its own clock from when it appeared; a still frame
/// under Reduce Motion.
private struct ModelRowGhostLine: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let ink: Color
    @State private var appeared = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            ModelRowWave(
                progress: ModelRowMotion.ghostProgress(elapsed: context.date.timeIntervalSince(appeared), reduceMotion: reduceMotion)
            )
            .stroke(ink, style: ModelRowView.waveStroke)
        }
    }
}

/// Draws the title, then the delete strike across its first line as laid out, so a wrapped
/// title is struck only as far as its first line runs. Text drawn this way is not read by
/// assistive technology beyond the title itself.
private struct ModelRowStrikeRenderer: TextRenderer, Animatable {
    var drawn: CGFloat
    var opacity: Double
    let ink: Color

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(drawn, opacity) }
        set {
            drawn = newValue.first
            opacity = newValue.second
        }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout { context.draw(line) }
        guard drawn > 0, opacity > 0, let first = layout.first else { return }
        let bounds = first.typographicBounds.rect
        let height = RhymeAITokens.ModelRow.waveHeight
        let rect = CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
        context.opacity = opacity
        context.stroke(
            ModelRowWave(progress: drawn).path(in: rect),
            with: .color(ink),
            style: ModelRowView.waveStroke
        )
    }
}

extension View {
    /// Records this part's frame in its row for `ModelRowTests` (debug builds only).
    func modelRowProbe(_ row: String, _ part: String) -> some View {
        #if DEBUG
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(row)) } action: { frame in
            ModelRowLayoutProbe.frames["\(row).\(part)"] = frame
        }
        #else
        self
        #endif
    }
}

#if DEBUG
/// Laid-out frames of row parts by "<row identifier>.<part>", in the row's coordinates.
@MainActor
enum ModelRowLayoutProbe {
    static var frames: [String: CGRect] = [:]
}

extension ModelRowContent {
    /// Every row state, built through the same resolver, for `UITestFlags.modelRowGallery`.
    static var gallery: [(content: ModelRowContent, isWet: Bool)] {
        let e2b = GGUFDownloadCatalog.options[0]
        let e4b = GGUFDownloadCatalog.options[1]
        let received: Int64 = 1_474_000_000
        let custom = GGUFCustomModel(id: "gallery", displayName: "Night Drive QA", fileName: "gallery.gguf")
        let rows: [(ModelRowContent, Bool)] = [
            (catalog(e2b, facts: Facts()), false),
            (catalog(e2b, facts: Facts(isActive: true)), false),
            (catalog(e2b, facts: Facts(isActive: true, receivedBytes: received)), false),
            (catalog(e2b, facts: Facts(pausedBytes: received)), false),
            (catalog(e2b, facts: Facts(isActive: true, isVerifying: true)), false),
            (catalog(e2b, facts: Facts(bytesOnDisk: e2b.expectedBytes, isInstalled: true)), false),
            (catalog(e2b, facts: Facts(bytesOnDisk: e2b.expectedBytes, isInstalled: true, isSelected: true)), true),
            (catalog(e2b, facts: Facts(bytesOnDisk: e2b.expectedBytes, isInstalled: true, isSelected: true)), false),
            (catalog(e2b, facts: Facts(bytesOnDisk: 3_427_878_784)), false),
            (catalog(e4b, facts: Facts(needsMoreMemory: true)), false),
            (catalog(e4b, facts: Facts(bytesOnDisk: e4b.expectedBytes, isInstalled: true, isSelected: true, needsMoreMemory: true)), false),
            (catalog(e4b, facts: Facts(bytesOnDisk: e4b.expectedBytes, isInstalled: true, needsMoreMemory: true)), false),
            (catalog(e2b, facts: Facts(bytesOnDisk: e2b.expectedBytes, isInstalled: true, isDeleting: true)), false),
            (catalog(e2b, facts: Facts(freedBytes: e2b.expectedBytes)), false),
            (ModelRowContent.custom(custom, facts: Facts(bytesOnDisk: 812_000_000)), false),
            (ModelRowContent.custom(custom, facts: Facts(bytesOnDisk: 812_000_000, isSelected: true)), false),
        ]
        return rows.map { (content: $0.0, isWet: $0.1) }
    }
}
#endif
