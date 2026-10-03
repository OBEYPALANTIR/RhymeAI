import Testing
import UIKit
@testable import Writers_Block

struct LyricsDynamicTypeTests {
    @Test
    func lyricsFontScalesForAccessibilityTextSizes() {
        let standardTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let accessibilityTraits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraLarge)

        let standardFont = LyricsTextView.lyricsFont(for: standardTraits.preferredContentSizeCategory)
        let accessibilityFont = LyricsTextView.lyricsFont(for: accessibilityTraits.preferredContentSizeCategory)

        #expect(accessibilityFont.pointSize > standardFont.pointSize)
    }
}
