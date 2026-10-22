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

    /// The clipped-element passes track elements by identity, not by label:
    /// two same-labelled controls in one scroll view each get their own pass.
    /// The real screens have no clipped duplicates, so this queues the
    /// stanza preview's repeated "A" scheme letters by hand.
    @MainActor
    func testSameLabelledClippedElementsEachGetTheirOwnPass() throws {
        let app = launch(["--ui-test-seed-prosody-song"])
        XCTAssertTrue(app.buttons["hideInlineAssistantButton"].waitForExistence(timeout: 8))
        app.buttons["Expand rhyme options"].tap()
        let scrollView = app.scrollViews["assistantScrollView"]
        let letters = scrollView.staticTexts.matching(NSPredicate(format: "label == %@", "A")).allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(letters.count, 2, "The seeded stanza should show two 'A' letters")
        let run = AuditRun(app: app, dimmedBackgroundText: 0)
        var identities: [String] = []
        for letter in letters.prefix(2) {
            let identity = try XCTUnwrap(Self.identity(of: letter, in: scrollView))
            identities.append(identity)
            run.enqueue(ClippedElement(element: letter, scrollView: scrollView, identity: identity))
        }
        XCTAssertEqual(run.pending.count, 2, "Same-labelled elements collapsed into one identity: \(identities)")
        // The passes may queue other clipped elements (such as "Local model
        // setup" at the pinned bar); those get passes of their own too.
        run.runPendingPasses(scroll: scrollFullyIntoView)
        XCTAssertTrue(run.audited.isSuperset(of: identities), "Each letter should complete its own pass: \(run.report)")
        for identity in identities {
            XCTAssertEqual(run.report.filter { $0.hasPrefix("-- contrast pass for \(identity),") }.count, 1, identity)
        }
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
        // Audit the list, not the empty state the screen shows until the
        // trashed song arrives.
        XCTAssertTrue(app.staticTexts["UI Trash Song"].waitForExistence(timeout: 5))
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
        // The drawer is still sliding in when its close button turns hittable;
        // a tap aimed at a row's trash button then lands on the row and opens
        // the song instead.
        Thread.sleep(forTimeInterval: 0.6)
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

        let run = AuditRun(app: app, dimmedBackgroundText: dimmedBackgroundText)
        do {
            try run.audit(.all, target: nil)
        } catch {
            XCTFail("Accessibility audit of \(surface) failed to run: \(error)")
        }
        run.runPendingPasses(scroll: scrollFullyIntoView)
        let attachment = XCTAttachment(string: run.report.isEmpty ? "(no issues)" : run.report.joined(separator: "\n"))
        attachment.name = "audit-\(surface)-issues"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct ClippedElement {
        let element: XCUIElement
        let scrollView: XCUIElement
        let identity: String
    }

    /// One audit of a screen. An element cut by the edge of its own scroll
    /// view (such as a button half under the assistant's pinned bar) makes the
    /// audit sample the view covering it, so it is queued and later gets a
    /// contrast pass of its own, scrolled fully into view, where it has no
    /// offscreen exemption. Every issue in every pass goes through `judge`.
    @MainActor
    private final class AuditRun {
        let app: XCUIApplication
        let dimmedBackgroundText: Int
        var backgroundTextLeft: Int
        var report: [String] = []
        private(set) var pending: [ClippedElement] = []
        private var queued: Set<String> = []
        private(set) var audited: Set<String> = []

        init(app: XCUIApplication, dimmedBackgroundText: Int) {
            self.app = app
            self.dimmedBackgroundText = dimmedBackgroundText
            backgroundTextLeft = dimmedBackgroundText
        }

        func enqueue(_ clipped: ClippedElement) {
            if queued.insert(clipped.identity).inserted { pending.append(clipped) }
        }

        func audit(_ types: XCUIAccessibilityAuditType, target: ClippedElement?) throws {
            try app.performAccessibilityAudit(for: types) { issue in
                let reason = self.judge(issue, target: target)
                self.report.append((reason.map { "FILTERED (\($0)) " } ?? "ISSUE ") + AccessibilityAuditUITests.describe(issue))
                return reason != nil
            }
        }

        /// The same rules for every pass; `target` is the element the pass
        /// was scrolled for.
        private func judge(_ issue: XCUIAccessibilityAuditIssue, target: ClippedElement?) -> String? {
            if let target, let element = issue.element,
               AccessibilityAuditUITests.identity(of: element, in: target.scrollView) == target.identity {
                return AccessibilityAuditUITests.knownNoiseReason(issue, in: app, allowNotHittable: false)
            }
            var reason = AccessibilityAuditUITests.knownNoiseReason(issue, in: app)
            if reason == nil, issue.element == nil, issue.auditType == .elementDetection, backgroundTextLeft > 0 {
                backgroundTextLeft -= 1
                reason = "text of the dimmed screen behind the modal sheet (\(dimmedBackgroundText) expected)"
            }
            if reason == nil, issue.auditType == .contrast, let element = issue.element,
               let clipped = AccessibilityAuditUITests.clipped(element, in: app) {
                if audited.contains(clipped.identity) {
                    reason = "cut by the edge of its scroll view; already passed its own pass fully in view"
                } else {
                    enqueue(clipped)
                    reason = "cut by the edge of its scroll view; audited in its own pass once scrolled fully into view"
                }
            }
            return reason
        }

        /// Gives each queued element its own contrast pass. An element counts
        /// as audited only once it was fully in view and its pass completed;
        /// otherwise it stays queued and is tried again, and after eight
        /// attempts anything still queued fails the test.
        func runPendingPasses(scroll: (ClippedElement) -> Void) {
            for _ in 0..<8 {
                guard let target = pending.first else { break }
                scroll(target)
                guard target.scrollView.frame.contains(target.element.frame) else {
                    report.append("-- could not scroll \(target.identity) fully into view")
                    continue
                }
                report.append("-- contrast pass for \(target.identity), scrolled fully into view")
                do {
                    try audit(.contrast, target: target)
                } catch {
                    report.append("-- contrast pass for \(target.identity) failed to run: \(error)")
                    continue
                }
                pending.removeFirst()
                audited.insert(target.identity)
            }
            XCTAssertTrue(pending.isEmpty, "Clipped elements left unaudited: \(pending.map(\.identity))")
        }
    }

    /// Identifies an element within one scroll view across scrolling and
    /// among same-labelled siblings: the scroll view (identifier, else its
    /// frame, which does not move as it scrolls), the element type, the
    /// identifier when present (else the label), and the element's index
    /// among the scroll view's descendants that share them.
    @MainActor
    private static func identity(of element: XCUIElement, in scrollView: XCUIElement) -> String? {
        let label = element.label, identifier = element.identifier, frame = element.frame
        let predicate = identifier.isEmpty
            ? NSPredicate(format: "label == %@", label)
            : NSPredicate(format: "identifier == %@", identifier)
        let siblings = scrollView.descendants(matching: element.elementType).matching(predicate).allElementsBoundByIndex
        guard let index = siblings.firstIndex(where: { $0.frame == frame }) else { return nil }
        let container = scrollView.identifier.isEmpty ? "scroll\(NSCoder.string(for: scrollView.frame))" : scrollView.identifier
        let name = identifier.isEmpty ? "'\(label)'" : "#\(identifier)"
        return "\(container)/\(element.elementType.rawValue)/\(name)/\(index)"
    }

    /// Drags the element's scroll view slowly (no momentum) until the element
    /// sits fully inside it.
    @MainActor
    private func scrollFullyIntoView(_ target: ClippedElement) {
        let element = target.element, scrollView = target.scrollView
        for _ in 0..<4 where !scrollView.frame.contains(element.frame) {
            let frame = element.frame, visible = scrollView.frame
            let dy = frame.maxY > visible.maxY ? -(frame.maxY - visible.maxY + 24) : visible.minY - frame.minY + 24
            let start = scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: dy)), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    /// The element and the scroll view that contains it and cuts it at an
    /// edge: the element is one of its descendants and only partly inside its
    /// frame.
    @MainActor
    private static func clipped(_ element: XCUIElement, in app: XCUIApplication) -> ClippedElement? {
        let frame = element.frame
        guard !element.label.isEmpty || !element.identifier.isEmpty else { return nil }
        for scrollView in app.scrollViews.allElementsBoundByIndex
        where scrollView.frame.intersects(frame) && !scrollView.frame.contains(frame) {
            if let identity = identity(of: element, in: scrollView) {
                return ClippedElement(element: element, scrollView: scrollView, identity: identity)
            }
        }
        return nil
    }

    private static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        "\(name(of: issue.auditType)) | \(issue.compactDescription) | \(issue.element == nil ? issue.detailedDescription + " | " : "")"
            + "\(issue.element?.elementType.rawValue ?? 0) '\(issue.element?.label ?? "")' "
            + "id='\(issue.element?.identifier ?? "")' \(issue.element.map { NSCoder.string(for: $0.frame) } ?? "")"
    }

    /// Rows that swap a one-line layout for a stacked one with ViewThatFits as
    /// text grows. The audit enlarges the text in place and reports the row it
    /// replaced as not scaling or clipped.
    private static let viewThatFitsLabels: Set<String> = ["Use line", "Keep for later", "Kept", "·", "words"]

    /// Issues the audit reports that are not defects in this app's views.
    /// Each entry states why it is filtered.
    @MainActor
    private static func knownNoiseReason(
        _ issue: XCUIAccessibilityAuditIssue,
        in app: XCUIApplication,
        allowNotHittable: Bool = true
    ) -> String? {
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
        case .contrast where allowNotHittable && !element.isHittable:
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
