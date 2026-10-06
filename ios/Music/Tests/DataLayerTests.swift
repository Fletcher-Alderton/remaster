import XCTest
@testable import Music

private final class StubQobuzStreamResolver: QobuzStreamResolving {
    struct Request {
        let trackID: Int64
        let quality: QobuzStreamQuality
    }

    private(set) var requests: [Request] = []

    func requestStreamURL(
        trackID: Int64,
        quality: QobuzStreamQuality,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<QobuzTrackURL, Error>) -> Void
    ) {
        requests.append(Request(trackID: trackID, quality: quality))
    }
}

private final class QobuzHangingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

final class DataLayerTests: XCTestCase {
    func testQobuzMP3RequestSignatureMatchesQobineProtocol() {
        XCTAssertEqual(
            QobuzStreamingClient.requestSignature(trackID: 64_868_955, timestamp: "1700000000", secret: "secret"),
            "1dee430e89644d6427a863d8905896ae"
        )
    }

    func testQobuzResolutionTimeoutCompletesOnce() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QobuzHangingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = QobuzStreamingClient(
            credentials: QobuzCredentials(userAuthToken: "test-token", userID: 1),
            session: session,
            resolutionTimeout: 0.05
        )
        let completed = expectation(description: "resolution finishes at deadline")
        var result: Result<QobuzTrackURL, Error>?

        client.requestStreamURL(trackID: 1, quality: .mp3) { value in
            result = value
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        session.invalidateAndCancel()

        guard case .failure(let error)? = result else {
            return XCTFail("Expected a timeout error")
        }
        XCTAssertEqual(error.localizedDescription, QobuzStreamingError.resolutionTimedOut.localizedDescription)
    }

