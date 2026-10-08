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

/// Motion for the skeleton rows. The breath is a slow opacity loop, not a
/// shimmer sweep: the design reserves gradients and glow, and the loop only
/// has to say "still writing". Android uses the same numbers.
enum SuggestionSkeletonMotion {
    static let minimumOpacity: Double = 0.55
    static let staticOpacity: Double = 0.75
    static let breathDuration: TimeInterval = 1.3
    static let breath: Animation = .easeInOut(duration: breathDuration).repeatForever(autoreverses: true)

    /// Bar widths, as fractions of the card's text column, so three stacked
    /// skeletons read as three different lines rather than one repeated block.
    static let lineWidthCycle: [(first: CGFloat, second: CGFloat)] = [(0.78, 0.46), (0.64, 0.38), (0.72, 0.52)]

    static func lineWidths(for slot: Int) -> (first: CGFloat, second: CGFloat) {
        let count = lineWidthCycle.count
        return lineWidthCycle[((slot % count) + count) % count]
    }
}
