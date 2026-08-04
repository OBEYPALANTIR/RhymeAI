import Testing
import UIKit
@testable import Writers_Block

struct LyricsDynamicTypeTests {
    @Test
    func lyricsFontScalesForAccessibilityTextSizes() {
        let standardTraits = UITraitCollection(preferredContentSizeCategory: .large)
        let accessibilityTraits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraLarge)

        let standardFont = LyricsTextView.scaledBodyFont(compatibleWith: standardTraits)
        let accessibilityFont = LyricsTextView.scaledBodyFont(compatibleWith: accessibilityTraits)

        #expect(accessibilityFont.pointSize > standardFont.pointSize)
    }
}
