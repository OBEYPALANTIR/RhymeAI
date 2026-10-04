import XCTest

final class AppAppearanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAppearanceWalkthroughPersistsGraphite() throws {
        let app = appearanceTestApp()
        app.launch()

        XCTAssertTrue(app.textViews["lyricsEditor"].waitForExistence(timeout: 8))
        openSettings(in: app)

        let picker = app.segmentedControls["appearancePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Appearance picker is missing from Settings")

        for style in ["Ink", "Paper", "Graphite"] {
            XCTAssertFalse(
                app.descendants(matching: .any)["\(style) preview"].exists,
                "\(style) color preview should not appear in Settings"
            )
        }

        for style in ["Ink", "Paper", "Graphite"] {
            let segment = picker.buttons[style]
            XCTAssertTrue(segment.waitForExistence(timeout: 3), "Missing \(style) appearance option")
            segment.tap()
            XCTAssertTrue(segment.isSelected, "\(style) did not apply immediately")
            waitForAppearanceToSettle()
            attachScreenshot(app, name: "appearance-\(style.lowercased())-settings")

            app.buttons["Done"].tap()
            XCTAssertTrue(app.textViews["lyricsEditor"].waitForExistence(timeout: 5))
            waitForAppearanceToSettle()
            attachScreenshot(app, name: "appearance-\(style.lowercased())-editor")

            if style != "Graphite" {
                openSettings(in: app)
            }
        }

        let editor = app.textViews["lyricsEditor"]
        editor.tap()
        editor.typeText("\nAppearance QA caret")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        attachScreenshot(app, name: "appearance-graphite-keyboard-caret")

        let assistantButton = app.buttons["unblockButton"]
        XCTAssertTrue(assistantButton.waitForExistence(timeout: 3))
        // Regular-width layouts keep the assistant open as an inline panel,
        // where this button would hide it instead.
        if !app.staticTexts["Assistant"].exists {
            assistantButton.tap()
        }
        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "appearance-graphite-assistant")
        // Sheet close on compact width, inline panel hide on regular width.
        app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Close Assistant", "Hide Assistant"])
        ).firstMatch.tap()

        let projectsButton = app.buttons["Open songs drawer"]
        XCTAssertTrue(projectsButton.waitForExistence(timeout: 5))
        projectsButton.tap()
        XCTAssertTrue(app.buttons["Create New Song"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "appearance-graphite-projects")
        app.buttons["Close drawer"].tap()

        app.terminate()
        app.launch()
        XCTAssertTrue(app.textViews["lyricsEditor"].waitForExistence(timeout: 8))
        openSettings(in: app)

        let relaunchedPicker = app.segmentedControls["appearancePicker"]
        XCTAssertTrue(relaunchedPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(relaunchedPicker.buttons["Graphite"].isSelected, "Graphite did not persist after relaunch")
        attachScreenshot(app, name: "appearance-graphite-relaunch")
    }

    @MainActor
    func testAnalysisStyleAppliesImmediatelyAndPersists() throws {
        let app = appearanceTestApp()
        app.launch()
        openSettings(in: app)

        let picker = app.segmentedControls["analysisStylePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["Color"].tap()
        XCTAssertTrue(picker.buttons["Color"].isSelected)
        picker.buttons["Ink Marks"].tap()
        XCTAssertTrue(picker.buttons["Ink Marks"].isSelected)
        XCTAssertTrue(app.staticTexts["Solid, dashed, dotted, and dash-dot lines identify rhyme families."].exists)

        app.terminate()
        app.launch()
        openSettings(in: app)
        let relaunchedPicker = app.segmentedControls["analysisStylePicker"]
        XCTAssertTrue(relaunchedPicker.buttons["Ink Marks"].isSelected)

        relaunchedPicker.buttons["Color"].tap()
        XCTAssertTrue(relaunchedPicker.buttons["Color"].isSelected)
    }

    private func appearanceTestApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-in-memory-store",
            "--ui-test-seed-prosody-song",
        ]
        return app
    }

    private func openSettings(in app: XCUIApplication) {
        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitForAppearanceToSettle() {
        let settled = XCTestExpectation(description: "Appearance transition settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            settled.fulfill()
        }
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 1.5), .completed)
    }
}
