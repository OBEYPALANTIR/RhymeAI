//
//  Writers_BlockUITests.swift
//  Writers BlockUITests
//
//  Created by Tyler Manring on 4/6/26.
//

import XCTest

final class Writers_BlockUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testUnBlockButtonHidesWhenAssistantSheetOpens() throws {
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
    func testBackSwipeClosesAssistantSheetWithoutReturningToMenu() throws {
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
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
