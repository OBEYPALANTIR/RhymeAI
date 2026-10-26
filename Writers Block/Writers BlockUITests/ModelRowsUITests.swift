import XCTest

/// Settings › On-Device model rows: every state at one height, in Ink and Graphite, with
/// screenshots of each, and an accessibility audit of the section.
final class ModelRowsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// `ModelRowContent.gallery` order; the row labels the screenshots are checked against.
    private static let galleryCount = 16
    static let inUseMessage = "Frees 3.43 GB on this device. You can download it again later. It's in use now; on-device suggestions stop until you choose another model."

    @MainActor
    func testEveryRowStateKeepsOneHeightInInkAndGraphite() throws {
        for style in ["ink", "graphite"] {
            let app = launch(style: style, extra: ["--ui-test-seed-installed-gguf-model", "--ui-test-model-row-gallery"])
            openLocalModels(app)
            var heights: [String: CGFloat] = [:]
            var shot = 0
            let last = app.buttons["modelRowGallery.\(Self.galleryCount - 1)"]
            XCTAssertTrue(app.buttons["gemmaDownload.gemma-4-e2b"].waitForExistence(timeout: 5))
            attach(app, "\(style)-\(device)-\(shot)")
            for _ in 0..<14 {
                for id in ["gemmaDownload.gemma-4-e2b", "gemmaDownload.gemma-4-e4b"] + (0..<Self.galleryCount).map({ "modelRowGallery.\($0)" }) {
                    let row = app.buttons[id]
                    if row.exists, row.isHittable { heights[id] = row.frame.height }
                }
                if last.exists, last.isHittable { break }
                app.scrollViews.firstMatch.swipeUp(velocity: .slow)
                shot += 1
                attach(app, "\(style)-\(device)-\(shot)")
            }
            XCTAssertEqual(heights.count, Self.galleryCount + 2, "every row was measured")
            // The row button plus its 55pt column. The spec holds 89 from a 332pt row up (the
            // narrowest designed width, the 380pt iPad column); below that the text gives way
            // to the chip, so a long title or warning beside Download wraps and the row grows.
            let rowWidth = app.buttons["gemmaDownload.gemma-4-e2b"].frame.width + 55
            for (id, height) in heights {
                // Gallery 11, the downloaded unselected E4B under 10 GB, has three metadata lines
                // in the spec's copy and grows below a 407pt row (see ModelRowTests).
                if rowWidth >= 332, id != "modelRowGallery.11" || rowWidth >= 407 {
                    XCTAssertEqual(height, 89, accuracy: 0.5, "\(id) in \(style) at \(rowWidth)pt")
                } else {
                    XCTAssertGreaterThanOrEqual(height, 88.5, "\(id) in \(style) at \(rowWidth)pt")
                }
            }
            let measured = XCTAttachment(string: "row width \(rowWidth)\n" + heights.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "\n"))
            measured.name = "\(style)-\(device)-heights"
            measured.lifetime = .keepAlways
            add(measured)
            app.terminate()
        }
    }

    /// The real flow on a seeded install: the selected row reads In use, its trash is a
    /// separate 55pt target, and the confirmation carries the in-use sentence.
    @MainActor
    func testSelectedRowOffersDeleteWithTheInUseSentence() throws {
        let app = launch(style: "ink", extra: ["--ui-test-seed-installed-gguf-model"])
        openLocalModels(app)
        let row = app.buttons["gemmaDownload.gemma-4-e2b"]
        let delete = app.buttons["gemmaDelete.gemma-4-e2b"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        scrollTo(delete, in: app)
        XCTAssertTrue(row.isSelected)
        XCTAssertEqual(row.label, "RhymeAI Gemma 4 E2B")
        XCTAssertEqual(row.value as? String, "In use, 3.43 GB on this device")
        XCTAssertEqual(delete.frame.width, 55, accuracy: 0.5)
        XCTAssertEqual(delete.frame.height, 89, accuracy: 0.5)
        XCTAssertFalse(app.staticTexts["gemmaEmptyNudge"].exists)
        let e4b = app.buttons["gemmaDownload.gemma-4-e4b"]
        XCTAssertTrue(e4b.label.hasPrefix("Download "))
        XCTAssertFalse(app.buttons["gemmaDelete.gemma-4-e4b"].exists)

        delete.tap()
        let alert = app.alerts["Delete RhymeAI Gemma 4 E2B?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label == %@", Self.inUseMessage)).firstMatch.exists)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(row.isSelected)
    }

    @MainActor
    func testModelSectionPassesTheAccessibilityAudit() throws {
        let app = launch(style: "ink", extra: ["--ui-test-seed-installed-gguf-model", "--ui-test-model-row-gallery"])
        openLocalModels(app)
        let row = app.buttons["gemmaDownload.gemma-4-e2b"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        scrollTo(row, in: app)
        // The audit covers the whole sheet; only issues on the model rows (row button plus its
        // 55pt column) or with no element count. Controls elsewhere in Settings are outside
        // this change and the existing AccessibilityAuditUITests baselines.
        var issues: [String] = []
        var rows: [CGRect] = []
        var unattributed: [String] = []
        let record: (XCUIAccessibilityAuditIssue) -> Bool = { issue in
            // A modal sheet yields text detections with no element or frame (measured per
            // layout in AccessibilityAuditUITests); they cannot be tied to the rows, so they
            // are listed in an attachment rather than failed here.
            if issue.element == nil, issue.auditType == .elementDetection {
                unattributed.append(issue.compactDescription)
                return true
            }
            if let frame = issue.element?.frame, !rows.contains(where: { $0.intersects(frame) }) { return true }
            // The pinned Save Settings bar overlaps rows scrolled under it; it is disabled, and
            // inactive components are exempt from text contrast.
            if issue.auditType == .contrast, issue.element?.isEnabled == false { return true }
            // The pinned General/Editor switch hands the audit a system segmented control whose
            // segment frames are taller than the drawn segments and reach over the rows below.
            if issue.auditType == .contrast, let label = issue.element?.label, app.segmentedControls.buttons[label].exists { return true }
            issues.append("\(issue.auditType.rawValue) | \(issue.compactDescription) | '\(issue.element?.label ?? "")' id='\(issue.element?.identifier ?? "")' \(issue.element.map { NSCoder.string(for: $0.frame) } ?? "")")
            return true
        }
        let rowQuery = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'gemmaDownload.' OR identifier BEGINSWITH 'modelRowGallery.' OR identifier BEGINSWITH 'customGGUF.'"))
        // Only what is on screen: between the pinned General/Editor switch and the Save bar.
        let top = app.descendants(matching: .any)["settingsTabPicker"].frame.maxY
        let bottom = app.buttons["saveSettingsButton"].frame.minY
        func measureRows() {
            rows = rowQuery.allElementsBoundByIndex.compactMap { row in
                var frame = row.frame
                frame.size.width += 55
                let visible = frame.insetBy(dx: 1, dy: 1).intersection(CGRect(x: frame.minX, y: top, width: frame.width, height: bottom - top))
                return visible.isNull || visible.isEmpty ? nil : visible
            }
        }
        measureRows()
        XCTAssertGreaterThan(rows.count, 2)
        try app.performAccessibilityAudit(for: .all, record)
        let last = app.buttons["modelRowGallery.\(Self.galleryCount - 1)"]
        scrollTo(last, in: app)
        measureRows()
        try app.performAccessibilityAudit(for: .all, record)
        let note = XCTAttachment(string: "unattributed detections: \(unattributed.count)\n" + unattributed.joined(separator: "\n"))
        note.name = "audit-\(device)-unattributed"
        note.lifetime = .keepAlways
        add(note)
        XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n"))
    }

    // MARK: Helpers

    private var device: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    }

    @MainActor
    private func launch(style: String, extra: [String]) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-in-memory-store", "--ui-test-seed-prosody-song", "-appAppearanceStyle", style] + extra
        app.launch()
        return app
    }

    @MainActor
    private func openLocalModels(_ app: XCUIApplication) {
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        let local = app.buttons["Local"]
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        local.tap()
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<20 where !element.isHittable {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
