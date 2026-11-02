#if os(macOS)
import AppKit
import SwiftUI

/// The macOS lyrics editor: a non-scrolling TextKit 2 NSTextView sized to its
/// text inside the editor's SwiftUI ScrollView, as the UITextView is on iOS.
/// Plain text only, so copy and cut never put the syllable underline on the
/// pasteboard.
final class LyricsNSTextView: NSTextView {
    /// Set when this view replaces a focused one (the writing column is
    /// re-created per song open); it takes the focus as soon as it is on screen.
    var resumesEditingOnAttach = false
    var onFocusChange: ((Bool) -> Void)?
    /// A new width rewraps the lines, so drawn highlight rects go stale.
    var onWidthChange: (() -> Void)?

    /// ⌘Z and ⇧⌘Z drive the app's one lyric history (the toolbar's undo and
    /// redo), so "Use line", rewrites and toolbar steps are undone in the
    /// same order. AppKit's own text undo is off (`allowsUndo = false`).
    var historyUndo: (() -> Void)?
    var historyRedo: (() -> Void)?
    var canUndoHistory: () -> Bool = { false }
    var canRedoHistory: () -> Bool = { false }

    @objc func undo(_ sender: Any?) { historyUndo?() }
    @objc func redo(_ sender: Any?) { historyRedo?() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return canUndoHistory()
        case #selector(redo(_:)): return canRedoHistory()
        default: return super.validateUserInterfaceItem(item)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { onWidthChange?() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, resumesEditingOnAttach else { return }
        resumesEditingOnAttach = false
        window.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

struct LyricsTextView: NSViewRepresentable {
    @Environment(\.appAppearanceStyle) private var appearance
    @EnvironmentObject private var viewModel: EditorViewModel

    @Binding var text: String
    var selection: NSRange? = nil
    var displayText: String? = nil
    var rewriteHighlight: LyricsRewriteHighlight? = nil
    var insertionHighlight: NSRange? = nil
    var onCursorChange: (Int) -> Void
    var onSelectionChange: ((NSRange) -> Void)? = nil
    var onEditingChange: ((Bool) -> Void)? = nil
    var bottomOverlayHeight: CGFloat = 0
    var rhymeHighlightEnabled: Bool = false
    var syllableColoringEnabled: Bool = false
    var isEditable: Bool = true
    var placeholder: String = "Start writing your lyrics here..."
    var resumesEditingOnCreate: Bool = false

    static let lyricsFont = NSFont.systemFont(ofSize: 16, weight: .regular)

    func makeNSView(context: Context) -> LyricsNSTextView {
        let textView = LyricsNSTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.resumesEditingOnAttach = resumesEditingOnCreate
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.onEditingChange?(focused)
        }
        textView.onWidthChange = { [weak coordinator = context.coordinator] in
            coordinator?.refreshRewriteHighlight()
        }
        textView.historyUndo = { [weak viewModel] in viewModel?.undoLyrics() }
        textView.historyRedo = { [weak viewModel] in viewModel?.redoLyrics() }
        textView.canUndoHistory = { [weak viewModel, weak coordinator = context.coordinator] in
            coordinator?.parent.isEditable == true && viewModel?.canUndoLyrics == true
        }
        textView.canRedoHistory = { [weak viewModel, weak coordinator = context.coordinator] in
            coordinator?.parent.isEditable == true && viewModel?.canRedoLyrics == true
        }
        textView.font = Self.lyricsFont
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setAccessibilityIdentifier("lyricsEditor")
        applyAppearance(to: textView)
        context.coordinator.attach(to: textView)
        context.coordinator.updatePlaceholder(textView, text: renderedText)
        return textView
    }

    func updateNSView(_ textView: LyricsNSTextView, context: Context) {
        context.coordinator.parent = self
        let currentRenderedText = renderedText
        let textChanged = context.coordinator.shouldApplyText(currentRenderedText) && textView.string != currentRenderedText
        if textChanged {
            context.coordinator.updateRenderedText(currentRenderedText, in: textView, selection: selection)
        }
        if context.coordinator.shouldApplySelection(selection),
           textView.string == currentRenderedText,
           let selection, selection.location >= 0, selection.length >= 0,
           selection.location <= currentRenderedText.utf16.count,
           selection.length <= currentRenderedText.utf16.count - selection.location,
           textView.selectedRange() != selection, !textView.hasMarkedText() {
            context.coordinator.isApplyingProgrammaticUpdate = true
            textView.setSelectedRange(selection)
            context.coordinator.isApplyingProgrammaticUpdate = false
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if textView.isSelectable != isEditable {
            textView.isSelectable = isEditable
        }
        if context.coordinator.shouldApplyAppearance(appearance: appearance, isEditable: isEditable) {
            applyAppearance(to: textView)
        }
        context.coordinator.updateColors(textView)
        if context.coordinator.shouldUpdatePlaceholder(
            text: currentRenderedText,
            appearance: appearance,
            placeholder: placeholder
        ) {
            context.coordinator.updatePlaceholder(textView, text: currentRenderedText)
        }
        if context.coordinator.shouldUpdateRewriteHighlight(textChanged: textChanged, highlight: activeHighlight) {
            context.coordinator.updateRewriteHighlight(
                textView,
                highlight: activeHighlight,
                animation: Self.highlightClearAnimation(for: context.transaction)
            )
        }
        if context.coordinator.shouldKeepCursorVisible(
            textChanged: textChanged,
            selection: selection,
            bottomOverlayHeight: bottomOverlayHeight
        ) {
            context.coordinator.scheduleKeepCursorVisible()
        }
    }

    /// Height of the laid-out text at the offered width, so the view grows
    /// with the lyrics and the surrounding ScrollView does the scrolling.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: LyricsNSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = textView.textContainer,
              let layout = textView.textLayoutManager else { return nil }
        let laidOutSize = container.size
        if laidOutSize.width != width {
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: layout.documentRange)
        let usedHeight = layout.usageBoundsForTextContainer.height
        // A measuring pass at another width must not leave the lines wrapped
        // there: the container only re-tracks the view when its frame changes.
        if textView.frame.width > 0, textView.frame.width != width {
            container.size = laidOutSize
        }
        let lineHeight = (textView.font ?? Self.lyricsFont).boundingRectForFont.height
        let placeholderHeight = context.coordinator.placeholderHeight(forWidth: width)
        // Fill an offered height, like the UITextView, so a click below the
        // last line still lands in the editor.
        let offered = proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let height = max(usedHeight, lineHeight, placeholderHeight, offered)
        return CGSize(width: width, height: ceil(height))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func applyAppearance(to textView: NSTextView) {
        let foreground = NSColor(appearance.palette.primaryInk)
        textView.textColor = foreground
        textView.insertionPointColor = isEditable ? NSColor(appearance.palette.caret) : .clear
        textView.selectedTextAttributes = [.backgroundColor: NSColor(appearance.palette.selectionTint)]
        textView.typingAttributes[.foregroundColor] = foreground
        textView.appearance = NSAppearance(named: appearance == .graphite ? .darkAqua : .aqua)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        typealias ColorSpanProvider = @Sendable (
            _ text: String,
            _ rhymeEnabled: Bool,
            _ syllablesEnabled: Bool,
            _ isDark: Bool
        ) async -> [LyricsColorSpan]

        var parent: LyricsTextView
        private var placeholderLabel: NSTextField?
        private var rewriteHighlightView: RewriteHighlightOverlayView?
        private weak var textView: NSTextView?
        private var lastAppearance: AppAppearanceStyle?
        private var lastIsEditable: Bool?
        private var lastPlaceholderText: String?
        private var lastPlaceholderAppearance: AppAppearanceStyle?
        private var lastPlaceholder: String?
        private var lastRewriteHighlight: LyricsRewriteHighlight?
        private var lastSelection: NSRange?
        private var lastRequestedText: String?
        private var lastPublishedText: String?
        private var lastRequestedSelection: NSRange?
        private var lastPublishedSelection: NSRange?
        private var lastBottomOverlayHeight: CGFloat?
        private var colorTask: Task<Void, Never>?
        private var colorRequest: ColorRequest?
        private var appliedColorSpans: [LyricsColorSpan] = []
        private var appliedForeground: NSColor?
        private var appliedColorText: String?
        private var pendingColorEdit: (source: String, range: NSRange, replacement: String)?
        private let colorAnalysisDebounce: Duration
        private let colorSpanProvider: ColorSpanProvider
        private struct ColorRequest: Equatable {
            let text: String
            let rhyme: Bool
            let syllables: Bool
            let appearance: AppAppearanceStyle
        }
        var isApplyingProgrammaticUpdate = false
        /// The update in progress removes the "Use line" mark; only that mark fades.
        private var clearedInsertionHighlight = false

        init(
            _ parent: LyricsTextView,
            colorAnalysisDebounce: Duration = .milliseconds(120),
            colorSpanProvider: @escaping ColorSpanProvider = { text, rhyme, syllables, isDark in
                await LyricsHighlighting.spans(
                    text: text,
                    rhymeEnabled: rhyme,
                    syllablesEnabled: syllables,
                    isDark: isDark
                )
            }
        ) {
            self.parent = parent
            self.colorAnalysisDebounce = colorAnalysisDebounce
            self.colorSpanProvider = colorSpanProvider
        }

        deinit {
            colorTask?.cancel()
        }

        func attach(to textView: NSTextView) {
            self.textView = textView
            guard rewriteHighlightView == nil else { return }
            let view = RewriteHighlightOverlayView()
            view.translatesAutoresizingMaskIntoConstraints = false
            textView.addSubview(view)
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: textView.topAnchor),
                view.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: textView.bottomAnchor)
            ])
            rewriteHighlightView = view
        }

