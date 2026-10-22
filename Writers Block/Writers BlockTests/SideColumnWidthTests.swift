import CoreGraphics
import Testing
@testable import Writers_Block

struct SideColumnWidthTests {
    @Test
    func sideColumnsTakeTheMinorGoldenShareWithA380Floor() {
        // iPad Pro 11-inch portrait: 38.2% is 319pt, so the 380pt floor holds.
        #expect(RhymeAITokens.Layout.sideColumnWidth(for: 834) == 380)
        // Landscape: 456pt leaves 738pt for the editor, about its 740pt cap.
        #expect(RhymeAITokens.Layout.sideColumnWidth(for: 1194) == 456)
        #expect(1194 - RhymeAITokens.Layout.sideColumnWidth(for: 1194) <= RhymeAITokens.Layout.editorMaxWidth)
        // The 1210pt-wide 11-inch (M5) window rounds 462.2 down.
        #expect(RhymeAITokens.Layout.sideColumnWidth(for: 1210) == 462)
    }
}
