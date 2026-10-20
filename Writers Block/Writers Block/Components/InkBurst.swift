import SwiftUI

/// The ink firework that ends a successful suggestion request: the spinner in
/// the primary button bursts into dots of ink that fly out, drop a little as if
/// wet, shrink and fade, while a blot at the centre collapses. It is the
/// Assistant's one celebratory beat. The geometry is deterministic so both
/// platforms draw the same burst; mirrors `InkBurstMotion` on Android.
enum InkBurstMotion {
    static let duration: TimeInterval = 0.48
    static let particleCount = 14

    /// How far the farthest dot travels.
    static let reach: CGFloat = 44

    /// Dot radius in flight; dots shrink to 40 percent of it as they fade.
    static let dotRadius: CGFloat = 2.2

    /// Blot radius at the start of the burst.
    static let blotRadius: CGFloat = 6

    /// One dot or blot: offset from the origin in units of `reach`, radius in points, alpha 0...1.
    struct Particle: Equatable {
        var x: CGFloat
        var y: CGFloat
        var radius: CGFloat
        var alpha: Double
    }

    /// Ease-out cubic: the dots leave fast and coast.
    static func eased(_ progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return 1 - pow(1 - p, 3)
    }

    static func alpha(_ progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return p < 0.7 ? 1 : 1 - (p - 0.7) / 0.3
    }

    /// The dots `progress` (0...1) into the burst.
    static func particles(progress: Double) -> [Particle] {
        let p = min(max(progress, 0), 1)
        let travel = eased(p)
        let alpha = alpha(p)
        // Dots keep their size in flight, then shrink to 40 percent as they fade.
        let radius = dotRadius * CGFloat(0.4 + 0.6 * alpha)
        return (0..<particleCount).map { index in
            // A fixed jitter per dot keeps the ring from reading as a gear.
            let jitter = Double((index * 7) % particleCount) / Double(particleCount) * 0.35
            let angle = Double(index) * (2 * .pi / Double(particleCount)) + jitter
            let speed = 0.72 + 0.28 * Double((index * 5) % 3) / 2
            let distance = travel * speed
            let drop = 0.18 * p * p
            var x = cos(angle) * distance
            var y = sin(angle) * distance + drop
            // The drop must not carry a dot past the reach.
            let length = hypot(x, y)
            if length > 1 {
                x /= length
                y /= length
            }
            return Particle(x: CGFloat(x), y: CGFloat(y), radius: radius, alpha: alpha)
        }
    }

    /// The blot left where the spinner was; it collapses as the dots leave.
    static func blot(progress: Double) -> Particle {
        let p = min(max(progress, 0), 1)
        return Particle(x: 0, y: 0, radius: blotRadius * CGFloat(1 - eased(p)), alpha: 1 - p)
    }
}

/// Draws one `InkBurstMotion` burst at `origin` (in this view's coordinates)
/// from `startedAt` until the burst has run its course. Pass `nil` for no
/// burst; the caller clears it after `InkBurstMotion.duration` so the timeline
/// stops ticking. Does not take touches.
struct InkBurstView: View {
    let startedAt: Date?
    let origin: CGPoint
    let ink: Color

    var body: some View {
        TimelineView(.animation(paused: startedAt == nil)) { context in
            Canvas { graphics, _ in
                guard let startedAt else { return }
                let progress = context.date.timeIntervalSince(startedAt) / InkBurstMotion.duration
                guard progress >= 0, progress < 1 else { return }
                for dot in InkBurstMotion.particles(progress: progress) {
                    let center = CGPoint(x: origin.x + dot.x * InkBurstMotion.reach, y: origin.y + dot.y * InkBurstMotion.reach)
                    let rect = CGRect(x: center.x - dot.radius, y: center.y - dot.radius, width: dot.radius * 2, height: dot.radius * 2)
                    graphics.fill(Path(ellipseIn: rect), with: .color(ink.opacity(dot.alpha)))
                }
                let blot = InkBurstMotion.blot(progress: progress)
                if blot.radius > 0 {
                    let rect = CGRect(x: origin.x - blot.radius, y: origin.y - blot.radius, width: blot.radius * 2, height: blot.radius * 2)
                    graphics.fill(Path(ellipseIn: rect), with: .color(ink.opacity(blot.alpha)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where the primary button's spinner is, so the burst can start from it.
struct SpinnerCenterPreferenceKey: PreferenceKey {
    static let defaultValue: CGPoint? = nil

    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) {
        value = nextValue() ?? value
    }
}
