import CoreGraphics
import SwiftUI
import Testing
import UIKit
@testable import Writers_Block

/// After "Use line" the insertion mark holds, then dries into the page on the
/// transaction's settle animation; a clear with animations disabled (Reduce
/// Motion) or without an animation snaps it off, and the rewrite highlight
/// never fades.
@MainActor
struct InsertionHighlightFadeTests {
    private static let rect = CGRect(x: 0, y: 0, width: 120, height: 22)
    private static let range = NSRange(location: 0, length: 5)

    /// An overlay on screen, so UIKit animations run and complete.
    private static func mountedOverlay() -> (UIWindow, RewriteHighlightOverlayView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let view = RewriteHighlightOverlayView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        view.configure(
            rects: [rect],
            isLoading: false,
            colors: RewriteHighlightColors.insertion(palette: AppAppearanceStyle.ink.palette)
        )
        return (window, view)
    }

    @Test func theMarkHoldsTwoSecondsBeforeItDries() {
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
        #expect(LyricsTextView.highlightClearAnimation(for: settle) != nil)
        // withRhymeAnimation(_, reduceMotion: true, _) disables animations on its transaction.
        settle.disablesAnimations = true
        #expect(LyricsTextView.highlightClearAnimation(for: settle) == nil)
        #expect(LyricsTextView.highlightClearAnimation(for: Transaction(animation: nil)) == nil)
    }

    @Test func aClearWithoutAnimationSnapsTheMarkOff() {
        let (window, view) = Self.mountedOverlay()
        defer { window.isHidden = true }

        view.clear(animation: nil)

        #expect(view.rects.isEmpty)
        #expect(view.colors == nil)
        #expect(view.alpha == 1)
    }

    @Test func aSettleClearKeepsTheMarkDrawnWhileItFadesThenRemovesIt() async throws {
        let (window, view) = Self.mountedOverlay()
        defer { window.isHidden = true }

        view.clear(animation: RhymeAITokens.Motion.settle)

        #expect(view.rects == [Self.rect], "the mark stays drawn while its alpha falls")
        #expect(view.alpha == 0, "the fade's end state")
        try await Task.sleep(for: .seconds(RhymeAITokens.Motion.settleDuration * 3))
        #expect(view.rects.isEmpty, "the rects go once the fade has completed")
        #expect(view.alpha == 1, "ready for the next mark")
    }

    @Test func aNewHighlightSurvivesTheOldFadesCompletion() async throws {
        let (window, view) = Self.mountedOverlay()
        defer { window.isHidden = true }
        view.clear(animation: RhymeAITokens.Motion.settle)

        view.configure(
            rects: [Self.rect],
            isLoading: true,
            colors: RewriteHighlightColors.pending(palette: AppAppearanceStyle.ink.palette)
        )

        #expect(view.alpha == 1)
        try await Task.sleep(for: .seconds(RhymeAITokens.Motion.settleDuration * 3))
        #expect(view.rects == [Self.rect], "the cancelled fade's completion must not erase the replacement")
        #expect(view.alpha == 1)
    }

    @Test func anEmptyOverlayHasNothingToFade() {
        let view = RewriteHighlightOverlayView()

        view.clear(animation: RhymeAITokens.Motion.settle)

        #expect(view.alpha == 1)
        #expect(view.rects.isEmpty)
    }
}
