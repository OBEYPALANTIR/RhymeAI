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

    /// Where the floating cluster sits along the bottom edge.
    var clusterAlignment: Alignment { self == .left ? .bottomLeading : .bottomTrailing }

    var clusterAnchor: UnitPoint { self == .left ? .bottomLeading : .bottomTrailing }

    static func resolve(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .right
    }
}
