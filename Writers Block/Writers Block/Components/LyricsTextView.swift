import SwiftUI
import UIKit

struct LyricsRewriteHighlight: Equatable {
    let range: NSRange
    let isLoading: Bool
    let isError: Bool
}

struct LyricsTextView: UIViewRepresentable {
    @Environment(\.appAppearanceStyle) private var appearance

    @Binding var text: String
    var selection: NSRange? = nil
    var displayText: String? = nil
    var rewriteHighlight: LyricsRewriteHighlight? = nil
    var onCursorChange: (Int) -> Void
    var onSelectionChange: ((NSRange) -> Void)? = nil
    var onEditingChange: ((Bool) -> Void)? = nil
    var bottomOverlayHeight: CGFloat = 0
    var isTransparentText: Bool = false
    var isEditable: Bool = true
    var placeholder: String = "Start writing your lyrics here..."

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.systemFont(ofSize: 16, weight: .regular)
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
        let textChanged = textView.text != currentRenderedText
        if textChanged {
            context.coordinator.isApplyingProgrammaticUpdate = true
            let selectedRange = selection ?? textView.selectedRange
            textView.text = currentRenderedText
            // Restore selection if still valid — the whole range must fit, not just
            // its start, or restoring after the text shrank raises NSRangeException.
            if selectedRange.location + selectedRange.length <= currentRenderedText.utf16.count {
                textView.selectedRange = selectedRange
            }
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
            isTransparentText: isTransparentText,
            isEditable: isEditable
        ) {
            applyAppearance(to: textView)
        }
        if context.coordinator.shouldUpdatePlaceholder(
            text: currentRenderedText,
            appearance: appearance,
            placeholder: placeholder
        ) {
            context.coordinator.updatePlaceholder(textView, text: currentRenderedText)
        }
        if context.coordinator.shouldUpdateRewriteHighlight(
            textChanged: textChanged,
            highlight: rewriteHighlight
        ) {
            context.coordinator.updateRewriteHighlight(textView, highlight: rewriteHighlight)
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

    private var renderedText: String {
        displayText ?? text
    }

    private func applyAppearance(to textView: UITextView) {
        let foreground = UIColor(appearance.palette.primaryInk)
        textView.textColor = isTransparentText ? .clear : foreground
        textView.tintColor = isEditable ? UIColor(appearance.palette.caret) : .clear
        textView.keyboardAppearance = appearance == .graphite ? .dark : .light
        textView.typingAttributes[.foregroundColor] = isTransparentText ? UIColor.clear : foreground
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: LyricsTextView
        private var placeholderLabel: UILabel?
        private var rewriteHighlightView: RewriteHighlightOverlayView?
        private weak var textView: UITextView?
        private var isObservingKeyboard = false
        private var keyboardFrameInScreen: CGRect = .zero
        private var isKeyboardVisible = false
        private var lastAppearance: AppAppearanceStyle?
        private var lastIsTransparentText: Bool?
        private var lastIsEditable: Bool?
        private var lastPlaceholderText: String?
        private var lastPlaceholderAppearance: AppAppearanceStyle?
        private var lastPlaceholder: String?
        private var lastRewriteHighlight: LyricsRewriteHighlight?
        private var lastSelection: NSRange?
        private var lastBottomOverlayHeight: CGFloat?
        var isApplyingProgrammaticUpdate = false

        init(_ parent: LyricsTextView) {
            self.parent = parent
        }

        deinit {
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
        }

        func shouldApplyAppearance(
            appearance: AppAppearanceStyle,
            isTransparentText: Bool,
            isEditable: Bool
        ) -> Bool {
            let changed = lastAppearance != appearance
                || lastIsTransparentText != isTransparentText
                || lastIsEditable != isEditable
            lastAppearance = appearance
            lastIsTransparentText = isTransparentText
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

        func updatePlaceholder(_ textView: UITextView, text: String) {
            if placeholderLabel == nil {
                let label = UILabel()
                label.text = parent.placeholder
                label.font = textView.font
                label.translatesAutoresizingMaskIntoConstraints = false
                textView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: textView.topAnchor),
                    label.leadingAnchor.constraint(equalTo: textView.leadingAnchor)
                ])
                placeholderLabel = label
            }
            placeholderLabel?.text = parent.placeholder
            placeholderLabel?.textColor = UIColor(parent.appearance.palette.placeholder)
            placeholderLabel?.isHidden = !text.isEmpty
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isApplyingProgrammaticUpdate else { return }
            parent.text = textView.text
            parent.onCursorChange(textView.selectedRange.location)
            parent.onSelectionChange?(textView.selectedRange)
            updatePlaceholder(textView, text: textView.text)
            // Invalidate intrinsic content size so SwiftUI resizes
            textView.invalidateIntrinsicContentSize()
            scheduleKeepCursorVisible()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // UIKit also fires this for programmatic resets (e.g. assigning
            // .text clamps the selection to {0,0} before first focus). Only
            // user-driven changes may move the app-level cursor — otherwise a
            // background reset clobbers seeded or restored cursor state.
            guard textView.isFirstResponder, !isApplyingProgrammaticUpdate else { return }
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
                guard let textView, let rewriteHighlightView else { return }
                let rects = self.highlightRects(in: textView, range: highlight.range)
                rewriteHighlightView.configure(
                    rects: rects,
                    isLoading: highlight.isLoading,
                    isError: highlight.isError
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
                animated: animated
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

            let layoutManager = textView.layoutManager
            let textContainer = textView.textContainer
            layoutManager.ensureLayout(for: textContainer)

            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            var rects: [CGRect] = []
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: glyphRange,
                in: textContainer
            ) { rect, _ in
                let expanded = rect
                    .insetBy(dx: -3, dy: -2)
                    .offsetBy(
                        dx: textView.textContainerInset.left,
                        dy: textView.textContainerInset.top
                    )
                rects.append(expanded)
            }
            return rects
        }
    }
}

private final class RewriteHighlightOverlayView: UIView {
    private var rects: [CGRect] = []
    private var isLoading = false
    private var isError = false
    private var scanProgress: CGFloat = 0
    private var displayLink: CADisplayLink?

    deinit {
        displayLink?.invalidate()
    }

    func configure(rects: [CGRect], isLoading: Bool, isError: Bool) {
        self.rects = rects
        self.isLoading = isLoading
        self.isError = isError

        if isLoading && !rects.isEmpty && !UIAccessibility.isReduceMotionEnabled {
            startScan()
        } else {
            stopScan()
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !rects.isEmpty else { return }

        let fillColor = isError
            ? UIColor.systemRed.withAlphaComponent(0.20)
            : UIColor.systemIndigo.withAlphaComponent(0.22)
        let strokeColor = isError
            ? UIColor.systemRed.withAlphaComponent(0.60)
            : UIColor.systemTeal.withAlphaComponent(0.70)

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
