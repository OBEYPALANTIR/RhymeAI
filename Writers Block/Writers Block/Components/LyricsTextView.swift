import CoreText
import SwiftUI
import UIKit

struct LyricsRewriteHighlight: Equatable {
    let range: NSRange
    let isLoading: Bool
    let isError: Bool
    var isInsertion: Bool = false
}

/// Lyrics leave the editor as plain text: the stock copy and cut would put the
/// storage's font and colour on the pasteboard as rich text.
final class LyricsUITextView: UITextView {
    /// Set when this view replaces a focused one (the writing column is
    /// re-created per song open); it takes the focus as soon as it is on screen.
    var resumesEditingOnAttach = false
    /// Called when a new width re-wraps the lines, so the syllable underline can follow.
    var onWidthChange: (() -> Void)?
    private var laidOutWidth: CGFloat?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard laidOutWidth != bounds.width else { return }
        laidOutWidth = bounds.width
        onWidthChange?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, resumesEditingOnAttach else { return }
        resumesEditingOnAttach = false
        becomeFirstResponder()
    }

    override func copy(_ sender: Any?) {
        let copied = selectedTextRange.flatMap(text(in:))
        super.copy(sender)
        if let copied, !copied.isEmpty { UIPasteboard.general.string = copied }
    }

    override func cut(_ sender: Any?) {
        let removed = selectedTextRange.flatMap(text(in:))
        super.cut(sender)
        if let removed, !removed.isEmpty { UIPasteboard.general.string = removed }
    }
}

struct LyricsTextView: UIViewRepresentable {
    @Environment(\.appAppearanceStyle) private var appearance

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
    /// The writing column is re-created for each song open (its cross-fade);
    /// a focused editor stays focused across it, as the one text view did before.
    var resumesEditingOnCreate: Bool = false

    func makeUIView(context: Context) -> UITextView {
        let textView = LyricsUITextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.resumesEditingOnAttach = resumesEditingOnCreate
        Self.configureTypography(textView)
        textView.backgroundColor = .clear
        applyAppearance(to: textView)
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.accessibilityIdentifier = "lyricsEditor"
        context.coordinator.attach(to: textView)
        context.coordinator.updatePlaceholder(textView, text: renderedText)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        let currentRenderedText = renderedText
        let textChanged = context.coordinator.shouldApplyText(currentRenderedText) && textView.text != currentRenderedText
        if textChanged {
            context.coordinator.updateRenderedText(currentRenderedText, in: textView, selection: selection)
        }
        if context.coordinator.shouldApplySelection(selection),
           textView.text == currentRenderedText,
           let selection, selection.location >= 0, selection.length >= 0,
           selection.location <= currentRenderedText.utf16.count,
           selection.length <= currentRenderedText.utf16.count - selection.location,
           textView.selectedRange != selection, textView.markedTextRange == nil {
            context.coordinator.isApplyingProgrammaticUpdate = true
            textView.selectedRange = selection
            context.coordinator.isApplyingProgrammaticUpdate = false
        }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if textView.isSelectable != isEditable {
            textView.isSelectable = isEditable
        }
        if context.coordinator.shouldApplyAppearance(
            appearance: appearance,
            isEditable: isEditable
        ) {
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
        if context.coordinator.shouldUpdateRewriteHighlight(
            textChanged: textChanged,
            highlight: activeHighlight
        ) {
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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func lyricsFont(for contentSizeCategory: UIContentSizeCategory) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(
            for: UIFont.systemFont(ofSize: 16, weight: .regular),
            compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSizeCategory)
        )
    }

    static func configureTypography(
        _ textView: UITextView,
        contentSizeCategory: UIContentSizeCategory? = nil
    ) {
        let category = contentSizeCategory ?? textView.traitCollection.preferredContentSizeCategory
        textView.adjustsFontForContentSizeCategory = true
        textView.font = lyricsFont(for: category == .unspecified ? .large : category)
    }

    private var renderedText: String {
        displayText ?? text
    }

    /// The animation a highlight clear may fade on: the transaction's own, or
    /// none when animations are disabled (Reduce Motion) or absent.
    static func highlightClearAnimation(for transaction: Transaction) -> Animation? {
        transaction.disablesAnimations ? nil : transaction.animation
    }

    /// Only a cleared "Use line" mark fades; the rewrite highlight clears in one frame.
    static func fadesOnClear(previous: LyricsRewriteHighlight?, next: LyricsRewriteHighlight?) -> Bool {
        next == nil && previous?.isInsertion == true
    }

    private var activeHighlight: LyricsRewriteHighlight? {
        rewriteHighlight ?? insertionHighlight.map {
            LyricsRewriteHighlight(range: $0, isLoading: false, isError: false, isInsertion: true)
        }
    }

    private func applyAppearance(to textView: UITextView) {
        let foreground = UIColor(appearance.palette.primaryInk)
        textView.textColor = foreground
        textView.tintColor = isEditable ? UIColor(appearance.palette.caret) : .clear
        textView.keyboardAppearance = appearance == .graphite ? .dark : .light
        textView.typingAttributes[.foregroundColor] = foreground
    }

    class Coordinator: NSObject, UITextViewDelegate {
        typealias ColorSpanProvider = @Sendable (
            _ text: String,
            _ rhymeEnabled: Bool,
            _ syllablesEnabled: Bool,
            _ isDark: Bool
        ) async -> [LyricsColorSpan]

        var parent: LyricsTextView
        private var placeholderLabel: UILabel?
        private var rewriteHighlightView: RewriteHighlightOverlayView?
        private weak var textView: UITextView?
        private var isObservingKeyboard = false
        private var keyboardFrameInScreen: CGRect = .zero
        private var isKeyboardVisible = false
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
        private(set) var underlineView: SyllableUnderlineView?
        /// The spans on screen. An edit moves them with the text at once and the
        /// next analysis replaces them, so a word never loses its colour in between.
        private(set) var appliedColorSpans: [LyricsColorSpan] = []
        private var appliedForeground: UIColor?
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
            NotificationCenter.default.removeObserver(self)
        }

        func attach(to textView: UITextView) {
            self.textView = textView
            if rewriteHighlightView == nil {
                let view = RewriteHighlightOverlayView()
                view.backgroundColor = .clear
                view.isUserInteractionEnabled = false
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
            if underlineView == nil {
                let view = SyllableUnderlineView()
                view.translatesAutoresizingMaskIntoConstraints = false
                // Behind the text, so descenders and the selection draw over the line.
                textView.insertSubview(view, at: 0)
                NSLayoutConstraint.activate([
                    view.topAnchor.constraint(equalTo: textView.topAnchor),
                    view.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
                    view.bottomAnchor.constraint(equalTo: textView.bottomAnchor)
                ])
                underlineView = view
                (textView as? LyricsUITextView)?.onWidthChange = { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.refreshUnderlines(textView, animated: false)
                }
            }

            guard !isObservingKeyboard else { return }
            isObservingKeyboard = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardWillChangeFrame),
                name: UIResponder.keyboardWillChangeFrameNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(keyboardWillHide),
                name: UIResponder.keyboardWillHideNotification,
                object: nil
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(contentSizeCategoryDidChange),
                name: UIContentSizeCategory.didChangeNotification,
                object: nil
            )
        }

