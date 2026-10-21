import CoreGraphics
import Testing
@testable import Writers_Block

@MainActor
struct SuggestionInkLineMotionTests {
    // MARK: - Slots

    @Test
    func opensOneGhostBeforeTheFirstLineArrives() {
        #expect(SuggestionInkLineMotion.placeholderCount(arrived: 0, isLoading: true) == 1)
        #expect(SuggestionInkLineMotion.slotCount(arrived: 0, isLoading: true) == 1)
    }

    @Test
    func eachArrivingLineTakesTheGhostsSlotAndTheNextGhostOpensBelow() {
        for arrived in 1...3 {
            #expect(SuggestionInkLineMotion.placeholderCount(arrived: arrived, isLoading: true) == 1)
            #expect(SuggestionInkLineMotion.slotCount(arrived: arrived, isLoading: true) == arrived + 1)
        }
    }

    @Test
    func longStreamsStillShowOneGhost() {
        #expect(SuggestionInkLineMotion.placeholderCount(arrived: 5, isLoading: true) == 1)
        #expect(SuggestionInkLineMotion.slotCount(arrived: 5, isLoading: true) == 6)
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

    // MARK: - Ink line

    @Test
    func theStrokeDrawsOnceOnTheSettleTierWithinTheUtilitarianCap() {
        #expect(SuggestionInkLineMotion.drawDuration == RhymeAITokens.Motion.settleDuration)
        #expect(SuggestionInkLineMotion.drawDuration <= 0.5)
    }

    @Test
    func theStrokeSettlesToALighterRestingInk() {
        #expect(SuggestionInkLineMotion.restingInkOpacity == 0.08)
        #expect(SuggestionInkLineMotion.strokeInkOpacity > SuggestionInkLineMotion.restingInkOpacity)
    }
}
