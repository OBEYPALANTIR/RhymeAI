import SwiftUI
import UIKit

struct LyricsTextView: UIViewRepresentable {
    @Binding var text: String
    var onCursorChange: (Int) -> Void
    var isTransparentText: Bool = false
    var placeholder: String = "Start writing your lyrics here..."

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = UIFont.systemFont(ofSize: 16, weight: .regular)
        textView.backgroundColor = .clear
        textView.textColor = isTransparentText ? .clear : UIColor.label.withAlphaComponent(0.9)
        textView.tintColor = UIColor(Color.indigo)
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.attach(to: textView)
        context.coordinator.updatePlaceholder(textView, text: text)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            let selectedRange = textView.selectedRange
            textView.text = text
            // Restore selection if still valid
            if selectedRange.location <= text.utf16.count {
                textView.selectedRange = selectedRange
            }
        }
        textView.textColor = isTransparentText ? .clear : UIColor.label.withAlphaComponent(0.9)
        context.coordinator.updatePlaceholder(textView, text: text)
        context.coordinator.scheduleKeepCursorVisible()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: LyricsTextView
        private var placeholderLabel: UILabel?
        private weak var textView: UITextView?
        private var isObservingKeyboard = false
        private var keyboardFrameInScreen: CGRect = .zero
        private var isKeyboardVisible = false

        init(_ parent: LyricsTextView) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func attach(to textView: UITextView) {
            self.textView = textView

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
                label.textColor = UIColor.label.withAlphaComponent(0.2)
                label.translatesAutoresizingMaskIntoConstraints = false
                textView.addSubview(label)
                NSLayoutConstraint.activate([
                    label.topAnchor.constraint(equalTo: textView.topAnchor),
                    label.leadingAnchor.constraint(equalTo: textView.leadingAnchor)
                ])
                placeholderLabel = label
            }
            placeholderLabel?.isHidden = !text.isEmpty
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.onCursorChange(textView.selectedRange.location)
            updatePlaceholder(textView, text: textView.text)
            // Invalidate intrinsic content size so SwiftUI resizes
            textView.invalidateIntrinsicContentSize()
            scheduleKeepCursorVisible()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.onCursorChange(textView.selectedRange.location)
            scheduleKeepCursorVisible()
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
            guard isKeyboardVisible, textView.isFirstResponder else { return }
            guard let scrollView = parentScrollView(for: textView) else { return }
            guard let selectedTextRange = textView.selectedTextRange else { return }

            textView.layoutIfNeeded()
            scrollView.layoutIfNeeded()

            let caretInTextView = textView.caretRect(for: selectedTextRange.start)
            let caretInScrollView = textView.convert(caretInTextView, to: scrollView)
            let visibleHeight = visibleHeightAboveKeyboard(in: scrollView)
            let lineHeight = textView.font?.lineHeight ?? 24
            let minCursorTop: CGFloat = 64
            let maxCursorTop = max(minCursorTop + lineHeight, visibleHeight * 0.45)

            let minAllowedOffset = caretInScrollView.minY - maxCursorTop
            let maxAllowedOffset = caretInScrollView.minY - minCursorTop
            let clampedOffset = scrollView.contentOffset.y.clamped(to: minAllowedOffset...maxAllowedOffset)
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

            return max(0, insetAdjustedHeight - keyboardOverlap)
        }
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
