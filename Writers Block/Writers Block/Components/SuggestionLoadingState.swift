import SwiftUI

/// How many empty suggestion slots the Assistant shows while lines are still
/// arriving. Suggestions stream in one line at a time, so the panel reserves a
/// few slots up front and lets each arriving line take the next one; lines past
/// the reserved slots simply append. Mirrors `SuggestionPlaceholders` on Android.
enum SuggestionPlaceholders {
    /// Slots drawn as skeleton rows before the first line arrives.
    static let visibleSlots = 3

    /// Skeleton rows to draw under the lines that have already arrived.
    static func count(isLoading: Bool, arrived: Int) -> Int {
        isLoading ? max(visibleSlots - arrived, 0) : 0
    }

    /// Total slots to lay out: every arrived line plus any remaining placeholders.
    static func slotCount(isLoading: Bool, arrived: Int) -> Int {
        arrived + count(isLoading: isLoading, arrived: arrived)
    }
}

/// The scribble that draws a skeleton row's two lines in, as if by a pencil,
/// while the real line is being written. One loop writes the first (longer)
/// line, then the second, holds for a beat, and starts over on a clean card. The wave is the UnBlock
/// underline's zigzag, tiled along the line. Mirrors `ScribbleMotion` on
/// Android; the numbers are shared and unit-tested on both platforms.
enum SuggestionScribbleMotion {
    /// Time to write both lines, start to finish.
    static let writeDuration: TimeInterval = 1.3

    /// Pause with both lines drawn before the card is wiped and written again.
    static let holdDuration: TimeInterval = 0.35
    static let period: TimeInterval = writeDuration + holdDuration

    /// Share of the writing time the first line takes: its share of the two lines' length.
    static let firstLineShare: Double = 0.63

    /// Under Reduce Motion the card holds this frame: first line drawn, second part way.
    static let staticLines: (first: Double, second: Double) = (1, 0.6)

    /// One wave of the UnBlock scribble in unit space: the same five points as
    /// `EditorViewConstants.Scribble` in EditorView.swift, which is private there.
    static let wave: [CGPoint] = [
        CGPoint(x: 0, y: 0.55),
        CGPoint(x: 0.18, y: 0.25),
        CGPoint(x: 0.42, y: 0.78),
        CGPoint(x: 0.68, y: 0.28),
        CGPoint(x: 1, y: 0.58),
    ]
    static let waveWidth: CGFloat = 34
    static let lineHeight: CGFloat = 10
    static let strokeWidth: CGFloat = 1.6

    /// Line lengths, as fractions of the card's text column, so three stacked
    /// skeletons read as three different lines rather than one repeated block.
    static let lineWidthCycle: [(first: CGFloat, second: CGFloat)] = [(0.78, 0.46), (0.64, 0.38), (0.72, 0.52)]

    static func lineWidths(for slot: Int) -> (first: CGFloat, second: CGFloat) {
        let count = lineWidthCycle.count
        return lineWidthCycle[((slot % count) + count) % count]
    }

    /// How much of each line is drawn `elapsed` seconds into the loop, each in 0...1.
    static func lines(elapsed: TimeInterval) -> (first: Double, second: Double) {
        let wrapped = elapsed - period * (elapsed / period).rounded(.down)
        let phase = wrapped / writeDuration
        let first = min(max(phase / firstLineShare, 0), 1)
        let second = min(max((phase - firstLineShare) / (1 - firstLineShare), 0), 1)
        return (first, second)
    }
}

/// The UnBlock wave tiled across a rect, as a strokeable shape. `trim(from:to:)`
/// draws it in from the left; `point(at:in:)` says where the drawn end is.
struct ScribbleLineShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points = Self.points(in: rect)
        guard let start = points.first else { return path }
        path.move(to: start)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    /// The polyline, in `rect`'s coordinates. Waves keep their 34-point period
    /// whatever the rect's width; the last one is cut at the edge, interpolating
    /// the segment it was on.
    static func points(in rect: CGRect) -> [CGPoint] {
        let waveWidth = SuggestionScribbleMotion.waveWidth
        let wave = SuggestionScribbleMotion.wave
        guard let first = wave.first, rect.width > 0 else { return [] }
        var points = [CGPoint(x: rect.minX, y: rect.minY + first.y * rect.height)]
        var cycle = 0
        while true {
            // Each wave continues from the previous wave's end point.
            for unit in wave.dropFirst() {
                let x = rect.minX + (CGFloat(cycle) + unit.x) * waveWidth
                let y = rect.minY + unit.y * rect.height
                if x >= rect.maxX {
                    let previous = points[points.count - 1]
                    let fraction = x > previous.x ? (rect.maxX - previous.x) / (x - previous.x) : 0
                    points.append(CGPoint(x: rect.maxX, y: previous.y + (y - previous.y) * fraction))
                    return points
                }
                points.append(CGPoint(x: x, y: y))
            }
            cycle += 1
        }
    }

    /// The point `progress` (0...1) of the way along the polyline by length.
    static func point(at progress: Double, in rect: CGRect) -> CGPoint {
        let points = points(in: rect)
        guard points.count > 1 else { return points.first ?? CGPoint(x: rect.minX, y: rect.midY) }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        var remaining = total * CGFloat(min(max(progress, 0), 1))
        for (index, length) in lengths.enumerated() {
            if remaining <= length || index == lengths.count - 1 {
                let fraction = length > 0 ? min(remaining / length, 1) : 0
                let from = points[index]
                let to = points[index + 1]
                return CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
            }
            remaining -= length
        }
        return points[points.count - 1]
    }
}
