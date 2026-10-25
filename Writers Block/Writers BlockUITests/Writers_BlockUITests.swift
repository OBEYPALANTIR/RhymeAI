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

    /// A test that fails after rotating leaves the simulator in landscape;
    /// start every test from portrait so that cannot cascade.
    @MainActor
    override func setUp() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testColoredLyricsTypingAtLineEnd() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = isolatedUITestApp()
        app.launch()
        let window = app.windows.firstMatch
        let portraitWindowFrame = try XCTUnwrap(
            waitForStableFrame(of: window, matching: { $0.height > $0.width }),
            "The app window never settled in portrait"
        )
        let newSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSong.waitForExistence(timeout: 5))
        newSong.tap()
        let editor = app.textViews["lyricsEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let text = "The last word is light tonight and the melody carries through the night"
        editor.typeText(text)
        XCTAssertEqual(editor.value as? String, text)
        let portraitKeyboardFrame = try XCTUnwrap(
            waitForVisibleKeyboardFrame(in: app, windowFrame: portraitWindowFrame),
            "The software keyboard never became visible in portrait"
        )
        XCTAssertLessThanOrEqual(editor.frame.minY, portraitKeyboardFrame.minY)
        XCTAssertNotNil(
            waitForStableFrame(of: editor, matching: { $0.intersects(portraitWindowFrame) }),
            "The editor frame did not settle before the portrait capture"
        )
        attachScreenshot(app, name: "colored-lyrics-line-end-portrait")
        editor.typeText("s\nA new line")
        XCTAssertEqual(editor.value as? String, text + "s\nA new line")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let expectsLandscape = isRunningOnIPad
        let rotatedWindowFrame = try XCTUnwrap(
            waitForStableFrame(of: window, matching: {
                expectsLandscape ? $0.width > $0.height : $0.height > $0.width
            }),
            expectsLandscape
                ? "The iPad app window never settled in landscape"
                : "The portrait-only iPhone app window did not remain portrait"
        )
        let rotatedKeyboardFrame = try XCTUnwrap(
            waitForVisibleKeyboardFrame(in: app, windowFrame: rotatedWindowFrame),
            "The software keyboard never became visible after the orientation request"
        )
        editor.typeText(" ends here")
        XCTAssertEqual(editor.value as? String, text + "s\nA new line ends here")
        XCTAssertLessThanOrEqual(editor.frame.minY, rotatedKeyboardFrame.minY)
        XCTAssertNotNil(
            waitForStableFrame(of: editor, matching: { $0.intersects(rotatedWindowFrame) }),
            "The editor frame did not settle after the orientation request"
        )
        attachScreenshot(
            app,
            name: expectsLandscape
                ? "colored-lyrics-line-end-ipad-landscape"
                : "colored-lyrics-line-end-iphone-portrait-retained"
        )
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
            app.buttons["settingsButton"].tap()
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
        // The drawer slides in and out; a tap that lands mid-transition is
        // dropped, so wait for each surface to settle before using it.
        app.buttons["Open songs drawer"].tap()
        let createNewSong = app.buttons["Create New Song"]
        XCTAssertNotNil(waitForStableFrame(of: createNewSong, matching: { _ in createNewSong.isHittable }))
        createNewSong.tap()
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        XCTAssertNotNil(waitForStableFrame(of: lyrics, matching: { _ in !createNewSong.exists }))
        XCTAssertEqual(lyrics.value as? String, "", "Create New Song must open an empty draft")
        app.buttons["Open songs drawer"].tap()
        let savedSong = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Position proof")).firstMatch
        XCTAssertNotNil(waitForStableFrame(of: savedSong, matching: { _ in savedSong.isHittable }))
        savedSong.tap()
        XCTAssertEqual(lyrics.value as? String, before)
        XCTAssertFalse(title.isHittable, "Restoring must not return the document to the top.")
        attachScreenshot(app, name: "long-draft-position-after-switch")
        lyrics.typeText("RESTORED")
        XCTAssertEqual(lyrics.value as? String, before.replacingOccurrences(of: "CURSORPROOF", with: "CURSORPROOFRESTORED"))
        attachScreenshot(app, name: "long-draft-caret-insertion-proof")
    }

    @MainActor
    func testTapOnSongsDrawerTopPaddingKeepsDrawerOpen() throws {
        let app = isolatedUITestApp()
        app.launch()
        createNewSong(in: app)
        XCTAssertTrue(app.buttons["Open songs drawer"].waitForExistence(timeout: 5))
        app.buttons["Open songs drawer"].tap()
        let closeDrawer = app.buttons["Close drawer"]
        let closeFrame = try XCTUnwrap(
            waitForStableFrame(of: closeDrawer, matching: { _ in closeDrawer.isHittable }),
            "The songs drawer did not settle open"
        )
        // Empty panel padding just above the search row, inside the drawer.
        // The panel runs from the leading edge to just past the close button
        // (full width on compact, a side panel on regular width), so halfway
        // to the button's trailing edge is the panel's middle, not the scrim.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: closeFrame.maxX / 2, dy: closeFrame.minY - 12))
            .tap()
        // Outlast the dismissal animation so a closing drawer is caught.
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot(app, name: "drawer-after-top-padding-tap")
        XCTAssertTrue(
            closeDrawer.exists && closeDrawer.isHittable,
            "A tap on the drawer's own padding must not dismiss the drawer"
        )
    }

    @MainActor
    func testBlankTrashScreenDoesNotPassTapsToTheDrawer() throws {
        let app = isolatedUITestApp()
        app.launch()
        createNewSong(in: app)
        XCTAssertTrue(app.buttons["Open songs drawer"].waitForExistence(timeout: 5))
        app.buttons["Open songs drawer"].tap()
        let createNewSong = app.buttons["Create New Song"]
        let createFrame = try XCTUnwrap(
            waitForStableFrame(of: createNewSong, matching: { _ in createNewSong.isHittable }),
            "The songs drawer did not settle open"
        )
        app.buttons["Open Trash Bin"].tap()
        let emptyTrash = app.staticTexts["No Songs in Trash"]
        XCTAssertTrue(emptyTrash.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        // Blank Trash space over the spot where Create New Song sits beneath.
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: max(createFrame.midX, 40), dy: createFrame.midY))
            .tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(
            emptyTrash.exists && app.buttons["Back to songs"].isHittable,
            "A tap on blank Trash space must not reach the songs drawer underneath"
        )
    }

    @MainActor
    func testCreateNewSongTapRightAfterOpeningDrawerIsHonoured() throws {
        let app = isolatedUITestApp()
        app.launch()
        createNewSong(in: app)
        let lyrics = app.textViews["lyricsEditor"]
        XCTAssertTrue(lyrics.waitForExistence(timeout: 5))
        lyrics.tap()
        lyrics.typeText("Draft that must be replaced")
        // No settle wait on purpose: the tap follows the open as fast as
        // XCUITest can deliver it and must still create the song.
        app.buttons["Open songs drawer"].tap()
        let createNewSong = app.buttons["Create New Song"]
        createNewSong.tap()
        let drawerGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: createNewSong
        )
        let outcome = XCTWaiter().wait(for: [drawerGone], timeout: 5)
        attachScreenshot(app, name: "drawer-after-immediate-create-tap")
        XCTAssertEqual(outcome, .completed, "Create New Song tapped right after opening must close the drawer")
        XCTAssertEqual(lyrics.value as? String, "", "Create New Song tapped right after opening must open an empty draft")
    }

    /// New Song lands with the caret in the title, so the first keystroke names
    /// the song; opening a saved song keeps its restored cursor instead.
    @MainActor
    func testNewSongFocusesTheTitleFieldAndOpeningASongDoesNot() throws {
        let app = isolatedUITestApp()
        app.launch()
        let newSong = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch
        XCTAssertTrue(newSong.waitForExistence(timeout: 5))
        newSong.tap()
        let title = app.textFields["songTitleEditor"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let focused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: title
        )
        XCTAssertEqual(XCTWaiter().wait(for: [focused], timeout: 3), .completed, "New Song must move focus to the title field")
        app.typeText("Paper Moon")
        XCTAssertEqual(title.value as? String, "Paper Moon")
        attachScreenshot(app, name: "new-song-title-focused")

        app.buttons["Open songs drawer"].tap()
        let createNewSong = app.buttons["Create New Song"]
        XCTAssertNotNil(waitForStableFrame(of: createNewSong, matching: { _ in createNewSong.isHittable }))
        createNewSong.tap()
        XCTAssertNotNil(waitForStableFrame(of: title, matching: { _ in !createNewSong.exists }))
        XCTAssertEqual(XCTWaiter().wait(for: [focused], timeout: 3), .completed, "Create New Song from the drawer must focus the title too")
        app.typeText("x")
        app.buttons["Open songs drawer"].tap()
        let savedSong = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Paper Moon")).firstMatch
        XCTAssertNotNil(waitForStableFrame(of: savedSong, matching: { _ in savedSong.isHittable }))
        savedSong.tap()
        XCTAssertNotNil(waitForStableFrame(of: title, matching: { _ in !savedSong.exists }))
        XCTAssertEqual(title.value as? String, "Paper Moon")
        XCTAssertFalse(title.value(forKey: "hasKeyboardFocus") as? Bool ?? false, "Opening a saved song keeps its restored cursor, not the title")
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
        let orientations: [UIDeviceOrientation] = isRunningOnIPad ? [.portrait, .landscapeLeft] : [.portrait]
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
    func testLyricsEditorRendersAtDefaultAndAccessibilityTextSizes() throws {
        let configurations: [(name: String, arguments: [String])] = [
            ("default", []),
            ("accessibility-xxxl", [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
            ]),
        ]

        for configuration in configurations {
            let app = isolatedUITestApp(arguments: ["--ui-test-seed-prosody-song"] + configuration.arguments)
            app.launch()

            let window = app.windows.firstMatch
            let windowFrame = try XCTUnwrap(
                waitForStableFrame(of: window, matching: { $0.height > $0.width }),
                "The app window never settled in portrait for \(configuration.name)"
            )
            let editor = app.textViews["lyricsEditor"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            XCTAssertTrue((editor.value as? String)?.contains("yellow music") == true)
            editor.tap()
            let keyboardProbe = " keyboard visible"
            editor.typeText(keyboardProbe)
            XCTAssertTrue((editor.value as? String)?.contains(keyboardProbe) == true)
            let keyboardFrame = try XCTUnwrap(
                waitForVisibleKeyboardFrame(in: app, windowFrame: windowFrame),
                "The software keyboard never occupied the app window for \(configuration.name)"
            )
            XCTAssertTrue(editor.isHittable)

            if configuration.name == "accessibility-xxxl" {
                let focusButton = app.buttons["focusModeButton"]
                XCTAssertTrue(focusButton.waitForExistence(timeout: 3))
                let outerHitOffset: CGFloat = 19
                var outerHitPoint = CGPoint(
                    x: focusButton.frame.midX,
                    y: focusButton.frame.midY + outerHitOffset
                )
                XCTAssertTrue(windowFrame.contains(outerHitPoint))
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: outerHitPoint.x, dy: outerHitPoint.y))
                    .tap()
                XCTAssertEqual(focusButton.value as? String, "On")

                outerHitPoint = CGPoint(
                    x: focusButton.frame.midX,
                    y: focusButton.frame.midY + outerHitOffset
                )
                XCTAssertTrue(windowFrame.contains(outerHitPoint))
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: outerHitPoint.x, dy: outerHitPoint.y))
                    .tap()
                XCTAssertEqual(focusButton.value as? String, "Off")
            }

            let topControls = [
                app.buttons["Open songs drawer"],
                app.buttons["undoLyricsButton"],
                app.buttons["redoLyricsButton"],
                app.buttons["focusModeButton"],
                app.buttons["songActionsButton"],
                app.buttons["settingsButton"],
            ]
            for control in topControls {
                XCTAssertTrue(control.waitForExistence(timeout: 3))
                XCTAssertTrue(windowFrame.contains(control.frame))
            }
            // Regular width at accessibility sizes stacks the leading and
            // trailing controls on two rows; order applies within a row.
            for (leading, trailing) in zip(topControls, topControls.dropFirst()) {
                let sharesRow = leading.frame.minY < trailing.frame.maxY && trailing.frame.minY < leading.frame.maxY
                if sharesRow {
                    XCTAssertLessThanOrEqual(leading.frame.maxX, trailing.frame.minX)
                } else {
                    XCTAssertLessThanOrEqual(leading.frame.maxY, trailing.frame.minY)
                }
            }

            let unblockButton = app.buttons["unblockButton"]
            let micButton = app.buttons["micButton"]
            XCTAssertTrue(unblockButton.waitForExistence(timeout: 3))
            XCTAssertTrue(micButton.waitForExistence(timeout: 3))
            XCTAssertTrue(windowFrame.contains(unblockButton.frame))
            XCTAssertTrue(windowFrame.contains(micButton.frame))
            XCTAssertLessThan(unblockButton.frame.maxX, micButton.frame.minX)
            XCTAssertLessThanOrEqual(unblockButton.frame.maxY, keyboardFrame.minY + 4)
            XCTAssertLessThanOrEqual(micButton.frame.maxY, keyboardFrame.minY + 4)
            XCTAssertNotNil(
                waitForStableFrame(of: unblockButton, matching: { windowFrame.contains($0) }),
                "The editor actions did not settle before the \(configuration.name) capture"
            )
            let lyricViewport = app.scrollViews["lyricsScrollView"]
            XCTAssertTrue(lyricViewport.waitForExistence(timeout: 3))
            XCTAssertLessThanOrEqual(lyricViewport.frame.maxY, unblockButton.frame.minY)
            XCTAssertLessThanOrEqual(lyricViewport.frame.maxY, micButton.frame.minY)
            print("C1V1 geometry \(configuration.name) keyboard shown: viewport=\(lyricViewport.frame) unblock=\(unblockButton.frame) mic=\(micButton.frame) keyboard=\(keyboardFrame)")
            attachScreenshot(app, name: "lyrics-editor-\(configuration.name)")

            lyricViewport.swipeUp()
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            XCTAssertLessThanOrEqual(lyricViewport.frame.maxY, unblockButton.frame.minY)
            XCTAssertLessThanOrEqual(lyricViewport.frame.maxY, micButton.frame.minY)
            print("C1V1 geometry \(configuration.name) keyboard hidden: viewport=\(lyricViewport.frame) unblock=\(unblockButton.frame) mic=\(micButton.frame)")
            attachScreenshot(app, name: "lyrics-editor-keyboard-hidden-\(configuration.name)")

            if configuration.name == "accessibility-xxxl" {
                let focusButton = app.buttons["focusModeButton"]
                focusButton.tap()
                XCTAssertFalse(unblockButton.exists)
                XCTAssertFalse(micButton.exists)
                focusButton.tap()
                XCTAssertTrue(unblockButton.waitForExistence(timeout: 3))
                XCTAssertLessThanOrEqual(lyricViewport.frame.maxY, unblockButton.frame.minY)
                attachScreenshot(app, name: "lyrics-editor-focus-exit-accessibility-xxxl")
            }

            app.terminate()
        }
    }

    @MainActor
    func testFloatingActionsClearLaterLyricLinesWithEarlierCaretAtXXXL() throws {
        try requirePhone()
        let app = isolatedUITestApp(arguments: [
            "--ui-test-seed-prosody-song",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        app.launch()

        let editor = app.textViews["lyricsEditor"]
        let viewport = app.scrollViews["lyricsScrollView"]
        let unblock = app.buttons["unblockButton"]
        let mic = app.buttons["micButton"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        XCTAssertTrue(unblock.waitForExistence(timeout: 5))
        XCTAssertTrue(mic.waitForExistence(timeout: 5))

        editor.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 20, dy: 20)).tap()
        editor.typeText(" keyboard visible")
        let lyrics = try XCTUnwrap(editor.value as? String)
        XCTAssertTrue(lyrics.contains("follow music"))
        XCTAssertTrue(lyrics.contains("mellow music"))
        let windowFrame = app.windows.firstMatch.frame
        XCTAssertNotNil(waitForVisibleKeyboardFrame(in: app, windowFrame: windowFrame))
        // The scroll viewport clips every visible lyric glyph, including lines after the caret.
        XCTAssertLessThanOrEqual(viewport.frame.maxY, unblock.frame.minY)
        XCTAssertLessThanOrEqual(viewport.frame.maxY, mic.frame.minY)
        print("C1V1 geometry earlier caret keyboard shown: viewport=\(viewport.frame) unblock=\(unblock.frame) mic=\(mic.frame)")
        attachScreenshot(app, name: "xxxl-earlier-caret-later-lines-keyboard-shown")

        viewport.swipeUp()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertLessThanOrEqual(viewport.frame.maxY, unblock.frame.minY)
        XCTAssertLessThanOrEqual(viewport.frame.maxY, mic.frame.minY)
        attachScreenshot(app, name: "xxxl-earlier-caret-later-lines-keyboard-hidden")
    }

    @MainActor
    func testRegularWidthEditorActionsScaleAtAccessibilitySizes() throws {
        try requireIPad()
        let configurations: [(name: String, arguments: [String])] = [
            ("default", []),
            ("accessibility-xxxl", [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
            ])
        ]
        var defaultHeights: (focus: CGFloat, hideAI: CGFloat, save: CGFloat)?

        for configuration in configurations {
            let app = isolatedUITestApp(arguments: [
                "--ui-test-seed-prosody-song", "--ui-test-force-save-failed"
            ] + configuration.arguments)
            app.launch()
            let window = app.windows.firstMatch.frame
            let focus = app.buttons["focusModeButton"]
            let hideAI = app.buttons["unblockButton"]
            let save = app.buttons["Save failed. Retry saving"]
            XCTAssertTrue(focus.waitForExistence(timeout: 5))
            XCTAssertTrue(hideAI.waitForExistence(timeout: 5))
            XCTAssertTrue(save.waitForExistence(timeout: 5))
            XCTAssertEqual(hideAI.label, "Hide AI suggestions")
            XCTAssertTrue(window.contains(focus.frame))
            XCTAssertTrue(window.contains(hideAI.frame))
            XCTAssertTrue(window.contains(save.frame))
            XCTAssertFalse(save.frame.intersects(focus.frame), "Save and Focus must not intersect across toolbar rows")
            print("C1 regular width \(configuration.name): save=\(save.frame) focus=\(focus.frame) hideAI=\(hideAI.frame)")
            XCTAssertGreaterThanOrEqual(hideAI.frame.height, 56)
            if let defaultHeights {
                XCTAssertGreaterThan(focus.frame.height, defaultHeights.focus)
                XCTAssertGreaterThan(hideAI.frame.height, defaultHeights.hideAI)
                XCTAssertGreaterThan(save.frame.height, defaultHeights.save)
            } else {
                defaultHeights = (focus.frame.height, hideAI.frame.height, save.frame.height)
            }
            attachScreenshot(app, name: "regular-width-actions-\(configuration.name)")
            focus.tap()
            XCTAssertEqual(focus.label, "Exit Focus")
            XCTAssertTrue(window.contains(focus.frame))
            attachScreenshot(app, name: "regular-width-exit-focus-\(configuration.name)")
            focus.tap()
            XCTAssertEqual(focus.label, "Focus")
            hideAI.tap()
            XCTAssertEqual(hideAI.label, "Open AI suggestions")
            attachScreenshot(app, name: "regular-width-hide-ai-hidden-\(configuration.name)")
            XCTAssertTrue(save.isHittable)
            save.tap()
            let retryFinished = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: save
            )
            XCTAssertEqual(XCTWaiter.wait(for: [retryFinished], timeout: 5), .completed)
            attachScreenshot(app, name: "regular-width-save-retried-\(configuration.name)")

            let unblock = app.buttons["unblockButton"]
            let mic = app.buttons["micButton"]
            let lyricViewport = app.scrollViews["lyricsScrollView"]
            func checkAlternateActions(_ stage: String) {
                XCTAssertEqual(unblock.label, "Open AI suggestions")
                XCTAssertTrue(mic.exists)
                XCTAssertNotNil(waitForStableFrame(of: unblock, matching: { window.contains($0) }))
                XCTAssertTrue(window.contains(mic.frame))
                XCTAssertFalse(unblock.frame.intersects(mic.frame))
                XCTAssertLessThanOrEqual(lyricViewport.frame.maxY, unblock.frame.minY)
                XCTAssertLessThanOrEqual(lyricViewport.frame.maxY, mic.frame.minY)
                XCTAssertEqual(mic.frame.width, 44, accuracy: 1)
                if configuration.name == "accessibility-xxxl" {
                    XCTAssertGreaterThan(unblock.frame.width, 180, "UnBlock must have room for its full wordmark")
                }
                print("C1 alternate \(configuration.name) \(stage): viewport=\(lyricViewport.frame) unblock=\(unblock.frame) mic=\(mic.frame)")
                attachScreenshot(app, name: "regular-width-unblock-\(configuration.name)-\(stage)")
            }
            checkAlternateActions("keyboard-hidden")
            focus.tap()
            XCTAssertEqual(focus.label, "Exit Focus")
            XCTAssertFalse(unblock.exists)
            focus.tap()
            XCTAssertEqual(focus.label, "Focus")
            XCTAssertTrue(unblock.waitForExistence(timeout: 5))
            checkAlternateActions("focus-return")
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            unblock.tap()
            let reopened = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", "Hide AI suggestions"), object: unblock
            )
            XCTAssertEqual(XCTWaiter.wait(for: [reopened], timeout: 5), .completed)
            attachScreenshot(app, name: "regular-width-ai-reopened-\(configuration.name)")
            app.terminate()
        }
    }

    @MainActor
    func testRegularWidthAlternateActionsClearShownKeyboard() throws {
        try requireIPad()
        let app = isolatedUITestApp(arguments: [
            "--ui-test-seed-prosody-song",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
        ])
        app.launch()
        let window = app.windows.firstMatch.frame
        let unblock = app.buttons["unblockButton"]
        let mic = app.buttons["micButton"]
        XCTAssertTrue(unblock.waitForExistence(timeout: 5))
        unblock.tap()
        XCTAssertEqual(unblock.label, "Open AI suggestions")
        let editor = app.textViews["lyricsEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        // A tap alone leaves the simulator's software keyboard collapsed when
        // it assumes a hardware keyboard; typing summons it.
        editor.typeText(" keyboard visible")
        let keyboard = try XCTUnwrap(
            waitForVisibleKeyboardFrame(in: app, windowFrame: window),
            "iPad software keyboard did not appear; shown-state clearance is unverified"
        )
        XCTAssertFalse(unblock.frame.intersects(mic.frame))
        XCTAssertLessThanOrEqual(app.scrollViews["lyricsScrollView"].frame.maxY, unblock.frame.minY)
        XCTAssertLessThanOrEqual(unblock.frame.maxY, keyboard.minY + 4)
        XCTAssertLessThanOrEqual(mic.frame.maxY, keyboard.minY + 4)
        attachScreenshot(app, name: "regular-width-unblock-accessibility-xxxl-keyboard-shown")
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
        try requireCompactEditor(app)
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
        try requireCompactEditor(app)
        XCTAssertLessThan(unblockButton.frame.maxX, micButton.frame.minX)

        // Measure from the editor's trailing safe-area edge, not the window: a
        // display with a trailing inset (the iPhone Duo's side status bar)
        // moves the whole editor in. The lyrics view sits 20pt inside that edge.
        let lyricsEditor = app.textViews["lyricsEditor"]
        XCTAssertTrue(lyricsEditor.waitForExistence(timeout: 5))
        let trailingEdge = lyricsEditor.frame.maxX + 20
        let trailingInset = trailingEdge - micButton.frame.maxX
        XCTAssertGreaterThanOrEqual(trailingInset, 20)
        XCTAssertLessThanOrEqual(trailingInset, 32)
        XCTAssertGreaterThanOrEqual(micButton.frame.width, 44)
        XCTAssertGreaterThanOrEqual(micButton.frame.height, 44)
        // The 56-point mic circle sits 20 points from the editor edge.
        XCTAssertEqual(micButton.frame.midX, trailingEdge - 20 - 28, accuracy: 1)
        XCTAssertEqual(micButton.frame.midY, unblockButton.frame.midY, accuracy: 1)
        XCTAssertLessThan(undoButton.frame.maxX, redoButton.frame.minX)
        XCTAssertLessThan(redoButton.frame.maxY, unblockButton.frame.minY)
        attachScreenshot(app, name: "mic-centered-idle")
        lyricsEditor.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3))
        XCTAssertEqual(micButton.frame.midX, trailingEdge - 20 - 28, accuracy: 1)
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
        // Enough lines to overflow the tallest editor viewport (iPad portrait).
        let longLyrics = (1...80)
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
        // iOS 27 menus expose SwiftUI menu items by label only, so accept either.
        let bridgeSection = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "sectionMenuBridge", "Bridge")
        ).firstMatch
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

        let settingsButton = app.buttons["settingsButton"]
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

        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()

        for name in ["Ink", "Paper", "Graphite"] {
            XCTAssertFalse(app.otherElements["\(name) preview"].exists)
            let option = app.buttons[name]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            XCTAssertTrue(option.isSelected, "\(name) did not apply immediately")
            XCTAssertTrue(app.buttons["saveSettingsButton"].isHittable)
        }
    }

    /// The provider control sits below the fold on short sheets (iPad), so
    /// its segments must stay tappable, and report selection, after the
    /// settings list scrolls.
    @MainActor
    func testProviderSegmentsWorkAfterScrollingSettings() throws {
        let app = isolatedUITestApp()
        app.launch()
        createNewSong(in: app)

        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        let picker = app.segmentedControls["providerPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "Provider control is missing from Settings")
        let scroll = app.scrollViews.element(boundBy: app.scrollViews.count - 1)
        let claude = picker.buttons["Claude"]
        // Short drags: a full swipe can carry the control straight past the
        // visible part of a short sheet.
        for _ in 0..<12 where !claude.isHittable {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -90)))
        }
        XCTAssertTrue(claude.isHittable, "Claude segment is not tappable after scrolling: \(claude.frame) in \(scroll.frame)")
        claude.tap()
        XCTAssertTrue(claude.isSelected, "Claude did not become the selected provider")
        XCTAssertTrue(app.secureTextFields["API Key"].waitForExistence(timeout: 5))

        let local = picker.buttons["Local"]
        local.tap()
        XCTAssertTrue(local.isSelected, "Local did not become the selected provider")
        XCTAssertFalse(claude.isSelected)
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
        try requireCompactEditor(app)
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
        try requireCompactEditor(app)
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
        expandTargetLineStressDetail(in: app)
        XCTAssertTrue(app.staticTexts["ˈDA da | ˈDA da"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "jɛloʊ")).firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    func testLocalAssistantStopAndRestart() throws {
        guard UserDefaults.standard.bool(forKey: "RhymeAITestNativeRuntimeUI") else {
            throw XCTSkip("Enable the local runtime UI gate after installing the accepted E2B model.")
        }
        let app = isolatedUITestApp(arguments: [
            "--ui-test-seed-prosody-song", "--ui-test-open-assistant",
            "-ggufEngineChoice", "gemma",
            "-selectedGGUFModelFileName", "gemma-4-E2B-it-rhymeai-Q4_K_M.gguf"
        ])
        app.launch()
        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
        let suggest = app.buttons["Suggest Next Line"]
        XCTAssertTrue(suggest.waitForExistence(timeout: 5))
        suggest.tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        let loading = XCTAttachment(screenshot: app.screenshot())
        loading.name = "local-suggestions-loading"
        loading.lifetime = .keepAlways
        add(loading)
        app.buttons["Stop"].tap()
        XCTAssertTrue(suggest.waitForExistence(timeout: 1))
        let stopped = XCTAttachment(screenshot: app.screenshot())
        stopped.name = "local-suggestions-stopped"
        stopped.lifetime = .keepAlways
        add(stopped)
        suggest.tap()
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 5))
        app.buttons["Stop"].tap()
        XCTAssertTrue(suggest.waitForExistence(timeout: 1))
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
            "-selectedProvider",
            "GEMINI",
            "--ui-test-seed-prosody-song",
            "--ui-test-open-assistant"
        ])
        app.launchEnvironment["GEMINI_TEST_KEY"] = "offline-smoke-key"
        app.launchEnvironment["RHYMEAI_GEMINI_BASE_URL"] = "https://127.0.0.1:1/v1beta"
        app.launch()

        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
        app.buttons["Suggest Next Line"].tap()
        approveCloudAISharing(in: app)

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
            expandTargetLineStressDetail(in: app)
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

            XCTAssertTrue(app.buttons["Move UI Trash Song to Trash"].waitForExistence(timeout: 5))
            app.buttons["Move UI Trash Song to Trash"].tap()

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

        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        app.buttons["settingsButton"].tap()
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
        app.launchArguments = ["--ui-test-local-store"]
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
            "-selectedProvider",
            "GEMINI",
            "--ui-test-seed-prosody-song",
            "--ui-test-open-assistant"
        ])
        app.launch()

        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
        app.buttons["Suggest Next Line"].tap()
        approveCloudAISharing(in: app)
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No API key set"))
                .firstMatch
                .waitForExistence(timeout: 10)
        )
    }

    @MainActor
    func testReleaseRewriteNoKeyFailsGracefully() throws {
        let app = isolatedUITestApp(arguments: [
            "-selectedProvider",
            "GEMINI",
            "--ui-test-seed-rewrite-selection",
            "--ui-test-force-rewrite-bar"
        ])
        app.launch()

        XCTAssertTrue(app.buttons["Rephrase"].waitForExistence(timeout: 5))
        app.buttons["Rephrase"].tap()
        approveCloudAISharing(in: app)

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

        app.buttons["songActionsButton"].tap()
        let exportButton = app.buttons["Export"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 3))
        exportButton.tap()
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
        // Regular-width layouts keep the assistant open as an inline panel,
        // where this button would hide it instead.
        if !app.staticTexts["Assistant"].exists {
            unblockButton.tap()
        }
        XCTAssertTrue(app.staticTexts["Assistant"].waitForExistence(timeout: 5))
        attachScreenshot(app, name: "release-assistant-panel")
        // Sheet close on compact width, inline panel hide on regular width.
        app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Close Assistant", "Hide Assistant"])
        ).firstMatch.tap()

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
        approveCloudAISharing(in: suggestionApp)
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
        approveCloudAISharing(in: rewriteApp)
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

        let settingsButton = app.buttons["settingsButton"]
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
                XCTAssertTrue(appearance.isSelected)
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
        try requireCompactEditor(app)
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
        // Compact width presents the assistant as a sheet ("Close Assistant");
        // regular width shows it inline ("Hide Assistant").
        let closeAssistant = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Close Assistant", "Hide Assistant"])
        ).firstMatch
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
            XCTAssertTrue(closeAssistant.exists)
            attachScreenshot(app, name: "model-return-\(appearance)")
        }
        closeAssistant.tap()
        XCTAssertTrue(app.buttons["unblockButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews["lyricsEditor"].exists)
    }

    /// The target line keeps its stress pattern and IPA behind a disclosure
    /// whose state is remembered between launches, so only expand it when it
    /// is collapsed.
    private func expandTargetLineStressDetail(in app: XCUIApplication) {
        let disclosure = app.buttons["targetLineStressDisclosure"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "Target line stress disclosure is missing")
        if disclosure.label == "Show stress pattern" {
            XCTAssertFalse(app.staticTexts["ˈDA da | ˈDA da"].exists, "Stress detail should stay hidden until asked for")
            disclosure.tap()
        }
        XCTAssertEqual(disclosure.label, "Hide stress pattern")
    }

    /// T5.12: a take that could not be saved is deleted only after the confirmation;
    /// cancelling keeps it.
    @MainActor
    func testFailedRecordingIsDeletedOnlyAfterConfirmation() throws {
        let app = isolatedUITestApp(arguments: ["--ui-test-seed-failed-take"])
        app.launch()
        let actions = app.buttons["songActionsButton"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        actions.tap()
        let recordings = app.buttons["Song Recordings"]
        XCTAssertTrue(recordings.waitForExistence(timeout: 5))
        recordings.tap()
        let failed = app.descendants(matching: .any)["failedRecordings"]
        XCTAssertTrue(failed.waitForExistence(timeout: 5))

        app.buttons["deleteFailedRecording"].tap()
        let confirm = app.buttons["Delete Recording"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "deleting asks first")
        let cancel = app.buttons["Cancel"]
        if cancel.exists { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
        XCTAssertTrue(failed.waitForExistence(timeout: 3), "cancelling keeps the recording")

        app.buttons["deleteFailedRecording"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: failed)
        waitForExpectations(timeout: 5)
    }

    private func isolatedUITestApp(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store"] + arguments
        return app
    }

    /// Cloud providers ask for sharing consent before the first request of a
    /// fresh install; the request only proceeds after the writer allows it.
    private func approveCloudAISharing(in app: XCUIApplication) {
        let allow = app.alerts.buttons["Allow and Continue"]
        XCTAssertTrue(allow.waitForExistence(timeout: 5), "Cloud AI sharing consent prompt did not appear")
        allow.tap()
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

    private func waitForVisibleKeyboardFrame(
        in app: XCUIApplication,
        windowFrame: CGRect,
        timeout: TimeInterval = 5
    ) -> CGRect? {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: timeout) else { return nil }
        return waitForStableFrame(of: keyboard, timeout: timeout) { frame in
            frame.height >= 100
                && frame.width >= windowFrame.width * 0.8
                && frame.intersects(windowFrame)
                && frame.maxY <= windowFrame.maxY + 4
        }
    }

    private func waitForStableFrame(
        of element: XCUIElement,
        timeout: TimeInterval = 5,
        matching predicate: (CGRect) -> Bool
    ) -> CGRect? {
        let deadline = Date().addingTimeInterval(timeout)
        var previousFrame: CGRect?
        var stableSampleCount = 0

        while Date() < deadline {
            let frame = element.frame.integral
            if element.exists && predicate(frame) {
                if frame == previousFrame {
                    stableSampleCount += 1
                } else {
                    previousFrame = frame
                    stableSampleCount = 1
                }
                if stableSampleCount >= 3 {
                    return frame
                }
            } else {
                previousFrame = nil
                stableSampleCount = 0
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        return nil
    }

    private var ipadAuditOrientations: [UIDeviceOrientation] {
        [.portrait, .landscapeLeft]
    }

    /// The UI test runner is an iPhone-family bundle, so on an iPad simulator
    /// its own `UIDevice` idiom reports `.phone`; the simulator name is the
    /// reliable signal for the device the app under test runs on.
    private var isRunningOnIPad: Bool {
        let simulatorName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        return UIDevice.current.userInterfaceIdiom == .pad || simulatorName.localizedCaseInsensitiveContains("iPad")
    }

    private func requireIPad() throws {
        guard isRunningOnIPad else {
            throw XCTSkip("iPad-only audit test")
        }
    }

    private func requirePhone() throws {
        guard !isRunningOnIPad else {
            throw XCTSkip("Phone-only assistant sheet test")
        }
    }

    /// A large phone can report a regular width class and get the wide
    /// editor, whose inline Assistant column shows its hide button; the
    /// compact chrome and sheet assertions do not apply there.
    private func requireCompactEditor(_ app: XCUIApplication) throws {
        if app.buttons["hideInlineAssistantButton"].exists {
            throw XCTSkip("Regular-width editor: the compact chrome and sheet assertions do not apply")
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
