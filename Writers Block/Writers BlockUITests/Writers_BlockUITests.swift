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
        // Mic button visible alongside UnBlock when a project is open
        XCTAssertTrue(app.buttons["micButton"].waitForExistence(timeout: 5))
        unblockButton.tap()

        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["unblockButton"].exists)
        XCTAssertFalse(app.buttons["UnBlock"].exists)
        // Mic button also hidden when assistant sheet is open (same hide condition)
        XCTAssertFalse(app.buttons["micButton"].exists)
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
        XCTAssertTrue(app.buttons["micButton"].waitForExistence(timeout: 5))

        let lyricsEditor = app.textViews.firstMatch
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        lyricsEditor.tap()
        lyricsEditor.typeText("Testing keyboard overlap")

        // Both buttons ride above the keyboard instead of hiding — matches Android.
        XCTAssertTrue(unblockButton.exists)
        XCTAssertTrue(app.buttons["micButton"].exists)
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(unblockButton.frame.maxY, keyboard.frame.minY + 4)
        XCTAssertLessThanOrEqual(app.buttons["micButton"].frame.maxY, keyboard.frame.minY + 4)
    }

    @MainActor
    func testPhoneAssistantControlsMatchAndroidOrder() throws {
        try requirePhone()

        let app = isolatedUITestApp(arguments: ["--ui-test-seed-prosody-song"])
        app.launch()

        let unblockButton = app.buttons["unblockButton"]
        let micButton = app.buttons["micButton"]
        XCTAssertTrue(unblockButton.waitForExistence(timeout: 5))
        XCTAssertTrue(micButton.waitForExistence(timeout: 5))
        XCTAssertLessThan(
            unblockButton.frame.midX,
            micButton.frame.midX,
            "iOS should match Android with UnBlock on the left and the microphone on the right"
        )
    }

    @MainActor
    func testUndoRedoButtonsRestoreLyrics() throws {
        // Given
        let app = isolatedUITestApp()
        app.launch()
        createNewSong(in: app)

        let editor = app.textViews["lyricsEditor"]
        let undoButton = app.buttons["undoLyricsButton"]
        let redoButton = app.buttons["redoLyricsButton"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        XCTAssertTrue(redoButton.waitForExistence(timeout: 5))
        XCTAssertFalse(undoButton.isEnabled)
        XCTAssertFalse(redoButton.isEnabled)

        // When
        editor.tap()
        editor.typeText("first line")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "enabled == true"),
                    object: undoButton
                )],
                timeout: 5
            ),
            .completed
        )
        undoButton.tap()

        // Then
        XCTAssertEqual(editor.value as? String, "")
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "enabled == true"),
                    object: redoButton
                )],
                timeout: 5
            ),
            .completed
        )

        // When
        redoButton.tap()

        // Then
        XCTAssertEqual(editor.value as? String, "first line")
        attachScreenshot(app, name: "undo-redo-phone")
    }

    @MainActor
    func testSavedCustomModelRemainsSelectableAfterRelaunch() throws {
        let app = isolatedUITestApp(arguments: ["--ui-test-seed-custom-gguf-model"])
        app.launch()
        createNewSong(in: app)

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["Local"].tap()
        XCTAssertTrue(app.staticTexts["Night Drive QA"].waitForExistence(timeout: 5))
        let selector = app.buttons["customGGUF.ui-test-custom-model"]
        XCTAssertTrue(selector.exists)
        selector.tap()
        XCTAssertTrue(app.staticTexts["Selected"].firstMatch.waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = ["--ui-test-in-memory-store"]
        app.launch()
        createNewSong(in: app)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        app.buttons["Local"].tap()
        let savedModel = app.staticTexts["Night Drive QA"]
        XCTAssertTrue(savedModel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["customGGUF.ui-test-custom-model"].exists)
        XCTAssertTrue(app.staticTexts["Selected"].firstMatch.exists)
        app.scrollViews.firstMatch.swipeUp()
        attachScreenshot(app, name: "saved-custom-model-after-relaunch")
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

        // ...so the UnBlock FAB and mic button must both yield. On iPhone both
        // anchor to the bottom, and the FABs would otherwise show through
        // behind the chip bar.
        XCTAssertFalse(app.buttons["unblockButton"].exists)
        XCTAssertFalse(app.buttons["UnBlock"].exists)
        XCTAssertFalse(app.buttons["micButton"].exists)
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
    func testRewriteActionsOpenReviewBarAndCancelBackToChipBar() throws {
        let app = isolatedUITestApp(arguments: [
            "--ui-test-seed-rewrite-selection",
            "--ui-test-force-rewrite-bar"
        ])
        app.launch()

        XCTAssertTrue(app.buttons["Rephrase"].waitForExistence(timeout: 5))

        for action in ["Rephrase", "Harder Rhyme", "Punch Up"] {
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), "\(action) button missing")
            app.buttons[action].tap()
            XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "\(action) did not open review controls")
            app.buttons["Cancel"].tap()
            XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), "\(action) cancel did not return to chip bar")
        }
    }

    @MainActor
    func testRewriteLoadingShowsRippleOverSelection() throws {
        let app = isolatedUITestApp(arguments: [
            "--ui-test-seed-prosody-song",
            "--ui-test-seed-rewrite-loading"
        ])
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["inlineRewriteReviewBar"].waitForExistence(timeout: 5),
            "seeded rewrite loading state did not show the inline review bar"
        )
        attachScreenshot(app, name: "rewrite-loading-ripple")
    }

    @MainActor
    func testLiveGeminiSelectedRewriteActionsProducePreviewForConfiguredModels() throws {
        let geminiTestKey = Self.geminiTestKey
        guard !geminiTestKey.isEmpty else {
            throw XCTSkip("GEMINI_TEST_KEY is required for live selected rewrite UI verification")
        }

        for modelId in Self.liveGeminiModelIds {
            let app = isolatedUITestApp(arguments: [
                "-selectedProvider",
                "GEMINI",
                "-selectedModel",
                modelId,
                "--ui-test-seed-rewrite-selection",
                "--ui-test-force-rewrite-bar"
            ])
            app.launchEnvironment["GEMINI_TEST_KEY"] = geminiTestKey
            app.launch()

            XCTAssertTrue(app.buttons["Rephrase"].waitForExistence(timeout: 5))
            attachScreenshot(app, name: "live-gemini-\(Self.screenshotSlug(modelId))-rewrite-chip")

            for action in ["Rephrase", "Harder Rhyme", "Punch Up"] {
                XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), "\(action) button missing for \(modelId)")
                app.buttons[action].tap()
                XCTAssertTrue(app.descendants(matching: .any)["inlineRewriteReviewBar"].waitForExistence(timeout: 5))

                let preview = app.staticTexts["Previewing \(action)"]
                if !preview.waitForExistence(timeout: 120) {
                    attachScreenshot(app, name: "live-gemini-\(Self.screenshotSlug(modelId))-\(Self.screenshotSlug(action))-failure")
                    let providerError = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Provider")).firstMatch
                    if providerError.exists {
                        XCTFail("Live Gemini selected rewrite returned provider error for \(modelId) \(action): \(providerError.label)")
                    } else {
                        XCTFail("Live Gemini selected rewrite did not reach preview for \(modelId) \(action)")
                    }
                }

                attachScreenshot(app, name: "live-gemini-\(Self.screenshotSlug(modelId))-\(Self.screenshotSlug(action))-preview")
                app.buttons["Cancel"].tap()
                XCTAssertTrue(app.buttons[action].waitForExistence(timeout: 5), "\(action) cancel did not return to chip bar for \(modelId)")
            }

            app.terminate()
        }
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
    func testDeletingSongOffersUndoAndRestores() throws {
        let app = isolatedUITestApp(arguments: ["--ui-test-seed-trash-song"])
        app.launch()

        let openDrawerButton = app.buttons["Open songs drawer"]
        XCTAssertTrue(openDrawerButton.waitForExistence(timeout: 5))
        openDrawerButton.tap()
        let deleteButton = app.buttons["Move UI Trash Song to Trash"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()

        let undoButton = app.buttons["Undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 3))
        undoButton.tap()

        XCTAssertTrue(app.buttons["Move UI Trash Song to Trash"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testMovingSongToTrashShowsFullPageTrashBinAndActions() throws {
        let app = isolatedUITestApp(arguments: ["--ui-test-seed-trash-song"])
        app.launch()

        let openDrawerButton = app.buttons["Open songs drawer"]
        XCTAssertTrue(openDrawerButton.waitForExistence(timeout: 5))
        openDrawerButton.tap()
        let deleteButton = app.buttons["Move UI Trash Song to Trash"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()

        // Delete is immediate (no confirmation); the undo toast confirms the move.
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))

        let openTrashButton = app.buttons["Open Trash Bin"]
        XCTAssertTrue(openTrashButton.waitForExistence(timeout: 5))
        openTrashButton.tap()

        XCTAssertTrue(app.staticTexts["Trash"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Undo"].exists)
        XCTAssertTrue(app.buttons["UI Trash Song"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "30 days left")).firstMatch.waitForExistence(timeout: 3))

        app.buttons["UI Trash Song"].tap()
        XCTAssertTrue(app.buttons["Restore"].isEnabled)
        XCTAssertTrue(app.buttons["Delete"].isEnabled)
    }

    @MainActor
    func testDrawerKeepsCloseAndClearSearchAsSeparateActions() throws {
        let app = isolatedUITestApp(arguments: ["--ui-test-seed-trash-song"])
        app.launch()

        app.buttons["Open songs drawer"].tap()

        let closeButton = app.buttons["Close drawer"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Clear search"].exists)

        let searchField = app.textFields["Search songs"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("missing")

        let clearButton = app.buttons["Clear search"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 5))
        XCTAssertTrue(closeButton.exists)
        clearButton.tap()

        XCTAssertTrue(app.buttons["Create New Song"].exists)
        XCTAssertTrue(closeButton.exists)
        closeButton.tap()
        XCTAssertTrue(app.buttons["unblockButton"].waitForExistence(timeout: 5))
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
    func testAssistantOfflineFailureShowsConnectionMessage() throws {
        let app = isolatedUITestApp(arguments: [
            "--ui-test-seed-prosody-song",
            "--ui-test-open-assistant"
        ])
        app.launchEnvironment["GEMINI_TEST_KEY"] = "offline-smoke-key"
        app.launchEnvironment["RHYMEAI_GEMINI_BASE_URL"] = "https://127.0.0.1:1/v1beta"
        app.launch()

        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
        app.buttons["Suggest Next Line"].tap()

        XCTAssertTrue(
            app.staticTexts["Provider request failed — check your connection and try again."]
                .waitForExistence(timeout: 15)
        )
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
    func testIPadUndoRedoControlsStayInTopBar() throws {
        try requireIPad()
        XCUIDevice.shared.orientation = .portrait

        let app = isolatedUITestApp()
        app.launch()
        createNewSong(in: app)

        let editor = app.textViews["lyricsEditor"]
        let undoButton = app.buttons["undoLyricsButton"]
        let redoButton = app.buttons["redoLyricsButton"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        XCTAssertTrue(redoButton.waitForExistence(timeout: 5))
        XCTAssertFalse(undoButton.isEnabled)
        XCTAssertFalse(redoButton.isEnabled)

        editor.tap()
        editor.typeText("iPad history check")

        XCTAssertEqual(
            XCTWaiter.wait(
                for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "enabled == true"),
                    object: undoButton
                )],
                timeout: 5
            ),
            .completed
        )
        XCTAssertLessThan(
            undoButton.frame.midY,
            editor.frame.minY,
            "iPad history controls should remain in the top bar instead of floating over the editor"
        )
        XCTAssertLessThan(undoButton.frame.midX, redoButton.frame.midX)
        attachScreenshot(app, name: "undo-redo-ipad")
    }

    @MainActor
    func testIPadWorkspaceHasCollapsibleProjectsSidebar() throws {
        try requireIPad()
        XCUIDevice.shared.orientation = .landscapeLeft

        let app = isolatedUITestApp(arguments: ["--ui-test-seed-prosody-song"])
        app.launch()

        let landscapeReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [landscapeReady], timeout: 5), .completed)

        let projectsSidebar = app.descendants(matching: .any)
            .matching(identifier: "ipadProjectsSidebar")
            .firstMatch
        let showSidebarButton = app.buttons["Show songs sidebar"]
        if app.frame.width >= 1_100 {
            XCTAssertTrue(projectsSidebar.waitForExistence(timeout: 5))
            attachScreenshot(app, name: "ipad-workspace-landscape")

            app.buttons["Create New Song"].tap()
            XCTAssertFalse(showSidebarButton.waitForExistence(timeout: 1))
            XCTAssertTrue(projectsSidebar.exists)

            let hideSidebarButton = app.buttons["Hide songs sidebar"]
            XCTAssertTrue(hideSidebarButton.waitForExistence(timeout: 5))
            hideSidebarButton.tap()
            XCTAssertFalse(projectsSidebar.waitForExistence(timeout: 1))

            XCTAssertTrue(showSidebarButton.waitForExistence(timeout: 5))
            showSidebarButton.tap()
            XCTAssertTrue(projectsSidebar.waitForExistence(timeout: 5))
        } else {
            XCTAssertTrue(showSidebarButton.waitForExistence(timeout: 5))
            XCTAssertFalse(projectsSidebar.exists)
            showSidebarButton.tap()
            XCTAssertTrue(projectsSidebar.waitForExistence(timeout: 5))
            XCTAssertTrue(app.alerts["ipadProjectsSidebar"].exists)
            attachScreenshot(app, name: "ipad-workspace-landscape-sidebar")
        }

        XCUIDevice.shared.orientation = .portrait
        let portraitReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.height > app.frame.width },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [portraitReady], timeout: 5), .completed)
        XCTAssertTrue(showSidebarButton.waitForExistence(timeout: 5))
        XCTAssertFalse(projectsSidebar.exists)
        attachScreenshot(app, name: "ipad-workspace-portrait")

        showSidebarButton.tap()
        XCTAssertTrue(projectsSidebar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts["ipadProjectsSidebar"].exists)
        attachScreenshot(app, name: "ipad-workspace-portrait-sidebar")

        app.buttons["Create New Song"].tap()
        XCTAssertFalse(projectsSidebar.waitForExistence(timeout: 1))

        XCUIDevice.shared.orientation = .landscapeLeft
        let returnedToLandscape = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height },
            object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [returnedToLandscape], timeout: 5), .completed)
        if app.frame.width >= 1_100 {
            XCTAssertTrue(projectsSidebar.waitForExistence(timeout: 5))
        } else {
            XCTAssertFalse(projectsSidebar.exists)
            XCTAssertTrue(showSidebarButton.waitForExistence(timeout: 5))
        }
    }

    @MainActor
    func testIPadTrashFlowUsesFullPageTrashAndActions() throws {
        try requireIPad()

        for orientation in ipadAuditOrientations {
            XCUIDevice.shared.orientation = orientation
            let app = isolatedUITestApp(arguments: ["--ui-test-seed-trash-song"])
            app.launch()

            let projectsSidebar = app.descendants(matching: .any)
                .matching(identifier: "ipadProjectsSidebar")
                .firstMatch
            if !projectsSidebar.exists {
                let showSidebarButton = app.buttons["Show songs sidebar"]
                XCTAssertTrue(showSidebarButton.waitForExistence(timeout: 5))
                showSidebarButton.tap()
            }
            XCTAssertTrue(projectsSidebar.waitForExistence(timeout: 5))

            XCTAssertTrue(app.buttons["Move UI Trash Song to Trash"].waitForExistence(timeout: 5))
            app.buttons["Move UI Trash Song to Trash"].tap()

            // Delete is immediate (no confirmation); the undo toast confirms the move.
            XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))

            XCTAssertTrue(app.buttons["Open Trash Bin"].waitForExistence(timeout: 5))
            app.buttons["Open Trash Bin"].tap()

            XCTAssertTrue(app.staticTexts["Trash"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.alerts["ipadTrashBin"].exists)
            attachScreenshot(
                app,
                name: orientation == .portrait ? "ipad-trash-portrait" : "ipad-trash-landscape"
            )
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

        if !app.otherElements["ipadProjectsSidebar"].exists {
            let showSidebarButton = app.buttons["Show songs sidebar"]
            XCTAssertTrue(showSidebarButton.waitForExistence(timeout: 5))
            showSidebarButton.tap()
        }
        XCTAssertTrue(app.textFields["Search songs"].waitForExistence(timeout: 5))
        app.buttons["Close drawer"].tap()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        XCTAssertTrue(app.buttons["Share"].waitForExistence(timeout: 5))
        app.buttons["Share"].tap()
        XCTAssertTrue(app.staticTexts["Export Song"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testReleaseWalkthroughCreatesExportsAndPersistsSong() throws {
        let app = XCUIApplication()
        app.launch()

        let title = "Release Walkthrough \(Int(Date().timeIntervalSince1970))"
        let lyrics = "[Verse]\nMidnight notes on a borrowed train\nI keep the hook alive through rain"

        createNewSong(in: app)

        let titleEditor = app.textFields["songTitleEditor"]
        XCTAssertTrue(titleEditor.waitForExistence(timeout: 5))
        titleEditor.tap()
        titleEditor.typeText(title)

        let lyricsEditor = app.textViews["lyricsEditor"]
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        lyricsEditor.tap()
        lyricsEditor.typeText(lyrics)

        XCTAssertTrue(app.images["Saved"].waitForExistence(timeout: 5))

        app.buttons["Share"].tap()
        XCTAssertTrue(app.staticTexts["Export Song"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Plain Text"))
                .firstMatch
                .waitForExistence(timeout: 5)
        )
        app.buttons["Cancel"].tap()

        app.terminate()
        app.launch()

        openExistingSong(in: app, title: title)

        XCTAssertTrue(app.textFields["songTitleEditor"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["songTitleEditor"].value as? String, title)
        XCTAssertTrue(
            ((app.textViews["lyricsEditor"].value as? String) ?? "")
                .contains("Midnight notes on a borrowed train")
        )
    }

    @MainActor
    func testReleaseSuggestionNoKeyFailsGracefully() throws {
        let app = isolatedUITestApp(arguments: [
            "--ui-test-seed-prosody-song",
            "--ui-test-open-assistant"
        ])
        app.launch()

        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
        app.buttons["Suggest Next Line"].tap()
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No API key set"))
                .firstMatch
                .waitForExistence(timeout: 10)
        )
        let openSettingsButton = app.buttons["Open Settings"]
        XCTAssertTrue(openSettingsButton.waitForExistence(timeout: 5))
        openSettingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Assistant"].exists)
    }

    @MainActor
    func testReleaseRewriteNoKeyFailsGracefully() throws {
        let app = isolatedUITestApp(arguments: [
            "--ui-test-seed-rewrite-selection",
            "--ui-test-force-rewrite-bar"
        ])
        app.launch()

        XCTAssertTrue(app.buttons["Rephrase"].waitForExistence(timeout: 5))
        app.buttons["Rephrase"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["inlineRewriteReviewBar"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No API key set"))
                .firstMatch
                .waitForExistence(timeout: 10)
        )
        let openSettingsButton = app.buttons["Open Settings"]
        XCTAssertTrue(openSettingsButton.waitForExistence(timeout: 5))
        openSettingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testAccessibilityTextSizeKeepsPrimaryActionsReachable() throws {
        try requirePhone()

        let app = isolatedUITestApp(arguments: ["--ui-test-accessibility-text-size"])
        app.launch()

        let newSongButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "New Song")
        ).firstMatch
        let loadSongButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Load Song")
        ).firstMatch
        let templatesButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Song Templates")
        ).firstMatch

        XCTAssertTrue(newSongButton.waitForExistence(timeout: 5))
        XCTAssertTrue(newSongButton.isHittable)

        app.swipeUp()
        XCTAssertTrue(loadSongButton.waitForExistence(timeout: 5))
        XCTAssertTrue(loadSongButton.isHittable)

        app.swipeUp()
        XCTAssertTrue(templatesButton.waitForExistence(timeout: 5))
        XCTAssertTrue(templatesButton.isHittable)

        app.swipeDown()
        app.swipeDown()
        XCTAssertTrue(newSongButton.isHittable)

        newSongButton.tap()

        XCTAssertTrue(app.otherElements["accessibilityTopBar"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open songs drawer"].isHittable)
        XCTAssertTrue(app.buttons["unblockButton"].isHittable)
        XCTAssertTrue(app.buttons["micButton"].exists)
        XCTAssertTrue(app.textViews["lyricsEditor"].exists)
    }

    @MainActor
    func testCompactTopBarPreservesLongTitleAndActions() throws {
        // Given
        try requirePhone()
        let app = isolatedUITestApp(arguments: ["--ui-test-seed-long-title-song"])

        // When
        app.launch()

        // Then
        let title = app.staticTexts["editorTopBarTitle"]
        let compactStats = app.staticTexts["editorCompactStats"]
        let savedStatus = app.images["Saved"]
        let lyricsEditor = app.textViews["lyricsEditor"]
        let shareButton = app.buttons["Share"]
        let settingsButton = app.buttons["Settings"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertTrue(compactStats.waitForExistence(timeout: 5))
        XCTAssertTrue(savedStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        XCTAssertTrue(
            (lyricsEditor.value as? String)?.contains("I trace the signal through the city light") == true,
            "The long-title fixture should expose deterministic multi-line rhyme content"
        )
        let frameEvidence = XCTAttachment(
            string: "title=\(title.frame), saved=\(savedStatus.frame), counter=\(compactStats.frame), share=\(shareButton.frame), settings=\(settingsButton.frame), app=\(app.frame)"
        )
        frameEvidence.name = "Compact top bar frames"
        frameEvidence.lifetime = .keepAlways
        add(frameEvidence)
        attachScreenshot(app, name: "compact-top-bar-long-title")
        XCTAssertGreaterThan(title.frame.width, 100)
        XCTAssertGreaterThan(compactStats.frame.width, 0)
        XCTAssertGreaterThan(compactStats.frame.height, 0)
        XCTAssertTrue(app.frame.intersects(compactStats.frame))
        XCTAssertGreaterThan(savedStatus.frame.width, 0)
        XCTAssertGreaterThan(savedStatus.frame.height, 0)
        XCTAssertTrue(app.frame.contains(savedStatus.frame))
        XCTAssertTrue(shareButton.isHittable)
        XCTAssertTrue(settingsButton.isHittable)

        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let syllablesToggle = app.switches["Syllable Guide"]
        let rhymeFamiliesToggle = app.switches["Rhyme Families"]
        XCTAssertTrue(syllablesToggle.waitForExistence(timeout: 5))
        XCTAssertTrue(rhymeFamiliesToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(syllablesToggle.value as? String, "1")
        XCTAssertEqual(rhymeFamiliesToggle.value as? String, "1")
    }

    @MainActor
    func testWelcomeCardsGrowAtAccessibilityTextSize() throws {
        // Given
        try requirePhone()
        let app = isolatedUITestApp(arguments: ["--ui-test-accessibility-text-size"])

        // When
        app.launch()

        // Then
        for label in ["New Song", "Load Song", "Song Templates"] {
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isHittable)
        }
        attachScreenshot(app, name: "welcome-accessibility-fixed-geometry")
    }

    @MainActor
    func testReleaseVisualWalkthroughCapturesScreenshots() throws {
        let app = isolatedUITestApp()
        app.launch()

        attachScreenshot(app, name: "release-welcome")

        createNewSong(in: app)

        let titleEditor = app.textFields["songTitleEditor"]
        XCTAssertTrue(titleEditor.waitForExistence(timeout: 5))
        titleEditor.tap()
        titleEditor.typeText("Release Visual Walkthrough")

        let lyricsEditor = app.textViews["lyricsEditor"]
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        lyricsEditor.tap()
        lyricsEditor.typeText("[Verse]\nMidnight notes on a borrowed train\nI keep the hook alive through rain")
        XCTAssertTrue(app.images["Saved"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "release-populated-editor")

        app.buttons["Share"].tap()
        XCTAssertTrue(app.staticTexts["Export Song"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Plain Text"))
                .firstMatch
                .waitForExistence(timeout: 5)
        )
        attachScreenshot(app, name: "release-export-sheet")
        app.buttons["Cancel"].tap()

        let unblockButton = app.buttons["unblockButton"]
        XCTAssertTrue(unblockButton.waitForExistence(timeout: 5))
        unblockButton.tap()
        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "release-assistant-panel")
        app.buttons["Close Assistant"].tap()

        app.terminate()

        let suggestionApp = isolatedUITestApp(arguments: [
            "-selectedProvider",
            "GEMINI",
            "-selectedModel",
            "gemini-3.5-flash",
            "--ui-test-seed-prosody-song",
            "--ui-test-open-assistant"
        ])
        suggestionApp.launch()
        XCTAssertTrue(suggestionApp.staticTexts["Assistant"].waitForExistence(timeout: 5))
        suggestionApp.buttons["Suggest Next Line"].tap()
        XCTAssertTrue(
            suggestionApp.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No API key set"))
                .firstMatch
                .waitForExistence(timeout: 10)
        )
        suggestionApp.swipeUp()
        attachScreenshot(suggestionApp, name: "release-assistant-no-key")
        suggestionApp.terminate()

        let rewriteApp = isolatedUITestApp(arguments: [
            "-selectedProvider",
            "GEMINI",
            "-selectedModel",
            "gemini-3.5-flash",
            "--ui-test-seed-rewrite-selection",
            "--ui-test-force-rewrite-bar"
        ])
        rewriteApp.launch()
        XCTAssertTrue(rewriteApp.buttons["Rephrase"].waitForExistence(timeout: 5))
        rewriteApp.buttons["Rephrase"].tap()
        XCTAssertTrue(rewriteApp.descendants(matching: .any)["inlineRewriteReviewBar"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            rewriteApp.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No API key set"))
                .firstMatch
                .waitForExistence(timeout: 10)
        )
        attachScreenshot(rewriteApp, name: "release-rewrite-no-key")
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

    private func createNewSong(in app: XCUIApplication) {
        let welcomeNewSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        if welcomeNewSong.waitForExistence(timeout: 2) {
            welcomeNewSong.tap()
            return
        }

        let openDrawerButton = app.buttons["Open songs drawer"]
        XCTAssertTrue(openDrawerButton.waitForExistence(timeout: 5))
        openDrawerButton.tap()

        let createNewSongButton = app.buttons["Create New Song"]
        XCTAssertTrue(createNewSongButton.waitForExistence(timeout: 5))
        createNewSongButton.tap()
    }

    private func openExistingSong(in app: XCUIApplication, title: String) {
        let loadSongButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Load Song")).firstMatch
        if loadSongButton.waitForExistence(timeout: 2) {
            loadSongButton.tap()
        } else {
            let openDrawerButton = app.buttons["Open songs drawer"]
            XCTAssertTrue(openDrawerButton.waitForExistence(timeout: 5))
            openDrawerButton.tap()
        }

        let savedSongButton = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        XCTAssertTrue(savedSongButton.waitForExistence(timeout: 5))
        savedSongButton.tap()
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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

    private static var geminiTestKey: String {
        ProcessInfo.processInfo.environment["GEMINI_TEST_KEY"]
            ?? ProcessInfo.processInfo.environment["SIMCTL_CHILD_GEMINI_TEST_KEY"]
            ?? ""
    }

    private static let liveGeminiModelIds = [
        "gemini-3.5-flash",
        "gemini-3.1-pro-preview"
    ]

    private static func screenshotSlug(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: "[^A-Za-z0-9_-]",
            with: "_",
            options: .regularExpression
        )
    }
}
