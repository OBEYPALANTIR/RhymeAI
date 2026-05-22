//
//  Writers_BlockUITests.swift
//  Writers BlockUITests
//
//  Created by Tyler Manring on 4/6/26.
//

import XCTest
import UIKit

final class Writers_BlockUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testUnBlockButtonHidesWhenAssistantSheetOpens() throws {
        let app = XCUIApplication()
        app.launch()

        let newSongButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSongButton.waitForExistence(timeout: 5))
        newSongButton.tap()

        let unblockButton = app.buttons["unblockButton"]
        XCTAssertTrue(unblockButton.waitForExistence(timeout: 5))
        unblockButton.tap()

        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["unblockButton"].exists)
        XCTAssertFalse(app.buttons["UnBlock"].exists)
    }

    @MainActor
    func testUnBlockButtonHidesWhileEditingLyrics() throws {
        let app = XCUIApplication()
        app.launch()

        let newSongButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSongButton.waitForExistence(timeout: 5))
        newSongButton.tap()

        let unblockButton = app.buttons["unblockButton"]
        XCTAssertTrue(unblockButton.waitForExistence(timeout: 5))

        let lyricsEditor = app.textViews.firstMatch
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        lyricsEditor.tap()
        lyricsEditor.typeText("Testing keyboard overlap")

        XCTAssertFalse(unblockButton.exists)
    }

    @MainActor
    func testRewriteChipBarStaysAboveKeyboardForSelectedLyrics() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-force-rewrite-bar")
        app.launch()

        let newSongButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSongButton.waitForExistence(timeout: 5))
        newSongButton.tap()

        let lyricsEditor = app.textViews["lyricsEditor"]
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        lyricsEditor.tap()
        lyricsEditor.typeText("Testing selected rewrite placement")

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))

        let rewriteAction = app.buttons["Rephrase"]
        XCTAssertTrue(rewriteAction.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(rewriteAction.frame.maxY, keyboard.frame.minY + 4)
    }

    @MainActor
    func testBackSwipeClosesAssistantSheetWithoutReturningToMenu() throws {
        let app = XCUIApplication()
        app.launch()

        let newSongButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSongButton.waitForExistence(timeout: 5))
        newSongButton.tap()

        let unblockButton = app.buttons["unblockButton"]
        XCTAssertTrue(unblockButton.waitForExistence(timeout: 5))
        unblockButton.tap()

        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertTrue(app.buttons["unblockButton"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Assistant"].exists)
        XCTAssertFalse(newSongButton.exists)
    }

    @MainActor
    func testPullDownClosesAssistantSheetWithoutLockingEditor() throws {
        let app = XCUIApplication()
        app.launch()

        let newSongButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSongButton.waitForExistence(timeout: 5))
        newSongButton.tap()

        let unblockButton = app.buttons["unblockButton"]
        XCTAssertTrue(unblockButton.waitForExistence(timeout: 5))
        unblockButton.tap()

        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        start.press(forDuration: 0.05, thenDragTo: end)

        XCTAssertTrue(app.buttons["unblockButton"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Assistant"].exists)
        XCTAssertFalse(newSongButton.exists)
    }

    @MainActor
    func testMovingSongToTrashShowsFullPageTrashBinAndActions() throws {
        let app = isolatedUITestApp(arguments: ["--ui-test-seed-trash-song"])
        app.launch()

        let openDrawerButton = app.buttons["Open songs drawer"]
        XCTAssertTrue(openDrawerButton.waitForExistence(timeout: 5))
        openDrawerButton.tap()
        let deleteButton = app.buttons["Delete UI Trash Song"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()

        let moveToTrashButton = app.buttons["Move to Trash"]
        XCTAssertTrue(moveToTrashButton.waitForExistence(timeout: 3))
        moveToTrashButton.tap()

        let openTrashButton = app.buttons["Open Trash Bin"]
        XCTAssertTrue(openTrashButton.waitForExistence(timeout: 5))
        openTrashButton.tap()

        XCTAssertTrue(app.staticTexts["Trash"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["UI Trash Song"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "30 days left")).firstMatch.waitForExistence(timeout: 3))

        app.buttons["UI Trash Song"].tap()
        XCTAssertTrue(app.buttons["Restore"].isEnabled)
        XCTAssertTrue(app.buttons["Delete"].isEnabled)
    }

    @MainActor
    func testStressAndIpaToggleRendersProsodyPreviewInAssistant() throws {
        let app = isolatedUITestApp(arguments: [
            "--ui-test-seed-prosody-song",
            "--ui-test-open-assistant",
            "--ui-test-enable-stress-preview"
        ])
        app.launch()

        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ˈDA da | ˈDA da"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "jɛloʊ")).firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    func testIPadSplitEditorShowsInlineAssistantAndProsody() throws {
        try requireIPad()

        for orientation in ipadAuditOrientations {
            XCUIDevice.shared.orientation = orientation
            let app = isolatedUITestApp(arguments: [
                "--ui-test-seed-prosody-song",
                "--ui-test-enable-stress-preview"
            ])
            app.launch()

            XCTAssertTrue(app.textViews["lyricsEditor"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["ˈDA da | ˈDA da"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "jɛloʊ")).firstMatch.waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["unblockButton"].exists)
            XCTAssertFalse(app.buttons["UnBlock"].exists)

            app.terminate()
        }
    }

    @MainActor
    func testIPadTrashFlowUsesFullPageTrashAndActions() throws {
        try requireIPad()

        for orientation in ipadAuditOrientations {
            XCUIDevice.shared.orientation = orientation
            let app = isolatedUITestApp(arguments: ["--ui-test-seed-trash-song"])
            app.launch()

            XCTAssertTrue(app.buttons["Open songs drawer"].waitForExistence(timeout: 5))
            app.buttons["Open songs drawer"].tap()

            XCTAssertTrue(app.buttons["Delete UI Trash Song"].waitForExistence(timeout: 5))
            app.buttons["Delete UI Trash Song"].tap()

            XCTAssertTrue(app.buttons["Move to Trash"].waitForExistence(timeout: 3))
            app.buttons["Move to Trash"].tap()

            XCTAssertTrue(app.buttons["Open Trash Bin"].waitForExistence(timeout: 5))
            app.buttons["Open Trash Bin"].tap()

            XCTAssertTrue(app.staticTexts["Trash"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["UI Trash Song"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "30 days left")).firstMatch.waitForExistence(timeout: 3))

            app.buttons["UI Trash Song"].tap()
            XCTAssertTrue(app.buttons["Restore"].isEnabled)
            XCTAssertTrue(app.buttons["Delete"].isEnabled)

            app.terminate()
        }
    }

    @MainActor
    func testIPadRewriteAccessoryStaysKeyboardSafe() throws {
        try requireIPad()

        for orientation in ipadAuditOrientations {
            XCUIDevice.shared.orientation = orientation
            let app = isolatedUITestApp(arguments: ["--ui-test-force-rewrite-bar"])
            app.launch()

            let newSongButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
            XCTAssertTrue(newSongButton.waitForExistence(timeout: 5))
            newSongButton.tap()

            let lyricsEditor = app.textViews["lyricsEditor"]
            XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
            lyricsEditor.tap()
            lyricsEditor.typeText("Testing iPad rewrite accessory placement")

            let rewriteAction = app.buttons["Rephrase"]
            XCTAssertTrue(rewriteAction.waitForExistence(timeout: 5))

            let keyboard = app.keyboards.firstMatch
            if keyboard.waitForExistence(timeout: 2) {
                XCTAssertLessThanOrEqual(rewriteAction.frame.maxY, keyboard.frame.minY + 4)
            } else {
                XCTAssertLessThanOrEqual(rewriteAction.frame.maxY, app.frame.maxY - 4)
            }

            app.terminate()
        }
    }

    @MainActor
    func testIPadModalSurfacesAreReachable() throws {
        try requireIPad()
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = isolatedUITestApp()
        app.launch()

        let loadSongButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Load Song")).firstMatch
        XCTAssertTrue(loadSongButton.waitForExistence(timeout: 5))
        loadSongButton.tap()
        XCTAssertTrue(app.staticTexts["Song Projects"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        let templatesButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Song Templates")).firstMatch
        XCTAssertTrue(templatesButton.waitForExistence(timeout: 5))
        templatesButton.tap()
        XCTAssertTrue(app.staticTexts["Choose a Template"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        let newSongButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSongButton.waitForExistence(timeout: 5))
        newSongButton.tap()

        let lyricsEditor = app.textViews["lyricsEditor"]
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        lyricsEditor.tap()
        lyricsEditor.typeText("yellow music")

        XCTAssertTrue(app.buttons["Open songs drawer"].waitForExistence(timeout: 5))
        app.buttons["Open songs drawer"].tap()
        XCTAssertTrue(app.textFields["Search songs"].waitForExistence(timeout: 5))
        app.buttons["Close drawer"].tap()

        XCTAssertTrue(app.buttons["gearshape"].waitForExistence(timeout: 5))
        app.buttons["gearshape"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 5))
        app.buttons["Share"].tap()
        XCTAssertTrue(app.staticTexts["Export Song"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    private func isolatedUITestApp(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store"] + arguments
        return app
    }

    private var ipadAuditOrientations: [UIDeviceOrientation] {
        [.portrait, .landscapeLeft]
    }

    private func requireIPad() throws {
        let simulatorName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        guard UIDevice.current.userInterfaceIdiom == .pad || simulatorName.localizedCaseInsensitiveContains("iPad") else {
            throw XCTSkip("iPad-only audit test")
        }
    }
}