        func shouldApplyText(_ text: String) -> Bool {
            guard text != lastRequestedText else { return false }
            lastRequestedText = text
            defer { lastPublishedText = nil }
            // A binding echo may arrive between UIKit's edit and its delegate callback.
            return text != lastPublishedText
        }

        func updateRenderedText(_ renderedText: String, in textView: UITextView, selection: NSRange? = nil) {
            isApplyingProgrammaticUpdate = true
            defer { isApplyingProgrammaticUpdate = false }
            let selectedRange = selection ?? textView.selectedRange
            textView.text = renderedText
            // Restore the whole range only when it still fits the new text.
            if selectedRange.location >= 0,
               selectedRange.length >= 0,
               selectedRange.location <= renderedText.utf16.count,
               selectedRange.length <= renderedText.utf16.count - selectedRange.location {
                textView.selectedRange = selectedRange
            }
            resetColorsAfterProgrammaticTextChange(textView)
        }

        func shouldApplySelection(_ selection: NSRange?) -> Bool {
            guard selection != lastRequestedSelection else { return false }
            lastRequestedSelection = selection
            defer { lastPublishedSelection = nil }
            return selection != lastPublishedSelection
        }

        func shouldApplyAppearance(
            appearance: AppAppearanceStyle,
            isEditable: Bool
        ) -> Bool {
            let changed = lastAppearance != appearance
                || lastIsEditable != isEditable
            lastAppearance = appearance
            lastIsEditable = isEditable
            return changed
        }

        func shouldUpdatePlaceholder(
            text: String,
            appearance: AppAppearanceStyle,
            placeholder: String
        ) -> Bool {
            let changed = lastPlaceholderText != text
                || lastPlaceholderAppearance != appearance
                || lastPlaceholder != placeholder
            lastPlaceholderText = text
            lastPlaceholderAppearance = appearance
            lastPlaceholder = placeholder
            return changed
        }

        func shouldUpdateRewriteHighlight(
            textChanged: Bool,
            highlight: LyricsRewriteHighlight?
        ) -> Bool {
            let changed = textChanged || lastRewriteHighlight != highlight
            clearedInsertionHighlight = LyricsTextView.fadesOnClear(previous: lastRewriteHighlight, next: highlight)
            lastRewriteHighlight = highlight
            return changed
        }

        /// The update in progress removes the "Use line" mark; only that mark fades.
        private var clearedInsertionHighlight = false

        func shouldKeepCursorVisible(
            textChanged: Bool,
            selection: NSRange?,
            bottomOverlayHeight: CGFloat
        ) -> Bool {
            let changed = textChanged
                || lastSelection != selection
                || lastBottomOverlayHeight != bottomOverlayHeight
            lastSelection = selection
            lastBottomOverlayHeight = bottomOverlayHeight
            return changed
        }

