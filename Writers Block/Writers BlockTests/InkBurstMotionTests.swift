import CoreGraphics
import Foundation
import Testing
@testable import Writers_Block

@MainActor
struct InkBurstMotionTests {
    private let samples: [TimeInterval] = stride(from: 0, to: 0.48, by: 0.012).map { $0 }

    @Test
    func fourteenDotsAndTheBlotWhileTheBurstRuns() {
        let start = InkBurstMotion.dots(elapsed: 0)
        #expect(start.count == 15)
        #expect(start.last == InkBurstMotion.Dot(offset: .zero, radius: 6, alpha: 1))
        #expect(start.dropLast().allSatisfy { $0.offset == .zero })
        #expect(InkBurstMotion.dots(elapsed: 0.47).count >= 14)
    }

    @Test
    func halfwayOffsetsPinTheSpeedJitterAndDrop() {
        // Golden values from the spec formula at p = 0.5, in units of the reach.
        let dots = InkBurstMotion.dots(elapsed: 0.24)
        let expected: [CGPoint] = [
            CGPoint(x: 0.63, y: 0.045),
            CGPoint(x: 0.710207, y: 0.556107),
            CGPoint(x: 0.469176, y: 0.633328),
        ]
        for (dot, want) in zip(dots.prefix(3), expected) {
            #expect(abs(dot.offset.x - want.x) < 1e-4)
            #expect(abs(dot.offset.y - want.y) < 1e-4)
        }
    }

    @Test
    func nothingIsLeftOnceTheBurstIsOver() {
        #expect(InkBurstMotion.dots(elapsed: 0.48).isEmpty)
        #expect(InkBurstMotion.dots(elapsed: 2).isEmpty)
        #expect(InkBurstMotion.dots(elapsed: -0.01).isEmpty)
    }

    @Test
    func dotsStayOpaqueUntil70PercentThenFade() {
        for elapsed in samples {
            let dots = InkBurstMotion.dots(elapsed: elapsed).prefix(14)
            let p = elapsed / 0.48
            if p < 0.7 {
                #expect(dots.allSatisfy { $0.alpha == 1 && abs($0.radius - 2.2) < 1e-9 })
            } else if p > 0.71 {
                #expect(dots.allSatisfy { $0.alpha < 1 && $0.radius < 2.2 })
            }
        }
    }

    @Test
    func dotsShrinkTowards40PercentAsTheyFade() {
        let late = InkBurstMotion.dots(elapsed: 0.4799).prefix(14)
        #expect(late.allSatisfy { $0.alpha < 0.01 && abs($0.radius - 2.2 * 0.4) < 0.01 })
    }

    @Test
    func theBlotCollapsesOnTheSameCurve() {
        let early = InkBurstMotion.dots(elapsed: 0.1)
        #expect(early.count == 15)
        let p = 0.1 / 0.48
        let eased = 1 - pow(1 - p, 3)
        #expect(abs(early[14].radius - 6 * (1 - eased)) < 1e-9)
        #expect(abs(early[14].alpha - (1 - p)) < 1e-9)
    }

    @Test
    func theReachIsNeverPassed() {
        for elapsed in samples {
            for dot in InkBurstMotion.dots(elapsed: elapsed) {
                #expect((dot.offset.x * dot.offset.x + dot.offset.y * dot.offset.y).squareRoot() <= 1 + 1e-9)
            }
        }
        #expect(InkBurstMotion.reach == 44)
        #expect(InkBurstMotion.duration == 0.48)
    }
}
