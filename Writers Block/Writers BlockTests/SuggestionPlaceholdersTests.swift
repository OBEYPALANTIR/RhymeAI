import CoreGraphics
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
    func skeletonLineWidthsCycleAndNeverIndexOutOfRange() {
        let first = SuggestionScribbleMotion.lineWidths(for: 0)
        #expect(SuggestionScribbleMotion.lineWidths(for: 3) == first)
        #expect(SuggestionScribbleMotion.lineWidths(for: -1) == SuggestionScribbleMotion.lineWidths(for: 2))
        for slot in 0..<6 {
            let widths = SuggestionScribbleMotion.lineWidths(for: slot)
            #expect(widths.first > widths.second)
            #expect(widths.first < CGFloat(1))
        }
    }
}

struct SuggestionScribbleMotionTests {
    private let firstLineDuration = SuggestionScribbleMotion.writeDuration * SuggestionScribbleMotion.firstLineShare

    @Test
    func aLoopStartsOnABlankCard() {
        let lines = SuggestionScribbleMotion.lines(elapsed: 0)
        #expect(lines.first == 0)
        #expect(lines.second == 0)
    }

    @Test
    func theFirstLineIsWrittenBeforeTheSecondStarts() {
        let halfway = SuggestionScribbleMotion.lines(elapsed: firstLineDuration / 2)
        #expect(abs(halfway.first - 0.5) < 0.01)
        #expect(halfway.second == 0)

        let handover = SuggestionScribbleMotion.lines(elapsed: firstLineDuration)
        #expect(handover.first > 0.99)
        #expect(handover.second < 0.01)
    }

    @Test
    func bothLinesAreDrawnAtTheEndOfTheWriteAndThroughTheHold() {
        let written = SuggestionScribbleMotion.lines(elapsed: SuggestionScribbleMotion.writeDuration)
        #expect(written.first == 1)
        #expect(written.second == 1)

        let held = SuggestionScribbleMotion.lines(elapsed: SuggestionScribbleMotion.writeDuration + SuggestionScribbleMotion.holdDuration / 2)
        #expect(held.first == 1)
        #expect(held.second == 1)
    }

    @Test
    func theLoopWipesTheCardAndStartsAgainAfterTheHold() {
        let restarted = SuggestionScribbleMotion.lines(elapsed: SuggestionScribbleMotion.period)
        #expect(restarted.first < 0.001)
        #expect(restarted.second == 0)

        let early = SuggestionScribbleMotion.lines(elapsed: 0.2)
        let nextLoop = SuggestionScribbleMotion.lines(elapsed: SuggestionScribbleMotion.period + 0.2)
        #expect(abs(early.first - nextLoop.first) < 0.001)
    }

    @Test
    func reducedMotionHoldsTheFirstLineDrawnAndTheSecondPartWay() {
        #expect(SuggestionScribbleMotion.staticLines.first == 1)
        #expect(SuggestionScribbleMotion.staticLines.second > 0.1)
        #expect(SuggestionScribbleMotion.staticLines.second < 0.9)
    }

    @Test
    func theScribbleSpansItsRectAndItsDrawnEndFollowsItsLength() {
        let rect = CGRect(x: 0, y: 0, width: 210, height: 10)
        let points = ScribbleLineShape.points(in: rect)
        #expect(points.first?.x == 0)
        #expect(points.last?.x == 210)
        #expect(points.allSatisfy { $0.y >= 0 && $0.y <= 10 })

        let start = ScribbleLineShape.point(at: 0, in: rect)
        let middle = ScribbleLineShape.point(at: 0.5, in: rect)
        let end = ScribbleLineShape.point(at: 1, in: rect)
        #expect(start.x == 0)
        #expect(middle.x > 60 && middle.x < 150)
        #expect(abs(end.x - 210) < 0.001)
    }
}
