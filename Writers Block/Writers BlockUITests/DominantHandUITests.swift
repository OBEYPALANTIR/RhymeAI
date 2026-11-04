import XCTest

/// The floating chrome follows Settings > Editor > Dominant hand: the round
/// button sits outermost at that hand's edge, the wide pill inside it.
final class DominantHandUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLeftHandMirrorsTheEditorAndOneLinersClusters() throws {
        let app = launch(hand: "left")
        let mic = app.buttons["micButton"]
        let unblock = app.buttons["unblockButton"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        XCTAssertLessThan(mic.frame.maxX, unblock.frame.minX, "The mic should be left of UnBlock")
        XCTAssertLessThan(mic.frame.minX, app.frame.width / 2, "The cluster should sit at the leading edge")

        let type = openOneLiners(app)
        XCTAssertLessThan(type.frame.maxX, app.buttons["Record a one liner"].frame.minX, "Type should be left of Record")
    }

    @MainActor
    func testRightHandKeepsTheClustersTrailing() throws {
        let app = launch(hand: "right")
        let mic = app.buttons["micButton"]
        let unblock = app.buttons["unblockButton"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(mic.frame.minX, unblock.frame.maxX, "The mic should be right of UnBlock")
        XCTAssertGreaterThan(mic.frame.maxX, app.frame.width / 2, "The cluster should sit at the trailing edge")

        let type = openOneLiners(app)
        XCTAssertGreaterThan(type.frame.minX, app.buttons["Record a one liner"].frame.maxX, "Type should be right of Record")
    }

    @MainActor
    private func launch(hand: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store", "-dominantHand", hand]
        app.launch()
        let newSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        if newSong.waitForExistence(timeout: 5) { newSong.tap() }
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 1.5) { tip.tap() }
        return app
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
