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

        // The drawer's card, not the editor's toolbar button behind the drawer.
        let entry = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND identifier != %@", "One Liners", "editorOneLinersButton")).firstMatch
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
        XCTAssertTrue(app.staticTexts["10 syl · bathroom"].exists)
        Thread.sleep(forTimeInterval: 0.5)  // the toast settles
        attach(app, "4-list-saved")
        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Saved to One Liners")).firstMatch.frame
        let typeButton = app.buttons["Type a one liner"].frame
        XCTAssertLessThan(toast.maxY, typeButton.minY, "The toast covers the floating actions")

        line.tap()
        XCTAssertTrue(app.staticTexts["Edit one liner"].waitForExistence(timeout: 5))
        attach(app, "4b-edit")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Line updated"].waitForExistence(timeout: 5))

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
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, "7-capture-record")
        stop.tap()
        app.buttons["Save"].tap()
        let play = app.buttons["Play take"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        attach(app, "8-list-with-take")
        play.tap()
        XCTAssertTrue(app.buttons["Stop take"].waitForExistence(timeout: 5))
        attach(app, "9-playing")
        app.buttons["Stop take"].tap()
        XCTAssertTrue(app.buttons["Play take"].waitForExistence(timeout: 5))
    }

    /// A widget's Record, the Record control and the Record intent all hand the app
    /// `record`; the launch argument makes the same hand-off.
    @MainActor
    func testRecordActionOpensTheCaptureSheetRecording() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store", "-oneLinerPendingAction", "record"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "OK"])).firstMatch
            if allow.waitForExistence(timeout: 3) { allow.tap() }
        }
        XCTAssertTrue(app.staticTexts["New one liner"].waitForExistence(timeout: 8))
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8), "The sheet opens already recording")
        Thread.sleep(forTimeInterval: 1)
        attach(app, "shortcut-record")
        stop.tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Play take"].waitForExistence(timeout: 5), "The take lands in One Liners")
    }

    /// The link a widget's body and the URL scheme use, through the app's onOpenURL.
    @MainActor
    func testRecordLinkOpensTheCaptureSheetRecording() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store"]
        app.launch()
        app.open(try XCTUnwrap(URL(string: "writersblock://one-liners/record")))

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<3 {
            let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "Allow", "OK"])).firstMatch
            if allow.waitForExistence(timeout: 3) { allow.tap() }
        }
        XCTAssertTrue(app.staticTexts["New one liner"].waitForExistence(timeout: 8))
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8), "The link opens the sheet already recording")
        Thread.sleep(forTimeInterval: 1.5)
        attach(app, "link-record")
        stop.tap()
    }

    /// A widget's Type opens the sheet with the keyboard already up, from a cold start.
    @MainActor
    func testTypeLinkOpensTheCaptureWithTheKeyboardUp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store"]
        app.open(try XCTUnwrap(URL(string: "writersblock://one-liners/type")))

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirm = springboard.buttons["Open"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }

        XCTAssertTrue(app.staticTexts["New one liner"].waitForExistence(timeout: 8))
        // The field takes focus with no tap. A simulator that has seen a hardware keyboard
        // keeps the software one minimized, so focus is the check, not the keyboard's frame.
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5), "The field has the keyboard with no tap")
        XCTAssertEqual(focused.placeholderValue, "Say it or type it")
        XCTAssertEqual(app.keyboards.count, 1)
        attach(app, "link-type-keyboard")
        app.typeText("Straight from the widget")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", "Straight from the widget")).firstMatch.exists)
    }

    /// A second Record while a line is still being typed keeps the line and says so.
    @MainActor
    func testASecondRequestKeepsTheOpenCapture() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store", "-oneLinerPendingAction", "type"]
        app.launch()
        XCTAssertTrue(app.staticTexts["New one liner"].waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 0.8)  // the field takes focus once the sheet is up
        app.typeText("Half a heart still beats on time")
        let typed = app.descendants(matching: .any).matching(NSPredicate(format: "value == %@", "Half a heart still beats on time"))
        XCTAssertTrue(typed.firstMatch.waitForExistence(timeout: 3), "The words are typed before the second request")
        attach(app, "second-request-before")

        // The system opens the link into the running app; XCUIApplication.open relaunches it.
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: "writersblock://one-liners/record")))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirm = springboard.buttons["Open"]
        if confirm.waitForExistence(timeout: 3) { confirm.tap() }

        let notice = app.staticTexts["Finish this one liner first. Save it or close it, then try again."]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        attach(app, "second-request-after")
        XCTAssertFalse(app.buttons["Stop recording"].exists, "The second request does not start recording")
        XCTAssertTrue(typed.firstMatch.exists, "The typed words are still in the field")
        attach(app, "second-request-kept")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Half a heart still beats on time"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testOpenActionShowsOneLiners() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store", "-oneLinerPendingAction", "open"]
        app.launch()

        XCTAssertTrue(app.staticTexts["No one liners yet."].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Record a one liner"].exists)
        XCTAssertFalse(app.staticTexts["New one liner"].exists, "Open shows the list, not a capture")
        attach(app, "shortcut-open")
        app.buttons["Back to songs"].tap()
        XCTAssertFalse(app.staticTexts["No one liners yet."].waitForExistence(timeout: 2))
    }

    /// The first screen offers One Liners without opening a song.
    @MainActor
    func testWelcomeCardOpensOneLiners() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store"]
        app.launch()

        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "One Liners")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        attach(app, "welcome-card")
        card.tap()

        XCTAssertTrue(app.staticTexts["No one liners yet."].waitForExistence(timeout: 5))
        attach(app, "welcome-one-liners")
        app.buttons["Back to songs"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Back returns to the welcome screen")
    }

    @MainActor
    func testWelcomeTypeActionOpensTheCaptureFocused() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store"]
        app.launch()

        let type = app.buttons["welcomeTypeOneLiner"]
        XCTAssertTrue(type.waitForExistence(timeout: 8))
        type.tap()

        XCTAssertTrue(app.staticTexts["New one liner"].waitForExistence(timeout: 8))
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5), "The field has the keyboard with no tap")
        XCTAssertEqual(focused.placeholderValue, "Say it or type it")
        XCTAssertFalse(app.buttons["Stop recording"].exists, "Type does not record")
        attach(app, "welcome-type")
        app.typeText("Straight from the welcome screen")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Straight from the welcome screen"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testWelcomeRecordActionOpensTheCaptureRecording() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store"]
        app.launch()

        let record = app.buttons["welcomeRecordOneLiner"]
        XCTAssertTrue(record.waitForExistence(timeout: 8))
        record.tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0..<2 {
            let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "OK"])).firstMatch
            if allow.waitForExistence(timeout: 3) { allow.tap() }
        }
        XCTAssertTrue(app.staticTexts["New one liner"].waitForExistence(timeout: 8))
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 8), "The sheet opens already recording")
        Thread.sleep(forTimeInterval: 1)
        attach(app, "welcome-record")
        stop.tap()
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Play take"].waitForExistence(timeout: 5), "The take lands in One Liners")
    }

    @MainActor
    func testEditorToolbarButtonOpensOneLiners() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store"]
        app.launch()

        let welcomeNewSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        if welcomeNewSong.waitForExistence(timeout: 3) { welcomeNewSong.tap() }
        let button = app.buttons["editorOneLinersButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 8))
        XCTAssertEqual(button.label, "One Liners")
        attach(app, "editor-toolbar")
        button.tap()

        XCTAssertTrue(app.staticTexts["No one liners yet."].waitForExistence(timeout: 5))
        app.buttons["Back to songs"].tap()
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Back returns to the editor")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
