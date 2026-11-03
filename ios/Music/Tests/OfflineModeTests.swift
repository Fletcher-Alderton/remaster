import XCTest
import UIKit
@testable import Music

/// Offline behaviour: with no connection only downloaded music is shown and played, until the
/// connection returns (automatic) or the user pulls down twice in a library tab (manual override).
@MainActor
final class OfflineModeTests: XCTestCase {
    override func tearDown() {
        OfflineCountingURLProtocol.reset()
        super.tearDown()
    }

    private func record(_ id: Int64, title: String, artist: String, album: String, albumID: String,
                        artistID: String? = "art-\(1)", minutesAgo: Double) -> QobuzDownloadRecord {
        var record = QobuzDownloadRecord(accountID: 1, trackID: id, requestedQuality: 6, actualFormatID: 6, title: title,
            artist: artist, albumID: albumID, albumTitle: album, duration: 180, mimeType: "audio/flac",
            samplingRate: 44.1, bitDepth: 16, byteCount: 1, filename: "\(UUID().uuidString).flac",
            completedAt: Date().addingTimeInterval(-minutesAgo * 60))
        record.artistID = artistID
        record.artworkURL = URL(string: "https://static.qobuz.com/images/covers/\(albumID)_600.jpg")
        return record
    }

    private var library: OfflineLibrary {
        OfflineLibrary(records: [
            record(12, title: "B Side", artist: "Ada", album: "First", albumID: "first", artistID: "42", minutesAgo: 30),
            record(11, title: "A Side", artist: "Ada", album: "First", albumID: "first", artistID: "42", minutesAgo: 31),
            record(21, title: "Solo", artist: "Ben", album: "Second", albumID: "second", artistID: "77", minutesAgo: 5)
        ])
    }

    // MARK: Mode

    func testOfflineRestrictsUntilReconnectOrManualOverride() {
        let mode = OfflineMode(startMonitoring: false)
        var notifications = 0
        let token = NotificationCenter.default.addObserver(forName: OfflineMode.didChange, object: mode, queue: nil) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        XCTAssertFalse(mode.restrictsToDownloads)
        mode.setOnline(false)
        XCTAssertTrue(mode.restrictsToDownloads)
        mode.showAllContent()
        XCTAssertFalse(mode.restrictsToDownloads, "Manual override shows everything while still offline")
        XCTAssertFalse(mode.isOnline)
        mode.setOnline(true)
        mode.setOnline(false)
        XCTAssertTrue(mode.restrictsToDownloads, "The override ends when the connection returns")
        mode.setOnline(false)
        XCTAssertEqual(notifications, 4, "Repeated identical states are not re-announced")
    }

    // MARK: Library

    func testOfflineLibraryGroupsDownloadsIntoAlbumsArtistsAndTracks() {
        let library = self.library
        XCTAssertEqual(library.tracks.map(\.title), ["Solo", "B Side", "A Side"], "Newest downloads first")
        XCTAssertEqual(library.albums.map(\.id), ["second", "first"])
        let first = library.albums[1]
        XCTAssertEqual(first.title, "First")
        XCTAssertEqual(first.artist, "Ada")
        XCTAssertEqual(first.tracks.map(\.title), ["A Side", "B Side"], "Album tracks keep download order")
        XCTAssertEqual(first.artworkURL?.absoluteString, "https://static.qobuz.com/images/covers/first_600.jpg")
        XCTAssertEqual(library.artists.map(\.name), ["Ben", "Ada"])
        XCTAssertEqual(library.artists[1].id, "42")
        let ada = library.profile(artistID: "42", name: "Ada")
        XCTAssertEqual(ada.tracks.map(\.title), ["A Side", "B Side"])
        XCTAssertEqual(ada.albums.map(\.id), ["first"])
        XCTAssertEqual(library.album(id: "first")?.tracks.count, 2)
        XCTAssertEqual(library.searchTracks(albumID: "first").map(\.id), [11, 12], "Download state can be shown per track")
        XCTAssertEqual(library.profile(artistID: "", name: "ben").tracks.map(\.title), ["Solo"], "Falls back to the artist name")
    }

    func testOldManifestsWithoutArtworkOrArtistStillDecode() throws {
        let json = #"[{"accountID":1,"trackID":5,"requestedQuality":6,"actualFormatID":6,"title":"T","mimeType":"audio/flac","samplingRate":44.1,"bitDepth":16,"byteCount":1,"filename":"x.flac","completedAt":0}]"#
        let records = try JSONDecoder().decode([QobuzDownloadRecord].self, from: Data(json.utf8))
        XCTAssertNil(records.first?.artworkURL)
        XCTAssertNil(records.first?.artistID)
    }

    func testPlaybackWhileOfflineSkipsTracksThatAreNotDownloaded() {
        let tracks = ["1", "2", "3", "4"].map { ScreenTrack(id: $0, title: $0, artist: "", album: "") }
        let downloaded: Set<String> = ["2", "4"]
        let result = OfflineMode.downloadedQueue(tracks, startingAt: 0) { downloaded.contains($0.id) }
        XCTAssertEqual(result.tracks.map(\.id), ["2", "4"])
        XCTAssertEqual(result.start, 0)
        let fromThird = OfflineMode.downloadedQueue(tracks, startingAt: 2) { downloaded.contains($0.id) }
        XCTAssertEqual(fromThird.tracks.map(\.id), ["2", "4"])
        XCTAssertEqual(fromThird.start, 1, "Starts at the first downloaded track at or after the one picked")
        XCTAssertTrue(OfflineMode.downloadedQueue(tracks, startingAt: 0) { _ in false }.tracks.isEmpty)
    }

