import CoreGraphics
import Foundation
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

    // MARK: - Scribble loop

    private func progress(at elapsed: TimeInterval) -> (first: CGFloat, second: CGFloat) {
        SuggestionInkLineMotion.lineProgress(elapsed: elapsed)
    }

    @Test
    func theLoopWritesFor1_3sHoldsFor0_35sAndRepeats() {
        #expect(SuggestionInkLineMotion.writeDuration == 1.3)
        #expect(SuggestionInkLineMotion.holdDuration == 0.35)
        #expect(abs(SuggestionInkLineMotion.loopPeriod - 1.65) < 1e-9)
    }

    @Test
    func bothLinesStartUndrawn() {
        #expect(progress(at: 0) == (0, 0))
    }

    @Test
    func theFirstLineDrawsAloneOverTheFirst63PercentOfTheWrite() {
        let mid = progress(at: 1.3 * 0.63 / 2)
        #expect(abs(mid.first - 0.5) < 1e-6)
        #expect(mid.second == 0)
        let boundary = progress(at: 1.3 * 0.63)
        #expect(abs(boundary.first - 1) < 1e-6)
        #expect(boundary.second < 1e-6)
    }

    @Test
    func theSecondLineDrawsOverTheRestOfTheWrite() {
        let mid = progress(at: 1.3 * (0.63 + 0.37 / 2))
        #expect(mid.first == 1)
        #expect(abs(mid.second - 0.5) < 1e-6)
    }

    @Test
    func bothLinesStayDrawnThroughTheHold() {
        for elapsed in [1.3, 1.45, 1.64] {
            #expect(progress(at: elapsed) == (1, 1))
        }
    }

    @Test
    func theWipeRestartsTheLoopEachPeriod() {
        #expect(progress(at: 1.65) == (0, 0))
        let again = progress(at: 1.65 + 1.3 * 0.63 / 2)
        #expect(abs(again.first - 0.5) < 1e-6)
        #expect(again.second == 0)
        #expect(progress(at: 10 * 1.65 + 1.5) == (1, 1))
    }

    @Test
    func reduceMotionHoldsTheFirstLineDrawnAndTheSecondAt60Percent() {
        #expect(SuggestionInkLineMotion.stillProgress == (1, 0.6))
    }

    @Test
    func theSecondScribbleIsAbout60PercentOfTheFirst() {
        #expect(SuggestionInkLineMotion.secondLineShare == 0.6)
    }

    // MARK: - Scribble wave

    @Test
    func theWaveTilesAtA34ptPeriod() {
        let points = SuggestionInkLineMotion.wavePoints(width: 68)
        let xs = points.map(\.x)
        let expected: [CGFloat] = [0, 0.18, 0.42, 0.68, 1, 1.18, 1.42, 1.68, 2].map { $0 * 34 }
        #expect(xs.count == expected.count)
        for (x, want) in zip(xs, expected) { #expect(abs(x - want) < 1e-6) }
        #expect(abs(points[0].y - 5.5) < 1e-6)
        #expect(abs(points[1].y - 2.5) < 1e-6)
        #expect(abs(points[5].y - 2.5) < 1e-6)
        #expect(abs(points.last!.y - 5.8) < 1e-6)
    }

    @Test
    func theLastPeriodIsCutAtTheEdge() {
        // 40pt: one full period, then cut between 1.0 (34pt) and 1.18 (40.12pt).
        let points = SuggestionInkLineMotion.wavePoints(width: 40)
        #expect(points.count == 6)
        #expect(points.last!.x == 40)
        let share = (40 - 34) / (0.18 * 34)
        #expect(abs(points.last!.y - (5.8 + (2.5 - 5.8) * share)) < 1e-6)
        #expect(points.allSatisfy { $0.x <= 40 && $0.y >= 0 && $0.y <= 10 })
    }

    @Test
    func theWaveScalesToItsBoxAndIsEmptyWithNoWidth() {
        #expect(SuggestionInkLineMotion.wavePoints(width: 0).isEmpty)
        let tall = SuggestionInkLineMotion.wavePoints(width: 34, height: 20)
        #expect(abs(tall[2].y - 15.6) < 1e-6)
    }
}