        func updateColors(_ textView: UITextView) {
            guard textView.markedTextRange == nil else { return }
            let request = ColorRequest(text: textView.text, rhyme: parent.rhymeHighlightEnabled,
                                       syllables: parent.syllableColoringEnabled, appearance: parent.appearance)
            guard colorRequest != request else { return }
            let previousRequest = colorRequest
            colorRequest = request
            colorTask?.cancel()
            let foreground = UIColor(request.appearance.palette.primaryInk)
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
                      self.colorRequest == request, textView.text == request.text,
                      textView.markedTextRange == nil else { return }
                self.isApplyingProgrammaticUpdate = true
                self.installColors(spans, for: request.text, on: textView, foreground: foreground)
                self.isApplyingProgrammaticUpdate = false
            }
        }

        /// `movedSpans` maps each previous span's start to its start after an
        /// edit, so its underline keeps its identity while the text shifts.
        func installColors(
            _ spans: [LyricsColorSpan],
            for text: String,
            on textView: UITextView,
            foreground: UIColor,
            movedSpans: [Int: Int]? = nil,
            animated: Bool = true
        ) {
            appliedColorSpans = spans
            appliedForeground = foreground
            appliedColorText = text
            Self.applyColors(
                spans,
                to: textView,
                foreground: foreground,
                sectionLabelForeground: UIColor(parent.appearance.palette.secondaryInk)
            )
            refreshUnderlines(textView, movedSpans: movedSpans, animated: animated)
        }

        func refreshUnderlines(_ textView: UITextView, movedSpans: [Int: Int]? = nil, animated: Bool) {
            // Measuring touches neither the storage nor the selection, so the
            // lines follow marked text too; the analysis waits for the commit.
            underlineView?.update(
                Self.underlineSegments(for: appliedColorSpans, in: textView),
                movedLocations: movedSpans,
                animated: animated
            )
        }

        func resetColorsAfterProgrammaticTextChange(_ textView: UITextView) {
            let foreground = UIColor(parent.appearance.palette.primaryInk)
            installColors([], for: textView.text, on: textView, foreground: foreground, animated: false)
        }

        /// Moves the spans with the user's edit before the debounced analysis
        /// replaces them: a deletion shortens the span it touches, letters typed
        /// into or against a word lengthen it, and any other insertion splits it.
        private func reconcileColorsAfterEdit(_ textView: UITextView) {
            defer { pendingColorEdit = nil }
            let text: String = textView.text
            guard let source = appliedColorText, let foreground = appliedForeground, source != text else { return }
            let moved: (spans: [LyricsColorSpan], locations: [Int: Int])
            if let pending = pendingColorEdit, pending.source == source,
               NSMaxRange(pending.range) <= source.utf16.count,
               (source as NSString).replacingCharacters(in: pending.range, with: pending.replacement) == text {
                moved = Self.spansMoved(appliedColorSpans, by: pending.range, replacement: pending.replacement)
            } else {
                moved = Self.spansMoved(appliedColorSpans, from: source, to: text)
            }
            installColors(moved.spans, for: text, on: textView, foreground: foreground, movedSpans: moved.locations)
        }

        /// The one replacement that turns `old` into `new`. Marked text,
        /// dictation and some system edits change the text without asking the
        /// delegate first, so the edit is read off the two texts.
        static func edit(from old: String, to new: String) -> (range: NSRange, replacement: String) {
            let before = Array(old.utf16)
            let after = Array(new.utf16)
            var prefix = 0
            while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < before.count - prefix, suffix < after.count - prefix,
                  before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
            let replacement = (new as NSString).substring(with: NSRange(location: prefix, length: after.count - prefix - suffix))
            return (NSRange(location: prefix, length: before.count - prefix - suffix), replacement)
        }

        /// Moves the spans across an edit read off the two texts. The region
        /// between their common prefix and suffix, widened to whole words, can
        /// hold several separate edits (two words edited, a split and a join,
        /// an autocorrection and a space). Unchanged words there keep their
        /// spans first; in each gap between them, each old span keeps the
        /// characters that survive, and each new word takes the colours of the
        /// spans whose characters it holds. A new word holding none waits for
        /// the analysis.
        static func spansMoved(
            _ spans: [LyricsColorSpan],
            from old: String,
            to new: String
        ) -> (spans: [LyricsColorSpan], locations: [Int: Int]) {
            let edit = edit(from: old, to: new)
            let oldText = old as NSString
            let newText = new as NSString
            func isWordUnit(_ unit: unichar) -> Bool {
                (65...90).contains(unit) || (97...122).contains(unit) || unit == 39 || unit == 0x2019 || unit == 0x02BC
            }
            var start = edit.range.location
            var oldEnd = NSMaxRange(edit.range)
            var newEnd = start + (edit.replacement as NSString).length
            while start > 0, isWordUnit(oldText.character(at: start - 1)) { start -= 1 }
            while oldEnd < oldText.length, isWordUnit(oldText.character(at: oldEnd)) {
                oldEnd += 1
                newEnd += 1
            }
            let delta = newText.length - oldText.length

            var adjusted: [(source: Int, span: LyricsColorSpan)] = []
            var replaced: [LyricsColorSpan] = []
            for span in spans {
                if NSMaxRange(span.range) <= start {
                    adjusted.append((span.range.location, span))
                } else if span.range.location >= oldEnd {
                    adjusted.append((span.range.location, LyricsColorSpan(
                        range: NSRange(location: span.range.location + delta, length: span.range.length),
                        foreground: span.foreground,
                        underline: span.underline
                    )))
                } else {
                    replaced.append(span)
                }
            }
            let words = LyricRegex.word.matches(in: new, range: NSRange(location: start, length: newEnd - start)).map(\.range)
            let full = NSRange(location: 0, length: oldText.length)
            let before = replaced.map { oldText.substring(with: NSIntersectionRange($0.range, full)) }
            let after = words.map { newText.substring(with: $0) }

            // Unchanged words anchor first: matched by text, in order, the most
            // of them, and among equal counts the ones that moved least, so a
            // repeated word pairs with itself rather than a neighbour.
            var anchors: [(Int, Int)] = []
            if before.count * after.count <= 250_000 {
                let columns = after.count + 1
                let weight = (oldEnd - start + newEnd - start + 1) * (min(before.count, after.count) + 1)
                func moved(_ i: Int, _ j: Int) -> Int {
                    abs((replaced[i].range.location - start) - (words[j].location - start))
                }
                var score = [Int](repeating: 0, count: (before.count + 1) * columns)
                for i in stride(from: before.count - 1, through: 0, by: -1) {
                    for j in stride(from: after.count - 1, through: 0, by: -1) {
                        var best = max(score[(i + 1) * columns + j], score[i * columns + j + 1])
                        if before[i] == after[j] {
                            best = max(best, score[(i + 1) * columns + j + 1] + weight - moved(i, j))
                        }
                        score[i * columns + j] = best
                    }
                }
                var i = 0, j = 0
                while i < before.count, j < after.count {
                    if before[i] == after[j], score[i * columns + j] == score[(i + 1) * columns + j + 1] + weight - moved(i, j) {
                        anchors.append((i, j))
                        i += 1
                        j += 1
                    } else if score[i * columns + j] == score[(i + 1) * columns + j] {
                        i += 1
                    } else {
                        j += 1
                    }
                }
            }
            for (oldIndex, newIndex) in anchors {
                adjusted.append((replaced[oldIndex].range.location, replaced[oldIndex].with(range: words[newIndex])))
            }

            // Between anchors, the characters that survive carry their colours.
            var previous = (-1, -1)
            for anchor in anchors + [(before.count, after.count)] {
                let gapSpans = Array(replaced[(previous.0 + 1)..<anchor.0])
                let gapWords = words[(previous.1 + 1)..<anchor.1]
                if !gapSpans.isEmpty, !gapWords.isEmpty {
                    let oldLower = previous.0 >= 0 ? NSMaxRange(replaced[previous.0].range) : start
                    let oldUpper = anchor.0 < before.count ? replaced[anchor.0].range.location : oldEnd
                    let newLower = previous.1 >= 0 ? NSMaxRange(words[previous.1]) : start
                    let newUpper = anchor.1 < after.count ? words[anchor.1].location : newEnd
                    let surviving = survivingPieces(
                        gapSpans,
                        old: oldText, in: NSRange(location: oldLower, length: max(oldUpper - oldLower, 0)),
                        new: newText, in: NSRange(location: newLower, length: max(newUpper - newLower, 0))
                    )
                    for word in gapWords {
                        let held = surviving.pieces.compactMap { piece -> (source: Int, span: LyricsColorSpan)? in
                            let kept = NSIntersectionRange(piece.span.range, word)
                            return kept.length > 0 ? (piece.source, piece.span.with(range: kept)) : nil
                        }.sorted { $0.span.range.location < $1.span.range.location }
                        for (index, piece) in held.enumerated() {
                            guard surviving.aligned else {
                                adjusted.append(piece)
                                continue
                            }
                            // An aligned word is coloured gap-free by the spans it holds.
                            let lower = index == 0 ? word.location : piece.span.range.location
                            let upper = index + 1 < held.count ? held[index + 1].span.range.location : NSMaxRange(word)
                            adjusted.append((piece.source, piece.span.with(range: NSRange(location: lower, length: upper - lower))))
                        }
                    }
                }
                previous = anchor
            }
            adjusted.sort { $0.span.range.location < $1.span.range.location }
            return clipped(adjusted)
        }

        /// Where each span's characters in `oldRange` land in `newRange`, as
        /// runs. Aligned along the longest common run of characters when the
        /// gap is small enough (`aligned`); otherwise only the gap's common
        /// prefix and suffix survive, and nothing is stretched.
        private static func survivingPieces(
            _ spans: [LyricsColorSpan],
            old: NSString, in oldRange: NSRange,
            new: NSString, in newRange: NSRange
        ) -> (pieces: [(source: Int, span: LyricsColorSpan)], aligned: Bool) {
            let oldUnits = (0..<oldRange.length).map { old.character(at: oldRange.location + $0) }
            let newUnits = (0..<newRange.length).map { new.character(at: newRange.location + $0) }
            var landing = [Int?](repeating: nil, count: oldUnits.count)
            let aligned = oldUnits.count * newUnits.count <= 250_000
            if aligned {
                // table[i * columns + j]: longest common run of oldUnits[i...] and newUnits[j...].
                let columns = newUnits.count + 1
                var table = [UInt16](repeating: 0, count: (oldUnits.count + 1) * columns)
                for i in stride(from: oldUnits.count - 1, through: 0, by: -1) {
                    for j in stride(from: newUnits.count - 1, through: 0, by: -1) {
                        table[i * columns + j] = oldUnits[i] == newUnits[j]
                            ? table[(i + 1) * columns + j + 1] + 1
                            : max(table[(i + 1) * columns + j], table[i * columns + j + 1])
                    }
                }
                var i = 0, j = 0
                while i < oldUnits.count, j < newUnits.count {
                    if oldUnits[i] == newUnits[j] {
                        landing[i] = newRange.location + j
                        i += 1
                        j += 1
                    } else if table[(i + 1) * columns + j] >= table[i * columns + j + 1] {
                        i += 1
                    } else {
                        j += 1
                    }
                }
            } else {
                var prefix = 0
                while prefix < oldUnits.count, prefix < newUnits.count, oldUnits[prefix] == newUnits[prefix] {
                    landing[prefix] = newRange.location + prefix
                    prefix += 1
                }
                var suffix = 0
                while suffix < oldUnits.count - prefix, suffix < newUnits.count - prefix,
                      oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] {
                    landing[oldUnits.count - 1 - suffix] = newRange.location + newUnits.count - 1 - suffix
                    suffix += 1
                }
            }
            var pieces: [(source: Int, span: LyricsColorSpan)] = []
            for span in spans {
                let lower = max(span.range.location, oldRange.location) - oldRange.location
                let upper = min(NSMaxRange(span.range), NSMaxRange(oldRange)) - oldRange.location
                var run: NSRange?
                for index in lower..<max(lower, upper) {
                    guard let target = landing[index] else { continue }
                    if let current = run, NSMaxRange(current) == target {
                        run = NSRange(location: current.location, length: current.length + 1)
                    } else {
                        if let current = run { pieces.append((span.range.location, span.with(range: current))) }
                        run = NSRange(location: target, length: 1)
                    }
                }
                if let current = run { pieces.append((span.range.location, span.with(range: current))) }
            }
            return (pieces, aligned)
        }

        static func spansMoved(
            _ spans: [LyricsColorSpan],
            by range: NSRange,
            replacement: String
        ) -> (spans: [LyricsColorSpan], locations: [Int: Int]) {
            clipped(movedPieces(spans, by: range, replacement: replacement))
        }

        /// Each span's surviving pieces after one replacement, with the start it had before.
        private static func movedPieces(
            _ spans: [LyricsColorSpan],
            by range: NSRange,
            replacement: String
        ) -> [(source: Int, span: LyricsColorSpan)] {
            let editStart = range.location
            let editEnd = NSMaxRange(range)
            let replacementLength = replacement.utf16.count
            let delta = replacementLength - range.length
            let fullReplacement = NSRange(location: 0, length: replacementLength)
            let extendsWord = replacementLength > 0
                && LyricRegex.word.firstMatch(in: replacement, range: fullReplacement)?.range == fullReplacement
            // Each moved span remembers the start it had before the edit.
            var adjusted: [(source: Int, span: LyricsColorSpan)] = []
            adjusted.reserveCapacity(spans.count + 1)
            func keep(_ span: LyricsColorSpan, from start: Int, to end: Int) {
                guard end > start else { return }
                adjusted.append((span.range.location, LyricsColorSpan(
                    range: NSRange(location: start, length: end - start),
                    foreground: span.foreground,
                    underline: span.underline
                )))
            }

            for span in spans {
                let start = span.range.location
                let end = NSMaxRange(span.range)
                if end < editStart || (end == editStart && !extendsWord) {
                    keep(span, from: start, to: end)
                } else if start > editEnd || (start == editEnd && !extendsWord) {
                    keep(span, from: start + delta, to: end + delta)
                } else if replacementLength > 0 && !extendsWord {
                    // A space or punctuation inside a word splits it.
                    keep(span, from: start, to: min(end, editStart))
                    keep(span, from: editStart + replacementLength, to: end > editEnd ? end + delta : 0)
                } else {
                    keep(
                        span,
                        from: start < editStart ? start : (extendsWord ? editStart : editStart + replacementLength),
                        to: end >= editEnd ? end + delta : (extendsWord ? editStart + replacementLength : editStart)
                    )
                }
            }
            return adjusted
        }

        /// An edit joining two words can leave their spans touching; never
        /// overlapping. Identity follows the clipped start, so a line keeps its layer.
        private static func clipped(
            _ adjusted: [(source: Int, span: LyricsColorSpan)]
        ) -> (spans: [LyricsColorSpan], locations: [Int: Int]) {
            var previousEnd = 0
            var moved: [LyricsColorSpan] = []
            var locations: [Int: Int] = [:]
            for (source, span) in adjusted {
                let start = max(span.range.location, previousEnd)
                let end = NSMaxRange(span.range)
                guard end > start else { continue }
                previousEnd = end
                if locations[source] == nil { locations[source] = start }
                moved.append(LyricsColorSpan(
                    range: NSRange(location: start, length: end - start),
                    foreground: span.foreground,
                    underline: span.underline
                ))
            }
            return (moved, locations)
        }

        /// `sectionLabelForeground` draws section header lines ("[Verse 1]",
        /// "[Chorus]") in a quieter neutral ink. It is a rendering attribute
        /// only: the stored text, its brackets, glyph metrics, selection and
        /// undo are untouched. Header lines carry no analysis spans, and spans
        /// are applied after it, so no lyric word loses its syllable or rhyme
        /// colour.
        ///
        /// Word colours are rendering attributes. The syllable underline is
        /// not: the text view draws only the foreground colour from rendering
        /// attributes, so `SyllableUnderlineView` draws it from `underlineSegments`.
        static func applyColors(
            _ spans: [LyricsColorSpan],
            to textView: UITextView,
            foreground: UIColor,
            sectionLabelForeground: UIColor? = nil
        ) {
            // Color attributes must not change glyph metrics or the user's selection.
            let sectionLabelRanges = sectionLabelForeground == nil ? [] : SectionMap.headerRanges(textView.text ?? "")
            let range = NSRange(location: 0, length: textView.textStorage.length)
            guard let layout = textView.textLayoutManager, let content = layout.textContentManager else { return }
            layout.renderingAttributesValidator = nil
            layout.removeRenderingAttribute(.foregroundColor, for: content.documentRange)
            layout.invalidateRenderingAttributes(for: content.documentRange)
            let render: (NSTextLayoutManager, NSTextRange) -> Void = { layout, target in
                guard let content = layout.textContentManager else { return }
                layout.setRenderingAttributes([.foregroundColor: foreground], for: target)
                let start = content.offset(from: content.documentRange.location, to: target.location)
                let end = content.offset(from: content.documentRange.location, to: target.endLocation)
                let targetRange = NSRange(location: start, length: end - start)
                if let sectionLabelForeground {
                    for header in sectionLabelRanges {
                        let intersection = NSIntersectionRange(header, targetRange)
                        guard intersection.length > 0,
                              let lower = content.location(content.documentRange.location, offsetBy: intersection.location),
                              let upper = content.location(lower, offsetBy: intersection.length),
                              let textRange = NSTextRange(location: lower, end: upper) else { continue }
                        layout.setRenderingAttributes([.foregroundColor: sectionLabelForeground], for: textRange)
                    }
                }
                for span in spans {
                    let intersection = NSIntersectionRange(span.range, targetRange)
                    guard intersection.length > 0,
                          let lower = content.location(content.documentRange.location, offsetBy: intersection.location),
                          let upper = content.location(lower, offsetBy: intersection.length),
                          let textRange = NSTextRange(location: lower, end: upper) else { continue }
                    layout.setRenderingAttributes(
                        [.foregroundColor: span.foreground.map(UIColor.init) ?? foreground],
                        for: textRange
                    )
                }
            }
            layout.renderingAttributesValidator = { layout, fragment in
                render(layout, fragment.rangeInElement)
            }
            if range.length > 0 { render(layout, content.documentRange) }
            textView.setNeedsDisplay()
        }

        /// One line per laid-out fragment of each underlined span, where the
        /// font's own underline would sit. Only the frames are measured here;
        /// the spans are not re-analysed.
        static func underlineSegments(for spans: [LyricsColorSpan], in textView: UITextView) -> [SyllableUnderlineView.Segment] {
            guard spans.contains(where: { $0.underline != nil }),
                  let layout = textView.textLayoutManager,
                  let content = layout.textContentManager else { return [] }
            let storage = textView.textStorage
            let full = NSRange(location: 0, length: storage.length)
            let inset = textView.textContainerInset
            layout.ensureLayout(for: content.documentRange)
            var segments: [SyllableUnderlineView.Segment] = []
            for span in spans {
                let range = NSIntersectionRange(span.range, full)
                guard range.length > 0, let underline = span.underline,
                      let lower = content.location(content.documentRange.location, offsetBy: range.location),
                      let upper = content.location(lower, offsetBy: range.length),
                      let textRange = NSTextRange(location: lower, end: upper) else { continue }
                let color = UIColor(underline)
                let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont
                    ?? textView.font ?? UIFont.systemFont(ofSize: UIFont.systemFontSize)
                let thickness = max(CTFontGetUnderlineThickness(font as CTFont), 1)
                let belowBaseline = -CTFontGetUnderlinePosition(font as CTFont)
                var fragment = 0
                var lastFrame: CGRect?
                layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, baseline, _ in
                    // The document's last line can report its segment twice.
                    guard frame.width > 0, frame != lastFrame else { return true }
                    lastFrame = frame
                    segments.append(SyllableUnderlineView.Segment(
                        location: range.location,
                        fragment: fragment,
                        frame: CGRect(
                            x: frame.minX + inset.left,
                            y: frame.minY + baseline + belowBaseline - thickness / 2 + inset.top,
                            width: frame.width,
                            height: thickness
                        ),
                        color: color
                    ))
                    fragment += 1
                    return true
                }
            }
            return segments
        }

        func updatePlaceholder(_ textView: UITextView, text: String) {
            if placeholderLabel == nil {
                let label = UILabel()
                label.text = parent.placeholder
                label.font = textView.font
                // The coordinator applies the same already-scaled font to both views.
                // Automatic label scaling would use its current trait collection and
                // can temporarily diverge from the notification's new category.
                label.adjustsFontForContentSizeCategory = false
                // Wrap rather than run off the trailing edge at larger text sizes.
                label.numberOfLines = 0
                label.translatesAutoresizingMaskIntoConstraints = false
                textView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: textView.topAnchor),
                    label.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
                    label.widthAnchor.constraint(lessThanOrEqualTo: textView.widthAnchor)
                ])
                placeholderLabel = label
            }
            placeholderLabel?.text = parent.placeholder
            placeholderLabel?.textColor = UIColor(parent.appearance.palette.placeholder)
            placeholderLabel?.isHidden = !text.isEmpty
        }

        func updateTypography(
            _ textView: UITextView,
            contentSizeCategory: UIContentSizeCategory? = nil
        ) {
            LyricsTextView.configureTypography(textView, contentSizeCategory: contentSizeCategory)
            placeholderLabel?.adjustsFontForContentSizeCategory = false
            placeholderLabel?.font = textView.font
            textView.invalidateIntrinsicContentSize()
            refreshUnderlines(textView, animated: false)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingProgrammaticUpdate else { return }
            reconcileColorsAfterEdit(textView)
            lastPublishedSelection = textView.selectedRange
            lastPublishedText = textView.text
            parent.text = textView.text
            parent.onCursorChange(textView.selectedRange.location)
            parent.onSelectionChange?(textView.selectedRange)
            updatePlaceholder(textView, text: textView.text)
            // Invalidate intrinsic content size so SwiftUI resizes
            textView.invalidateIntrinsicContentSize()
            scheduleKeepCursorVisible()
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText text: String
        ) -> Bool {
            pendingColorEdit = (textView.text, range, text)
            return true
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // UIKit also fires this for programmatic resets (e.g. assigning
            // .text clamps the selection to {0,0} before first focus). Only
            // user-driven changes may move the app-level cursor — otherwise a
            // background reset clobbers seeded or restored cursor state.
            guard textView.isFirstResponder, !isApplyingProgrammaticUpdate else { return }
            lastPublishedSelection = textView.selectedRange
            parent.onCursorChange(textView.selectedRange.location)
            parent.onSelectionChange?(textView.selectedRange)
            scheduleKeepCursorVisible()
        }

        func updateRewriteHighlight(_ textView: UITextView, highlight: LyricsRewriteHighlight?, animation: Animation? = nil) {
            guard let rewriteHighlightView else { return }
            guard let highlight, highlight.range.length > 0 else {
                rewriteHighlightView.clear(animation: clearedInsertionHighlight ? animation : nil)
                return
            }

            DispatchQueue.main.async { [weak textView, weak rewriteHighlightView] in
                guard let textView, let rewriteHighlightView, self.lastRewriteHighlight == highlight else { return }
                let rects = self.highlightRects(in: textView, range: highlight.range)
                rewriteHighlightView.configure(
                    rects: rects,
                    isLoading: highlight.isLoading,
                    colors: RewriteHighlightColors.forHighlight(highlight, palette: self.parent.appearance.palette)
                )
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onEditingChange?(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onEditingChange?(false)
        }

        @objc private func keyboardWillChangeFrame(_ notification: Notification) {
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
                return
            }

            keyboardFrameInScreen = frame
            let screenHeight = textView?.window?.windowScene?.screen.bounds.height ?? frame.maxY
            isKeyboardVisible = frame.minY < screenHeight
            scheduleKeepCursorVisible(animated: true)
        }

        @objc private func keyboardWillHide(_ notification: Notification) {
            isKeyboardVisible = false
            keyboardFrameInScreen = .zero
        }

        @objc private func contentSizeCategoryDidChange(_ notification: Notification) {
            guard let textView else { return }
            let category = notification.userInfo?[UIContentSizeCategory.newValueUserInfoKey]
                as? UIContentSizeCategory
            updateTypography(textView, contentSizeCategory: category)
        }

        func scheduleKeepCursorVisible(animated: Bool = false) {
            guard let textView else { return }

            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.keepCursorVisible(textView, animated: animated)
            }
        }

        private func keepCursorVisible(_ textView: UITextView, animated: Bool) {
            guard textView.isFirstResponder else { return }
            guard isKeyboardVisible || parent.bottomOverlayHeight > 0 || textView.selectedRange.length > 0 else { return }
            guard let scrollView = parentScrollView(for: textView) else { return }
            guard let selectedTextRange = textView.selectedTextRange else { return }

            textView.layoutIfNeeded()
            scrollView.layoutIfNeeded()

            let selectedRectInTextView = selectedTextRect(in: textView, selectedTextRange: selectedTextRange)
            let selectedRectInScrollView = textView.convert(selectedRectInTextView, to: scrollView)
            let visibleHeight = visibleHeightAboveKeyboard(in: scrollView)
            let lineHeight = textView.font?.lineHeight ?? 24
            let isRangeSelection = textView.selectedRange.length > 0
            let minSelectionTop: CGFloat = isRangeSelection ? 104 : 64
            let selectionBottomClearance: CGFloat = isRangeSelection ? 20 : 12
            let maxSelectionBottom = max(
                minSelectionTop + lineHeight,
                visibleHeight - selectionBottomClearance
            )

            let minAllowedOffset = selectedRectInScrollView.maxY - maxSelectionBottom
            let maxAllowedOffset = selectedRectInScrollView.minY - minSelectionTop
            let allowedLowerOffset = min(minAllowedOffset, maxAllowedOffset)
            let allowedUpperOffset = max(minAllowedOffset, maxAllowedOffset)
            let clampedOffset = scrollView.contentOffset.y.clamped(to: allowedLowerOffset...allowedUpperOffset)
            let minContentOffset = -scrollView.adjustedContentInset.top
            let maxContentOffset = max(
                minContentOffset,
                scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            )
            let boundedOffset = clampedOffset.clamped(to: minContentOffset...maxContentOffset)

            guard abs(boundedOffset - scrollView.contentOffset.y) > 0.5 else { return }
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: boundedOffset),
                animated: animated && !UIAccessibility.isReduceMotionEnabled
            )
        }

        private func selectedTextRect(in textView: UITextView, selectedTextRange: UITextRange) -> CGRect {
            guard textView.selectedRange.length > 0 else {
                return textView.caretRect(for: selectedTextRange.start)
            }

            let rects = textView.selectionRects(for: selectedTextRange)
                .map(\.rect)
                .filter { rect in
                    !rect.isNull &&
                        !rect.isEmpty &&
                        rect.origin.x.isFinite &&
                        rect.origin.y.isFinite &&
                        rect.size.width.isFinite &&
                        rect.size.height.isFinite
                }
            guard let first = rects.first else {
                return textView.caretRect(for: selectedTextRange.start)
            }

            return rects.dropFirst().reduce(first) { partial, rect in
                partial.union(rect)
            }
        }

        private func parentScrollView(for view: UIView) -> UIScrollView? {
            var superview = view.superview
            while let current = superview {
                if let scrollView = current as? UIScrollView {
                    return scrollView
                }
                superview = current.superview
            }

            return nil
        }

        private func visibleHeightAboveKeyboard(in scrollView: UIScrollView) -> CGFloat {
            let insetAdjustedHeight = scrollView.bounds.height
                - scrollView.adjustedContentInset.top
                - scrollView.adjustedContentInset.bottom

            guard isKeyboardVisible, let window = scrollView.window else {
                return max(0, insetAdjustedHeight)
            }

            let keyboardFrameInWindow = window.convert(keyboardFrameInScreen, from: nil)
            let scrollFrameInWindow = scrollView.convert(scrollView.bounds, to: window)
            let keyboardOverlap = max(0, scrollFrameInWindow.maxY - keyboardFrameInWindow.minY)

            return max(0, insetAdjustedHeight - keyboardOverlap - parent.bottomOverlayHeight)
        }

        private func highlightRects(in textView: UITextView, range: NSRange) -> [CGRect] {
            let nsText = textView.text as NSString
            guard range.location >= 0, range.location + range.length <= nsText.length else {
                return []
            }

            guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
                  let end = textView.position(from: start, offset: range.length),
                  let textRange = textView.textRange(from: start, to: end) else { return [] }
            let rects = textView.selectionRects(for: textRange).map { $0.rect.insetBy(dx: -3, dy: -2) }
            return rects
        }
    }
}

