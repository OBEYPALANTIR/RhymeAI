import CoreGraphics
import Foundation
import Testing
@testable import Writers_Block

struct InkBurstMotionTests {
    private func distance(_ particle: InkBurstMotion.Particle) -> CGFloat {
        hypot(particle.x, particle.y)
    }

    @Test
    func theBurstStartsAsABlotWhereTheSpinnerWas() {
        let dots = InkBurstMotion.particles(progress: 0)
        #expect(dots.count == InkBurstMotion.particleCount)
        #expect(dots.allSatisfy { distance($0) < 0.001 && $0.alpha == 1 })
        #expect(InkBurstMotion.blot(progress: 0).radius == InkBurstMotion.blotRadius)
        #expect(InkBurstMotion.blot(progress: 0).alpha == 1)
    }

    @Test
    func dotsLeaveFastCoastAndNeverPassTheReach() {
        let early = InkBurstMotion.particles(progress: 0.25).map(distance)
        let late = InkBurstMotion.particles(progress: 0.75).map(distance)
        let end = InkBurstMotion.particles(progress: 1).map(distance)
        #expect(zip(early, late).allSatisfy { $1 > $0 })
        #expect(early.reduce(0, +) / CGFloat(early.count) > 0.3)
        #expect(end.allSatisfy { $0 <= 1.0001 })
        #expect(InkBurstMotion.particles(progress: 0.9).allSatisfy { distance($0) <= 1.0001 })
    }

    @Test
    func dotsHoldTheirInkThenFadeOutByTheEnd() {
        #expect(InkBurstMotion.alpha(0.5) == 1)
        #expect(InkBurstMotion.alpha(0.85) > 0.4 && InkBurstMotion.alpha(0.85) < 0.6)
        #expect(abs(InkBurstMotion.alpha(1)) < 0.0001)
        #expect(InkBurstMotion.particles(progress: 1).allSatisfy { abs($0.alpha) < 0.0001 })
    }

    @Test
    func dotsKeepTheirSizeInFlightThenShrinkAsTheyFade() {
        let full = InkBurstMotion.dotRadius
        #expect(InkBurstMotion.particles(progress: 0.5).allSatisfy { abs($0.radius - full) < 0.0001 })
        #expect(InkBurstMotion.particles(progress: 0.69).allSatisfy { abs($0.radius - full) < 0.0001 })
        #expect(InkBurstMotion.particles(progress: 0.85).allSatisfy { $0.radius < full && $0.radius > full * 0.4 })
        #expect(InkBurstMotion.particles(progress: 1).allSatisfy { abs($0.radius - full * 0.4) < 0.0001 })
    }

    @Test
    func theBlotCollapsesAsTheDotsLeave() {
        #expect(InkBurstMotion.blot(progress: 0.5).radius < InkBurstMotion.blot(progress: 0.1).radius)
        #expect(InkBurstMotion.blot(progress: 1).radius == 0)
        #expect(InkBurstMotion.blot(progress: 1).alpha == 0)
    }

    @Test
    func wetInkDropsALittleOnItsWayOut() {
        let dots = InkBurstMotion.particles(progress: 1)
        let meanY = dots.map(\.y).reduce(0, +) / CGFloat(dots.count)
        #expect(meanY > 0.1)
    }

    @Test
    func theRingIsNotAGear() {
        let angles = InkBurstMotion.particles(progress: 0.5).map { atan2($0.y, $0.x) }.sorted()
        let gaps = zip(angles.dropFirst(), angles).map { $0 - $1 }
        #expect((gaps.max() ?? 0) - (gaps.min() ?? 0) > 0.05)
    }

    @Test
    func theBurstIsTheOneBeatAllowedPastTheUtilitarianTiers() {
        #expect(InkBurstMotion.duration <= 0.5)
    }
}
