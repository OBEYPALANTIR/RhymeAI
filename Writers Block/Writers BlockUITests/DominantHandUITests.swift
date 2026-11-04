import XCTest

/// The floating chrome follows Settings > Editor > Dominant hand: the round
/// button sits outermost at that hand's physical edge, the wide pill inside it,
/// in left-to-right and right-to-left layouts alike.
final class DominantHandUITests: XCTestCase {
    private static let forceRightToLeft = ["-NSForceRightToLeftWritingDirection", "YES"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLeftHandMirrorsTheEditorAndOneLinersClusters() throws {
        let app = launch(hand: "left")
        assertMicIsPhysically(left: true, in: app)
        let type = openOneLiners(app)
        XCTAssertLessThan(type.frame.maxX, app.buttons["Record a one liner"].frame.minX, "Type should be left of Record")
    }

    @MainActor
    func testRightHandKeepsTheClustersTrailing() throws {
        let app = launch(hand: "right")
        assertMicIsPhysically(left: false, in: app)
        let type = openOneLiners(app)
        XCTAssertGreaterThan(type.frame.minX, app.buttons["Record a one liner"].frame.maxX, "Type should be right of Record")
    }

    @MainActor
    func testLeftHandStaysPhysicallyLeftInRightToLeftLayout() throws {
        let app = launch(hand: "left", extraArguments: Self.forceRightToLeft)
        assertMicIsPhysically(left: true, in: app)
        let type = openOneLiners(app)
        XCTAssertLessThan(type.frame.maxX, app.buttons["Record a one liner"].frame.minX, "RTL: Type should stay left of Record")
    }

    @MainActor
    func testRightHandStaysPhysicallyRightInRightToLeftLayout() throws {
        let app = launch(hand: "right", extraArguments: Self.forceRightToLeft)
        assertMicIsPhysically(left: false, in: app)
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
        let app = launch(hand: "left", extraArguments: ["--ui-test-fake-voice-recording"])
        let mic = app.buttons["micButton"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        mic.tap()
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 5))

        let timer = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+:[0-9]{2}$")).firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5), "The recording timer should show")
        Thread.sleep(forTimeInterval: 1)  // the pill finishes stretching
        let width = app.frame.width
        XCTAssertGreaterThan(timer.frame.minX, mic.frame.maxX - 1, "The pill should grow right, toward the centre")
        XCTAssertGreaterThanOrEqual(mic.frame.minX, 0)
        XCTAssertLessThanOrEqual(timer.frame.maxX, width, "The recording pill ran off screen")
        XCTAssertLessThanOrEqual(app.buttons["unblockButton"].frame.maxX, width, "UnBlock was pushed off screen")

        app.buttons["Stop recording"].tap()
    }

    // MARK: - Helpers

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
        let half = app.frame.width / 2
        if left {
            XCTAssertLessThan(mic.frame.maxX, unblock.frame.minX, "The mic should be left of UnBlock", line: line)
            XCTAssertLessThan(mic.frame.minX, half, "The cluster should sit at the left edge", line: line)
        } else {
            XCTAssertGreaterThan(mic.frame.minX, unblock.frame.maxX, "The mic should be right of UnBlock", line: line)
            XCTAssertGreaterThan(mic.frame.maxX, half, "The cluster should sit at the right edge", line: line)
        }
    }

    @MainActor
    private func openOneLiners(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["Open songs drawer"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND identifier != %@", "One Liners", "editorOneLinersButton")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let type = app.buttons["Type a one liner"]
        XCTAssertTrue(type.waitForExistence(timeout: 5))
        return type
    }
}