/// Colours for the pending-rewrite and insertion highlight, taken from the
/// appearance palette so the editor stays monochrome while a rewrite is in
/// flight. The overlay sits above the text, so the fill stays translucent.
struct RewriteHighlightColors: Equatable {
    static let pendingFillOpacity: CGFloat = 0.45
    static let pendingStrokeOpacity: CGFloat = 0.90
    static let errorFillOpacity: CGFloat = 0.20
    static let errorStrokeOpacity: CGFloat = 0.60
    static let insertionFillOpacity: CGFloat = 0.12
    static let insertionStrokeOpacity: CGFloat = 0.45

    let fill: UIColor
    let stroke: UIColor

    /// A selection waiting for, or receiving, a rewrite: the editor's own
    /// selection tint with a strong-outline border. Nothing moves.
    static func pending(palette: AppAppearancePalette) -> RewriteHighlightColors {
        RewriteHighlightColors(
            fill: UIColor(palette.selectionTint).withAlphaComponent(pendingFillOpacity),
            stroke: UIColor(palette.outlineStrong).withAlphaComponent(pendingStrokeOpacity)
        )
    }

    static func error(palette: AppAppearancePalette) -> RewriteHighlightColors {
        RewriteHighlightColors(
            fill: UIColor(palette.error).withAlphaComponent(errorFillOpacity),
            stroke: UIColor(palette.error).withAlphaComponent(errorStrokeOpacity)
        )
    }

