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
        continueAfterFailure = false
    }

    @MainActor
    func testUnBlockButtonHidesWhenAssistantSheetOpens() throws {
        try requirePhone()

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
    func testUnBlockButtonStaysVisibleWhileEditingLyrics() throws {
        try requirePhone()

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

        // Button rides above the keyboard instead of hiding — matches Android.
        XCTAssertTrue(unblockButton.exists)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(unblockButton.frame.maxY, keyboard.frame.minY + 4)
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
    func testUnBlockButtonHidesWhenRewriteBarVisible() throws {
        try requirePhone()

        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-force-rewrite-bar")
        app.launch()

        let newSongButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSongButton.waitForExistence(timeout: 5))
        newSongButton.tap()

        let lyricsEditor = app.textViews["lyricsEditor"]
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        lyricsEditor.tap()
        lyricsEditor.typeText("Selection rewrite bar")

        // The selection rewrite bar is up (forced for the test)...
        XCTAssertTrue(app.buttons["Rephrase"].waitForExistence(timeout: 5))

        // ...so the UnBlock FAB must yield. On iPhone both anchor to the bottom,
        // and the FAB would otherwise show through behind the chip bar.
        XCTAssertFalse(app.buttons["unblockButton"].exists)
        XCTAssertFalse(app.buttons["UnBlock"].exists)
    }

    @MainActor
    func testSingleWordLookUpOpensInspector() throws {
        try requirePhone()

        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-in-memory-store")
        app.launch()

        let newSongButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSongButton.waitForExistence(timeout: 5))
        newSongButton.tap()

        let editor = app.textViews["lyricsEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("yellow")

        // Select the single word, then open the Word Inspector from the chip
        // bar's look-up button (parity with Android). Regression guard: the
        // look-up's hit area was once only the glyph, so edge taps fell through
        // to the text view and the button silently did nothing.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.03)).doubleTap()
        XCTAssertTrue(app.buttons["Punch Up"].waitForExistence(timeout: 5),
                      "selecting a word did not raise the rewrite chip bar")

        let lookUp = app.buttons["Look up word"]
        XCTAssertTrue(lookUp.waitForExistence(timeout: 5), "look-up button missing from the chip bar")
        lookUp.tap()
        XCTAssertTrue(app.staticTexts["Word inspector"].waitForExistence(timeout: 5),
                      "look-up did not open the Word Inspector")
    }

    @MainActor
    func testBackSwipeClosesAssistantSheetWithoutReturningToMenu() throws {
        try requirePhone()

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
        try requirePhone()

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
    func testAssistantStopCancelsSuggestionRequest() throws {
        let geminiTestKey = ProcessInfo.processInfo.environment["GEMINI_TEST_KEY"]
            ?? ProcessInfo.processInfo.environment["SIMCTL_CHILD_GEMINI_TEST_KEY"]
            ?? ""
        guard !geminiTestKey.isEmpty else {
            throw XCTSkip("GEMINI_TEST_KEY is required for live assistant cancel UI verification")
        }

        let app = isolatedUITestApp(arguments: [
            "--ui-test-seed-prosody-song",
            "--ui-test-open-assistant"
        ])
        app.launchEnvironment["GEMINI_TEST_KEY"] = geminiTestKey
        app.launch()

        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
        app.buttons["Suggest Next Line"].tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))

        app.buttons["Stop"].tap()

        XCTAssertTrue(app.buttons["Suggest Next Line"].waitForExistence(timeout: 5))
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

    private func requirePhone() throws {
        let simulatorName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        guard UIDevice.current.userInterfaceIdiom == .phone && !simulatorName.localizedCaseInsensitiveContains("iPad") else {
            throw XCTSkip("Phone-only assistant sheet test")
        }
    }
}
