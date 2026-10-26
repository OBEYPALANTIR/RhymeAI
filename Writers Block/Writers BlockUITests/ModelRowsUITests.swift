import XCTest

/// Settings › On-Device model rows: every state at one height, in Ink and Graphite, with
/// screenshots of each, and an accessibility audit of the section.
final class ModelRowsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// `ModelRowContent.gallery` order; the row labels the screenshots are checked against.
    private static let galleryCount = 15
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
                if rowWidth >= 332 {
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
        var issues: [String] = []
        let pinnedBottom = app.descendants(matching: .any)["settingsTabPicker"].frame.maxY
        let record: (XCUIAccessibilityAuditIssue) -> Bool = { issue in
            // Controls above the rows (the On-Device Engine picker) sit half under the pinned
            // General/Editor switch once the rows are scrolled into view, so they read as clipped.
            if issue.auditType == .textClipped, let frame = issue.element?.frame, frame.minY < pinnedBottom { return true }
            // Done is a system navigation bar item; it uses the Large Content Viewer instead of growing.
            if issue.auditType == .dynamicType, let label = issue.element?.label, app.navigationBars.buttons[label].exists { return true }
            issues.append("\(issue.auditType.rawValue) | \(issue.compactDescription) | '\(issue.element?.label ?? "")' id='\(issue.element?.identifier ?? "")' \(issue.element.map { NSCoder.string(for: $0.frame) } ?? "")")
            return true
        }
        try app.performAccessibilityAudit(for: .all, record)
        let last = app.buttons["modelRowGallery.\(Self.galleryCount - 1)"]
        scrollTo(last, in: app)
        try app.performAccessibilityAudit(for: .all, record)
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
        for _ in 0..<12 where !element.isHittable {
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