    static func insertion(palette: AppAppearancePalette) -> RewriteHighlightColors {
        RewriteHighlightColors(
            fill: UIColor(palette.primaryInk).withAlphaComponent(insertionFillOpacity),
            stroke: UIColor(palette.primaryInk).withAlphaComponent(insertionStrokeOpacity)
        )
    }

    static func forHighlight(_ highlight: LyricsRewriteHighlight, palette: AppAppearancePalette) -> RewriteHighlightColors {
        if highlight.isInsertion { return insertion(palette: palette) }
        if highlight.isError { return error(palette: palette) }
        return pending(palette: palette)
    }
}

/// Draws the rewrite and insertion highlight: a rounded tint and a 1pt border
/// around the affected glyph rects. It is static by design; the rewrite bar
/// at the bottom of the editor carries the loading state.
final class RewriteHighlightOverlayView: UIView {
    private(set) var rects: [CGRect] = []
    private(set) var isLoading = false
    private(set) var colors: RewriteHighlightColors?

    /// Counts configurations so a fade's completion never erases a highlight
    /// that replaced it meanwhile.
    private var generation = 0

    /// Runs the fade. Tests inject a driver that hands the changes and the
    /// completion back, so the fade's states can be checked without a clock.
    typealias FadeDriver = (_ animation: Animation, _ changes: @escaping () -> Void, _ completion: @escaping () -> Void) -> Void
    var fadeDriver: FadeDriver = { animation, changes, completion in
        UIView.animate(animation, changes: changes, completion: completion)
    }

