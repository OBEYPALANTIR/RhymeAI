import SwiftUI

/// Which edge the floating chrome (UnBlock + mic, One Liners Record + Type)
/// sits on. Left mirrors the cluster: round button outermost at the left edge.
/// Android mirror: `DominantHand`.
enum DominantHand: String, CaseIterable, Hashable, Identifiable {
    case right
    case left

    static let storageKey = "dominantHand"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .right: "Right"
        case .left: "Left"
        }
    }

    /// Handedness is physical: Left is the screen's left edge in every
    /// locale. In a right-to-left layout the leading edge is on the right, so
    /// the cluster's semantic edge (and its HStack order) flips with it.
    func usesLeadingEdge(in direction: LayoutDirection) -> Bool {
        (self == .left) != (direction == .rightToLeft)
    }

    /// Where the floating cluster sits along the bottom edge.
    func clusterAlignment(in direction: LayoutDirection) -> Alignment {
        usesLeadingEdge(in: direction) ? .bottomLeading : .bottomTrailing
    }

    func clusterAnchor(in direction: LayoutDirection) -> UnitPoint {
        usesLeadingEdge(in: direction) ? .bottomLeading : .bottomTrailing
    }

    static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .right
    }
}
