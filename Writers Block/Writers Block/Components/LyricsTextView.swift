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
        textView.font = Self.scaledBodyFont(compatibleWith: textView.traitCollection)
        textView.adjustsFontForContentSizeCategory = true
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
        applyAppearance(to: textView, coordinator: context.coordinator)
        context.coordinator.updatePlaceholder(textView, text: renderedText)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        textView.font = Self.scaledBodyFont(compatibleWith: textView.traitCollection)
        let currentRenderedText = renderedText
        if textView.text != currentRenderedText {
            context.coordinator.isApplyingProgrammaticUpdate = true
            let selectedRange = textView.selectedRange
            textView.text = currentRenderedText
            // Restore selection if still valid — the whole range must fit, not just
            // its start, or restoring after the text shrank raises NSRangeException.
            if selectedRange.location + selectedRange.length <= currentRenderedText.utf16.count {
                textView.selectedRange = selectedRange
            }
            context.coordinator.isApplyingProgrammaticUpdate = false
        }
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
        applyAppearance(to: textView)
        context.coordinator.updatePlaceholder(textView, text: currentRenderedText)
        context.coordinator.updateRewriteHighlight(textView, highlight: rewriteHighlight)
        context.coordinator.scheduleKeepCursorVisible()
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
        private var isApplyingProgrammaticTextUpdate = false
        private var keyboardFrameInScreen: CGRect = .zero
        private var isKeyboardVisible = false
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
                RewriteHighlightOverlayLayout.install(view, in: textView)
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
            placeholderLabel?.textColor = UIColor(parent.appearance.palette.placeholder)
            placeholderLabel?.isHidden = !text.isEmpty
            placeholderLabel?.font = textView.font
            placeholderLabel?.text = parent.placeholder
            placeholderLabel?.textColor = UIColor(parent.appearance.palette.placeholder)
        }

        func updateAppearance(_ palette: AppAppearancePalette) {
            rewriteHighlightView?.updateAppearance(palette)
        }

        func updateRenderedText(_ text: String, in textView: UITextView) {
            let selectedRange = textView.selectedRange
            isApplyingProgrammaticTextUpdate = true
            defer { isApplyingProgrammaticTextUpdate = false }
            textView.text = text
            if selectedRange.location + selectedRange.length <= text.utf16.count {
                textView.selectedRange = selectedRange
            }
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

            let rects = RewriteHighlightGeometry.enclosingRects(
                layoutManager: textView.layoutManager,
                textContainer: textView.textContainer,
                characterRange: highlight.range,
                textContainerInset: CGPoint(
                    x: textView.textContainerInset.left,
                    y: textView.textContainerInset.top
                )
            )
            rewriteHighlightView.configure(
                rects: rects,
                isLoading: highlight.isLoading,
                isError: highlight.isError
            )
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

    }
}

final class RewriteHighlightOverlayView: UIView {
    private var rects: [CGRect] = []
    private var isLoading = false
    private var isError = false
    private var rippleProgress: CGFloat = 0
    private var displayLink: CADisplayLink?
    private var lastFrameTimestamp: CFTimeInterval?
    private lazy var displayLinkTarget = RewriteRippleDisplayLinkTarget(owner: self)
    private var selectionFillColor = UIColor.clear
    private var selectionStrokeColor = UIColor.clear
    private var rippleColor = UIColor.clear
    private var errorColor = UIColor.clear

    var isRippleAnimating: Bool {
        displayLink != nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        observeReduceMotionChanges()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observeReduceMotionChanges()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stopRipple()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateRippleState()
    }

    func configure(rects: [CGRect], isLoading: Bool, isError: Bool) {
        self.rects = rects
        self.isLoading = isLoading
        self.isError = isError

        updateRippleState()
        setNeedsDisplay()
    }

    func updateAppearance(_ palette: AppAppearancePalette) {
        selectionFillColor = UIColor(palette.selectionTint).withAlphaComponent(
            RewriteRippleMotion.loadingSelectionFillOpacity
        )
        selectionStrokeColor = UIColor(palette.outlineStrong).withAlphaComponent(0.82)
        rippleColor = UIColor(palette.primaryInk)
        errorColor = UIColor(palette.error)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), !rects.isEmpty else { return }