        func shouldApplyText(_ text: String) -> Bool {
            guard text != lastRequestedText else { return false }
            lastRequestedText = text
            defer { lastPublishedText = nil }
            // A binding echo may arrive between AppKit's edit and its delegate callback.
            return text != lastPublishedText
        }

        func updateRenderedText(_ renderedText: String, in textView: NSTextView, selection: NSRange? = nil) {
            isApplyingProgrammaticUpdate = true
            defer { isApplyingProgrammaticUpdate = false }
            let selectedRange = selection ?? textView.selectedRange()
            textView.string = renderedText
            if selectedRange.location >= 0,
               selectedRange.length >= 0,
               selectedRange.location <= renderedText.utf16.count,
               selectedRange.length <= renderedText.utf16.count - selectedRange.location {
                textView.setSelectedRange(selectedRange)
            }
            resetColorsAfterProgrammaticTextChange(textView)
            textView.invalidateIntrinsicContentSize()
        }

        func shouldApplySelection(_ selection: NSRange?) -> Bool {
            guard selection != lastRequestedSelection else { return false }
            lastRequestedSelection = selection
            defer { lastPublishedSelection = nil }
            return selection != lastPublishedSelection
        }

        func shouldApplyAppearance(appearance: AppAppearanceStyle, isEditable: Bool) -> Bool {
            let changed = lastAppearance != appearance || lastIsEditable != isEditable
            lastAppearance = appearance
            lastIsEditable = isEditable
            return changed
        }

