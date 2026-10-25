import CoreGraphics
import Testing
import UIKit
@testable import Writers_Block

/// After "Use line" the insertion mark holds, then dries into the page on the
/// settle tier; a clear with animations disabled (Reduce Motion) snaps it off.
struct InsertionHighlightFadeTests {
    private static let rect = CGRect(x: 0, y: 0, width: 120, height: 22)

    @MainActor
    private static func configuredOverlay() -> RewriteHighlightOverlayView {
        let view = RewriteHighlightOverlayView()
        view.configure(
            rects: [rect],
            isLoading: false,
            colors: RewriteHighlightColors.insertion(palette: AppAppearanceStyle.ink.palette)
        )
        return view
    }

    @Test func theMarkHoldsTwoSecondsBeforeItDries() {
        #expect(EditorViewConstants.InsertionHighlight.holdDuration == 2.0)
    }

    @Test func theFadeIsTheSettleSpring() {
        #expect(RewriteHighlightOverlayView.fadeDuration == RhymeAITokens.Motion.settleDuration)
        #expect(RewriteHighlightOverlayView.fadeDuration == 0.42)
        #expect(RewriteHighlightOverlayView.fadeDamping == 0.80)
    }

    @Test @MainActor
    func aClearWithoutAnimationSnapsTheMarkOff() {
        let view = Self.configuredOverlay()

        view.clear(fading: false)

        #expect(view.rects.isEmpty)
        #expect(view.colors == nil)
        #expect(view.alpha == 1)
    }

    @Test @MainActor
    func aFadingClearKeepsTheMarkDrawnWhileItDries() {
        let view = Self.configuredOverlay()

        view.clear(fading: true)

        #expect(view.rects == [Self.rect], "the mark stays drawn while its alpha falls")
        #expect(view.alpha == 0, "the fade's end state")
    }

    @Test @MainActor
    func aNewHighlightCancelsTheFade() {
        let view = Self.configuredOverlay()
        view.clear(fading: true)

        view.configure(
            rects: [Self.rect],
            isLoading: true,
            colors: RewriteHighlightColors.pending(palette: AppAppearanceStyle.ink.palette)
        )

        #expect(view.alpha == 1)
        #expect(view.rects == [Self.rect])
    }

    @Test @MainActor
    func anEmptyOverlayHasNothingToFade() {
        let view = RewriteHighlightOverlayView()

        view.clear(fading: true)

        #expect(view.alpha == 1)
        #expect(view.rects.isEmpty)
    }
}
