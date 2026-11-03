import XCTest

/// Captures marketing/demo screenshots from a real Qobuz session.
///
/// Skipped unless `QOBUZ_DEMO_DIR` is set (pass it to `xcodebuild` as
/// `QOBUZ_DEMO_DIR=/path`; the test runner receives it prefixed with
/// `TEST_RUNNER_`). Screens are written to that directory as PNGs.
final class DemoCaptureUITests: XCTestCase {
    private var app: XCUIApplication!
    private var directory: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let dir = ProcessInfo.processInfo.environment["QOBUZ_DEMO_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_QOBUZ_DEMO_DIR to capture demo screenshots")
        }
        directory = dir
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: nil)
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-reset-ui-test-state", "-ipod-preview"]
        app.launch()
    }

    private func shot(_ name: String) {
        let data = XCUIScreen.main.screenshot().pngRepresentation
        try? data.write(to: URL(fileURLWithPath: "\(directory!)/\(name).png"))
    }

    /// Waits for the saved-library grid to have loaded real album artwork.
    private func waitForLibrary() {
        let card = app.cells.matching(
            NSPredicate(format: "identifier BEGINSWITH 'qobuz.albumCard.'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 60), "saved albums did not load")
        // Give async artwork one extra beat so cards are not captured blank.
        sleep(3)
    }

    func testCaptureDemoScreens() {
        // Discover: editorial sections.
        XCTAssertTrue(app.buttons["tab.discover"].waitForExistence(timeout: 10))
        app.buttons["tab.discover"].tap()
        sleep(6)
        shot("01-discover")

        // Search: grouped album/artist/track results for a stable query.
        app.buttons["tab.search"].tap()
        sleep(1)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText("Glaive\n")
            sleep(8)
            shot("02-search")
        }

        // Albums: the saved-library artwork grid.
        app.buttons["tab.albums"].tap()
        waitForLibrary()
        shot("03-albums")

        // Artists: saved artists with circular portraits.
        app.buttons["tab.artists"].tap()
        sleep(8)
        shot("04-artists")

        // Tracks: saved tracks with 78 pt rows.
        app.buttons["tab.tracks"].tap()
        sleep(8)
        shot("05-tracks")

        // Album detail, then play, now playing, and queue.
        app.buttons["tab.albums"].tap()
        waitForLibrary()
        let card = app.cells.matching(
            NSPredicate(format: "identifier BEGINSWITH 'qobuz.albumCard.'")).firstMatch
        card.tap()
        XCTAssertTrue(app.buttons["albumDetail.play"].waitForExistence(timeout: 25))
        sleep(3)
        shot("06-album-detail")

        app.buttons["albumDetail.play"].tap()
        XCTAssertTrue(app.staticTexts["player.title"].waitForExistence(timeout: 15))
        sleep(6)
        shot("07-now-playing")

        let queueButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'up next'")).firstMatch
        if queueButton.waitForExistence(timeout: 6) {
            queueButton.tap()
            if app.otherElements["queue"].waitForExistence(timeout: 6) {
                sleep(3)
                shot("08-queue")
            }
        }
    }
}
