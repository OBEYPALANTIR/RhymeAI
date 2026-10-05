import SwiftUI
import UIKit

struct LyricsRewriteHighlight: Equatable {
    let range: NSRange
    let isLoading: Bool
    let isError: Bool
    var isInsertion: Bool = false
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

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
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
            context.coordinator.updateRewriteHighlight(textView, highlight: activeHighlight)
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
        private var appliedColorSpans: [LyricsColorSpan] = []
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
            lastRewriteHighlight = highlight
            return changed
        }

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

        func installColors(
            _ spans: [LyricsColorSpan],
            for text: String,
            on textView: UITextView,
            foreground: UIColor
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
        }

        func resetColorsAfterProgrammaticTextChange(_ textView: UITextView) {
            let foreground = UIColor(parent.appearance.palette.primaryInk)
            installColors([], for: textView.text, on: textView, foreground: foreground)
        }

        private func reconcileColorsAfterEdit(_ textView: UITextView) {
            defer { pendingColorEdit = nil }
            guard let edit = pendingColorEdit,
                  appliedColorText == edit.source,
                  let foreground = appliedForeground,
                  edit.range.location <= edit.source.utf16.count,
                  edit.range.length <= edit.source.utf16.count - edit.range.location else { return }
            let expectedText = (edit.source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            guard expectedText == textView.text else { return }
            let replacementLength = edit.replacement.utf16.count
            let editEnd = NSMaxRange(edit.range)
            let delta = replacementLength - edit.range.length
            var adjusted: [LyricsColorSpan] = []
            adjusted.reserveCapacity(appliedColorSpans.count + 1)

            for span in appliedColorSpans {
                let spanEnd = NSMaxRange(span.range)
                if spanEnd <= edit.range.location {
                    adjusted.append(span)
                } else if span.range.location >= editEnd {
                    adjusted.append(LyricsColorSpan(
                        range: NSRange(location: span.range.location + delta, length: span.range.length),
                        foreground: span.foreground,
                        underline: span.underline
                    ))
                } else {
                    let prefixLength = max(edit.range.location - span.range.location, 0)
                    if prefixLength > 0 {
                        adjusted.append(LyricsColorSpan(
                            range: NSRange(location: span.range.location, length: prefixLength),
                            foreground: span.foreground,
                            underline: span.underline
                        ))
                    }
                    let suffixLength = max(spanEnd - editEnd, 0)
                    if suffixLength > 0 {
                        adjusted.append(LyricsColorSpan(
                            range: NSRange(location: edit.range.location + replacementLength, length: suffixLength),
                            foreground: span.foreground,
                            underline: span.underline
                        ))
                    }
                }
            }

            installColors(adjusted, for: textView.text, on: textView, foreground: foreground)
        }

        /// `sectionLabelForeground` draws section header lines ("[Verse 1]",
        /// "[Chorus]") in a quieter neutral ink. It is a rendering attribute
        /// only: the stored text, its brackets, glyph metrics, selection and
        /// undo are untouched. Header lines carry no analysis spans, and spans
        /// are applied after it, so no lyric word loses its syllable or rhyme
        /// colour.
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
            layout.removeRenderingAttribute(.underlineStyle, for: content.documentRange)
            layout.removeRenderingAttribute(.underlineColor, for: content.documentRange)
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
                    var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: span.foreground.map(UIColor.init) ?? foreground]
                    if let underline = span.underline {
                        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                        attributes[.underlineColor] = UIColor(underline)
                    }
                    layout.setRenderingAttributes(attributes, for: textRange)
                }
            }
            layout.renderingAttributesValidator = { layout, fragment in
                render(layout, fragment.rangeInElement)
            }
            if range.length > 0 { render(layout, content.documentRange) }
            textView.setNeedsDisplay()
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

        func updateRewriteHighlight(_ textView: UITextView, highlight: LyricsRewriteHighlight?) {
            guard let rewriteHighlightView else { return }
            guard let highlight, highlight.range.length > 0 else {
                rewriteHighlightView.configure(rects: [], isLoading: false, isError: false)
                return
            }

            DispatchQueue.main.async { [weak textView, weak rewriteHighlightView] in
                guard let textView, let rewriteHighlightView, self.lastRewriteHighlight == highlight else { return }
                let rects = self.highlightRects(in: textView, range: highlight.range)
                rewriteHighlightView.configure(
                    rects: rects,
                    isLoading: highlight.isLoading,
                    isError: highlight.isError,
                    insertionColor: highlight.isInsertion ? UIColor(self.parent.appearance.palette.primaryInk) : nil
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

final class RewriteHighlightOverlayView: UIView {
    private var rects: [CGRect] = []
    private var isLoading = false
    private var isError = false
    private var insertionColor: UIColor?
    private var scanProgress: CGFloat = 0
    private var displayLink: CADisplayLink?

    var isRippleAnimating: Bool { displayLink != nil }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview == nil { stopScan() }
    }

    deinit {
        displayLink?.invalidate()
    }

    func configure(rects: [CGRect], isLoading: Bool, isError: Bool, insertionColor: UIColor? = nil) {
        self.rects = rects
        self.isLoading = isLoading
        self.isError = isError
        self.insertionColor = insertionColor

        if isLoading && !rects.isEmpty && !UIAccessibility.isReduceMotionEnabled {
            startScan()
        } else {
            stopScan()
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !rects.isEmpty else { return }

        let fillColor = insertionColor?.withAlphaComponent(0.12) ?? (isError
            ? UIColor.systemRed.withAlphaComponent(0.20)
            : UIColor.systemIndigo.withAlphaComponent(0.22))
        let strokeColor = insertionColor?.withAlphaComponent(0.45) ?? (isError
            ? UIColor.systemRed.withAlphaComponent(0.60)
            : UIColor.systemTeal.withAlphaComponent(0.70))

        context.setFillColor(fillColor.cgColor)
        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(1.0)

        for highlightRect in rects {
            let path = UIBezierPath(roundedRect: highlightRect, cornerRadius: RhymeAITokens.Radius.xs)
            context.addPath(path.cgPath)
            context.drawPath(using: .fillStroke)
        }

        guard isLoading, !UIAccessibility.isReduceMotionEnabled else { return }

        for highlightRect in rects {
            let bandWidth = max(highlightRect.width * 0.45, 24)
            let travel = highlightRect.width + bandWidth * 2
            let centerX = highlightRect.minX - bandWidth + travel * scanProgress
            context.saveGState()
            UIBezierPath(roundedRect: highlightRect, cornerRadius: RhymeAITokens.Radius.xs).addClip()
            let colors = [
                UIColor.systemIndigo.withAlphaComponent(0).cgColor,
                UIColor.systemIndigo.withAlphaComponent(0.6).cgColor,
                UIColor.systemIndigo.withAlphaComponent(0).cgColor
            ] as CFArray
            let locations: [CGFloat] = [0, 0.5, 1]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
                context.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: centerX - bandWidth, y: highlightRect.midY),
                    end: CGPoint(x: centerX + bandWidth, y: highlightRect.midY),
                    options: []
                )
            }
            context.restoreGState()
        }
    }

    private func startScan() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(stepScan))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopScan() {
        displayLink?.invalidate()
        displayLink = nil
        scanProgress = 0
    }

    @objc private func stepScan() {
        guard !UIAccessibility.isReduceMotionEnabled else { stopScan(); return }
        let frameDuration = displayLink?.duration ?? (1.0 / 60.0)
        scanProgress += CGFloat((frameDuration > 0 ? frameDuration : 1.0 / 60.0) / 1.2)
        if scanProgress > 1 {
            scanProgress = 0
        }
        setNeedsDisplay()
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
