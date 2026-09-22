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
    func testColoredLyricsTypingAtLineEnd() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = isolatedUITestApp()
        app.launch()
        let newSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSong.waitForExistence(timeout: 5))
        newSong.tap()
        let editor = app.textViews["lyricsEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let text = "The last word is light tonight and the melody carries through the night"
        editor.typeText(text)
        attachScreenshot(app, name: "colored-lyrics-line-end-portrait")
        editor.typeText("s\nA new line")
        XCTAssertEqual(editor.value as? String, text + "s\nA new line")
        XCUIDevice.shared.orientation = .landscapeLeft
        editor.typeText(" ends here")
        XCTAssertEqual(editor.value as? String, text + "s\nA new line ends here")
        attachScreenshot(app, name: "colored-lyrics-line-end-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testModelDownloadSurvivesSettingsBackgroundAndRelaunch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RUN_GGUF_DOWNLOAD_QA"] == "1")
        XCUIDevice.shared.orientation = .portrait
        let app = isolatedUITestApp(arguments: ["--ui-test-seed-prosody-song"])
        app.launch()
        let model = app.buttons["gemmaDownload.gemma-4-e2b"]
        func openDownloads() {
            app.buttons["gearshape"].tap()
            app.buttons["Local"].tap()
            for _ in 0..<8 {
                if model.isHittable { break }
                app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            }
            XCTAssertTrue(model.isHittable)
        }
        func percent() -> Int {
            let status = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Downloading RhymeAI Gemma 4 E2B")).firstMatch
            guard status.exists else { return -1 }
            return Int(status.label.components(separatedBy: "… ").last?.components(separatedBy: "%").first ?? "") ?? -1
        }
        func waitForProgress(after value: Int) {
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in percent() > value }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 90), .completed)
        }
        openDownloads()
        if !model.label.contains("Pause") { model.tap() }
        waitForProgress(after: 0)
        let before = percent()
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "Download before leaving Settings"
        initial.lifetime = .keepAlways
        add(initial)
        app.buttons["Done"].tap()
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 5)
        app.activate()
        openDownloads()
        waitForProgress(after: before)
        let background = percent()
        app.terminate()
        app.launch()
        openDownloads()
        waitForProgress(after: background)
        let restored = XCTAttachment(screenshot: app.screenshot())
        restored.name = "Download restored after process relaunch"
        restored.lifetime = .keepAlways
        add(restored)
        model.tap()
        XCTAssertTrue(app.staticTexts["Download paused. Tap Download to resume."].waitForExistence(timeout: 10))
    }

    @MainActor
    func testLongDraftRestoresVisibleScrollAndCaretWhenSwitchingSongs() throws {
        let app = isolatedUITestApp()
        app.launch()
        let newSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSong.waitForExistence(timeout: 5))
        newSong.tap()
        let title = app.textFields["songTitleEditor"]
        title.tap()
        title.typeText("Position proof")
        let lyrics = app.textViews["lyricsEditor"]
        lyrics.tap()
        lyrics.typeText((1...60).map { "Line \($0) carries a quiet melody" }.joined(separator: "\n"))
        let window = app.windows.firstMatch.frame
        let scrollStart = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.width * 0.25, dy: window.height * 0.3))
        let scrollEnd = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.width * 0.25, dy: window.height * 0.55))
        scrollEnd.press(forDuration: 0.1, thenDragTo: scrollStart)
        scrollStart.tap()
        lyrics.typeText("CURSORPROOF")
        let before = try XCTUnwrap(lyrics.value as? String)
        XCTAssertTrue(before.contains("CURSORPROOF"))
        attachScreenshot(app, name: "long-draft-position-before-switch")
        XCTAssertFalse(title.isHittable, "The title must be above the scrolled viewport.")
        app.buttons["Open songs drawer"].tap()
        app.buttons["Create New Song"].tap()
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        app.buttons["Open songs drawer"].tap()
        let savedSong = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Position proof")).firstMatch
        XCTAssertTrue(savedSong.waitForExistence(timeout: 5))
        savedSong.tap()
        XCTAssertEqual(lyrics.value as? String, before)
        XCTAssertFalse(title.isHittable, "Restoring must not return the document to the top.")
        attachScreenshot(app, name: "long-draft-position-after-switch")
        lyrics.typeText("RESTORED")
        XCTAssertEqual(lyrics.value as? String, before.replacingOccurrences(of: "CURSORPROOF", with: "CURSORPROOFRESTORED"))
        attachScreenshot(app, name: "long-draft-caret-insertion-proof")
    }

    @MainActor
    func testSongNotebookKeepsAndInsertsAlternateWithoutReplacingDraft() throws {
        let app = isolatedUITestApp()
        app.launch()
        let newSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSong.waitForExistence(timeout: 5))
        newSong.tap()
        let lyrics = app.textViews["lyricsEditor"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.tap()
        lyrics.typeText("A quiet line of light")
        app.buttons["songActionsButton"].tap()
        app.buttons["Song Notebook"].tap()
        XCTAssertTrue(app.navigationBars["Song Notebook"].waitForExistence(timeout: 5))
        let alternate = app.textFields["Keep a line for later"]
        XCTAssertTrue(alternate.waitForExistence(timeout: 5))
        alternate.tap()
        alternate.typeText("An echo in the night")
        app.buttons["Keep alternate"].tap()
        XCTAssertTrue(app.staticTexts["An echo in the night"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "song-notebook-kept-alternate")
        app.buttons["Done"].tap()
        XCTAssertEqual(lyrics.value as? String, "A quiet line of light")
        app.buttons["songActionsButton"].tap()
        app.buttons["Song Notebook"].tap()
        app.buttons["Insert"].tap()
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        XCTAssertTrue((lyrics.value as? String)?.contains("A quiet line of light") == true)
        XCTAssertTrue((lyrics.value as? String)?.contains("An echo in the night") == true)
        app.buttons["songActionsButton"].tap()
        app.buttons["Song Notebook"].tap()
        app.buttons["Draft History"].tap()
        app.buttons["Save version"].tap()
        XCTAssertFalse(app.staticTexts["Your saved versions will appear here."].exists)
        attachScreenshot(app, name: "song-notebook-draft-history")
    }

    @MainActor
    func testWelcomeActionsRemainReachableAtAccessibilityTextSize() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let simulatorName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad || simulatorName.localizedCaseInsensitiveContains("iPad")
        let orientations: [UIDeviceOrientation] = isIPad ? [.portrait, .landscapeLeft] : [.portrait]
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            let app = isolatedUITestApp(arguments: [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
            ])
            app.launch()

            let welcomeScroll = app.scrollViews["welcomeScroll"]
            XCTAssertTrue(welcomeScroll.waitForExistence(timeout: 5))
            let templates = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Song Templates")).firstMatch
            for _ in 0..<6 {
                if templates.isHittable && templates.frame.maxY < app.windows.firstMatch.frame.maxY - 40 { break }
                welcomeScroll.swipeUp()
            }
            XCTAssertTrue(templates.isHittable)
            attachScreenshot(app, name: "welcome-accessibility-templates-\(orientation.rawValue)")
            templates.tap()
            XCTAssertTrue(app.navigationBars["Choose a Template"].waitForExistence(timeout: 5))
            app.buttons["Done"].tap()

            let newSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
            for _ in 0..<6 {
                if newSong.isHittable { break }
                welcomeScroll.swipeDown()
            }
            XCTAssertTrue(newSong.isHittable)
            newSong.tap()
            XCTAssertTrue(app.textViews["lyricsEditor"].waitForExistence(timeout: 5))
            app.terminate()
        }
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
    func testEditorChromeKeepsToolbarHistoryAndWritingActionOrder() throws {
        try requirePhone()

        let app = isolatedUITestApp()
        app.launch()

        let newSongButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSongButton.waitForExistence(timeout: 5))
        newSongButton.tap()

        let unblockButton = app.buttons["unblockButton"]
        let micButton = app.buttons["micButton"]
        let undoButton = app.buttons["undoLyricsButton"]
        let redoButton = app.buttons["redoLyricsButton"]
        XCTAssertTrue(unblockButton.waitForExistence(timeout: 5))
        XCTAssertTrue(micButton.waitForExistence(timeout: 5))
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        XCTAssertTrue(redoButton.exists)
        XCTAssertLessThan(unblockButton.frame.maxX, micButton.frame.minX)

        let window = app.windows.firstMatch.frame
        let trailingInset = window.maxX - micButton.frame.maxX
        XCTAssertGreaterThanOrEqual(trailingInset, 20)
        XCTAssertLessThanOrEqual(trailingInset, 32)
        XCTAssertGreaterThanOrEqual(micButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(micButton.frame.height, 44)
        // The 56-point mic circle sits 20 points from the editor edge.
        XCTAssertEqual(micButton.frame.midX, window.maxX - 20 - 28, accuracy: 1)
        XCTAssertEqual(micButton.frame.midY, unblockButton.frame.midY, accuracy: 1)
        XCTAssertLessThan(undoButton.frame.maxX, redoButton.frame.minX)
        XCTAssertLessThan(redoButton.frame.maxY, unblockButton.frame.minY)
        attachScreenshot(app, name: "mic-centered-idle")
        app.textViews["lyricsEditor"].tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        XCTAssertEqual(micButton.frame.midX, window.maxX - 20 - 28, accuracy: 1)
        XCTAssertLessThanOrEqual(micButton.frame.maxY, keyboard.frame.minY + 4)
        attachScreenshot(app, name: "mic-centered-keyboard")
    }

    @MainActor
    func testSectionMenuStaysPinnedAfterEditorScroll() throws {
        let app = isolatedUITestApp()
        app.launch()
        createNewSong(in: app)

        let songActions = app.buttons["songActionsButton"]
        let songTitle = app.textFields["songTitleEditor"]
        let editorStats = app.staticTexts["editorStats"]
        let lyricsEditor = app.textViews["lyricsEditor"]
        XCTAssertTrue(songActions.waitForExistence(timeout: 5))
        XCTAssertTrue(songTitle.waitForExistence(timeout: 5))
        XCTAssertTrue(editorStats.waitForExistence(timeout: 5))
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        XCTAssertEqual(editorStats.label, "0w · 0s")
        XCTAssertGreaterThanOrEqual(editorStats.frame.minY, songTitle.frame.maxY)
        XCTAssertLessThan(editorStats.frame.maxY, lyricsEditor.frame.minY)

        lyricsEditor.tap()
        let longLyrics = (1...36)
            .map { "Lyric line \($0)" }
            .joined(separator: "\n")
        lyricsEditor.typeText(longLyrics)
        app.swipeUp()
        app.swipeUp()

        XCTAssertTrue(songActions.exists)
        XCTAssertTrue(songActions.isHittable)
        XCTAssertFalse(songTitle.isHittable)

        songActions.tap()
        let sectionMenu = app.buttons["sectionMenuButton"]
        XCTAssertTrue(sectionMenu.waitForExistence(timeout: 3))
        sectionMenu.tap()
        let bridgeSection = app.buttons["sectionMenuBridge"]
        XCTAssertTrue(bridgeSection.waitForExistence(timeout: 3))
        bridgeSection.tap()

        XCTAssertTrue((lyricsEditor.value as? String)?.contains("[Bridge]") == true)
    }

    @MainActor
    func testSettingsKeepsTabsAndSaveBarPinned() throws {
        try requirePhone()

        let app = isolatedUITestApp()
        app.launch()

        let newSongButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSongButton.waitForExistence(timeout: 5))
        newSongButton.tap()

        let settingsButton = app.buttons["gearshape"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        let generalTab = app.buttons["General"]
        let editorTab = app.buttons["Editor"]
        let saveButton = app.buttons["saveSettingsButton"]
        XCTAssertTrue(generalTab.waitForExistence(timeout: 5))
        XCTAssertTrue(editorTab.exists)
        XCTAssertTrue(saveButton.exists)

        editorTab.tap()
        XCTAssertTrue(app.switches["Whole Song Context"].waitForExistence(timeout: 5))
        XCTAssertTrue(saveButton.exists)
        XCTAssertTrue(saveButton.isHittable)
    }

    @MainActor
    func testAppearancePickerAppliesInkPaperAndGraphiteImmediately() throws {
        try requirePhone()

        let app = isolatedUITestApp()
        app.launch()
        createNewSong(in: app)

        let settingsButton = app.buttons["gearshape"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        for name in ["Ink", "Paper", "Graphite"] {
            XCTAssertFalse(app.otherElements["\(name) preview"].exists)
            let option = app.buttons[name]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            XCTAssertEqual(option.value as? String, "Selected")
            XCTAssertTrue(app.buttons["saveSettingsButton"].isHittable)
        }
    }

    @MainActor
    func testLyricsUndoAndRedoControlsRestoreTyping() throws {
        let app = isolatedUITestApp()
        app.launch()
        createNewSong(in: app)

        let undoButton = app.buttons["undoLyricsButton"]
        let redoButton = app.buttons["redoLyricsButton"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        XCTAssertTrue(redoButton.exists)
        XCTAssertFalse(undoButton.isEnabled)
        XCTAssertFalse(redoButton.isEnabled)

        let lyricsEditor = app.textViews["lyricsEditor"]
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        lyricsEditor.tap()
        lyricsEditor.typeText("First line")

        let undoEnabled = NSPredicate(format: "enabled == true")
        expectation(for: undoEnabled, evaluatedWith: undoButton)
        waitForExpectations(timeout: 3)
        XCTAssertFalse(redoButton.isEnabled)

        undoButton.tap()
        XCTAssertEqual(lyricsEditor.value as? String, "")
        XCTAssertTrue(redoButton.isEnabled)

        redoButton.tap()
        XCTAssertEqual(lyricsEditor.value as? String, "First line")
        XCTAssertTrue(undoButton.isEnabled)
    }

    @MainActor
    func testUndoAndRedoControlsDismissWhileRecordingAndReturnAfterStopping() throws {
        let app = isolatedUITestApp(arguments: ["--ui-test-fake-voice-recording"])
        app.launch()
        createNewSong(in: app)

        let undoButton = app.buttons["undoLyricsButton"]
        let redoButton = app.buttons["redoLyricsButton"]
        let micButton = app.buttons["micButton"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        XCTAssertTrue(redoButton.exists)
        XCTAssertTrue(micButton.waitForExistence(timeout: 5))
        let idleMicFrame = micButton.frame

        micButton.tap()

        XCTAssertTrue(undoButton.waitForNonExistence(timeout: 3))
        XCTAssertTrue(redoButton.waitForNonExistence(timeout: 3))
        XCTAssertTrue(micButton.exists)
        XCTAssertEqual(micButton.frame.midX, idleMicFrame.midX, accuracy: 1)
        XCTAssertEqual(micButton.frame.midY, idleMicFrame.midY, accuracy: 1)

        micButton.tap()

        XCTAssertTrue(undoButton.waitForExistence(timeout: 3))
        XCTAssertTrue(redoButton.exists)
    }

    @MainActor
    func testIPadEditorKeepsHistoryInToolbarAndWritingActionsAtBottom() throws {
        try requireIPad()

        let app = isolatedUITestApp()
        app.launch()
        createNewSong(in: app)

        let lyricsEditor = app.textViews["lyricsEditor"]
        let undoButton = app.buttons["undoLyricsButton"]
        let unblockButton = app.buttons["unblockButton"]
        let micButton = app.buttons["micButton"]
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5))
        XCTAssertTrue(unblockButton.waitForExistence(timeout: 5))
        XCTAssertTrue(micButton.waitForExistence(timeout: 5))
        XCTAssertLessThan(undoButton.frame.maxY, lyricsEditor.frame.minY)
        XCTAssertGreaterThan(unblockButton.frame.midY, lyricsEditor.frame.midY)
        XCTAssertGreaterThan(micButton.frame.midY, lyricsEditor.frame.midY)
        XCTAssertLessThan(unblockButton.frame.maxX, micButton.frame.minX)
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
    func testRewriteLoadingShowsShimmerOverSelection() throws {
        let app = isolatedUITestApp(arguments: [
            "--ui-test-seed-prosody-song",
            "--ui-test-seed-rewrite-loading"
        ])
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["inlineRewriteReviewBar"].waitForExistence(timeout: 5),
            "seeded rewrite loading state did not show the inline review bar"
        )
        attachScreenshot(app, name: "rewrite-loading-shimmer")
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
        let deleteButton = app.buttons["Delete UI Trash Song"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.tap()

        let undoButton = app.buttons["Undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 3))
        undoButton.tap()

        XCTAssertTrue(app.buttons["Delete UI Trash Song"].waitForExistence(timeout: 5))
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

        // Delete is immediate (no confirmation); the undo toast confirms the move.
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))

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

            let unblockButton = app.buttons["unblockButton"]
            let hideAssistantButton = app.buttons["hideInlineAssistantButton"]
            XCTAssertTrue(unblockButton.waitForExistence(timeout: 5))
            XCTAssertTrue(hideAssistantButton.waitForExistence(timeout: 5))

            hideAssistantButton.tap()
            XCTAssertFalse(app.staticTexts["Assistant"].waitForExistence(timeout: 1))
            XCTAssertTrue(unblockButton.exists)

            unblockButton.tap()
            XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))

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

            // Delete is immediate (no confirmation); the undo toast confirms the move.
            XCTAssertTrue(app.buttons["Undo"].waitForExistence(timeout: 3))

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

        XCTAssertTrue(app.buttons["songActionsButton"].waitForExistence(timeout: 5))
        app.buttons["songActionsButton"].tap()
        XCTAssertTrue(app.buttons["Export"].waitForExistence(timeout: 5))
        app.buttons["Export"].tap()
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

        app.buttons["songActionsButton"].tap()
        app.buttons["Export"].tap()
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
        app.buttons["Cancel"].tap()
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
        let options = XCTMeasureOptions()
        options.iterationCount = 10
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            isolatedUITestApp().launch()
        }
    }

    @MainActor
    func testEditorInteractionPerformance() throws {
        try requirePhone()

        let app = isolatedUITestApp(arguments: [
            "--ui-test-seed-prosody-song",
            "--ui-test-fake-voice-recording",
        ])
        app.launch()

        let lyricsEditor = app.textViews["lyricsEditor"]
        let unblockButton = app.buttons["unblockButton"]
        let micButton = app.buttons["micButton"]
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        XCTAssertTrue(unblockButton.waitForExistence(timeout: 5))
        XCTAssertTrue(micButton.waitForExistence(timeout: 5))

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: options
        ) {
            lyricsEditor.tap()
            lyricsEditor.typeText("\nA measured line keeps time inside the light")
            app.swipeUp()
            app.swipeDown()
            let hideKeyboard = app.keyboards.buttons["Hide keyboard"]
            if hideKeyboard.exists {
                hideKeyboard.tap()
            }

            unblockButton.tap()
            XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
            app.buttons["Close Assistant"].tap()
            XCTAssertTrue(unblockButton.waitForExistence(timeout: 5))

            micButton.tap()
            XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 3))
            app.buttons["Stop recording"].tap()
            XCTAssertTrue(micButton.waitForExistence(timeout: 3))
        }
    }

    @MainActor
    func testAppearanceSwitchPerformance() throws {
        try requirePhone()

        let app = isolatedUITestApp(arguments: ["--ui-test-seed-prosody-song"])
        app.launch()

        let settingsButton = app.buttons["gearshape"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()
        XCTAssertTrue(app.staticTexts["APPEARANCE"].waitForExistence(timeout: 5))

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: options
        ) {
            for name in ["Paper", "Graphite", "Ink"] {
                let appearance = app.buttons[name]
                XCTAssertTrue(appearance.isHittable)
                appearance.tap()
                XCTAssertEqual(appearance.value as? String, "Selected")
            }
        }
    }

    @MainActor
    func testSuggestionActionsKeepWithoutEditingAndInsertWithUndo() throws {
        let app = isolatedUITestApp(arguments: ["--ui-test-seed-suggestions"])
        app.launch()
        let lyricsEditor = app.textViews["lyricsEditor"]
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        let isInline = app.buttons["hideInlineAssistantButton"].exists
        if !isInline { app.buttons["unblockButton"].tap() }
        let useLine = app.buttons["useSuggestionButton"]
        for _ in 0..<6 where !useLine.isHittable {
            app.scrollViews["assistantScrollView"].swipeUp()
        }
        XCTAssertTrue(useLine.isHittable)
        let suggestion = app.staticTexts["A quiet light carries me home"]
        XCTAssertTrue(suggestion.isHittable)
        suggestion.tap()
        XCTAssertTrue(useLine.isHittable)
        attachScreenshot(app, name: "suggestion-explicit-actions")

        app.buttons["keepSuggestionButton"].tap()
        XCTAssertEqual(app.buttons["keepSuggestionButton"].label, "Kept")
        if !isInline {
            app.buttons["Close Assistant"].tap()
            XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        }
        XCTAssertEqual(lyricsEditor.value as? String, "An opening line")
        if !isInline {
            app.buttons["unblockButton"].tap()
            for _ in 0..<6 where !useLine.isHittable {
                app.scrollViews["assistantScrollView"].swipeUp()
            }
        }
        useLine.tap()
        XCTAssertTrue(app.buttons["undoInsertedLineButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(lyricsEditor.value as? String, "An opening line\nA quiet light carries me home\n")
        attachScreenshot(app, name: "suggestion-line-added-feedback")
        app.buttons["undoInsertedLineButton"].tap()
        XCTAssertEqual(lyricsEditor.value as? String, "An opening line")
        XCTAssertFalse(app.buttons["undoInsertedLineButton"].exists)
    }

    @MainActor
    func testInsertionFeedbackKeepsRecordingStopReachable() throws {
        try requirePhone()
        let app = isolatedUITestApp(arguments: ["--ui-test-seed-suggestions", "--ui-test-fake-voice-recording"])
        app.launch()
        let mic = app.buttons["micButton"]
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        mic.tap()
        XCTAssertTrue(app.buttons["Stop recording"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["focusModeButton"].isEnabled)
        app.buttons["unblockButton"].tap()
        let useLine = app.buttons["useSuggestionButton"]
        for _ in 0..<6 where !useLine.isHittable {
            app.scrollViews["assistantScrollView"].swipeUp()
        }
        XCTAssertTrue(useLine.isHittable)
        useLine.tap()
        XCTAssertTrue(app.buttons["undoInsertedLineButton"].waitForExistence(timeout: 5))
        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.isHittable)
        attachScreenshot(app, name: "line-added-recording-stop")
        stop.tap()
        XCTAssertFalse(app.buttons["Stop recording"].exists)
        XCTAssertTrue(app.buttons["focusModeButton"].isEnabled)
        XCTAssertEqual(app.textViews["lyricsEditor"].value as? String, "An opening line\nA quiet light carries me home\n")
    }

    @MainActor
    func testFocusModeRestoresControlsAndTabletAssistantChoice() throws {
        let app = isolatedUITestApp(arguments: ["--ui-test-seed-suggestions"])
        app.launch()
        let focus = app.buttons["focusModeButton"]
        let editor = app.textViews["lyricsEditor"]
        XCTAssertTrue(focus.waitForExistence(timeout: 5))
        let assistantWasOpen = app.buttons["hideInlineAssistantButton"].exists
        focus.tap()
        XCTAssertEqual(focus.label, "Exit Focus")
        XCTAssertEqual(focus.value as? String, "On")
        XCTAssertFalse(app.buttons["songActionsButton"].exists)
        XCTAssertFalse(app.buttons["unblockButton"].exists)
        XCTAssertFalse(app.staticTexts["editorStats"].exists)
        XCTAssertFalse(app.buttons["hideInlineAssistantButton"].exists)
        attachScreenshot(app, name: "focus-writing")
        editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: editor.frame.width - 8, dy: 10)).tap()
        editor.typeText(" stays mine")
        XCTAssertEqual(editor.value as? String, "An opening line stays mine")
        focus.tap()
        XCTAssertEqual(focus.label, "Focus")
        XCTAssertTrue(app.buttons["songActionsButton"].exists)
        XCTAssertTrue(app.staticTexts["editorStats"].exists)
        XCTAssertEqual(app.buttons["hideInlineAssistantButton"].exists, assistantWasOpen)
        attachScreenshot(app, name: "focus-controls-restored")
        if assistantWasOpen {
            XCTAssertEqual(app.buttons["unblockButton"].label, "Hide AI suggestions")
            app.buttons["hideInlineAssistantButton"].tap()
            XCTAssertTrue(app.buttons["unblockButton"].waitForExistence(timeout: 3))
            XCTAssertEqual(app.buttons["unblockButton"].label, "Open AI suggestions")
            focus.tap()
            XCTAssertEqual(focus.label, "Exit Focus")
            focus.tap()
            XCTAssertEqual(focus.label, "Focus")
            XCTAssertFalse(app.buttons["hideInlineAssistantButton"].exists)
            XCTAssertEqual(app.buttons["unblockButton"].label, "Open AI suggestions")
        }
    }

    @MainActor
    func testModelSetupReturnsToAssistantInEveryAppearance() throws {
        let app = isolatedUITestApp(arguments: [
            "--ui-test-seed-prosody-song", "--ui-test-open-assistant",
            "-selectedProvider", "local"
        ])
        app.launch()
        for appearance in ["Graphite", "Paper", "Ink"] {
            let setup = app.buttons["Local model setup"]
            XCTAssertTrue(setup.waitForExistence(timeout: 5))
            for _ in 0..<5 where !setup.isHittable { app.swipeUp() }
            setup.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            app.buttons[appearance].tap()
            attachScreenshot(app, name: "model-settings-\(appearance)")
            app.buttons["Done"].tap()
            XCTAssertTrue(setup.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["Close Assistant"].exists)
            attachScreenshot(app, name: "model-return-\(appearance)")
        }
        app.buttons["Close Assistant"].tap()
        XCTAssertTrue(app.buttons["unblockButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["lyricsEditor"].exists)
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