    func configure(rects: [CGRect], isLoading: Bool, colors: RewriteHighlightColors?) {
        // A new highlight cancels a fade in progress.
        generation += 1
        layer.removeAllAnimations()
        alpha = 1
        self.rects = rects
        self.isLoading = isLoading
        self.colors = colors
        setNeedsDisplay()
    }

    /// Clears the mark: in one frame, or, with the transaction's animation
    /// (the "Use line" mark dries on `Motion.settle`), by fading its alpha on
    /// that very animation and removing the rects when the fade completes.
    func clear(animation: Animation?) {
        guard let animation, !rects.isEmpty, alpha > 0 else {
            configure(rects: [], isLoading: false, colors: nil)
            return
        }
        generation += 1
        let fading = generation
        fadeDriver(animation, { [weak self] in
            self?.alpha = 0
        }, { [weak self] in
            guard let self, self.generation == fading else { return }
            self.configure(rects: [], isLoading: false, colors: nil)
        })
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let colors, !rects.isEmpty else { return }

        context.setFillColor(colors.fill.cgColor)
        context.setStrokeColor(colors.stroke.cgColor)
        context.setLineWidth(1.0)

        for highlightRect in rects {
            let path = UIBezierPath(roundedRect: highlightRect, cornerRadius: RhymeAITokens.Radius.xs)
            context.addPath(path.cgPath)
            context.drawPath(using: .fillStroke)
        }
    }
}

