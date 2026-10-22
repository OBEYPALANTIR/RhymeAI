import XCTest

/// Settings → Backup against the app's in-memory Google Drive and fake sign-in
/// (`--ui-test-fake-drive`), so no account or network is involved.
final class BackupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    override func setUp() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testBackupSectionStatesThroughConnectBackUpAndDisconnect() throws {
        let app = launch()
        createNewSong(in: app)
        openBackup(in: app)

        XCTAssertTrue(waitForLabel(element("backupProviderStatus", in: app), "Google Drive not connected"))
        let footer = element("backupFooter", in: app)
        XCTAssertEqual(footer.label, "Songs, trash and recordings are backed up to your Google Drive's private app storage. API keys are never included. Songs and recordings also sync through iCloud.")
        XCTAssertFalse(app.buttons["backUpNow"].isEnabled)
        XCTAssertFalse(app.buttons["disconnectGoogleDrive"].exists)

        tap(app.buttons["connectGoogleDrive"], in: app)
        XCTAssertTrue(waitForLabel(element("backupProviderStatus", in: app), "Waiting to back up · Google Drive"))
        XCTAssertTrue(app.buttons["disconnectGoogleDrive"].waitForExistence(timeout: 5))

        tap(app.buttons["backUpNow"], in: app)
        XCTAssertTrue(waitForLabel(element("backupProviderStatus", in: app), "Last backed up just now · Google Drive"))
        XCTAssertTrue(waitForLabel(element("cloudBackupStatus", in: app), "Backup complete."))

        tap(app.buttons["disconnectGoogleDrive"], in: app)
        XCTAssertTrue(waitForLabel(element("backupProviderStatus", in: app), "Google Drive not connected"))
        XCTAssertTrue(waitForLabel(element("cloudBackupStatus", in: app), "Disconnected from Google Drive."))
        XCTAssertTrue(app.buttons["connectGoogleDrive"].exists)
        XCTAssertFalse(app.buttons["backUpNow"].isEnabled)
    }

    @MainActor
    func testConnectingOffersTheDriveSongsAndRestoreMergesThem() throws {
        let app = launch(["--ui-test-fake-drive-seeded"])
        createNewSong(in: app)
        openBackup(in: app)

        tap(app.buttons["connectGoogleDrive"], in: app)

        XCTAssertTrue(app.staticTexts["Restore your songs?"].waitForExistence(timeout: 5))
        XCTAssertEqual(element("firstRunRestoreBody", in: app).label, "We found 2 songs and 2 recordings in your Google Drive backup.")
        app.buttons["firstRunRestore"].tap()

        XCTAssertTrue(waitForLabel(element("cloudBackupStatus", in: app), "Restore complete. Projects, trash, and missing recordings were restored."))
        XCTAssertTrue(waitForLabel(element("backupProviderStatus", in: app), "Last backed up just now · Google Drive"))
        XCTAssertFalse(app.staticTexts["Restore your songs?"].exists)

        // Close Settings by dragging the sheet down from its title bar.
        let title = app.navigationBars["Settings"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        title.press(forDuration: 0.1, thenDragTo: title.withOffset(CGVector(dx: 0, dy: 700)))
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))
        let drawer = app.buttons["Open songs drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        drawer.tap()
        XCTAssertTrue(text("Drive Song One", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(text("Drive Song Two", in: app).exists)
    }

    @MainActor
    func testAnEmptyLibraryIsOfferedTheBackupAtLaunchAndNotNowLeavesItAlone() throws {
        let app = launch(["--ui-test-fake-drive-seeded", "--ui-test-fake-drive-connected"])

        XCTAssertTrue(app.staticTexts["Restore your songs?"].waitForExistence(timeout: 8))
        app.buttons["firstRunNotNow"].tap()
        XCTAssertTrue(app.staticTexts["Restore your songs?"].waitForNonExistence(timeout: 5))

        createNewSong(in: app)
        let drawer = app.buttons["Open songs drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        drawer.tap()
        XCTAssertFalse(text("Drive Song One", in: app).waitForExistence(timeout: 2))
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store", "--ui-test-fake-drive"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func createNewSong(in app: XCUIApplication) {
        let welcomeNewSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        if welcomeNewSong.waitForExistence(timeout: 3) {
            welcomeNewSong.tap()
            return
        }
        let drawer = app.buttons["Open songs drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        drawer.tap()
        let create = app.buttons["Create New Song"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
    }

    @MainActor
    private func openBackup(in app: XCUIApplication) {
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        tap(app.buttons["cloudBackupDisclosure"], in: app)
        XCTAssertTrue(app.buttons["importBackupFile"].waitForExistence(timeout: 5))
    }

    /// Scrolls the Settings sheet until the element can be tapped.
    @MainActor
    private func tap(_ target: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(target) is missing")
        let scroll = app.scrollViews.element(boundBy: max(app.scrollViews.count - 1, 0))
        for _ in 0..<10 where !target.isHittable {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -160)))
        }
        XCTAssertTrue(target.isHittable, "\(target) is not hittable")
        target.tap()
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func text(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 8) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
        if !result { XCTFail("\(element) label stayed \"\(element.exists ? element.label : "<missing>")\", wanted \"\(label)\"") }
        return result
    }
}
