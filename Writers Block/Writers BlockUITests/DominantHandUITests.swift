import XCTest

/// The floating chrome follows Settings > Editor > Dominant hand: the round
/// button sits outermost at that hand's physical edge, the wide pill inside it,
/// in left-to-right and right-to-left layouts alike.
final class DominantHandUITests: XCTestCase {
    /// Both flags: the writing direction alone does not mirror an iOS layout.
    private static let forceRightToLeft = [
        "-AppleTextDirection", "YES",
        "-NSForceRightToLeftWritingDirection", "YES",
    ]
    /// How close the round button must sit to its hand's edge of the content
    /// it floats over: the editor column (beside the inline assistant on iPad)
    /// or the One Liners list (capped at 740pt on a regular width).
    private static let edgeTolerance: CGFloat = 40

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLeftHandMirrorsTheEditorAndOneLinersClusters() throws {
        let app = launch(hand: "left")
        assertMicIsPhysically(left: true, in: app)
        assertOneLinersCluster(left: true, in: app)
    }

    @MainActor
    func testRightHandKeepsTheClustersTrailing() throws {
        let app = launch(hand: "right")
        assertMicIsPhysically(left: false, in: app)
        assertOneLinersCluster(left: false, in: app)
    }

    @MainActor
    func testLeftHandStaysPhysicallyLeftInRightToLeftLayout() throws {
        let app = launch(hand: "left", extraArguments: Self.forceRightToLeft)
        assertLayoutIsMirrored(app, element: app.buttons["Open songs drawer"])
        assertMicIsPhysically(left: true, in: app)
        assertOneLinersCluster(left: true, in: app, mirrored: true)
    }

    @MainActor
    func testRightHandStaysPhysicallyRightInRightToLeftLayout() throws {
        let app = launch(hand: "right", extraArguments: Self.forceRightToLeft)
        assertLayoutIsMirrored(app, element: app.buttons["Open songs drawer"])
        assertMicIsPhysically(left: false, in: app)
        assertOneLinersCluster(left: false, in: app, mirrored: true)
    }

    @MainActor
    func testSettingsPickerSwitchesHands() throws {
        // No -dominantHand argument: it would shadow what the picker writes.
        let app = launch(hand: nil)
        pickHand("Right", in: app)
        assertMicIsPhysically(left: false, in: app)

        pickHand("Left", in: app)
        assertMicIsPhysically(left: true, in: app)

        // Leave the simulator right-handed for the next run.
        pickHand("Right", in: app)
        assertMicIsPhysically(left: false, in: app)
    }

    @MainActor
    func testLeftHandedRecordingPillGrowsTowardTheCentreOnScreen() throws {
        try assertLeftHandedRecordingPillGrowsTowardTheCentre(extraArguments: [])
    }

    @MainActor
    func testLeftHandedRecordingPillGrowsTowardTheCentreInRightToLeftLayout() throws {
        try assertLeftHandedRecordingPillGrowsTowardTheCentre(extraArguments: Self.forceRightToLeft, mirrored: true)
    }

    // MARK: - Helpers

    @MainActor
    private func assertLeftHandedRecordingPillGrowsTowardTheCentre(extraArguments: [String], mirrored: Bool = false) throws {
        let app = launch(hand: "left", extraArguments: ["--ui-test-fake-voice-recording"] + extraArguments)
        if mirrored { assertLayoutIsMirrored(app, element: app.buttons["Open songs drawer"]) }
        let mic = app.buttons["micButton"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        mic.tap()
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 5))

        let timer = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+:[0-9]{2}$")).firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5), "The recording timer should show")
        Thread.sleep(forTimeInterval: 1)  // the pill finishes stretching
        let width = app.frame.width
        assertEdgeGap(mic.frame.minX - editorColumn(in: app).minX, "The stop button should stay at the left edge")
        XCTAssertGreaterThan(timer.frame.minX, mic.frame.maxX - 1, "The pill should grow right, toward the centre")
        XCTAssertLessThanOrEqual(timer.frame.maxX, width, "The recording pill ran off screen")
        XCTAssertLessThanOrEqual(app.buttons["unblockButton"].frame.maxX, width, "UnBlock was pushed off screen")