    func testQobuzTrackURLDecodesQobineResponseShape() throws {
        let json = Data(#"{"url":"https://media.example/track.mp3","format_id":5,"mime_type":"audio/mpeg","sampling_rate":44.1,"bit_depth":16}"#.utf8)
        let result = try JSONDecoder().decode(QobuzTrackURL.self, from: json)
        XCTAssertEqual(result.formatID, QobuzStreamQuality.mp3.rawValue)
        XCTAssertEqual(result.mimeType, "audio/mpeg")
        XCTAssertEqual(result.url.host, "media.example")
    }

    func testQobuzTrackSearchDecodesResults() throws {
        let json = Data(#"{"tracks":{"items":[{"id":12345,"title":"Example Song","duration":210,"performer":{"name":"Example Artist"},"album":{"title":"Example Album"}}]}}"#.utf8)
        let response = try JSONDecoder().decode(QobuzTrackSearchResponse.self, from: json)
        XCTAssertEqual(response.tracks.items.count, 1)
        XCTAssertEqual(response.tracks.items[0].id, 12345)
        XCTAssertEqual(response.tracks.items[0].subtitle, "Example Artist • Example Album")
    }

    func testQobuzCatalogSearchFixtureDecodesMixedIDsAndArtworkVariants() throws {
        let data = try qobuzFixture(named: "qobuz-catalog-search")
        let response = try JSONDecoder().decode(QobuzCatalogSearchResponse.self, from: data)

        let album = try XCTUnwrap(response.albums?.items.first)
        XCTAssertEqual(album.id, "123456")
        XCTAssertEqual(album.year, "2024")
        XCTAssertEqual(album.quality, "24-bit / 96000 Hz")
        XCTAssertEqual(album.artworkURL?.absoluteString, "https://img.example/large.jpg")

        let artist = try XCTUnwrap(response.artists?.items.first)
        XCTAssertEqual(artist.id, "42")
        XCTAssertEqual(artist.albumsCount, 3)

        let track = try XCTUnwrap(response.tracks?.items.first)
        XCTAssertEqual(track.id, 987654)
        XCTAssertEqual(track.album?.id, "123456")
        XCTAssertEqual(track.album?.imageURL?.absoluteString, "https://img.example/xlarge.jpg")
        XCTAssertEqual(QobuzCatalogMapper.track(track).catalogAlbumID, "123456")
    }

    func testQobuzAlbumDetailFixtureDecodesAndMapsTracks() throws {
        let album = try JSONDecoder().decode(QobuzCatalogAlbum.self, from: qobuzFixture(named: "qobuz-album-detail"))
        let mapped = QobuzCatalogMapper.album(album)

        XCTAssertEqual(mapped.id, "album-123456")
        XCTAssertEqual(mapped.genre, "Jazz")
        XCTAssertEqual(mapped.tracks.map(\.id), ["555"])
        XCTAssertEqual(mapped.tracks.first?.catalogAlbumID, "album-123456")
    }

    func testQobuzArtistDetailFixtureDecodesBiographyAndAlbums() throws {
        let artist = try JSONDecoder().decode(QobuzCatalogArtist.self, from: qobuzFixture(named: "qobuz-artist-detail"))
        let mapped = QobuzCatalogMapper.profile(artist)

        XCTAssertEqual(mapped.id, "42")
        XCTAssertEqual(mapped.subtitle, "1 albums")
        XCTAssertEqual(mapped.information, "A fixture biography.")
        XCTAssertEqual(mapped.albums.map(\.id), ["123456"])
    }

    private func qobuzFixture(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: DataLayerTests.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testQobuzQualitiesMapToQobuzFormatIDs() {
        XCTAssertEqual(QobuzStreamQuality.allCases.map(\.rawValue), [5, 6, 7, 27])
        XCTAssertEqual(QobuzStreamQuality.cd.detail, "Lossless, 16-bit / 44.1 kHz")
        XCTAssertNotEqual(
            QobuzStreamingClient.requestSignature(trackID: 12345, timestamp: "1700000000", secret: "secret", quality: .mp3),
            QobuzStreamingClient.requestSignature(trackID: 12345, timestamp: "1700000000", secret: "secret", quality: .cd)
        )
    }


    func testAutomaticAppearanceUsesLocalNightHours() {
        XCTAssertTrue(ThemeManager.isNight(hour: 0))
        XCTAssertTrue(ThemeManager.isNight(hour: 6))
        XCTAssertFalse(ThemeManager.isNight(hour: 7))
        XCTAssertFalse(ThemeManager.isNight(hour: 18))
        XCTAssertTrue(ThemeManager.isNight(hour: 19))
        XCTAssertTrue(ThemeManager.isNight(hour: 23))
    }

    func testSongSwipeCellUsesDarkThemeSurfaceAtInitialization() {
        let originalMode = ThemeManager.mode
        defer { ThemeManager.mode = originalMode }
        ThemeManager.mode = .dark

        let cell = SongSwipeActionCell(style: .default, reuseIdentifier: nil)

        XCTAssertEqual(cell.backgroundColor, DesignSystem.pageBackground)
        XCTAssertEqual(cell.contentView.backgroundColor, DesignSystem.pageBackground)
    }

    func testPlayerUsesBrokenHeartWhenRemovingLike() {
        XCTAssertEqual(PlayerViewController.likeConfirmationLabel(isLiked: true), "Added to Likes")
        XCTAssertEqual(PlayerViewController.likeConfirmationLabel(isLiked: false), "Removed from Likes")
    }

    func testAlbumDetailUsesAContinuousScrollingTableHeader() {
        let tracks = (0..<10).map {
            ScreenTrack(
                id: "track-\($0)",
                title: "Track \($0)",
                artist: "Artist",
                album: "Album",
                quality: "FLAC",
                artwork: nil,
                duration: 180
            )
        }
        let album = ScreenAlbum(
            id: "album",
            title: "Album",
            artist: "Artist",
            year: "2026",
            genre: "Electronic",
            quality: "FLAC",
            artwork: nil,
            tracks: tracks
        )
        let controller = AlbumDetailViewController(album: album)
        controller.loadViewIfNeeded()
        let table = controller.view.subviews.compactMap { $0 as? UITableView }.first

        XCTAssertNotNil(table?.tableHeaderView)
        XCTAssertEqual(table?.tableHeaderView?.accessibilityIdentifier, "albumDetail.header")
    }


    func testTabConfigurationKeepsAtLeastOneUniqueTab() {
        let configuration = TabConfiguration(enabledTabs: [.albums, .albums, .artists])
        XCTAssertEqual(configuration.enabledTabs, [.albums, .artists])
        var onlyTab = TabConfiguration(enabledTabs: [.artists])
        onlyTab.setEnabled(false, for: .artists)
        XCTAssertEqual(onlyTab.enabledTabs, [.artists])
    }

    func testQueueStateReturnsNilForInvalidCurrentIndex() {
        XCTAssertNil(QueueState(trackIDs: ["a"], currentIndex: 2).currentTrackID)
        XCTAssertEqual(QueueState(trackIDs: ["a"], currentIndex: 0).currentTrackID, "a")
    }


    func testQobuzQueueControllerRequestsSelectedQualityAndRejectsInvalidTrackIDs() {
        let track = ScreenTrack(id: "2468", title: "Song", artist: "Artist", album: "Album", duration: 120)
        let client = StubQobuzStreamResolver()
        let controller = QobuzPlaybackController(
            client: client,
            quality: { .hiRes96 },
            trackProvider: { $0 == track.id ? track : nil }
        )
        controller.setQueue(trackIDs: [track.id], startingAt: 0)
        controller.play()
        XCTAssertEqual(client.requests.map(\.trackID), [2468])
        XCTAssertEqual(client.requests.map(\.quality), [.hiRes96])
        XCTAssertTrue(controller.queueState.isPlaying)

        var errorDescription: String?
        controller.onError = { errorDescription = $0.localizedDescription }
        controller.setQueue(trackIDs: ["not-numeric"], startingAt: 0)
        controller.play()
        XCTAssertEqual(errorDescription, QobuzStreamingError.invalidQobuzTrackID.localizedDescription)
        XCTAssertFalse(controller.queueState.isPlaying)
        XCTAssertEqual(client.requests.count, 1)
    }


    func testSongSwipeThresholdsResolveAllFourActions() {
        let width: CGFloat = 300
        XCTAssertNil(SongSwipeActionCell.resolvedAction(for: -60, width: width))
        XCTAssertEqual(SongSwipeActionCell.resolvedAction(for: -100, width: width), .enqueue)
        XCTAssertEqual(SongSwipeActionCell.resolvedAction(for: -230, width: width), .playNext)
        XCTAssertEqual(SongSwipeActionCell.resolvedAction(for: 100, width: width), .toggleLike)
        XCTAssertEqual(SongSwipeActionCell.resolvedAction(for: 230, width: width), .more)
    }

    func testAppStatePersistsLikesAndTabOrder() {
        let suiteName = "MusicTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults)
        state.toggleLike(trackID: "one")
        state.updateTabConfiguration(TabConfiguration(enabledTabs: [.albums, .artists]))
        let reloaded = AppState(defaults: defaults)
        XCTAssertTrue(reloaded.isLiked(trackID: "one"))
        XCTAssertEqual(reloaded.tabConfiguration.enabledTabs, [.albums, .artists])
    }

    func testLegacyLocalTabsAreRemovedFromPersistedPreferences() throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data(#"{"enabledTabs":["genres","tracks","playlists"]}"#.utf8), forKey: "Music.AppState.tabConfiguration")

        let state = AppState(defaults: defaults)

        XCTAssertEqual(state.tabConfiguration.enabledTabs, [.discover])
        let data = try XCTUnwrap(defaults.data(forKey: "Music.AppState.tabConfiguration"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String]])
        XCTAssertEqual(saved["enabledTabs"], ["discover"])
    }
}