        let fillColor = isError
            ? errorColor.withAlphaComponent(0.20)
            : selectionFillColor
        let strokeColor = isError
            ? errorColor.withAlphaComponent(0.60)
            : selectionStrokeColor

        context.setFillColor(fillColor.cgColor)
        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(1.0)

        for highlightRect in rects {
            let path = UIBezierPath(roundedRect: highlightRect, cornerRadius: RhymeAITokens.Radius.xs)
            context.addPath(path.cgPath)
            context.drawPath(using: isLoading && !isError ? .fill : .fillStroke)
        }

        guard isLoading, !isError else { return }

        let progress = UIAccessibility.isReduceMotionEnabled
            ? RewriteRippleMotion.stableProgress
            : rippleProgress

        for highlightRect in rects {
            context.saveGState()
            UIBezierPath(roundedRect: highlightRect, cornerRadius: RhymeAITokens.Radius.xs).addClip()
            drawWave(
                in: context,
                rect: highlightRect,
                y: highlightRect.maxY - 3.5,
                progress: progress,
                phaseOffset: 0,
                amplitude: 1.45,
                color: rippleColor.withAlphaComponent(0.88),
                lineWidth: 1.2
            )
            drawWave(
                in: context,
                rect: highlightRect,
                y: highlightRect.maxY - 1.35,
                progress: progress,
                phaseOffset: .pi * 0.7,
                amplitude: 0.8,
                color: rippleColor.withAlphaComponent(0.42),
                lineWidth: 0.8
            )
            context.restoreGState()
        }
    }

    private func drawWave(
        in context: CGContext,
        rect: CGRect,
        y: CGFloat,
        progress: CGFloat,
        phaseOffset: CGFloat,
        amplitude: CGFloat,
        color: UIColor,
        lineWidth: CGFloat
    ) {
        let path = UIBezierPath()
        path.move(to: CGPoint(
            x: rect.minX,
            y: y + RewriteRippleMotion.verticalOffset(
                fraction: 0,
                progress: progress,
                amplitude: amplitude,
                phaseOffset: phaseOffset
            )
        ))
        for index in 1...24 {
            let fraction = CGFloat(index) / 24
            path.addLine(to: CGPoint(
                x: rect.minX + rect.width * fraction,
                y: y + RewriteRippleMotion.verticalOffset(
                    fraction: fraction,
                    progress: progress,
                    amplitude: amplitude,
                    phaseOffset: phaseOffset
                )
            ))
        }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.addPath(path.cgPath)
        context.strokePath()
    }

    private func startRipple() {
        guard displayLink == nil, window != nil else { return }
        let link = CADisplayLink(
            target: displayLinkTarget,
            selector: #selector(RewriteRippleDisplayLinkTarget.stepRipple(_:))
        )
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopRipple() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrameTimestamp = nil
        rippleProgress = 0
    }

    fileprivate func stepRipple(_ displayLink: CADisplayLink) {
        guard !UIAccessibility.isReduceMotionEnabled else { stopRipple(); return }
        let elapsed = lastFrameTimestamp.map { max(0, displayLink.timestamp - $0) }
            ?? max(0, displayLink.targetTimestamp - displayLink.timestamp)
        lastFrameTimestamp = displayLink.timestamp
        rippleProgress = RewriteRippleMotion.advancedProgress(from: rippleProgress, elapsed: elapsed)
        setNeedsDisplay()
    }

    private func updateRippleState() {
        if isLoading && !rects.isEmpty && !UIAccessibility.isReduceMotionEnabled && window != nil {
            startRipple()
        } else {
            stopRipple()
        }
    }

    private func observeReduceMotionChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reduceMotionStatusDidChange),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil
        )
    }

    @objc private func reduceMotionStatusDidChange() {
        updateRippleState()
        setNeedsDisplay()
    }
}

private final class RewriteRippleDisplayLinkTarget: NSObject {
    private weak var owner: RewriteHighlightOverlayView?

    init(owner: RewriteHighlightOverlayView) {
        self.owner = owner
    }

    @objc func stepRipple(_ displayLink: CADisplayLink) {
        owner?.stepRipple(displayLink)
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