/// Draws the syllable underline behind the editor's text, one layer per
/// span fragment. When the spans change, a line keeps its left edge and its
/// position follows the text at once, while its width eases from the old
/// length to the new one on the feedback tier: each deleted character takes
/// its own width of line away and each typed letter adds one. A line whose
/// word is gone fades out on the same tier. Core Animation runs the motion,
/// so no analysis or layout happens per frame; Reduce Motion snaps.
final class SyllableUnderlineView: UIView {
    struct Segment: Equatable {
        let location: Int
        let fragment: Int
        let frame: CGRect
        let color: UIColor
    }

    private struct Key: Hashable {
        let location: Int
        let fragment: Int
    }

    static let duration = RhymeAITokens.Motion.feedbackDuration
    static let widthAnimationKey = "syllableUnderline.width"
    static let fadeAnimationKey = "syllableUnderline.fade"

    private(set) var segments: [Segment] = []
    private var lines: [Key: CALayer] = [:]
    var motionEnabled: () -> Bool = { !UIAccessibility.isReduceMotionEnabled }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The layer drawing a span's fragment, for tests.
    func line(at location: Int, fragment: Int = 0) -> CALayer? {
        lines[Key(location: location, fragment: fragment)]
    }

    /// `movedLocations` maps a previous span start to its start after an edit;
    /// a start missing from it lost its span. Without it, starts are kept.
    func update(_ newSegments: [Segment], movedLocations: [Int: Int]?, animated: Bool) {
        // The first lines on screen (a song opening, a guide turned on) appear at once.
        let animates = animated && motionEnabled() && !lines.isEmpty
        var previous: [Key: CALayer] = [:]
        var leaving: [CALayer] = []
        for (key, line) in lines {
            let location = movedLocations.map { $0[key.location] } ?? key.location
            if let location, previous[Key(location: location, fragment: key.fragment)] == nil {
                previous[Key(location: location, fragment: key.fragment)] = line
            } else {
                leaving.append(line)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var next: [Key: CALayer] = [:]
        for segment in newSegments {
            let key = Key(location: segment.location, fragment: segment.fragment)
            guard next[key] == nil else { continue }
            let line: CALayer
            let fromWidth: CGFloat
            if let existing = previous.removeValue(forKey: key) {
                line = existing
                fromWidth = (existing.presentation() ?? existing).bounds.width
            } else {
                line = CALayer()
                line.anchorPoint = CGPoint(x: 0, y: 0.5)
                layer.addSublayer(line)
                fromWidth = 0
            }
            line.frame = segment.frame
            line.backgroundColor = segment.color.cgColor
            if animates, abs(fromWidth - segment.frame.width) > 0.5 {
                let width = CABasicAnimation(keyPath: "bounds.size.width")
                width.fromValue = fromWidth
                width.toValue = segment.frame.width
                width.duration = Self.duration
                width.timingFunction = CAMediaTimingFunction(name: .easeOut)
                line.add(width, forKey: Self.widthAnimationKey)
            } else {
                line.removeAnimation(forKey: Self.widthAnimationKey)
            }
            next[key] = line
        }
        leaving.append(contentsOf: previous.values)
        for line in leaving {
            guard animates else {
                line.removeFromSuperlayer()
                continue
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = (line.presentation() ?? line).opacity
            fade.toValue = Float(0)
            fade.duration = Self.duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            line.opacity = 0
            line.add(fade, forKey: Self.fadeAnimationKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { [weak line] in
                line?.removeFromSuperlayer()
            }
        }
        CATransaction.commit()
        lines = next
        segments = newSegments
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}

private extension LyricsColorSpan {
    func with(range: NSRange) -> LyricsColorSpan {
        LyricsColorSpan(range: range, foreground: foreground, underline: underline)
    }
}
