import XCTest

/// Songs drawer → One Liners: type a line, see it in the pool, open Send to
/// song, trash it with Undo, and open the record sheet.
final class OneLinersUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTypeSendTrashAndRecordFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store"]
        app.launch()

        let welcomeNewSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        if welcomeNewSong.waitForExistence(timeout: 3) { welcomeNewSong.tap() }
        let openDrawer = app.buttons["Open songs drawer"]
        XCTAssertTrue(openDrawer.waitForExistence(timeout: 8))
        openDrawer.tap()

        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "One Liners")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.6)
        attach(app, "1-drawer")
        entry.tap()

        XCTAssertTrue(app.staticTexts["No one liners yet."].waitForExistence(timeout: 5))
        attach(app, "2-empty")

        app.buttons["Type a one liner"].tap()
        XCTAssertTrue(app.staticTexts["Lands in One Liners. Pick a song later, or never."].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.8)  // the field takes focus once the sheet is up
        app.typeText("Found the Lord in a gas station bathroom")
        attach(app, "3-capture-type")
        app.buttons["Save"].tap()

        let line = app.staticTexts["Found the Lord in a gas station bathroom"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved to One Liners"].waitForExistence(timeout: 3))
        attach(app, "4-list-saved")

        line.swipeRight()
        let send = app.buttons["Send to song"]
        if send.waitForExistence(timeout: 3) { send.tap() }
        XCTAssertTrue(app.navigationBars["Send to song"].waitForExistence(timeout: 5))
        attach(app, "5-send-picker")
        app.buttons["Cancel"].tap()

        line.swipeLeft()
        let trash = app.buttons["Trash"]
        if trash.waitForExistence(timeout: 3) { trash.tap() }
        XCTAssertTrue(app.staticTexts["Line moved to Trash"].waitForExistence(timeout: 5))
        attach(app, "6-trashed")
        app.buttons["Undo"].tap()
        XCTAssertTrue(line.waitForExistence(timeout: 5))

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        app.buttons["Record a one liner"].tap()
        for _ in 0..<2 {
            let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "OK"])).firstMatch
            if allow.waitForExistence(timeout: 3) { allow.tap() }
        }
        XCTAssertTrue(app.staticTexts["New one liner"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, "7-capture-record")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