        func shouldUpdatePlaceholder(text: String, appearance: AppAppearanceStyle, placeholder: String) -> Bool {
            let changed = lastPlaceholderText != text
                || lastPlaceholderAppearance != appearance
                || lastPlaceholder != placeholder
            lastPlaceholderText = text
            lastPlaceholderAppearance = appearance
            lastPlaceholder = placeholder
            return changed
        }

        func shouldUpdateRewriteHighlight(textChanged: Bool, highlight: LyricsRewriteHighlight?) -> Bool {
            let changed = textChanged || lastRewriteHighlight != highlight
            clearedInsertionHighlight = LyricsTextView.fadesOnClear(previous: lastRewriteHighlight, next: highlight)
            lastRewriteHighlight = highlight
            return changed
        }

        func shouldKeepCursorVisible(textChanged: Bool, selection: NSRange?, bottomOverlayHeight: CGFloat) -> Bool {
            let changed = textChanged
                || lastSelection != selection
                || lastBottomOverlayHeight != bottomOverlayHeight
            lastSelection = selection
            lastBottomOverlayHeight = bottomOverlayHeight
            return changed
        }

        func updateColors(_ textView: NSTextView) {
            guard !textView.hasMarkedText() else { return }
            let request = ColorRequest(text: textView.string, rhyme: parent.rhymeHighlightEnabled,
                                       syllables: parent.syllableColoringEnabled, appearance: parent.appearance)
            guard colorRequest != request else { return }
            let previousRequest = colorRequest
            colorRequest = request
            colorTask?.cancel()
            let foreground = NSColor(request.appearance.palette.primaryInk)
            if !request.rhyme && !request.syllables {
                installColors([], for: request.text, on: textView, foreground: foreground)
                return
            }
            let shouldCoalesceTextChange = previousRequest.map {
                $0.text != request.text
                    && $0.rhyme == request.rhyme
                    && $0.syllables == request.syllables
                    && $0.appearance == request.appearance
            } ?? false
            colorTask = Task { [weak self, weak textView] in
                guard let self else { return }
                if shouldCoalesceTextChange {
                    do {
                        try await Task.sleep(for: colorAnalysisDebounce)
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                let spans = await colorSpanProvider(
                    request.text,
                    request.rhyme,
                    request.syllables,
                    request.appearance == .graphite
                )
                guard !Task.isCancelled, let textView,
                      self.colorRequest == request, textView.string == request.text,
                      !textView.hasMarkedText() else { return }
                self.isApplyingProgrammaticUpdate = true
                self.installColors(spans, for: request.text, on: textView, foreground: foreground)
                self.isApplyingProgrammaticUpdate = false
            }
        }

        private func installColors(_ spans: [LyricsColorSpan], for text: String, on textView: NSTextView, foreground: NSColor) {
            appliedColorSpans = spans
            appliedForeground = foreground
            appliedColorText = text
            // Restyling the storage would end an in-progress composition.
            if !textView.hasMarkedText(), let storage = textView.textStorage {
                let selection = textView.selectedRange()
                if LyricsTextAttributes.applyUnderlines(spans, to: storage), textView.selectedRange() != selection {
                    textView.setSelectedRange(selection)
                }
                removeUnderlineFromTypingAttributes(textView)
            }
            guard let layout = textView.textLayoutManager else { return }
            LyricsTextAttributes.applyRenderingColors(
                spans,
                text: textView.string,
                storageLength: textView.textStorage?.length ?? 0,
                layout: layout,
                foreground: foreground,
                sectionLabelForeground: NSColor(parent.appearance.palette.secondaryInk)
            )
            textView.needsDisplay = true
        }

        private func resetColorsAfterProgrammaticTextChange(_ textView: NSTextView) {
            installColors([], for: textView.string, on: textView,
                          foreground: NSColor(parent.appearance.palette.primaryInk))
        }

        private func reconcileColorsAfterEdit(_ textView: NSTextView) {
            defer { pendingColorEdit = nil }
            guard let edit = pendingColorEdit,
                  appliedColorText == edit.source,
                  let foreground = appliedForeground,
                  let adjusted = LyricsTextAttributes.spansAfterEdit(
                      appliedColorSpans,
                      source: edit.source,
                      range: edit.range,
                      replacement: edit.replacement,
                      newText: textView.string
                  ) else { return }
            installColors(adjusted, for: textView.string, on: textView, foreground: foreground)
        }

        private func removeUnderlineFromTypingAttributes(_ textView: NSTextView) {
            guard let attributes = LyricsTextAttributes.removingUnderline(from: textView.typingAttributes) else { return }
            textView.typingAttributes = attributes
        }

        func updatePlaceholder(_ textView: NSTextView, text: String) {
            if placeholderLabel == nil {
                let label = NSTextField(wrappingLabelWithString: parent.placeholder)
                label.font = textView.font
                label.isSelectable = false
                label.drawsBackground = false
                label.isBezeled = false
                label.translatesAutoresizingMaskIntoConstraints = false
                textView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: textView.topAnchor),
                    label.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
                    label.widthAnchor.constraint(lessThanOrEqualTo: textView.widthAnchor)
                ])
                placeholderLabel = label
            }
            placeholderLabel?.stringValue = parent.placeholder
            placeholderLabel?.textColor = NSColor(parent.appearance.palette.placeholder)
            placeholderLabel?.isHidden = !text.isEmpty
        }

        func placeholderHeight(forWidth width: CGFloat) -> CGFloat {
            guard let placeholderLabel, !placeholderLabel.isHidden else { return 0 }
            placeholderLabel.preferredMaxLayoutWidth = width
            return placeholderLabel.fittingSize.height
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView, !isApplyingProgrammaticUpdate else { return }
            reconcileColorsAfterEdit(textView)
            let selectedRange = textView.selectedRange()
            lastPublishedSelection = selectedRange
            lastPublishedText = textView.string
            parent.text = textView.string
            parent.onCursorChange(selectedRange.location)
            parent.onSelectionChange?(selectedRange)
            updatePlaceholder(textView, text: textView.string)
            textView.invalidateIntrinsicContentSize()
            scheduleKeepCursorVisible()
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            pendingColorEdit = (textView.string, affectedCharRange, replacementString ?? "")
            removeUnderlineFromTypingAttributes(textView)
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // AppKit also posts this for programmatic resets. Only the writer's
            // own moves may change the app-level cursor.
            guard let textView = notification.object as? NSTextView,
                  textView.window?.firstResponder === textView,
                  !isApplyingProgrammaticUpdate else { return }
            let selectedRange = textView.selectedRange()
            lastPublishedSelection = selectedRange
            parent.onCursorChange(selectedRange.location)
            parent.onSelectionChange?(selectedRange)
            scheduleKeepCursorVisible()
        }

        // MARK: Highlight and scrolling

        func updateRewriteHighlight(_ textView: NSTextView, highlight: LyricsRewriteHighlight?, animation: Animation? = nil) {
            guard let rewriteHighlightView else { return }
            guard let highlight, highlight.range.length > 0 else {
                rewriteHighlightView.clear(animation: clearedInsertionHighlight ? animation : nil)
                return
            }
            DispatchQueue.main.async { [weak textView, weak rewriteHighlightView] in
                guard let textView, let rewriteHighlightView, self.lastRewriteHighlight == highlight else { return }
                rewriteHighlightView.configure(
                    rects: self.segmentRects(in: textView, range: highlight.range).map { $0.insetBy(dx: -3, dy: -2) },
                    isLoading: highlight.isLoading,
                    colors: RewriteHighlightColors.forHighlight(highlight, palette: self.parent.appearance.palette)
                )
            }
        }

        /// Redraws the shown highlight at the current wrap, after a width change.
        func refreshRewriteHighlight() {
            guard let textView, let highlight = lastRewriteHighlight, highlight.range.length > 0 else { return }
            updateRewriteHighlight(textView, highlight: highlight)
        }

        func scheduleKeepCursorVisible() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.textView else { return }
                self.keepCursorVisible(textView)
            }
        }

        /// Keeps the caret or selection in view and clear of the rewrite bar
        /// that overlays the bottom of the editor; the enclosing ScrollView
        /// does the moving. A Mac has no keyboard to wait for, so this runs
        /// whenever the editor has focus.
        private func keepCursorVisible(_ textView: NSTextView) {
            guard textView.window?.firstResponder === textView else { return }
            // The editor grows in SwiftUI's next layout pass; settle it first so
            // the new last line is inside the scrollable content.
            textView.window?.contentView?.layoutSubtreeIfNeeded()
            let selected = textView.selectedRange()
            let caretRange = selected.length > 0 ? selected : NSRange(location: selected.location, length: 0)
            let rects = segmentRects(in: textView, range: caretRange, caretFallback: true)
            guard let first = rects.first else { return }
            let rect = rects.dropFirst().reduce(first) { $0.union($1) }
            let clearance: CGFloat = selected.length > 0 ? 20 : 12
            textView.scrollToVisible(CGRect(
                x: rect.minX,
                y: rect.minY,
                width: max(rect.width, 1),
                height: rect.height + parent.bottomOverlayHeight + clearance
            ))
        }

        /// Glyph rects for `range` in the text view's coordinates.
        private func segmentRects(in textView: NSTextView, range: NSRange, caretFallback: Bool = false) -> [CGRect] {
            let length = (textView.string as NSString).length
            guard range.location >= 0, range.location + range.length <= length,
                  let layout = textView.textLayoutManager,
                  let content = layout.textContentManager,
                  let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end) else { return [] }
            layout.ensureLayout(for: textRange)
            let origin = textView.textContainerOrigin
            var rects: [CGRect] = []
            let type: NSTextLayoutManager.SegmentType = range.length == 0 && caretFallback ? .standard : .highlight
            layout.enumerateTextSegments(in: textRange, type: type, options: []) { _, frame, _, _ in
                rects.append(frame.offsetBy(dx: origin.x, dy: origin.y))
                return true
            }
            return rects
        }
    }
}

