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

    func testDefaultLibraryTabsAndMiniPlayerAreVisible() {
        XCTAssertTrue(app.buttons["tab.albums"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["miniPlayer.open"].waitForExistence(timeout: 3))
        app.buttons["tab.tracks"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["library.tracks"].waitForExistence(timeout: 2))
    }

    func testSwipePastLastTabOpensSettingsAndSwipeBackReturns() {
        app.buttons["tab.genres"].tap()
        let genres = app.descendants(matching: .any)["library.genres"]
        XCTAssertTrue(genres.waitForExistence(timeout: 2))
        swipeFromRightEdgeLeft(on: genres)
        let settings = app.descendants(matching: .any)["settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 2))
        swipeFromLeftEdgeRight(on: settings)
        XCTAssertTrue(app.descendants(matching: .any)["library.genres"].waitForExistence(timeout: 2))
    }

    func testSettingsCanSwitchBetweenDarkAndLightAppearance() {
        app.buttons["tab.genres"].tap()
        let genres = app.descendants(matching: .any)["library.genres"]
        XCTAssertTrue(genres.waitForExistence(timeout: 2))
        swipeFromRightEdgeLeft(on: genres)

        let appearance = app.segmentedControls["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 2))
        appearance.buttons["Dark"].tap()
        XCTAssertTrue(appearance.buttons["Dark"].isSelected)
        appearance.buttons["Light"].tap()
        XCTAssertTrue(appearance.buttons["Light"].isSelected)
        appearance.buttons["Auto"].tap()
        XCTAssertTrue(appearance.buttons["Auto"].isSelected)
    }

    func testTrackRowHalfSwipeShowsQueueConfirmation() {
        app.buttons["tab.tracks"].tap()
        let row = app.tables.cells["libraryRow.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        let start = row.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5))
        let end = row.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.5))
        start.press(forDuration: 0.20, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.10)
        XCTAssertTrue(app.descendants(matching: .any)["songAction.toast"].waitForExistence(timeout: 2))
    }

    func testOpeningLikedTrackDoesNotShowHeartConfirmation() {
        app.buttons["tab.tracks"].tap()
        let row = app.tables.cells["libraryRow.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 2))

        let swipeStart = row.coordinate(withNormalizedOffset: CGVector(dx: 0.28, dy: 0.5))
        let swipeEnd = row.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.5))
        swipeStart.press(forDuration: 0.20, thenDragTo: swipeEnd, withVelocity: .slow, thenHoldForDuration: 0.10)
        let toast = app.descendants(matching: .any)["songAction.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 2))
        XCTAssertEqual(toast.label, "Liked")

        row.tap()
        let player = app.descendants(matching: .any)["player"]
        XCTAssertTrue(player.waitForExistence(timeout: 2))
        let confirmation = app.staticTexts["player.likeConfirmation"]
        XCTAssertFalse(confirmation.waitForExistence(timeout: 0.8))
    }

    func testTrackLongPressShowsArtistAlbumAndGenreDestinations() {
        app.buttons["tab.tracks"].tap()
        let row = app.tables.cells["libraryRow.0"]
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        row.press(forDuration: 0.65)

        XCTAssertTrue(app.descendants(matching: .any)["trackNavigationMenu"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Artist:'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Album:'")).firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Genre:'")).firstMatch.exists)
    }

    func testSelectingTrackQueuesOnlyThatTrackAndRowsBelowIt() {
        app.buttons["tab.tracks"].tap()
        let trackTable = app.tables.firstMatch
        XCTAssertTrue(trackTable.waitForExistence(timeout: 2))
        let originalCount = trackTable.cells.count
        XCTAssertGreaterThanOrEqual(originalCount, 3)

        trackTable.cells.element(boundBy: 1).tap()
        let player = app.descendants(matching: .any)["player"]
        XCTAssertTrue(player.waitForExistence(timeout: 2))
        player.swipeUp()

        let queue = app.descendants(matching: .any)["queue"]
        XCTAssertTrue(queue.waitForExistence(timeout: 2))
        XCTAssertEqual(app.tables.firstMatch.cells.count, originalCount - 2)
    }

    func testPullDownSearchAndFilterIsAvailableOnEveryLibraryTab() {
        let tabs = ["tracks", "albums", "artists", "playlists", "genres"]
        for tab in tabs {
            app.buttons["tab.\(tab)"].tap()
            let library = app.descendants(matching: .any)["library.\(tab)"]
            XCTAssertTrue(library.waitForExistence(timeout: 2))
            library.swipeDown()
            XCTAssertTrue(app.descendants(matching: .any)["librarySearch.\(tab)"].waitForExistence(timeout: 2))
            XCTAssertTrue(app.descendants(matching: .any)["libraryFilter.\(tab)"].exists)
        }
    }

    func testMiniPlayerOpensPlayerAndSwipeDownDismisses() {
        let miniPlayer = app.buttons["miniPlayer.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
        miniPlayer.tap()
        let player = app.descendants(matching: .any)["player"]
        XCTAssertTrue(player.waitForExistence(timeout: 2))
        let artwork = app.otherElements["player.artwork"]
        let waveform = app.otherElements["player.waveform"]
        let quality = app.staticTexts["player.quality"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 2))
        XCTAssertTrue(waveform.waitForExistence(timeout: 2))
        XCTAssertTrue(quality.waitForExistence(timeout: 2))
        XCTAssertEqual(artwork.frame.width, artwork.frame.height, accuracy: 1)
        XCTAssertGreaterThanOrEqual(artwork.frame.minX, 30)
        XCTAssertGreaterThanOrEqual(waveform.frame.minY - quality.frame.maxY, 18)
        let pausedPlayer = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        pausedPlayer.name = "Paused Player Shadow"
        pausedPlayer.lifetime = .keepAlways
        add(pausedPlayer)
        player.swipeDown()
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))
    }

    func testPlayerSwipeUpOpensQueueAndQueueSwipeDownReturns() {
        let miniPlayer = app.buttons["miniPlayer.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
        miniPlayer.tap()
        let player = app.descendants(matching: .any)["player"]
        XCTAssertTrue(player.waitForExistence(timeout: 2))

        player.swipeUp()
        let queue = app.descendants(matching: .any)["queue"]
        XCTAssertTrue(queue.waitForExistence(timeout: 2))

        queue.swipeDown()
        XCTAssertTrue(player.waitForExistence(timeout: 2))
    }

    func testPlayerHorizontalSwipesChangeTrackAndUpdateMiniPlayer() {
        app.buttons["tab.tracks"].tap()
        let firstTrack = app.tables.cells["libraryRow.0"]
        XCTAssertTrue(firstTrack.waitForExistence(timeout: 2))
        firstTrack.tap()

        let player = app.descendants(matching: .any)["player"]
        let title = app.staticTexts["player.title"]
        XCTAssertTrue(player.waitForExistence(timeout: 2))
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        let firstTitle = title.label

        player.swipeLeft()
        expectation(
            for: NSPredicate(format: "label != %@", firstTitle),
            evaluatedWith: title
        )
        waitForExpectations(timeout: 2)
        let nextTitle = title.label

        player.swipeRight()
        expectation(
            for: NSPredicate(format: "label == %@", firstTitle),
            evaluatedWith: title
        )
        waitForExpectations(timeout: 2)

        player.swipeLeft()
        expectation(
            for: NSPredicate(format: "label == %@", nextTitle),
            evaluatedWith: title
        )
        waitForExpectations(timeout: 2)
        player.swipeDown()

        let miniPlayer = app.buttons["miniPlayer.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 2))
        XCTAssertTrue(miniPlayer.label.contains(nextTitle))
    }

    func testAlbumDetailSwipeDownReturnsToAlbums() {
        app.buttons["tab.albums"].tap()
        let albumWithLongTrackList = app.collectionViews.cells["albumCard.1"]
        XCTAssertTrue(albumWithLongTrackList.waitForExistence(timeout: 2))
        albumWithLongTrackList.tap()

        let detail = app.descendants(matching: .any)["albumDetail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 2))
        detail.swipeDown()
        XCTAssertTrue(app.descendants(matching: .any)["library.albums"].waitForExistence(timeout: 2))
    }

    func testAlbumLongPressOffersPlayNextAndAddToQueue() {
        app.buttons["tab.albums"].tap()
        let album = app.collectionViews.cells["albumCard.0"]
        XCTAssertTrue(album.waitForExistence(timeout: 2))
        album.press(forDuration: 0.65)

        XCTAssertTrue(app.descendants(matching: .any)["albumQueueMenu"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Play Next"].exists)
        XCTAssertTrue(app.buttons["Add to Queue"].exists)
        app.buttons["Play Next"].tap()

        let toast = app.descendants(matching: .any)["songAction.toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 2))
        XCTAssertEqual(toast.label, "Album Queued Next")
    }

    func testAlbumDetailHeaderLongPressOffersQueueMenu() {
        app.buttons["tab.albums"].tap()
        let album = app.collectionViews.cells["albumCard.0"]
        XCTAssertTrue(album.waitForExistence(timeout: 2))
        album.tap()

        let title = app.staticTexts["albumDetail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 2))
        title.press(forDuration: 0.65)

        XCTAssertTrue(app.descendants(matching: .any)["albumQueueMenu"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Play Next"].exists)
        XCTAssertTrue(app.buttons["Add to Queue"].exists)
    }

    func testProfileDetailSwipeDownReturnsToLibrary() {
        app.buttons["tab.artists"].tap()
        let firstProfile = app.tables.cells["libraryRow.0"]
        XCTAssertTrue(firstProfile.waitForExistence(timeout: 2))
        firstProfile.tap()

        let detail = app.descendants(matching: .any)["profileDetail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 2))
        detail.swipeDown()
        XCTAssertTrue(app.descendants(matching: .any)["library.artists"].waitForExistence(timeout: 2))
    }

    private func swipeFromRightEdgeLeft(on element: XCUIElement) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.995, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func swipeFromLeftEdgeRight(on element: XCUIElement) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.80, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
}
