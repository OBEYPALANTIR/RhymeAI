import XCTest
import UIKit

/// Screenshot walkthrough for visual review. It asserts nothing about
/// behaviour: every step is best effort and a missing surface is written to
/// the "ux-audit-notes" attachment instead of failing the run.
///
/// Opt in with `TEST_RUNNER_RUN_UX_AUDIT=1`. Optional comma-separated filters:
/// `TEST_RUNNER_UX_AUDIT_APPEARANCES` (ink,paper,graphite),
/// `TEST_RUNNER_UX_AUDIT_SIZES` (default,ax3),
/// `TEST_RUNNER_UX_AUDIT_ORIENTATIONS` (portrait,landscape) and
/// `TEST_RUNNER_UX_AUDIT_SCENES` (scene names below).
/// Attachments are named `<appearance>__<size>__<orientation>__<nn>-<screen>`.
/// Landscape attachments are the unrotated screen buffer; rotate them a
/// quarter turn anticlockwise when exporting.
final class UXAuditWalkthroughUITests: XCTestCase {
    private var appearance = "ink"
    private var size = "default"
    private var orientationName = "portrait"
    private var shotIndex = 0
    private var notes: [String] = []
    private var controlFindings: [String] = []
    private var seenControlFindings = Set<String>()

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testUXAuditWalkthroughCapturesEveryScreen() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["RUN_UX_AUDIT"] == "1", "Set TEST_RUNNER_RUN_UX_AUDIT=1 to capture the UX audit walkthrough")
        defer { XCUIDevice.shared.orientation = .portrait }

        let appearances = filter(environment["UX_AUDIT_APPEARANCES"], default: ["ink", "paper", "graphite"])
        let sizes = filter(environment["UX_AUDIT_SIZES"], default: ["default", "ax3"])
        let scenes = filter(environment["UX_AUDIT_SCENES"], default: Scene.allCases.map(\.rawValue))
        let orientations = filter(environment["UX_AUDIT_ORIENTATIONS"], default: ["portrait", "landscape"])

        for appearance in appearances {
            for size in sizes {
                self.appearance = appearance
                self.size = size
                shotIndex = 0
                if orientations.contains("portrait") {
                    run(scenes: scenes, orientation: .portrait)
                }
                if isRunningOnIPad, size == "default", orientations.contains("landscape") {
                    run(scenes: scenes.filter { ["editor", "drawer", "welcome"].contains($0) }, orientation: .landscapeLeft)
                }
            }
        }

        attach(text: notes.joined(separator: "\n"), name: "ux-audit-notes")
        attach(text: controlFindings.joined(separator: "\n"), name: "ux-audit-controls")
    }

    private enum Scene: String, CaseIterable {
        case welcome, editor, drawer, assistant, cloud, suggestions, rewrite, recording, settings, states
    }

    @MainActor
    private func run(scenes: [String], orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        orientationName = orientation == .portrait ? "portrait" : "landscape"
        for name in scenes {
            guard let scene = Scene(rawValue: name) else { continue }
            switch scene {
            case .welcome: welcomeScene()
            case .editor: editorScene()
            case .drawer: drawerScene()
            case .assistant: assistantScene()
            case .cloud: cloudScene()
            case .suggestions: suggestionsScene()
            case .rewrite: rewriteScene()
            case .recording: recordingScene()
            case .settings: settingsScene()
            case .states: statesScene()
            }
        }
    }

    // MARK: - Scenes

    @MainActor
    private func welcomeScene() {
        let app = launch()
        shot(app, "welcome")
        if tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Load Song")).firstMatch, "Load Song") {
            shot(app, "projects-sheet-empty")
            tap(app.buttons["Done"], "projects Done")
        }
        if tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Song Templates")).firstMatch, "Song Templates") {
            shot(app, "templates-sheet")
            app.swipeUp()
            shot(app, "templates-sheet-scrolled")
        }
        app.terminate()
    }

    @MainActor
    private func editorScene() {
        let app = launch()
        guard tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch, "New Song") else {
            app.terminate()
            return
        }
        let lyrics = app.textViews["lyricsEditor"]
        guard lyrics.waitForExistence(timeout: 5) else {
            note("MISSING lyricsEditor")
            app.terminate()
            return
        }
        shot(app, "editor-empty")
        tap(app.buttons["songActionsButton"], "song actions (empty song)")
        shot(app, "song-actions-menu-empty-song")
        dismissMenu(app)

        tap(app.textFields["songTitleEditor"], "title field")
        app.textFields["songTitleEditor"].typeText("Borrowed Train")
        lyrics.tap()
        shot(app, "editor-empty-keyboard")
        lyrics.typeText("[Verse 1]\nMidnight notes on a borrowed train\nI keep the hook alive through rain\nEvery echo knows my name\nNothing here will stay the same\n\n[Chorus]\nHold the light and hold the line\nEvery borrowed word is mine")
        shot(app, "editor-lyrics-keyboard")

        tap(app.buttons["songActionsButton"], "song actions")
        shot(app, "song-actions-menu")
        if tap(app.buttons["Insert Section"], "Insert Section") {
            shot(app, "insert-section-menu")
            dismissMenu(app)
        }
        dismissMenu(app)

        tap(app.buttons["songActionsButton"], "song actions")
        if tap(app.buttons["Export"], "Export") {
            shot(app, "export-sheet")
            tap(app.buttons["Cancel"], "export Cancel")
        }
        shot(app, "editor-lyrics")

        tap(app.buttons["songActionsButton"], "song actions")
        if tap(app.buttons["Song Notebook"], "Song Notebook") {
            shot(app, "notebook-alternates-empty")
            let alternate = app.textFields["Keep a line for later"]
            if tap(alternate, "alternate field") {
                alternate.typeText("An echo in the night")
                tap(app.buttons["Keep alternate"], "Keep alternate")
                shot(app, "notebook-alternate-kept")
            }
            if tap(app.buttons["Draft History"], "Draft History") {
                shot(app, "notebook-history-empty")
                tap(app.buttons["Save version"], "Save version")
                shot(app, "notebook-history-version")
                tap(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Midnight notes")).firstMatch, "version disclosure")
                if tap(app.buttons["Restore this version"], "Restore this version", scrolling: app.collectionViews.firstMatch) {
                    shot(app, "notebook-restore-dialog")
                    let cancel = app.buttons["Cancel"]
                    if cancel.exists && cancel.isHittable { cancel.tap() } else { dismissMenu(app) }
                }
            }
            tap(app.buttons["Done"], "notebook Done")
        }

        tap(app.buttons["songActionsButton"], "song actions")
        if tap(app.buttons["Song Recordings"], "Song Recordings") {
            shot(app, "song-recordings-empty")
            tap(app.buttons["Done"], "recordings Done")
        }

        if tap(app.buttons["focusModeButton"], "Focus") {
            shot(app, "focus-mode")
            tap(app.buttons["focusModeButton"], "Exit Focus")
        }
        app.terminate()

        let analysed = launch([
            "--ui-test-seed-prosody-song", "--ui-test-enable-stress-preview",
            "-editor.isRhymeHighlightEnabled", "YES", "-editor.isBeatGridEnabled", "YES",
        ])
        if analysed.textViews["lyricsEditor"].waitForExistence(timeout: 5) {
            shot(analysed, "editor-rhyme-families")
        }
        analysed.terminate()
    }

    @MainActor
    private func drawerScene() {
        let app = launch(["--ui-test-seed-trash-song"])
        guard tap(app.buttons["Open songs drawer"], "Open songs drawer", timeout: 6) else {
            app.terminate()
            return
        }
        shot(app, "drawer-songs")
        let search = app.textFields.firstMatch
        if tap(search, "drawer search") {
            search.typeText("zzz")
            shot(app, "drawer-search-no-match")
            tap(app.buttons["Clear search"], "Clear search")
            // Return dismisses the keyboard, which otherwise covers the bottom row.
            search.typeText("\n")
        }
        if tap(app.buttons["Recordings"], "Recordings tab") {
            shot(app, "drawer-recordings-empty")
            tap(app.buttons["Songs"], "Songs tab")
        }
        if tap(app.buttons["Move UI Trash Song to Trash"], "Move to Trash") {
            shot(app, "drawer-undo-toast-songs-empty", settle: 0.4)
        }
        // The undo toast covers the drawer's bottom row until it dismisses itself.
        if tap(app.buttons["Open Trash Bin"], "Open Trash Bin", hittableWithin: 7) {
            shot(app, "trash-songs")
            if tap(app.buttons["UI Trash Song"], "trash row") {
                shot(app, "trash-selected")
                if tap(app.buttons["Delete"], "trash Delete") {
                    shot(app, "trash-delete-forever-alert")
                    tap(app.alerts.buttons["Cancel"], "alert Cancel")
                }
            }
            if tap(app.buttons["Recordings"], "trash Recordings tab") {
                shot(app, "trash-recordings-empty")
            }
            tap(app.buttons["Back to songs"], "Back to songs")
        }
        app.terminate()
    }

    @MainActor
    private func assistantScene() {
        let app = launch(["--ui-test-seed-prosody-song", "--ui-test-open-assistant", "--ui-test-enable-stress-preview"])
        guard app.staticTexts["Assistant"].waitForExistence(timeout: 6) else {
            note("MISSING Assistant")
            app.terminate()
            return
        }
        shot(app, "assistant-idle-local")
        // The disclosure remembers its state, so it is put back afterwards.
        let stress = app.buttons["targetLineStressDisclosure"]
        if stress.waitForExistence(timeout: 2), stress.label == "Show stress pattern", tap(stress, "Show stress pattern") {
            shot(app, "assistant-stress-expanded")
            tap(stress, "Hide stress pattern")
        }
        let scroll = app.scrollViews["assistantScrollView"]
        if tap(app.buttons["Expand rhyme options"], "Expand rhyme options", scrolling: scroll) {
            shot(app, "assistant-rhyme-options")
        }
        scroll.swipeUp()
        shot(app, "assistant-idle-scrolled")
        scroll.swipeDown()
        if tap(app.buttons["Context & Theme help"], "help button") {
            shot(app, "assistant-help-sheet")
            tap(app.buttons["Done"], "help Done")
        }
        app.terminate()

        // The theme field accepts input with Whole Song Context on (the default,
        // pinned here so a value saved on the simulator cannot change the scene).
        let typing = launch([
            "--ui-test-seed-prosody-song", "--ui-test-open-assistant",
            "-editor.useWholeSongContext", "YES",
        ])
        let themeView = typing.textViews["What is this song about?"]
        let theme = themeView.waitForExistence(timeout: 6)
            ? themeView
            : typing.textFields["What is this song about?"]
        if tap(theme, "theme field", timeout: 6) {
            XCTAssertTrue(theme.isEnabled, "Context & Theme must stay editable with Whole Song Context on")
            theme.typeText("Leaving town")
            // The placeholder no longer names the field once it holds text, so find it by value.
            let typed = typing.descendants(matching: .any)
                .matching(NSPredicate(format: "value == %@", "Leaving town")).firstMatch
            XCTAssertTrue(typed.waitForExistence(timeout: 3), "Typed theme did not appear in Context & Theme")
            shot(typing, "assistant-keyboard")
        } else {
            XCTFail("Context & Theme field was not reachable")
        }
        typing.terminate()
    }

    @MainActor
    private func cloudScene() {
        let gemini = ["-selectedProvider", "GEMINI", "-selectedModel", "gemini-3.5-flash",
                      "--ui-test-seed-prosody-song", "--ui-test-open-assistant"]

        let noKey = launch(gemini)
        if tap(noKey.buttons["Suggest Next Line"], "Suggest Next Line", timeout: 6, scrolling: noKey.scrollViews["assistantScrollView"]) {
            if noKey.alerts.firstMatch.waitForExistence(timeout: 5) {
                shot(noKey, "cloud-consent-alert")
                tap(noKey.alerts.buttons["Allow and Continue"], "Allow and Continue")
            }
            _ = noKey.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No API key set")).firstMatch.waitForExistence(timeout: 10)
            noKey.scrollViews["assistantScrollView"].swipeUp()
            shot(noKey, "assistant-no-key")
        }
        noKey.terminate()

        // An unroutable host keeps the request pending long enough to see
        // the loading state before stopping it.
        let loading = launch(gemini, environment: [
            "GEMINI_TEST_KEY": "ux-audit-key", "RHYMEAI_GEMINI_BASE_URL": "https://10.255.255.1/v1beta",
        ])
        if tap(loading.buttons["Suggest Next Line"], "Suggest Next Line", timeout: 6, scrolling: loading.scrollViews["assistantScrollView"]) {
            tap(loading.alerts.buttons["Allow and Continue"], "Allow and Continue")
            if loading.buttons["Stop"].waitForExistence(timeout: 5) {
                loading.scrollViews["assistantScrollView"].swipeUp()
                shot(loading, "assistant-loading")
                tap(loading.buttons["Stop"], "Stop")
                shot(loading, "assistant-stopped")
            } else {
                note("MISSING assistant loading state")
            }
        }
        loading.terminate()

        let offline = launch(gemini, environment: [
            "GEMINI_TEST_KEY": "ux-audit-key", "RHYMEAI_GEMINI_BASE_URL": "https://127.0.0.1:1/v1beta",
        ])
        if tap(offline.buttons["Suggest Next Line"], "Suggest Next Line", timeout: 6, scrolling: offline.scrollViews["assistantScrollView"]) {
            tap(offline.alerts.buttons["Allow and Continue"], "Allow and Continue")
            _ = offline.buttons["Retry"].waitForExistence(timeout: 15)
            offline.scrollViews["assistantScrollView"].swipeUp()
            shot(offline, "assistant-error")
        }
        offline.terminate()
    }

    @MainActor
    private func suggestionsScene() {
        let app = launch(["--ui-test-seed-suggestions", "--ui-test-enable-stress-preview"])
        guard app.textViews["lyricsEditor"].waitForExistence(timeout: 6) else {
            app.terminate()
            return
        }
        if !app.buttons["hideInlineAssistantButton"].exists {
            tap(app.buttons["unblockButton"], "UnBlock")
        }
        let useLine = app.buttons["useSuggestionButton"]
        for _ in 0..<6 where !(useLine.exists && useLine.isHittable) {
            app.scrollViews["assistantScrollView"].swipeUp()
        }
        shot(app, "suggestion-cards")
        if tap(app.buttons["keepSuggestionButton"], "Keep suggestion") {
            shot(app, "suggestion-kept")
        }
        if tap(useLine, "Use line") {
            shot(app, "line-added-feedback", settle: 0.4)
        }
        app.terminate()
    }

    @MainActor
    private func rewriteScene() {
        let app = launch(["--ui-test-seed-rewrite-selection", "--ui-test-force-rewrite-bar"])
        if app.buttons["Rephrase"].waitForExistence(timeout: 6) {
            shot(app, "rewrite-chip-bar")
            tap(app.buttons["Rephrase"], "Rephrase")
            _ = app.buttons["Retry"].waitForExistence(timeout: 8)
            shot(app, "rewrite-review-local-result")
        }
        app.terminate()

        let loading = launch(["--ui-test-seed-prosody-song", "--ui-test-seed-rewrite-loading"])
        if loading.descendants(matching: .any)["inlineRewriteReviewBar"].waitForExistence(timeout: 6) {
            shot(loading, "rewrite-loading")
        }
        loading.terminate()

        let inspector = launch()
        if tap(inspector.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch, "New Song") {
            let editor = inspector.textViews["lyricsEditor"]
            if tap(editor, "lyrics editor") {
                editor.typeText("night")
                editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: 14)).doubleTap()
                if inspector.buttons["Look up word"].waitForExistence(timeout: 4) {
                    shot(inspector, "rewrite-chip-bar-keyboard")
                    tap(inspector.buttons["Look up word"], "Look up word")
                    _ = inspector.staticTexts["Word inspector"].waitForExistence(timeout: 5)
                    // The rhyme dictionary loads off the main thread; the
                    // result chips are the point of this capture.
                    if !inspector.buttons["light"].waitForExistence(timeout: 20) {
                        note("MISSING inspector rhyme chips")
                    }
                    shot(inspector, "word-inspector", settle: 2)
                } else {
                    note("MISSING Look up word (\(variant))")
                }
            }
        }
        inspector.terminate()
    }

    @MainActor
    private func recordingScene() {
        let app = launch(["--ui-test-seed-prosody-song", "--ui-test-fake-voice-recording"])
        if tap(app.buttons["micButton"], "mic", timeout: 6) {
            _ = app.buttons["Stop recording"].waitForExistence(timeout: 3)
            shot(app, "recording-active", settle: 1.2)
            tap(app.buttons["Stop recording"], "Stop recording")
            shot(app, "recording-stopped")
        }
        tap(app.buttons["songActionsButton"], "song actions")
        if tap(app.buttons["Song Recordings"], "Song Recordings") {
            shot(app, "song-recordings")
            tap(app.buttons["Done"], "recordings Done")
        }
        if tap(app.buttons["Open songs drawer"], "Open songs drawer") {
            tap(app.buttons["Recordings"], "Recordings tab")
            shot(app, "drawer-recordings")
        }
        app.terminate()
    }

    @MainActor
    private func settingsScene() {
        let app = launch(["--ui-test-seed-prosody-song"])
        guard tap(app.buttons["settingsButton"], "Settings", timeout: 6),
              app.navigationBars["Settings"].waitForExistence(timeout: 5) else {
            app.terminate()
            return
        }
        // On iPad the editor and assistant scroll views sit behind the sheet;
        // the sheet's own scroll view is the last one in the hierarchy.
        var scroll = app.scrollViews.element(boundBy: max(app.scrollViews.count - 1, 0))
        captureScrolling(app, in: scroll, name: "settings-general-local", pages: 4)
        if tap(app.buttons["cloudBackupDisclosure"], "Cloud backup disclosure", scrolling: scroll) {
            shot(app, "settings-cloud-backup")
            scroll.swipeUp()
            shot(app, "settings-cloud-backup-scrolled")
        }
        // Reopen rather than swipe back to the top: a swipe down at the top
        // of the sheet dismisses it.
        tap(app.buttons["Done"], "settings Done")
        guard tap(app.buttons["settingsButton"], "Settings (reopen)", timeout: 6),
              app.navigationBars["Settings"].waitForExistence(timeout: 5) else {
            app.terminate()
            return
        }
        scroll = app.scrollViews.element(boundBy: max(app.scrollViews.count - 1, 0))
        for provider in ["Gemini", "OpenAI", "Claude"] {
            let segment = app.buttons[provider]
            if tap(segment, "provider \(provider)", scrolling: scroll) {
                shot(app, "settings-provider-\(provider.lowercased())")
                if provider == "Gemini" {
                    scroll.swipeUp()
                    shot(app, "settings-provider-gemini-scrolled")
                    scroll.swipeDown()
                }
            }
        }
        // A typed key is the one setting that waits for Save. The audit
        // discards it so no key reaches the simulator's Keychain.
        let keyField = app.secureTextFields["API Key"]
        if tap(keyField, "API key field", scrolling: scroll) {
            keyField.typeText("ux-audit-placeholder")
            shot(app, "settings-unsaved-key")
            tap(app.buttons["Done"], "settings Done (unsaved key)")
            if app.buttons["Discard Changes"].waitForExistence(timeout: 3) {
                shot(app, "settings-unsaved-key-dialog")
                tap(app.buttons["Discard Changes"], "Discard Changes")
            } else {
                note("MISSING unsaved key dialog")
            }
            guard tap(app.buttons["settingsButton"], "Settings (after discard)", timeout: 6),
                  app.navigationBars["Settings"].waitForExistence(timeout: 5) else {
                app.terminate()
                return
            }
        }
        if tap(app.buttons["Editor"], "Editor tab") {
            shot(app, "settings-editor")
            if tap(app.buttons["Whole Song Context help"], "editor help") {
                shot(app, "settings-help-sheet")
                tap(app.navigationBars["Whole Song Context"].buttons["Done"], "help Done")
            }
        }
        if tap(app.buttons["saveSettingsButton"], "Save Settings") {
            shot(app, "settings-saved", settle: 0.3)
        }
        app.terminate()
    }

    @MainActor
    private func statesScene() {
        let failed = launch(["--ui-test-seed-prosody-song", "--ui-test-force-save-failed"])
        if failed.textViews["lyricsEditor"].waitForExistence(timeout: 6) {
            shot(failed, "save-failed")
        }
        failed.terminate()
    }

    // MARK: - Helpers

    private var variant: String { "\(appearance)__\(size)__\(orientationName)" }

    private var isRunningOnIPad: Bool {
        let simulatorName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        return UIDevice.current.userInterfaceIdiom == .pad || simulatorName.localizedCaseInsensitiveContains("iPad")
    }

    private func filter(_ raw: String?, default all: [String]) -> [String] {
        guard let raw, !raw.isEmpty else { return all }
        let wanted = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return all.filter(wanted.contains)
    }

    @MainActor
    private func launch(_ arguments: [String] = [], environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        var launchArguments = ["--ui-test-in-memory-store", "-appAppearanceStyle", appearance] + arguments
        if size == "ax3" {
            launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
        }
        app.launchArguments = launchArguments
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        app.launch()
        return app
    }

    private func note(_ message: String) {
        notes.append("[\(variant)] \(message)")
    }

    @MainActor
    @discardableResult
    private func tap(
        _ element: XCUIElement,
        _ what: String,
        timeout: TimeInterval = 4,
        hittableWithin: TimeInterval = 0,
        scrolling scrollView: XCUIElement? = nil
    ) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            note("MISSING \(what)")
            return false
        }
        if let scrollView, scrollView.exists {
            // A third of the visible height per step: a full swipe can carry
            // a control straight past the visible part of a short sheet.
            for _ in 0..<16 where !element.isHittable {
                let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                start.press(
                    forDuration: 0.05,
                    thenDragTo: start.withOffset(CGVector(dx: 0, dy: -scrollView.frame.height / 3))
                )
            }
        }
        let deadline = Date().addingTimeInterval(hittableWithin)
        while !element.isHittable, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard element.isHittable else {
            note("NOT HITTABLE \(what)")
            return false
        }
        element.tap()
        return true
    }

    @MainActor
    private func dismissMenu(_ app: XCUIApplication) {
        let frame = app.windows.firstMatch.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width * 0.3, dy: frame.height * 0.75))
            .tap()
        Thread.sleep(forTimeInterval: 0.5)
    }

    @MainActor
    private func captureScrolling(_ app: XCUIApplication, in scroll: XCUIElement, name: String, pages: Int) {
        shot(app, "\(name)-1")
        guard pages > 1 else { return }
        for page in 2...pages {
            scroll.swipeUp()
            shot(app, "\(name)-\(page)")
        }
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String, settle: TimeInterval = 0.7) {
        Thread.sleep(forTimeInterval: settle)
        shotIndex += 1
        // The app-cropped screenshot uses portrait coordinates and cuts a
        // landscape window in half, so landscape captures the whole screen.
        let screenshot = orientationName == "landscape" ? XCUIScreen.main.screenshot() : app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = String(format: "%@__%02d-%@", variant, shotIndex, name)
        attachment.lifetime = .keepAlways
        add(attachment)
        if appearance == "ink" || size == "ax3" {
            auditControls(app, screen: name)
        }
    }

    private func attach(text: String, name: String) {
        let attachment = XCTAttachment(string: text.isEmpty ? "(none)" : text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Records buttons whose label is empty or reads like an SF Symbol name,
    /// and visible buttons smaller than the 44pt touch target.
    @MainActor
    private func auditControls(_ app: XCUIApplication, screen: String) {
        guard let snapshot = try? app.snapshot() else { return }
        let window = app.windows.firstMatch.frame
        func visit(_ element: XCUIElementSnapshot) {
            if element.elementType == .button || element.elementType == .switch {
                let label = element.label
                let frame = element.frame
                let onScreen = frame.width > 0 && frame.height > 0 && window.contains(CGPoint(x: frame.midX, y: frame.midY))
                var problems: [String] = []
                if label.trimmingCharacters(in: .whitespaces).isEmpty {
                    problems.append("no label")
                } else if label.range(of: #"^[a-z0-9]+([._][a-z0-9]+)+$"#, options: .regularExpression) != nil {
                    problems.append("symbol-name label")
                }
                if onScreen, min(frame.width, frame.height) < 43.5 {
                    problems.append(String(format: "small %.0fx%.0f", frame.width, frame.height))
                }
                if label.isEmpty { problems.append(String(format: "at %.0f,%.0f %.0fx%.0f", frame.minX, frame.minY, frame.width, frame.height)) }
                if onScreen, !problems.isEmpty {
                    let key = "\(size)|\(label)|\(element.identifier)|\(problems.joined(separator: ","))"
                    if seenControlFindings.insert(key).inserted {
                        controlFindings.append("[\(variant)] \(screen): '\(label)' id='\(element.identifier)' — \(problems.joined(separator: ", "))")
                    }
                }
            }
            element.children.forEach(visit)
        }
        visit(snapshot)
    }
}
