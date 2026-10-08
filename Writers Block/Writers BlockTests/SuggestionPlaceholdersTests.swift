import Testing
@testable import Writers_Block

struct SuggestionPlaceholdersTests {
    @Test
    func reservesThreeSkeletonSlotsBeforeTheFirstLineArrives() {
        #expect(SuggestionPlaceholders.count(isLoading: true, arrived: 0) == 3)
        #expect(SuggestionPlaceholders.slotCount(isLoading: true, arrived: 0) == 3)
    }

    @Test
    func eachArrivingLineTakesTheNextReservedSlot() {
        #expect(SuggestionPlaceholders.count(isLoading: true, arrived: 1) == 2)
        #expect(SuggestionPlaceholders.count(isLoading: true, arrived: 2) == 1)
        #expect(SuggestionPlaceholders.count(isLoading: true, arrived: 3) == 0)
        #expect(SuggestionPlaceholders.slotCount(isLoading: true, arrived: 2) == 3)
    }

    @Test
    func linesPastTheReservedSlotsAppendWithoutNewSkeletons() {
        #expect(SuggestionPlaceholders.count(isLoading: true, arrived: 5) == 0)
        #expect(SuggestionPlaceholders.slotCount(isLoading: true, arrived: 5) == 5)
    }

    @Test
    func noSkeletonsRemainOnceGenerationStops() {
        #expect(SuggestionPlaceholders.count(isLoading: false, arrived: 0) == 0)
        #expect(SuggestionPlaceholders.count(isLoading: false, arrived: 1) == 0)
        #expect(SuggestionPlaceholders.slotCount(isLoading: false, arrived: 1) == 1)
    }

    @Test
    func skeletonBarWidthsCycleAndNeverIndexOutOfRange() {
        let first = SuggestionSkeletonMotion.lineWidths(for: 0)
        #expect(SuggestionSkeletonMotion.lineWidths(for: 3) == first)
        #expect(SuggestionSkeletonMotion.lineWidths(for: -1) == SuggestionSkeletonMotion.lineWidths(for: 2))
        for slot in 0..<6 {
            let widths = SuggestionSkeletonMotion.lineWidths(for: slot)
            #expect(widths.first > widths.second)
            #expect(widths.first < 1)
        }
    }

    @Test
    func reducedMotionHoldsAReadableStaticOpacity() {
        #expect(SuggestionSkeletonMotion.staticOpacity > SuggestionSkeletonMotion.minimumOpacity)
        #expect(SuggestionSkeletonMotion.staticOpacity < 1)
    }
}
