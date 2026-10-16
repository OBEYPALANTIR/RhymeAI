import CoreGraphics
import Testing
@testable import Writers_Block

struct SuggestionInkLineMotionTests {
    @Test
    func threePlaceholdersBeforeTheFirstLineLands() {
        #expect(SuggestionInkLineMotion.placeholderCount(suggestionCount: 0, isLoading: true) == 3)
    }

    @Test
    func onePlaceholderTrailsTheListWhileTheStreamIsOpen() {
        #expect(SuggestionInkLineMotion.placeholderCount(suggestionCount: 1, isLoading: true) == 1)
        #expect(SuggestionInkLineMotion.placeholderCount(suggestionCount: 6, isLoading: true) == 1)
    }

    @Test
    func noPlaceholdersOnceTheStreamClosesOrIsStopped() {
        #expect(SuggestionInkLineMotion.placeholderCount(suggestionCount: 0, isLoading: false) == 0)
        #expect(SuggestionInkLineMotion.placeholderCount(suggestionCount: 4, isLoading: false) == 0)
    }

    @Test
    func cycleSumsTheMotionLadder() {
        #expect(abs(SuggestionInkLineMotion.drawDuration - 0.68) < 0.0001)
        #expect(abs(SuggestionInkLineMotion.holdDuration - 0.26) < 0.0001)
        #expect(abs(SuggestionInkLineMotion.fadeDuration - 0.16) < 0.0001)
        #expect(abs(SuggestionInkLineMotion.restDuration - 0.26) < 0.0001)
        #expect(abs(SuggestionInkLineMotion.cycleDuration - 1.36) < 0.0001)
        #expect(abs(SuggestionInkLineMotion.rowOffset - 0.26) < 0.0001)
    }

    @Test
    func strokeDrawsThenHoldsThenFades() {
        #expect(SuggestionInkLineMotion.strokeExtent(phase: 0) == 0)
        let midDraw = SuggestionInkLineMotion.strokeExtent(phase: SuggestionInkLineMotion.drawDuration / 2)
        #expect(midDraw > 0 && midDraw < 1)
        #expect(SuggestionInkLineMotion.strokeExtent(phase: SuggestionInkLineMotion.drawDuration) == 1)

        let holdEnd = SuggestionInkLineMotion.drawDuration + SuggestionInkLineMotion.holdDuration
        #expect(SuggestionInkLineMotion.strokeOpacity(phase: holdEnd - 0.001) == 1)
        let midFade = SuggestionInkLineMotion.strokeOpacity(phase: holdEnd + SuggestionInkLineMotion.fadeDuration / 2)
        #expect(midFade > 0 && midFade < 1)
        #expect(SuggestionInkLineMotion.strokeOpacity(phase: holdEnd + SuggestionInkLineMotion.fadeDuration) == 0)
        #expect(SuggestionInkLineMotion.strokeOpacity(phase: SuggestionInkLineMotion.cycleDuration - 0.001) == 0)
    }

    @Test
    func laterRowsStartOneStateTierLater() {
        #expect(SuggestionInkLineMotion.phase(elapsed: 0.1, row: 1) == 0)
        #expect(abs(SuggestionInkLineMotion.phase(elapsed: 0.36, row: 1) - 0.1) < 0.0001)
        #expect(abs(SuggestionInkLineMotion.phase(elapsed: 0.62, row: 2) - 0.1) < 0.0001)
        #expect(abs(SuggestionInkLineMotion.phase(elapsed: 1.36, row: 0)) < 0.0001)
    }

    @Test
    func textBarFractionsCycleAcrossRows() {
        #expect(SuggestionInkLineMotion.textBarFraction(row: 0) == SuggestionInkLineMotion.textBarFraction(row: 3))
        #expect(SuggestionInkLineMotion.textBarFractions.allSatisfy { $0 >= 0.4 && $0 <= 0.9 })
    }
}
