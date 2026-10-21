import XCTest

/// Drives the Assistant's suggestion loading state with the scripted stream
/// (`--ui-test-scripted-suggestions`, debug builds only), so the real ghost
/// cards, arrivals and cancellation run with no provider key, network request
/// or model. The ghosts are hidden from accessibility, so these tests follow
/// the "Writing…" caption, the Stop button and the cards' "Use line" buttons,
/// and attach screenshots of each state for review.
///
/// Launches the way `isolatedUITestApp` does, with the in-memory store first:
/// songs stay in memory, API keys in an in-memory keychain, and the editor's
/// settings in their own defaults suite (`UITestFlags.editorDefaults`). Other
/// launch state still touches the standard domain, so run these under a
/// separate bundle ID or on a disposable simulator.
final class SuggestionLoadingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testScriptedRequestHoldsWritingThenFillsTheSlots() throws {
        let app = scriptedSuggestionApp(hold: 5, interval: 0.6, count: 4)
        app.launch()
        try runLoadingToResults(in: app, expectedLines: 4, screenshotPrefix: "default-size")
    }

    @MainActor
    func testScriptedRequestAtAnAccessibilityTextSize() throws {
        let app = scriptedSuggestionApp(
            hold: 5,
            interval: 0.6,
            count: 4,
            extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        )
        app.launch()
        try runLoadingToResults(in: app, expectedLines: 4, screenshotPrefix: "accessibility-xxxl")
    }

    @MainActor
    func testStopDuringTheHoldClosesTheEmptySection() throws {
        let app = scriptedSuggestionApp(hold: 30, interval: 1, count: 4)
        app.launch()

        let suggest = app.buttons["Suggest Next Line"]
        XCTAssertTrue(suggest.waitForExistence(timeout: 5))
        suggest.tap()
        XCTAssertTrue(app.staticTexts["suggestionsWriting"].waitForExistence(timeout: 3))

        // The button's label cross-fades from Suggest Next Line to Stop.
        let stop = app.buttons["Stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3))
        stop.tap()

        XCTAssertTrue(suggest.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForAbsence(of: app.staticTexts["suggestionsWriting"], timeout: 3))
        XCTAssertEqual(app.buttons.matching(identifier: "useSuggestionButton").count, 0)
        attachScreenshot(of: app, named: "stopped-during-hold")
    }

    // MARK: - Helpers

    @MainActor
    private func runLoadingToResults(in app: XCUIApplication, expectedLines: Int, screenshotPrefix: String) throws {
        let suggest = app.buttons["Suggest Next Line"]
        XCTAssertTrue(suggest.waitForExistence(timeout: 5))
        suggest.tap()

        let writing = app.staticTexts["suggestionsWriting"]
        XCTAssertTrue(writing.waitForExistence(timeout: 3), "The Writing… caption should appear as soon as the request starts")
        XCTAssertTrue(app.buttons["Stop"].waitForExistence(timeout: 3), "The button should cross-fade to Stop")
        XCTAssertEqual(
            app.buttons.matching(identifier: "useSuggestionButton").count,
            0,
            "No card should land during the hold"
        )
        attachScreenshot(of: app, named: "\(screenshotPrefix)-writing")

        // Mid-stream: the first line in its slot and the next ghost open below it.
        let first = app.buttons.matching(identifier: "useSuggestionButton").element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 10), "The first scripted line should land after the hold")
        attachScreenshot(of: app, named: "\(screenshotPrefix)-first-line")

        let last = app.buttons.matching(identifier: "useSuggestionButton").element(boundBy: expectedLines - 1)
        XCTAssertTrue(last.waitForExistence(timeout: 15), "Every scripted line should land")
        XCTAssertTrue(suggest.waitForExistence(timeout: 5), "Suggest Next Line should return once the stream ends")
        XCTAssertTrue(waitForAbsence(of: writing, timeout: 3), "The Writing… caption should leave with the stream")
        XCTAssertEqual(app.buttons.matching(identifier: "useSuggestionButton").count, expectedLines)
        attachScreenshot(of: app, named: "\(screenshotPrefix)-arrived")
    }

    @MainActor
    private func scriptedSuggestionApp(
        hold: Double,
        interval: Double,
        count: Int,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-test-in-memory-store",
            "--ui-test-seed-prosody-song",
            "--ui-test-open-assistant",
            "--ui-test-scripted-suggestions",
        ] + extraArguments
        app.launchEnvironment["RHYMEAI_UITEST_SUGGESTION_HOLD"] = String(hold)
        app.launchEnvironment["RHYMEAI_UITEST_SUGGESTION_INTERVAL"] = String(interval)
        app.launchEnvironment["RHYMEAI_UITEST_SUGGESTION_COUNT"] = String(count)
        return app
    }

    @MainActor
    private func waitForAbsence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "suggestions-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