    // MARK: Library tabs

    private func catalog(_ mode: QobuzCatalogViewController.Mode, offline: OfflineMode) -> QobuzCatalogViewController {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineCountingURLProtocol.self]
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "t", userID: 1),
                                          session: URLSession(configuration: configuration), catalogAppID: "app")
        let library = self.library
        let controller = QobuzCatalogViewController(mode: mode, client: client, offlineMode: offline, offlineLibrary: { library })
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        controller.view.layoutIfNeeded()
        return controller
    }

    private func all(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + all($0) } }
    private func status(_ controller: UIViewController) -> String {
        (all(controller.view).first { ($0.accessibilityIdentifier ?? "").hasSuffix(".status") } as? UILabel)?.text ?? ""
    }
    private func rows(_ controller: UIViewController) -> Int {
        all(controller.view).compactMap { $0 as? UITableView }.first?.numberOfRows(inSection: 0) ?? -1
    }
    private func drain(_ seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func testLibraryTabShowsOnlyDownloadsOfflineAndEverythingAfterReconnect() {
        OfflineCountingURLProtocol.body = #"{"tracks":{"items":[{"id":11,"title":"A Side"},{"id":12,"title":"B Side"},{"id":99,"title":"Streaming Only"}],"total":3}}"#
        let offline = OfflineMode(startMonitoring: false)
        offline.setOnline(false)
        let controller = catalog(.tracks, offline: offline)
        drain()
        XCTAssertEqual(OfflineCountingURLProtocol.requests, 0, "No Qobuz request while showing downloads only")
        XCTAssertEqual(rows(controller), 3)
        XCTAssertTrue(status(controller).hasPrefix("Offline"), status(controller))

        offline.setOnline(true)
        drain()
        XCTAssertEqual(OfflineCountingURLProtocol.requests, 1, "Reconnecting reloads the full library automatically")
        XCTAssertEqual(rows(controller), 3)
        XCTAssertFalse(status(controller).contains("Offline"))
        XCTAssertFalse(status(controller).contains("Refreshing"), "Automatic reloads stay quiet")
    }

    func testSecondPullDownRefreshesAndShowsAllContentWhileOffline() {
        OfflineCountingURLProtocol.body = #"{"tracks":{"items":[{"id":99,"title":"Streaming Only"}],"total":1}}"#
        let offline = OfflineMode(startMonitoring: false)
        offline.setOnline(false)
        let controller = catalog(.tracks, offline: offline)
        drain()
        controller.libraryPulledDown()
        XCTAssertEqual(OfflineCountingURLProtocol.requests, 0, "First pull only reveals search and sort")
        XCTAssertTrue(offline.restrictsToDownloads)
        OfflineCountingURLProtocol.holdResponses = true
        controller.libraryPulledDown()
        XCTAssertFalse(offline.restrictsToDownloads, "Second pull shows all content while offline")
        XCTAssertEqual(status(controller), "Refreshing your Qobuz library…")
        OfflineCountingURLProtocol.release()
        drain()
        XCTAssertEqual(OfflineCountingURLProtocol.requests, 1)
        XCTAssertEqual(rows(controller), 1)
    }

    func testDiscoverAndSearchWhileOfflineUseDownloads() {
        OfflineCountingURLProtocol.body = "{}"
        let offline = OfflineMode(startMonitoring: false)
        offline.setOnline(false)
        let discover = catalog(.discover, offline: offline)
        drain()
        XCTAssertEqual(OfflineCountingURLProtocol.requests, 0)
        XCTAssertTrue(status(discover).hasPrefix("Offline"))

        let search = catalog(.search, offline: offline)
        let bar = all(search.view).compactMap { $0 as? UISearchBar }.first!
        bar.text = "side"
        search.searchBarSearchButtonClicked(bar)
        drain()
        XCTAssertEqual(OfflineCountingURLProtocol.requests, 0)
        XCTAssertGreaterThanOrEqual(rows(search), 2, "Downloaded matches are searched locally")
        XCTAssertTrue(status(search).hasPrefix("Offline"))

        offline.setOnline(true)
        drain()
        XCTAssertGreaterThan(OfflineCountingURLProtocol.requests, 0, "Discover reloads once back online")
    }

    // MARK: Artist page

    func testArtistTopTrackPlaysItAndEveryTrackBelow() throws {
        let tracks = (1...4).map { ScreenTrack(id: "\($0)", title: "Top \($0)", artist: "Ada", album: "A") }
        let controller = ProfileDetailViewController(profile: ScreenProfile(id: "42", name: "Ada", subtitle: "", information: "", tracks: tracks))
        var played: [[String]] = []
        controller.onPlayTracks = { played.append($0.map(\.id)) }
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        controller.view.layoutIfNeeded()
        let table = try XCTUnwrap(all(controller.view).compactMap { $0 as? UITableView }.first)
        controller.tableView(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(played, [["2", "3", "4"]])
    }
}

/// Counts catalog requests; can hold responses so in-flight UI state can be observed.
final class OfflineCountingURLProtocol: URLProtocol {
    static var requests = 0
    static var body = "{}"
    static var holdResponses = false
    private static var held: [OfflineCountingURLProtocol] = []

    static func reset() { requests = 0; body = "{}"; holdResponses = false; held = [] }
    static func release() { holdResponses = false; let waiting = held; held = []; waiting.forEach { $0.respond() } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.main.async {
            Self.requests += 1
            if Self.holdResponses { Self.held.append(self) } else { self.respond() }
        }
    }
    private func respond() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
