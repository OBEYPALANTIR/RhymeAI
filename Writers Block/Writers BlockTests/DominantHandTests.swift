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
    func unknownValuesFallBackToRightAndLeftMirrorsTheCluster() {
        #expect(DominantHand.resolve("ambidextrous") == .right)
        #expect(DominantHand.allCases.map(\.displayName) == ["Right", "Left"])
        #expect(DominantHand.right.clusterAlignment == .bottomTrailing)
        #expect(DominantHand.left.clusterAlignment == .bottomLeading)
    }
}