/// Draws the rewrite and insertion highlight: a rounded tint and a 1pt border
/// around the affected glyph rects. It is static by design; the rewrite bar
/// at the bottom of the editor carries the loading state.
final class RewriteHighlightOverlayView: NSView {
    private(set) var rects: [CGRect] = []
    private(set) var isLoading = false
    private(set) var colors: RewriteHighlightColors?

    /// Counts configurations so a fade's completion never erases a highlight
    /// that replaced it meanwhile.
    private var generation = 0

    override var isFlipped: Bool { true }

    // Clicks and drags reach the text view underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(rects: [CGRect], isLoading: Bool, colors: RewriteHighlightColors?) {
        generation += 1
        alphaValue = 1
        self.rects = rects
        self.isLoading = isLoading
        self.colors = colors
        needsDisplay = true
    }

    /// Clears the mark in one frame, or fades it on the transaction's
    /// animation (the "Use line" mark dries on `Motion.settle`).
    func clear(animation: Animation?) {
        guard let animation, !rects.isEmpty, alphaValue > 0 else {
            configure(rects: [], isLoading: false, colors: nil)
            return
        }
        generation += 1
        let fading = generation
        NSAnimationContext.animate(animation, changes: { [weak self] in
            self?.animator().alphaValue = 0
        }, completion: { [weak self] in
            guard let self, self.generation == fading else { return }
            self.configure(rects: [], isLoading: false, colors: nil)
        })
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let colors, !rects.isEmpty else { return }
        colors.fill.setFill()
        colors.stroke.setStroke()
        for highlightRect in rects {
            let path = NSBezierPath(
                roundedRect: highlightRect,
                xRadius: RhymeAITokens.Radius.xs,
                yRadius: RhymeAITokens.Radius.xs
            )
            path.lineWidth = 1
            path.fill()
            path.stroke()
        }
    }
}
#endif
