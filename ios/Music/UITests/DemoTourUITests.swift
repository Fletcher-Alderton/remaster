import XCTest

/// Drives a slow, camera-friendly tour of the app so the run can be recorded
/// with `xcrun simctl io <udid> recordVideo` for the README demo GIF.
///
/// Skipped unless `QOBUZ_DEMO_TOUR` is set (pass it as
/// `TEST_RUNNER_QOBUZ_DEMO_TOUR=1`).
final class DemoTourUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["QOBUZ_DEMO_TOUR"] != nil else {
            throw XCTSkip("Set TEST_RUNNER_QOBUZ_DEMO_TOUR=1 to run the recorded demo tour")
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-reset-ui-test-state", "-ipod-preview"]
        app.launch()
    }

    func testTour() {
        // Discover.
        XCTAssertTrue(app.buttons["tab.discover"].waitForExistence(timeout: 10))
        sleep(7)

        // Albums: let the artwork grid settle.
        app.buttons["tab.albums"].tap()
        let card = app.cells.matching(
            NSPredicate(format: "identifier BEGINSWITH 'qobuz.albumCard.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 60))
        sleep(6)

        // Artists, then Tracks.
        app.buttons["tab.artists"].tap()
        sleep(7)
        app.buttons["tab.tracks"].tap()
        sleep(7)

        // Album detail, then start playback.
        app.buttons["tab.albums"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        sleep(2)
        card.tap()
        XCTAssertTrue(app.buttons["albumDetail.play"].waitForExistence(timeout: 25))
        sleep(5)
        app.buttons["albumDetail.play"].tap()

        // Now playing, with the waveform and metadata.
        XCTAssertTrue(app.staticTexts["player.title"].waitForExistence(timeout: 15))
        sleep(8)

        // Up Next.
        let queueButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'up next'")).firstMatch
        if queueButton.waitForExistence(timeout: 6) {
            queueButton.tap()
            sleep(7)
        }
    }
}
