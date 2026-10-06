import XCTest

final class MusicUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("-reset-ui-test-state")
        app.launch()
    }

    func testOnlyQobuzTabsAreVisibleByDefault() {
        for tab in ["discover", "search", "albums", "artists"] {
            XCTAssertTrue(app.buttons["tab.\(tab)"].waitForExistence(timeout: 3))
        }
        for legacyTab in ["tracks", "playlists", "genres"] {
            XCTAssertFalse(app.buttons["tab.\(legacyTab)"].exists)
        }
        XCTAssertFalse(app.buttons["miniPlayer.open"].exists)
    }

    func testSettingsContainsNoLocalImportOrLegacyTabControls() {
        let signInButton = app.buttons["Continue with Qobuz"]
        XCTAssertTrue(signInButton.waitForExistence(timeout: 3))
        signInButton.tap()

        XCTAssertTrue(app.descendants(matching: .any)["settings"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["LIBRARY TABS"].exists)
        XCTAssertFalse(app.staticTexts["Import Music"].exists)

        let tabRows = app.tables.cells
        XCTAssertEqual(tabRows.count, 4)
        for legacyTitle in ["Tracks", "Playlists", "Genres"] {
            XCTAssertFalse(tabRows.containing(.staticText, identifier: legacyTitle).firstMatch.exists)
        }
    }
}
