import XCTest

/// Resizes the app's window across the 760pt side-column width with the
/// window's corner handle. Needs an iPad in iPadOS "Windowed Apps"
/// (or Stage Manager) mode; each test skips when the window cannot be resized.
final class TabletWindowResizeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let simulatorName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad || simulatorName.localizedCaseInsensitiveContains("iPad"),
            "iPad-only window resize test"
        )
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    @MainActor
    func testTypingContinuesWhileTheWindowCrossesTheSideColumnWidth() throws {
        let app = launch()
        let lyrics = app.textViews["lyricsEditor"]
        lyrics.tap()
        app.typeText("Q")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "typing-before-resize \(NSCoder.string(for: app.windows.firstMatch.frame)) keyboards=\(app.keyboards.count)"
        shot.lifetime = .keepAlways
        add(shot)

        try narrowBelowSideColumnWidth(app)
        XCTAssertFalse(app.buttons["hideInlineAssistantButton"].exists, "The inline column should be gone below 760pt")
        XCTAssertEqual(lyrics.value(forKey: "hasKeyboardFocus") as? Bool, true, "The lyrics lost focus when the window narrowed")
        // No tap: typing only lands if the lyric view kept first responder.
        app.typeText("R")

        widen(app)
        XCTAssertTrue(app.buttons["hideInlineAssistantButton"].waitForExistence(timeout: 3))
        XCTAssertEqual(lyrics.value(forKey: "hasKeyboardFocus") as? Bool, true, "The lyrics lost focus when the window widened")
        app.typeText("S")

        let text = try XCTUnwrap(lyrics.value as? String)
        XCTAssertTrue(text.contains("QRS"), "Typing was interrupted across the resize: \(text)")
    }

    @MainActor
    func testHiddenInlineAssistantStaysHiddenAfterTheNarrowWindowPanel() throws {
        let app = launch()
        app.buttons["hideInlineAssistantButton"].tap()
        XCTAssertFalse(app.buttons["hideInlineAssistantButton"].waitForExistence(timeout: 1))

        try openPanelInNarrowWindowThenWiden(app)
        XCTAssertFalse(app.buttons["hideInlineAssistantButton"].exists, "Widening overrode the writer's choice to hide the column")
        XCTAssertEqual(app.buttons["unblockButton"].label, "Open AI suggestions")
    }

    @MainActor
    func testShownInlineAssistantReturnsAfterTheNarrowWindowPanel() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["hideInlineAssistantButton"].exists)

        try openPanelInNarrowWindowThenWiden(app)
        XCTAssertTrue(app.buttons["hideInlineAssistantButton"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["unblockButton"].label, "Hide AI suggestions")
    }

    // MARK: - Helpers

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store", "--ui-test-seed-prosody-song"]
        app.launch()
        XCTAssertTrue(app.textViews["lyricsEditor"].waitForExistence(timeout: 8))
        // The system remembers the last window size, so start from the widest.
        widen(app)
        XCTAssertTrue(app.buttons["hideInlineAssistantButton"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor
    private func openPanelInNarrowWindowThenWiden(_ app: XCUIApplication) throws {
        try narrowBelowSideColumnWidth(app)
        app.buttons["unblockButton"].tap()
        XCTAssertTrue(app.buttons["closeAssistantButton"].waitForExistence(timeout: 3), "UnBlock did not open the panel below 760pt")
        widen(app)
        XCTAssertFalse(app.buttons["closeAssistantButton"].exists, "The panel stayed open at the side-column width")
    }

    /// Drags the window's bottom-trailing corner slowly (a fast drag can
    /// snap the window to a preset size); the window recentres, so the width
    /// is read back rather than assumed.
    @MainActor
    @discardableResult
    private func resize(_ app: XCUIApplication, toWidth target: CGFloat) -> CGFloat {
        let frame = app.windows.firstMatch.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        // The bottom corner sits under a docked keyboard; then use the top one.
        let keyboardTop = app.keyboards.firstMatch.exists ? app.keyboards.firstMatch.frame.minY : .greatestFiniteMagnitude
        let y = frame.maxY - 6 < keyboardTop ? frame.maxY - 6 : frame.minY + 6
        let corner = origin.withOffset(CGVector(dx: frame.maxX - 6, dy: y))
        let destination = origin.withOffset(CGVector(dx: frame.minX + target - 6, dy: y))
        corner.press(forDuration: 0.6, thenDragTo: destination, withVelocity: .slow, thenHoldForDuration: 0.3)
        Thread.sleep(forTimeInterval: 1.2)
        return app.windows.firstMatch.frame.width
    }

    /// Narrows until the window is first under 760pt and checks the layout
    /// the app shows there. Window widths snap to steps that depend on the
    /// display (about 117pt on a 12.9-inch iPad, so the first width under 760
    /// can be 695pt), so any width that keeps the regular size class is
    /// accepted; if the step lands in the compact size class, widen one step.
    @MainActor
    private func narrowBelowSideColumnWidth(_ app: XCUIApplication) throws {
        let start = app.windows.firstMatch.frame.width
        var widths = [start]
        for _ in 0..<16 where widths.last! >= 760 {
            widths.append(resize(app, toWidth: max(widths.last! - 60, 740)))
        }
        try XCTSkipIf(widths.last! == start, "The window cannot be resized here; needs Windowed Apps or Stage Manager mode")
        if !usesRegularLayout(app), widths.count > 1 {
            widths.append(resize(app, toWidth: widths[widths.count - 2]))
            try XCTSkipIf(
                widths.last! >= 760 || !usesRegularLayout(app),
                "This display has no regular-width window under 760pt; widths reached: \(widths)"
            )
        }
        XCTAssertLessThan(widths.last!, 760, "Widths reached: \(widths)")
        XCTAssertTrue(usesRegularLayout(app), "Expected the regular size class; widths reached: \(widths)")
        // The single-column editor: no inline column, and UnBlock stays.
        XCTAssertFalse(app.buttons["hideInlineAssistantButton"].exists, "The inline column should be gone below 760pt; widths reached: \(widths)")
        XCTAssertTrue(app.buttons["unblockButton"].exists, "UnBlock is missing in the single-column editor; widths reached: \(widths)")
    }

    /// The writing column is inset 34pt in the regular layout and 20pt in the
    /// compact one (`editorSidePadding`); under 760pt it is not width-capped,
    /// so the inset is the title field's offset from the window edge.
    @MainActor
    private func usesRegularLayout(_ app: XCUIApplication) -> Bool {
        let title = app.textFields["songTitleEditor"]
        return title.exists && title.frame.minX - app.windows.firstMatch.frame.minX > 27
    }

    /// Widens until the window stops growing.
    @MainActor
    private func widen(_ app: XCUIApplication) {
        var width = app.windows.firstMatch.frame.width
        for _ in 0..<6 {
            let next = resize(app, toWidth: width + 400)
            if next <= width { break }
            width = next
        }
    }
}
