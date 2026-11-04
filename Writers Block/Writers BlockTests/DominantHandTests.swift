import Foundation
import SwiftUI
import Testing
@testable import Writers_Block

struct DominantHandTests {
    @Test
    func preferenceRoundTripsThroughDefaults() throws {
        let suiteName = "DominantHandTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(DominantHand.storageKey == "dominantHand")
        // Nothing stored yet: right-handed.
        #expect(DominantHand.resolve(defaults.string(forKey: DominantHand.storageKey)) == .right)

        for hand in DominantHand.allCases {
            defaults.set(hand.rawValue, forKey: DominantHand.storageKey)
            #expect(DominantHand.resolve(defaults.string(forKey: DominantHand.storageKey)) == hand)
        }
    }

    @Test
    func unknownValuesFallBackToRight() {
        #expect(DominantHand.resolve("ambidextrous") == .right)
        #expect(DominantHand.allCases.map(\.displayName) == ["Right", "Left"])
    }

    @Test
    func handednessStaysPhysicalInBothLayoutDirections() {
        // Left-to-right: leading is the left edge.
        #expect(DominantHand.left.usesLeadingEdge(in: .leftToRight))
        #expect(!DominantHand.right.usesLeadingEdge(in: .leftToRight))
        #expect(DominantHand.left.clusterAlignment(in: .leftToRight) == .bottomLeading)
        #expect(DominantHand.right.clusterAlignment(in: .leftToRight) == .bottomTrailing)
        // Right-to-left: leading is the right edge, so Left uses trailing.
        #expect(!DominantHand.left.usesLeadingEdge(in: .rightToLeft))
        #expect(DominantHand.right.usesLeadingEdge(in: .rightToLeft))
        #expect(DominantHand.left.clusterAlignment(in: .rightToLeft) == .bottomTrailing)
        #expect(DominantHand.right.clusterAlignment(in: .rightToLeft) == .bottomLeading)
    }
}
