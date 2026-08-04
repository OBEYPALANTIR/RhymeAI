import UIKit

enum RewriteHighlightGeometry {
    static func enclosingRects(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        characterRange: NSRange,
        textContainerInset: CGPoint
    ) -> [CGRect] {
        let textLength = layoutManager.textStorage?.length ?? 0
        guard characterRange.location != NSNotFound,
              characterRange.location <= textLength,
              characterRange.length <= textLength - characterRange.location else {
            return []
        }

        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var rects: [CGRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: textContainer
        ) { rect, _ in
            rects.append(
                rect
                    .insetBy(dx: -3, dy: -2)
                    .offsetBy(dx: textContainerInset.x, dy: textContainerInset.y)
            )
        }
        return rects
    }
}

enum RewriteHighlightOverlayLayout {
    static func install(_ overlay: UIView, in textView: UITextView) {
        overlay.frame = textView.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.addSubview(overlay)
    }
}
