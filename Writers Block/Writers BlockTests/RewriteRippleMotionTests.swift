import CoreGraphics
import Testing
import UIKit
@testable import Writers_Block

struct RewriteRippleMotionTests {
    @Test
    func loopEndpointsShareTheSamePhase() {
        #expect(RewriteRippleMotion.phase(progress: 0) == RewriteRippleMotion.phase(progress: 1))
    }

    @Test
    func secondWaveKeepsItsPhaseOffset() {
        let first = RewriteRippleMotion.verticalOffset(
            fraction: 0.25,
            progress: 0.4,
            amplitude: 1.45,
            phaseOffset: 0
        )
        let second = RewriteRippleMotion.verticalOffset(
            fraction: 0.25,
            progress: 0.4,
            amplitude: 1.45,
            phaseOffset: .pi * 0.7
        )

        #expect(abs(first - second) > 0.1)
    }

    @Test
    func reducedMotionUsesAStableRippleFrame() {
        #expect(RewriteRippleMotion.stableProgress == 0.72)
    }

    @Test
    func wallClockElapsedTimeDrivesTheLoop() {
        let halfway = RewriteRippleMotion.advancedProgress(from: 0, elapsed: 0.6)
        let looped = RewriteRippleMotion.advancedProgress(from: halfway, elapsed: 0.6)

        #expect(abs(halfway - 0.5) < 0.0001)
        #expect(abs(looped) < 0.0001)
    }

    @Test
    func loadingFillKeepsLyricsReadable() {
        #expect(RewriteRippleMotion.loadingSelectionFillOpacity <= 0.20)
    }

    @Test @MainActor
    func selectedPhraseGeometrySpansTheRequestedGlyphs() {
        let text = "[Verse]\nyellow music\nfollow music\nmellow music"
        let textStorage = NSTextStorage(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 16)
        ])
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: 320, height: 1_000))
        textContainer.lineFragmentPadding = 0
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let characterRange = (text as NSString).range(of: "yellow music")
        let rects = RewriteHighlightGeometry.enclosingRects(
            layoutManager: layoutManager,
            textContainer: textContainer,
            characterRange: characterRange,
            textContainerInset: .zero
        )

        #expect(rects.count == 1)
        #expect(rects[0].width > 80)
        #expect(rects[0].minY > 10)
    }

    @Test @MainActor
    func highlightOverlayFollowsTheTextViewBounds() {
        let textView = UITextView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let overlay = UIView()

        RewriteHighlightOverlayLayout.install(overlay, in: textView)
        textView.bounds.size = CGSize(width: 360, height: 240)
        textView.layoutIfNeeded()

        #expect(overlay.frame == textView.bounds)
    }

    @Test @MainActor
    func loadingHighlightIsStillAndKeepsThePaletteColours() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let textView = UITextView(frame: window.bounds)
        let overlay = RewriteHighlightOverlayView(frame: textView.bounds)
        window.addSubview(textView)
        RewriteHighlightOverlayLayout.install(overlay, in: textView)

        let colors = RewriteHighlightColors.pending(palette: AppAppearanceStyle.ink.palette)
        overlay.configure(
            rects: [CGRect(x: 10, y: 10, width: 120, height: 24)],
            isLoading: true,
            colors: colors
        )

        #expect(overlay.layer.animationKeys() == nil)
        #expect(overlay.colors == colors)
    }

    @Test
    func pendingRewriteUsesTheAppearanceSelectionAndOutline() {
        for style in [AppAppearanceStyle.ink, .paper, .graphite] {
            let palette = style.palette
            let pending = RewriteHighlightColors.pending(palette: palette)
            #expect(pending.fill == UIColor(palette.selectionTint).withAlphaComponent(RewriteHighlightColors.pendingFillOpacity))
            #expect(pending.stroke == UIColor(palette.outlineStrong).withAlphaComponent(RewriteHighlightColors.pendingStrokeOpacity))

            let failed = RewriteHighlightColors.error(palette: palette)
            #expect(failed.fill == UIColor(palette.error).withAlphaComponent(RewriteHighlightColors.errorFillOpacity))
        }
    }

    @Test
    func highlightKindPicksItsColours() {
        let palette = AppAppearanceStyle.ink.palette
        let loading = LyricsRewriteHighlight(range: NSRange(location: 0, length: 4), isLoading: true, isError: false, isInsertion: false)
        let failed = LyricsRewriteHighlight(range: NSRange(location: 0, length: 4), isLoading: false, isError: true, isInsertion: false)
        let inserted = LyricsRewriteHighlight(range: NSRange(location: 0, length: 4), isLoading: false, isError: false, isInsertion: true)

        #expect(RewriteHighlightColors.forHighlight(loading, palette: palette) == .pending(palette: palette))
        #expect(RewriteHighlightColors.forHighlight(failed, palette: palette) == .error(palette: palette))
        #expect(RewriteHighlightColors.forHighlight(inserted, palette: palette) == .insertion(palette: palette))
    }

    @Test @MainActor
    func malformedSelectionRangeDoesNotOverflow() {
        let textStorage = NSTextStorage(string: "short")
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: 320, height: 180))
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)

        let rects = RewriteHighlightGeometry.enclosingRects(
            layoutManager: layoutManager,
            textContainer: textContainer,
            characterRange: NSRange(location: Int.max - 2, length: 10),
            textContainerInset: .zero
        )

        #expect(rects.isEmpty)
    }
}
