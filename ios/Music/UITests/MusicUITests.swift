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
        for tab in ["discover", "search", "albums", "artists", "tracks"] {
            XCTAssertTrue(app.buttons["tab.\(tab)"].waitForExistence(timeout: 3))
        }
        for legacyTab in ["playlists", "genres"] {
            XCTAssertFalse(app.buttons["tab.\(legacyTab)"].exists)
        }
        XCTAssertFalse(app.buttons["miniPlayer.open"].exists)
    }

    func testSettingsContainsNoLocalImportOrLegacyTabControls() {
        let settings = openSettingsFromSignedOutTracks()
        XCTAssertTrue(app.staticTexts["LIBRARY TABS"].exists)
        XCTAssertFalse(app.staticTexts["Import Music"].exists)
        XCTAssertTrue(app.segmentedControls["settings.appearance"].exists)
        XCTAssertTrue(app.segmentedControls["settings.qobuzQuality"].exists)
        XCTAssertTrue(app.buttons["Account: Not signed in"].exists)

        let tabRows = settings.tables.cells
        XCTAssertEqual(tabRows.count, 5)
        for title in ["Discover", "Search", "Albums", "Artists", "Tracks"] {
            XCTAssertTrue(tabRows.containing(.staticText, identifier: title).firstMatch.exists)
        }
        for legacyTitle in ["Playlists", "Genres"] {
            XCTAssertFalse(tabRows.containing(.staticText, identifier: legacyTitle).firstMatch.exists)
        }
        returnToSignedOutTracks(from: settings)
    }

    func testSignedOutSettingsAppearanceAndQualityAreUsableWithoutOAuth() {
        let settings = openSettingsFromSignedOutTracks()
        let appearance = app.segmentedControls["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 2))
        for title in ["Dark", "Light", "Auto"] {
            appearance.buttons[title].tap()
            XCTAssertTrue(appearance.buttons[title].isSelected)
        }

        let quality = app.segmentedControls["settings.qobuzQuality"]
        XCTAssertTrue(quality.exists)
        // Quality is below the five tab rows on a 320 x 568 display.
        if !quality.buttons["MP3"].isHittable { settings.swipeUp() }
        for title in ["MP3", "Hi-Res 96", "Hi-Res 192", "CD"] {
            XCTAssertTrue(quality.buttons[title].isHittable)
            quality.buttons[title].tap()
            XCTAssertTrue(quality.buttons[title].isSelected)
        }
        returnToSignedOutTracks(from: settings)
    }

    func testEditingTabsKeepsSettingsVisibleAndEdgeReturnWorks() {
        let settings = openSettingsFromSignedOutTracks()
        let searchSwitch = settings.tables.cells.containing(.staticText, identifier: "Search").switches.firstMatch
        XCTAssertTrue(searchSwitch.isHittable)
        searchSwitch.tap()
        XCTAssertFalse(app.buttons["tab.search"].exists)
        XCTAssertTrue(settings.exists)
        // Editing tab preferences must not reactivate root navigation while
        // Settings still owns the content and its left-edge return gesture.
        swipeContentEdge(forward: true)
        XCTAssertTrue(settings.exists)
        XCTAssertFalse(app.buttons["tab.discover"].isSelected)
        searchSwitch.tap()
        XCTAssertTrue(app.buttons["tab.search"].exists)
        returnToSignedOutTracks(from: settings)
    }

    private func openSettingsFromSignedOutTracks() -> XCUIElement {
        let tracks = app.buttons["tab.tracks"]
        XCTAssertTrue(tracks.waitForExistence(timeout: 3))
        tracks.tap()
        XCTAssertTrue(tracks.isSelected)
        // Never tap Continue: it starts OAuth, not Settings. The welcome screen
        // must participate in content-edge navigation even without credentials.
        XCTAssertTrue(app.buttons["Continue with Qobuz"].waitForExistence(timeout: 2))
        swipeContentEdge(forward: true)
        let settings = app.descendants(matching: .any)["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 2))
        return settings
    }

    private func returnToSignedOutTracks(from settings: XCUIElement) {
        swipeContentEdge(forward: false)
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: settings)
        waitForExpectations(timeout: 2)
        XCTAssertTrue(app.buttons["tab.tracks"].isSelected)
        XCTAssertTrue(app.buttons["Continue with Qobuz"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["miniPlayer.open"].exists)
    }

    private func swipeContentEdge(forward: Bool) {
        // y = 65% is in the child content, not the 44 pt tab strip. Both
        // directions begin within the historical 24 pt screen-edge region.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.995 : 0.005, dy: 0.65))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.20 : 0.80, dy: 0.65))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
}
