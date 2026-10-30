import CoreGraphics
import SwiftUI
import Testing
import UIKit
@testable import Writers_Block

/// After "Use line" the insertion mark holds, then dries into the page on the
/// transaction's settle animation; a clear with animations disabled (Reduce
/// Motion) or without an animation snaps it off, and the rewrite highlight
/// never fades. The fade is driven through the overlay's injectable driver,
/// so no test depends on the runner's clock or display.
@MainActor
struct InsertionHighlightFadeTests {
    private static let rect = CGRect(x: 0, y: 0, width: 120, height: 22)
    private static let range = NSRange(location: 0, length: 5)

    /// A fade the test steps through by hand: `changes` runs at once, as
    /// UIKit does, and `finish` plays the completion when the test says so.
    @MainActor
    private final class ManualFade {
        private(set) var animation: Animation?
        private var completion: (() -> Void)?
        var started: Bool { animation != nil }

        func driver() -> RewriteHighlightOverlayView.FadeDriver {
            { [self] animation, changes, completion in
                self.animation = animation
                self.completion = completion
                changes()
            }
        }

        func finish() {
            let completion = self.completion
            self.completion = nil
            completion?()
        }
    }

    private static func configuredOverlay() -> (RewriteHighlightOverlayView, ManualFade) {
        let view = RewriteHighlightOverlayView()
        let fade = ManualFade()
        view.fadeDriver = fade.driver()
        view.configure(
            rects: [rect],
            isLoading: false,
            colors: RewriteHighlightColors.insertion(palette: AppAppearanceStyle.ink.palette)
        )
        return (view, fade)
    }

    /// Pins the constant the editor's hold task sleeps on (PARITY: Android holds 2.0s too).
    @Test func theHoldConstantIsTwoSeconds() {
        #expect(EditorViewConstants.InsertionHighlight.holdDuration == 2.0)
    }

    @Test func onlyAClearedInsertionMarkFades() {
        let insertion = LyricsRewriteHighlight(range: Self.range, isLoading: false, isError: false, isInsertion: true)
        let rewrite = LyricsRewriteHighlight(range: Self.range, isLoading: true, isError: false)
        #expect(LyricsTextView.fadesOnClear(previous: insertion, next: nil))
        #expect(!LyricsTextView.fadesOnClear(previous: rewrite, next: nil), "the rewrite highlight clears in one frame")
        #expect(!LyricsTextView.fadesOnClear(previous: insertion, next: rewrite), "a replacement is drawn, not faded")
        #expect(!LyricsTextView.fadesOnClear(previous: nil, next: nil))
    }

    @Test func theFadeTakesTheTransactionsAnimationUnlessAnimationsAreDisabled() {
        var settle = Transaction(animation: RhymeAITokens.Motion.settle)
        #expect(LyricsTextView.highlightClearAnimation(for: settle) == RhymeAITokens.Motion.settle, "the transaction's own animation, not a substitute")
        // withRhymeAnimation(_, reduceMotion: true, _) disables animations on its transaction.
        settle.disablesAnimations = true
        #expect(LyricsTextView.highlightClearAnimation(for: settle) == nil)
        #expect(LyricsTextView.highlightClearAnimation(for: Transaction(animation: nil)) == nil)
    }

    @Test func aClearWithoutAnimationSnapsTheMarkOff() {
        let (view, fade) = Self.configuredOverlay()

        view.clear(animation: nil)

        #expect(!fade.started, "no fade runs for a one-frame clear")
        #expect(view.rects.isEmpty)
        #expect(view.colors == nil)
        #expect(view.alpha == 1)
    }

    @Test func aSettleClearKeepsTheMarkDrawnUntilTheFadeCompletesThenRemovesIt() {
        let (view, fade) = Self.configuredOverlay()

        view.clear(animation: RhymeAITokens.Motion.settle)

        #expect(fade.animation == RhymeAITokens.Motion.settle, "the fade runs on the animation it was handed")
        #expect(view.rects == [Self.rect], "the mark stays drawn while its alpha falls")
        #expect(view.alpha == 0, "the fade's end state")
        fade.finish()
        #expect(view.rects.isEmpty, "the rects go once the fade has completed")
        #expect(view.alpha == 1, "ready for the next mark")
    }

    @Test func aNewHighlightSurvivesTheOldFadesCompletion() {
        let (view, fade) = Self.configuredOverlay()
        view.clear(animation: RhymeAITokens.Motion.settle)

        view.configure(
            rects: [Self.rect],
            isLoading: true,
            colors: RewriteHighlightColors.pending(palette: AppAppearanceStyle.ink.palette)
        )
        #expect(view.alpha == 1)
        fade.finish()

        #expect(view.rects == [Self.rect], "the cancelled fade's completion must not erase the replacement")
        #expect(view.alpha == 1)
    }

    @Test func anEmptyOverlayHasNothingToFade() {
        let view = RewriteHighlightOverlayView()
        let fade = ManualFade()
        view.fadeDriver = fade.driver()

        view.clear(animation: RhymeAITokens.Motion.settle)

        #expect(!fade.started)
        #expect(view.alpha == 1)
        #expect(view.rects.isEmpty)
    }
}
