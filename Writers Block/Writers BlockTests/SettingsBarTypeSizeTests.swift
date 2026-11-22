import SwiftUI
import Testing
@testable import Writers_Block

struct SettingsBarTypeSizeTests {
    @Test
    func barTypeSizeGrowsWithTheUserSizeUpToTheCompactCap() {
        let sizes = DynamicTypeSize.allCases
        for isCompact in [true, false] {
            let bar = sizes.map { SettingsView.barTypeSize(for: $0, isCompact: isCompact) }
            #expect(zip(bar, bar.dropFirst()).allSatisfy { $0 <= $1 }, "compact: \(isCompact)")
        }
        for size in sizes {
            #expect(SettingsView.barTypeSize(for: size, isCompact: true) == min(size, .xxxLarge))
            #expect(SettingsView.barTypeSize(for: size, isCompact: false) == size)
        }
        #expect(SettingsView.barTypeSize(for: .accessibility5, isCompact: true) == .xxxLarge)
    }
}
