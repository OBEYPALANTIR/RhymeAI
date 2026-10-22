import XCTest

/// Runs Xcode's accessibility audit over the iPad surfaces: the editor with
/// the inline assistant, the songs drawer, Trash, both Settings tabs, the
/// suggestion cards and the Word Inspector. Every reported issue fails the
/// test unless `isKnownNoise` names it with a reason.
final class AccessibilityAuditUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
        let simulatorName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad || simulatorName.localizedCaseInsensitiveContains("iPad"),
            "iPad-only accessibility audit"
        )
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testEditorWithInlineAssistantPassesAudit() throws {
        let app = launch(["--ui-test-seed-prosody-song"])
        XCTAssertTrue(app.buttons["hideInlineAssistantButton"].waitForExistence(timeout: 8))
        // Expanded, so the Rhyme Scheme, Rhyme Density and Complexity rows are audited too.
        let expand = app.buttons["Expand rhyme options"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5))
        expand.tap()
        XCTAssertTrue(app.buttons["Collapse rhyme options"].waitForExistence(timeout: 5))
        audit(app, "editor-inline-assistant")
    }

    @MainActor
    func testSongsDrawerPassesAudit() throws {
        let app = launch(["--ui-test-seed-trash-song"])
        openDrawer(app)
        audit(app, "songs-drawer")
    }

    @MainActor
    func testTrashScreenPassesAudit() throws {
        let app = launch(["--ui-test-seed-trash-song"])
        openDrawer(app)
        app.buttons["Move UI Trash Song to Trash"].tap()
        let openTrash = app.buttons["Open Trash Bin"]
        // Trashing the open song can close the drawer; reopen it if so.
        if !openTrash.waitForExistence(timeout: 3) {
            openDrawer(app)
        }
        XCTAssertTrue(waitUntilHittable(openTrash, timeout: 8))
        openTrash.tap()
        XCTAssertTrue(app.buttons["Back to songs"].waitForExistence(timeout: 5))
        audit(app, "trash")
    }

    @MainActor
    func testSettingsGeneralTabPassesAudit() throws {
        let app = launch(["--ui-test-seed-prosody-song"])
        openSettings(app)
        audit(app, "settings-general", dimmedBackgroundText: 2)
    }

    @MainActor
    func testSettingsEditorTabPassesAudit() throws {
        let app = launch(["--ui-test-seed-prosody-song"])
        openSettings(app)
        app.buttons["Editor"].tap()
        audit(app, "settings-editor", dimmedBackgroundText: 2)
    }

    @MainActor
    func testSuggestionCardsPassAudit() throws {
        let app = launch(["--ui-test-seed-suggestions"])
        XCTAssertTrue(app.textViews["lyricsEditor"].waitForExistence(timeout: 8))
        if !app.buttons["hideInlineAssistantButton"].exists {
            app.buttons["unblockButton"].tap()
        }
        let useLine = app.buttons["useSuggestionButton"].firstMatch
        XCTAssertTrue(useLine.waitForExistence(timeout: 8))
        for _ in 0..<6 where !useLine.isHittable {
            app.scrollViews["assistantScrollView"].swipeUp()
        }
        audit(app, "suggestion-cards")
    }

    @MainActor
    func testWordInspectorPassesAudit() throws {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New Song")).firstMatch.tap()
        let editor = app.textViews["lyricsEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("night")
        editor.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 24, dy: 14)).doubleTap()
        let lookUp = app.buttons["Look up word"]
        XCTAssertTrue(lookUp.waitForExistence(timeout: 5))
        lookUp.tap()
        XCTAssertTrue(app.staticTexts["Word inspector"].waitForExistence(timeout: 5))
        // The rhyme chips load off the main thread; audit the finished sheet.
        XCTAssertTrue(app.buttons["light"].waitForExistence(timeout: 20))
        audit(app, "word-inspector", dimmedBackgroundText: 6)
    }

    // MARK: - Helpers

    @MainActor
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store"] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func openDrawer(_ app: XCUIApplication) {
        let open = app.buttons["Open songs drawer"]
        XCTAssertTrue(open.waitForExistence(timeout: 8))
        open.tap()
        XCTAssertTrue(waitUntilHittable(app.buttons["Close drawer"], timeout: 5))
    }

    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    @MainActor
    /// `dimmedBackgroundText` is how many unlabelled text detections the
    /// dimmed screen behind a modal sheet produces on this surface, measured
    /// from runs (the audit gives those issues no element or frame). Only that
    /// many are filtered; one more, such as new unlabelled text inside the
    /// sheet, fails the test.
    private func audit(_ app: XCUIApplication, _ surface: String, dimmedBackgroundText: Int = 0) {
        // Let presentation animations settle so frames are final.
        Thread.sleep(forTimeInterval: 1)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "audit-\(surface)"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        var report: [String] = []
        var backgroundTextLeft = dimmedBackgroundText
        do {
            try app.performAccessibilityAudit { issue in
                let line = "\(Self.name(of: issue.auditType)) | \(issue.compactDescription) | \(issue.element == nil ? issue.detailedDescription + " | " : "")"
                    + "\(issue.element?.elementType.rawValue ?? 0) '\(issue.element?.label ?? "")' "
                    + "id='\(issue.element?.identifier ?? "")' \(issue.element.map { NSCoder.string(for: $0.frame) } ?? "")"
                var reason = Self.knownNoiseReason(issue, in: app)
                if reason == nil, issue.element == nil, issue.auditType == .elementDetection, backgroundTextLeft > 0 {
                    backgroundTextLeft -= 1
                    reason = "text of the dimmed screen behind the modal sheet (\(dimmedBackgroundText) expected)"
                }
                report.append((reason.map { "FILTERED (\($0)) " } ?? "ISSUE ") + line)
                return reason != nil
            }
        } catch {
            XCTFail("Accessibility audit of \(surface) failed to run: \(error)")
        }
        let attachment = XCTAttachment(string: report.isEmpty ? "(no issues)" : report.joined(separator: "\n"))
        attachment.name = "audit-\(surface)-issues"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Rows that swap a one-line layout for a stacked one with ViewThatFits as
    /// text grows. The audit enlarges the text in place and reports the row it
    /// replaced as not scaling or clipped.
    private static let viewThatFitsLabels: Set<String> = ["Use line", "Keep for later", "Kept", "·", "words"]

    /// Issues the audit reports that are not defects in this app's views.
    /// Each entry states why it is filtered.
    @MainActor
    private static func knownNoiseReason(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication) -> String? {
        guard let element = issue.element else { return nil }
        let label = element.label
        // XCUITest on this OS still lists SwiftUI elements marked
        // accessibilityHidden (the Trash header's hidden grid glyph shows up
        // too), so the audit reports two hidden views: the full-height canvas
        // texture behind each column and the drawer row's "·" separator.
        let fullHeight = element.frame.height >= app.windows.firstMatch.frame.height
        if issue.auditType == .sufficientElementDescription, element.elementType == .other, label.isEmpty, fullHeight {
            return "hidden canvas background (AppWritingBackground)"
        }
        if label == "·" {
            return "hidden separator glyph"
        }
        switch issue.auditType {
        case .contrast where !element.isEnabled:
            return "disabled control; inactive components are exempt from text contrast"
        case .contrast where app.segmentedControls.buttons[label].exists:
            // The custom control hands assistive technology a system segmented
            // control; its segment frames are taller than the drawn 44pt
            // segments, so the audit samples two surface colours. The drawn
            // label is primary ink on the raised surface.
            return "segment of the represented system segmented control; frame does not match the drawn segment"
        case .contrast where !element.isHittable:
            return "covered by another view or scrolled out of sight; the audit samples the wrong pixels"
        case .textClipped where element.elementType == .textField:
            return "single-line text field; its text scrolls, nothing is cut off"
        case .dynamicType where app.navigationBars.buttons[label].exists:
            return "system navigation bar item; it uses the Large Content Viewer instead of growing"
        case .dynamicType, .textClipped:
            let words = label.split(separator: " ").last.map(String.init) ?? label
            if viewThatFitsLabels.contains(label) || viewThatFitsLabels.contains(words) || label.range(of: #"^[A-Z][a-z]+ \d{1,2}, \d{4}$"#, options: .regularExpression) != nil {
                return "ViewThatFits row; the stacked layout replaces it at larger sizes"
            }
            return nil
        default:
            return nil
        }
    }

    private static func name(of type: XCUIAccessibilityAuditType) -> String {
        switch type {
        case .contrast: "contrast"
        case .elementDetection: "elementDetection"
        case .hitRegion: "hitRegion"
        case .sufficientElementDescription: "sufficientElementDescription"
        case .dynamicType: "dynamicType"
        case .textClipped: "textClipped"
        case .trait: "trait"
        default: "other(\(type.rawValue))"
        }
    }
}
