import CoreGraphics
import Testing
@testable import Writers_Block

@MainActor
struct SuggestionInkLineMotionTests {
    // MARK: - Slots

    @Test
    func reservesThreeGhostSlotsBeforeTheFirstLineArrives() {
        #expect(SuggestionInkLineMotion.placeholderCount(arrived: 0, isLoading: true) == 3)
        #expect(SuggestionInkLineMotion.slotCount(arrived: 0, isLoading: true) == 3)
    }

    @Test
    func eachArrivingLineTakesTheNextReservedSlot() {
        #expect(SuggestionInkLineMotion.placeholderCount(arrived: 1, isLoading: true) == 2)
        #expect(SuggestionInkLineMotion.placeholderCount(arrived: 2, isLoading: true) == 1)
        #expect(SuggestionInkLineMotion.placeholderCount(arrived: 3, isLoading: true) == 0)
        #expect(SuggestionInkLineMotion.slotCount(arrived: 1, isLoading: true) == 3)
        #expect(SuggestionInkLineMotion.slotCount(arrived: 2, isLoading: true) == 3)
    }

    @Test
    func linesPastTheReservedSlotsAppendWithoutNewGhosts() {
        #expect(SuggestionInkLineMotion.placeholderCount(arrived: 5, isLoading: true) == 0)
        #expect(SuggestionInkLineMotion.slotCount(arrived: 5, isLoading: true) == 5)
    }

    @Test
    func noGhostsRemainOnceGenerationStops() {
        #expect(SuggestionInkLineMotion.placeholderCount(arrived: 0, isLoading: false) == 0)
        #expect(SuggestionInkLineMotion.placeholderCount(arrived: 1, isLoading: false) == 0)
        #expect(SuggestionInkLineMotion.slotCount(arrived: 1, isLoading: false) == 1)
        // A request that ends with no lines leaves nothing, so the section closes.
        #expect(SuggestionInkLineMotion.slotCount(arrived: 0, isLoading: false) == 0)
    }

    @Test
    func textBarFractionsCycleAcrossSlotsAndNeverIndexOutOfRange() {
        #expect(SuggestionInkLineMotion.textBarFraction(slot: 0) == SuggestionInkLineMotion.textBarFraction(slot: 3))
        #expect(SuggestionInkLineMotion.textBarFraction(slot: -1) == SuggestionInkLineMotion.textBarFraction(slot: 0))
        #expect(SuggestionInkLineMotion.textBarFractions.allSatisfy { $0 >= 0.4 && $0 <= 0.9 })
    }

    // MARK: - Ink line timing

    @Test
    func cycleIsBuiltFromTheMotionLadder() {
        #expect(SuggestionInkLineMotion.drawDuration == RhymeAITokens.Motion.settleDuration)
        #expect(SuggestionInkLineMotion.holdDuration == RhymeAITokens.Motion.stateDuration)
        #expect(SuggestionInkLineMotion.fadeDuration == RhymeAITokens.Motion.feedbackDuration)
        #expect(SuggestionInkLineMotion.restDuration == RhymeAITokens.Motion.stateDuration)
        #expect(abs(SuggestionInkLineMotion.cycleDuration - 1.10) < 0.0001)
    }

    @Test
    func noStepPassesTheUtilitarianCap() {
        let steps = [
            SuggestionInkLineMotion.drawDuration,
            SuggestionInkLineMotion.holdDuration,
            SuggestionInkLineMotion.fadeDuration,
            SuggestionInkLineMotion.restDuration,
        ]
        #expect(steps.allSatisfy { $0 <= 0.5 })
    }

    @Test
    func aLoopStartsOnABlankBar() {
        #expect(SuggestionInkLineMotion.phase(elapsed: 0) == 0)
        #expect(SuggestionInkLineMotion.phase(elapsed: -1) == 0)
        #expect(SuggestionInkLineMotion.strokeExtent(phase: 0) == 0)
    }

    @Test
    func strokeDrawsThenHoldsThenFades() {
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
    func theLoopWrapsAtTheEndOfEachCycle() {
        let cycle = SuggestionInkLineMotion.cycleDuration
        #expect(abs(SuggestionInkLineMotion.phase(elapsed: cycle)) < 0.0001)
        #expect(abs(SuggestionInkLineMotion.phase(elapsed: cycle + 0.1) - 0.1) < 0.0001)
        #expect(abs(SuggestionInkLineMotion.phase(elapsed: 3 * cycle + 0.25) - 0.25) < 0.0001)
    }

    @Test
    func stillBarReadsMoreStronglyThanTheRestingBar() {
        #expect(SuggestionInkLineMotion.staticInkOpacity > SuggestionInkLineMotion.restingInkOpacity)
        #expect(SuggestionInkLineMotion.staticInkOpacity < SuggestionInkLineMotion.strokeInkOpacity)
    }
}