        app.buttons["Stop recording"].tap()
    }

    @MainActor
    private func launch(hand: String?, extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store"] + (hand.map { ["-dominantHand", $0] } ?? []) + extraArguments
        app.launch()
        let newSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        if newSong.waitForExistence(timeout: 5) { newSong.tap() }
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 1.5) { tip.tap() }
        return app
    }

    /// A button's distance inside its edge: never past the edge (negative,
    /// which would mean it is anchored somewhere else) and at most 40pt in.
    private func assertEdgeGap(_ gap: CGFloat, _ message: String, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(gap, 0, "\(message) (\(gap)pt past the edge)", line: line)
        XCTAssertLessThanOrEqual(gap, Self.edgeTolerance, "\(message) (\(gap)pt in from the edge)", line: line)
    }

    /// Precondition for the right-to-left cases: a control unrelated to the
    /// setting (a top-leading button) really did move to the right half, so
    /// the layout is mirrored and the physical-side assertions mean something.
    @MainActor
    private func assertLayoutIsMirrored(_ app: XCUIApplication, element: XCUIElement, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), line: line)
        XCTAssertGreaterThan(element.frame.midX, app.frame.width / 2, "The layout is not mirrored: \(element) stayed on the left", line: line)
    }

    @MainActor
    private func pickHand(_ hand: String, in app: XCUIApplication) {
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.segmentedControls["settingsTabPicker"].buttons["Editor"].tap()
        // The Editor section's identifier covers its children, so find the control by its options.
        let picker = app.segmentedControls.containing(.button, identifier: "Left").firstMatch
        // It closes the Editor tab, below the fold on a phone.
        if !picker.waitForExistence(timeout: 2) { app.swipeUp() }
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Dominant hand picker is missing from Settings")
        picker.buttons[hand].tap()
        app.buttons["Done"].tap()
    }

    @MainActor
    private func assertMicIsPhysically(left: Bool, in app: XCUIApplication, line: UInt = #line) {
        let mic = app.buttons["micButton"]
        let unblock = app.buttons["unblockButton"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5), line: line)
        let column = editorColumn(in: app)
        if left {
            XCTAssertLessThan(mic.frame.maxX, unblock.frame.minX, "The mic should be left of UnBlock", line: line)
            assertEdgeGap(mic.frame.minX - column.minX, "The mic should sit at the left edge", line: line)
        } else {
            XCTAssertGreaterThan(mic.frame.minX, unblock.frame.maxX, "The mic should be right of UnBlock", line: line)
            assertEdgeGap(column.maxX - mic.frame.maxX, "The mic should sit at the right edge", line: line)
        }
    }

    /// Type is the round button: outermost, within 40pt of the hand's edge.
    @MainActor
    private func assertOneLinersCluster(left: Bool, in app: XCUIApplication, mirrored: Bool = false, line: UInt = #line) {
        app.buttons["Open songs drawer"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND identifier != %@", "One Liners", "editorOneLinersButton")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), line: line)
        entry.tap()
        if mirrored { assertLayoutIsMirrored(app, element: app.buttons["Back to songs"], line: line) }

        let type = app.buttons["Type a one liner"]
        let record = app.buttons["Record a one liner"]
        XCTAssertTrue(type.waitForExistence(timeout: 5), line: line)
        // The cluster floats over the list, which spans the window on a
        // compact width and is capped at 740pt and centred on a regular one.
        let list = app.collectionViews.containing(NSPredicate(format: "label == %@", "No one liners yet.")).firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), "The One Liners list is missing", line: line)
        let content = list.frame
        if app.horizontalSizeClass == .compact {
            XCTAssertEqual(content.width, app.frame.width, accuracy: 1, "A compact list should span the window", line: line)
        }
        if left {
            XCTAssertLessThan(type.frame.maxX, record.frame.minX, "Type should be left of Record", line: line)
            assertEdgeGap(type.frame.minX - content.minX, "Type should sit at the left edge", line: line)
        } else {
            XCTAssertGreaterThan(type.frame.minX, record.frame.maxX, "Type should be right of Record", line: line)
            assertEdgeGap(content.maxX - type.frame.maxX, "Type should sit at the right edge", line: line)
        }
    }

    /// The editor column's horizontal extent, from its top bar's outermost
    /// controls (the songs drawer and Settings buttons sit at its two edges,
    /// in either layout direction). On iPad the inline assistant takes the
    /// rest of the window, so the window edge is not the column edge.
    @MainActor
    private func editorColumn(in app: XCUIApplication) -> (minX: CGFloat, maxX: CGFloat) {
        let drawer = app.buttons["Open songs drawer"].frame
        let settings = app.buttons["Settings"].frame
        return (min(drawer.minX, settings.minX), max(drawer.maxX, settings.maxX))
    }
}
