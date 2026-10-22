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

    @Test(arguments: [678, 759] as [CGFloat])
    func narrowRegularWindowsUseTheSingleColumn(windowWidth: CGFloat) {
        // Stage Manager down to the regular threshold, Split View 1/2: a 380pt
        // column would leave the editor narrower than the column itself.
        #expect(!RhymeAITokens.Layout.fitsSideColumn(windowWidth: windowWidth))
        #expect(windowWidth - RhymeAITokens.Layout.sideColumnWidth(for: windowWidth) < RhymeAITokens.Layout.assistantColumnWidth)
    }

    @Test(arguments: [760, 795, 834, 1024, 1194, 1210] as [CGFloat])
    func twoColumnWindowsKeepTheEditorAtLeastAsWideAsTheColumn(windowWidth: CGFloat) {
        // 760 is the threshold; 795 is Split View 2/3 on the 11-inch.
        #expect(RhymeAITokens.Layout.fitsSideColumn(windowWidth: windowWidth))
        #expect(windowWidth - RhymeAITokens.Layout.sideColumnWidth(for: windowWidth) >= RhymeAITokens.Layout.assistantColumnWidth)
    }

    @Test(arguments: [true, false])
    func reachingTheSideColumnWidthClosesThePanelAndKeepsTheChoice(inlineColumn: Bool) {
        // Hidden or shown before the window narrowed, the column stays that way.
        let narrowWithPanel = TabletAssistantVisibility(inlineColumn: inlineColumn, sheet: true)
        #expect(narrowWithPanel.crossing(toSideColumns: true) == TabletAssistantVisibility(inlineColumn: inlineColumn, sheet: false))
        #expect(narrowWithPanel.crossing(toSideColumns: false) == narrowWithPanel)
    }
}
