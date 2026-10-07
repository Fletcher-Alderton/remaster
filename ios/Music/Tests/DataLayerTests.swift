import XCTest
import UIKit
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

private final class QobuzCatalogURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class UnexpectedArtworkURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "artwork-regression.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Detail artwork should be loaded from the size-specific cache, not requested: \(request.url?.absoluteString ?? "")")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

// Requests remain pending until a test explicitly completes them. This lets us
// exercise reuse and same-ID/new-URL races without timing-dependent sleeps.
private final class ControlledArtworkURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var pending: [URL: [ControlledArtworkURLProtocol]] = [:]
    private static var requests: [URL] = []

    static var requestedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static func hasPending(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !(pending[url] ?? []).isEmpty
    }

    static func complete(_ url: URL, data: Data) {
        lock.lock()
        let protocols = pending.removeValue(forKey: url) ?? []
        lock.unlock()
        XCTAssertFalse(protocols.isEmpty, "Expected an intercepted artwork request")
        for item in protocols {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!
            item.client?.urlProtocol(item, didReceive: response, cacheStoragePolicy: .notAllowed)
            item.client?.urlProtocol(item, didLoad: data)
            item.client?.urlProtocolDidFinishLoading(item)
        }
    }

    static func reset() {
        lock.lock()
        let protocols = pending.values.flatMap { $0 }
        pending.removeAll()
        requests.removeAll()
        lock.unlock()
        for item in protocols { item.client?.urlProtocol(item, didFailWithError: URLError(.cancelled)) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "artwork-regression.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.requests.append(url)
        Self.pending[url, default: []].append(self)
        Self.lock.unlock()
    }
    override func stopLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.pending[url]?.removeAll { $0 === self }
        Self.lock.unlock()
    }
}

private final class StubPresentationPlayback: PlaybackControlling {
    private(set) var queueState = QueueState()
    var onStateChange: ((QueueState) -> Void)?
    private(set) var selections: [Int] = []

    func emit(_ state: QueueState) {
        queueState = state
        onStateChange?(state)
    }
    func setQueue(trackIDs: [String], startingAt index: Int) {
        selections.append(index)
        emit(QueueState(trackIDs: trackIDs, currentIndex: index))
    }
    func enqueue(trackID: String) {
        var state = queueState; state.trackIDs.append(trackID); emit(state)
    }
    func playNext(trackID: String) {
        var state = queueState; state.trackIDs.insert(trackID, at: min(state.currentIndex + 1, state.trackIDs.count)); emit(state)
    }
    func togglePlayPause() { queueState.isPlaying ? pause() : play() }
    func play() { var state = queueState; state.isPlaying = true; emit(state) }
    func pause() { var state = queueState; state.isPlaying = false; emit(state) }
    func seek(to elapsed: TimeInterval) { var state = queueState; state.elapsed = elapsed; emit(state) }
    func next() { var state = queueState; state.currentIndex += 1; emit(state) }
    func previous() { var state = queueState; state.currentIndex = max(0, state.currentIndex - 1); emit(state) }
    func setShuffled(_ shuffled: Bool) { var state = queueState; state.isShuffled = shuffled; emit(state) }
    func clearQueue() { emit(QueueState()) }
}

// Deterministic input for the real UIKit long-press handler, without sleeps or
// touching a simulator. Locations are expressed in the handler's target view.
private final class TestAlbumLongPressRecognizer: UILongPressGestureRecognizer {
    var simulatedState: UIGestureRecognizer.State = .began
    var simulatedLocation = CGPoint.zero
    override var state: UIGestureRecognizer.State {
        get { simulatedState }
        set { simulatedState = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { simulatedLocation }
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

    func testQobuzCatalogHTTPErrorIncludesEndpointAndServerMessage() {
        let response = Data(#"{"message":"Invalid type parameter"}"#.utf8)
        let error = QobuzStreamingError.catalogRequestFailure(
            path: "album/getFeatured",
            statusCode: 400,
            responseData: response
        )

        XCTAssertEqual(
            error.localizedDescription,
            "Qobuz catalog request to album/getFeatured failed (HTTP 400): Invalid type parameter"
        )
    }

    func testQobuzCatalogHTTPErrorFallsBackWithoutResponseMessage() {
        let error = QobuzStreamingError.catalogRequestFailure(
            path: "artist/get",
            statusCode: 400,
            responseData: Data("not-json".utf8)
        )

        XCTAssertEqual(
            error.localizedDescription,
            "Qobuz catalog request to artist/get failed (HTTP 400)."
        )
    }

    func testQobuzTrackSearchDecodesResults() throws {
        let json = Data(#"{"tracks":{"items":[{"id":12345,"title":"Example Song","duration":210,"performer":{"name":"Example Artist"},"album":{"title":"Example Album"}}]}}"#.utf8)
        let response = try JSONDecoder().decode(QobuzTrackSearchResponse.self, from: json)
        XCTAssertEqual(response.tracks.items.count, 1)
        XCTAssertEqual(response.tracks.items[0].id, 12345)
        XCTAssertEqual(response.tracks.items[0].subtitle, "Example Artist • Example Album")
    }

    func testQobuzDiscoveryIndexDecodesEditorialAlbumsPlaylistsAndTags() throws {
        let json = Data(#"{"containers":{"new_releases":{"data":{"items":[{"id":"album-1","title":"Morning Light","artists":[{"id":42,"name":"Ada Rivers"}],"image":{"large":"https://img.example/album.jpg"},"duration":220,"dates":{"original":"2025-06-01"}}]}},"qobuzissims":{"data":{"items":[]}},"playlists":{"data":{"items":[{"id":77,"name":"Focus Mix","description":"Quiet listening","owner":{"id":6,"name":"Qobuz"},"image":{"rectangle":"https://img.example/playlist.jpg","covers":[]},"tracks_count":18,"duration":3000}]}},"playlists_tags":{"data":{"items":[{"slug":"focus","name":"Focus"}]}}}}"#.utf8)
        let response = try JSONDecoder().decode(QobuzCatalogDiscoveryResponse.self, from: json)
        let containers = try XCTUnwrap(response.containers)
        let album = try XCTUnwrap(containers.newReleases?.data?.items.first)
        let playlist = try XCTUnwrap(containers.playlists?.data?.items.first)
        let tag = try XCTUnwrap(containers.playlistsTags?.data?.items.first)

        XCTAssertEqual(album.id, "album-1")
        XCTAssertEqual(album.primaryArtist?.id, "42")
        XCTAssertEqual(album.year, "2025")
        XCTAssertEqual(album.artworkURL?.absoluteString, "https://img.example/album.jpg")
        XCTAssertEqual(playlist.id, "77")
        XCTAssertEqual(playlist.name, "Focus Mix")
        XCTAssertEqual(playlist.artworkURL?.absoluteString, "https://img.example/playlist.jpg")
        XCTAssertEqual(playlist.tracksCount, 18)
        XCTAssertEqual(tag.slug, "focus")
    }

    func testQobuzDiscoveryGenreAndPlaylistPagesDecodePagination() throws {
        let genreJSON = Data(#"{"genres":{"items":[{"id":7,"name":"Jazz","slug":"jazz","color":"blue"}]}}"#.utf8)
        let genres = try JSONDecoder().decode(QobuzCatalogGenreListResponse.self, from: genreJSON)
        XCTAssertEqual(genres.genres?.items.first?.id, "7")
        XCTAssertEqual(genres.genres?.items.first?.name, "Jazz")

        let playlistJSON = Data(#"{"items":[{"id":77,"name":"Focus Mix","tracks_count":18}],"total":41,"offset":20,"limit":20}"#.utf8)
        let playlists = try JSONDecoder().decode(QobuzCatalogPlaylistsResponse.self, from: playlistJSON)
        XCTAssertEqual(playlists.items.map(\.id), ["77"])
        XCTAssertEqual(playlists.total, 41)
        XCTAssertEqual(playlists.offset, 20)
        XCTAssertEqual(playlists.limit, 20)
    }

    func testQobuzFeaturedArtistsAreDerivedAndDeduplicatedFromFeaturedAlbums() throws {
        let json = Data(#"{"albums":{"items":[{"id":"1","title":"First","artist":{"id":"42","name":"Alpha"}},{"id":"2","title":"Second","artist":{"id":42,"name":"Alpha"}},{"id":"3","title":"Third","artist":{"id":"7","name":"Beta"}}],"total":3}}"#.utf8)
        let response = try JSONDecoder().decode(QobuzCatalogFeaturedResponse.self, from: json)
        let artists = try XCTUnwrap(QobuzCatalogMapper.featuredArtists(from: response.albums))

        XCTAssertEqual(artists.items.map(\.id), ["42", "7"])
        XCTAssertEqual(artists.items.map(\.name), ["Alpha", "Beta"])
        XCTAssertEqual(artists.total, 2)
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

    func testQobuzAlbumTrackNavigationKeepsPerformerSeparateFromPrimaryArtist() throws {
        let json = Data(#"{"id":"compilation","title":"Compilation","artist":{"id":42,"name":"Album Artist"},"tracks":{"items":[{"id":701,"title":"Guest Song","performer":{"id":99,"name":"Guest Artist"}},{"id":702,"title":"Album Song"}]}}"#.utf8)
        let album = try JSONDecoder().decode(QobuzCatalogAlbum.self, from: json)
        let mapped = QobuzCatalogMapper.album(album)

        XCTAssertEqual(mapped.artist, "Album Artist")
        XCTAssertEqual(mapped.tracks.map(\.artist), ["Guest Artist", "Album Artist"])
        XCTAssertEqual(mapped.tracks.map(\.catalogArtistID), ["99", "42"])
        XCTAssertEqual(mapped.tracks.map(\.catalogAlbumID), ["compilation", "compilation"])
    }

    func testQobuzArtistPageAndReleaseResponsesMapToProfile() throws {
        let pageJSON = Data(#"{"id":42,"name":{"display":"Ada Rivers"},"images":{"portrait":{"hash":"portrait-hash","format":"jpg"}},"biography":{"content":"Artist biography"},"top_tracks":[]}"#.utf8)
        let page = try JSONDecoder().decode(QobuzCatalogArtistPage.self, from: pageJSON)
        let releasesJSON = Data(#"{"items":[{"id":"release-1","title":"First Light","artists":[{"id":42,"name":"Ada Rivers"}],"image":{"large":"https://img.example/release.jpg"},"dates":{"original":"2023-01-01"}}],"total":1}"#.utf8)
        let releases = try JSONDecoder().decode(QobuzCatalogPage<QobuzCatalogDiscoveryAlbum>.self, from: releasesJSON)
        let profile = QobuzCatalogMapper.profile(QobuzCatalogMapper.artistPage(page, releases: releases))

        XCTAssertEqual(page.portraitURL?.absoluteString, "https://static.qobuz.com/images/artists/covers/large/portrait-hash.jpg")
        XCTAssertEqual(profile.id, "42")
        XCTAssertEqual(profile.name, "Ada Rivers")
        XCTAssertEqual(profile.information, "Artist biography")
        XCTAssertEqual(profile.albums.map(\.id), ["release-1"])
    }

    func testQobuzArtistDetailFixtureDecodesBiographyAndAlbums() throws {
        let artist = try JSONDecoder().decode(QobuzCatalogArtist.self, from: qobuzFixture(named: "qobuz-artist-detail"))
        let mapped = QobuzCatalogMapper.profile(artist)

        XCTAssertEqual(mapped.id, "42")
        XCTAssertEqual(mapped.subtitle, "1 albums")
        XCTAssertEqual(mapped.information, "A fixture biography.")
        XCTAssertEqual(mapped.albums.map(\.id), ["123456"])
    }

    func testQobuzFavoritesDecodeAllSavedGroupsAndArtwork() throws {
        let json = Data(#"{"albums":{"items":[{"id":"saved-album","title":"Saved Album","artist":{"id":42,"name":"Ada Rivers"},"image":{"medium":"https://img.example/album-medium.jpg"}}],"total":1,"limit":1000,"offset":0},"artists":{"items":[{"id":42,"name":"Ada Rivers","image":{"large":"//img.example/artist.jpg"}}],"total":1,"limit":1000,"offset":0},"tracks":{"items":[{"id":"77","title":"Saved Track","performer":{"id":42,"name":"Ada Rivers"},"album":{"id":"saved-album","title":"Saved Album","image":{"extralarge":"https://img.example/cover.jpg"}},"streamable":true}],"total":1,"limit":1000,"offset":0}}"#.utf8)
        let response = try JSONDecoder().decode(QobuzCatalogLibraryResponse.self, from: json)
        XCTAssertEqual(response.albums?.items.map(\.id), ["saved-album"])
        XCTAssertEqual(response.artists?.items.map(\.id), ["42"])
        XCTAssertEqual(response.tracks?.items.map(\.id), [77])
        XCTAssertEqual(response.tracks?.total, 1)
        XCTAssertEqual(response.tracks?.limit, 1000)
        XCTAssertEqual(response.tracks?.offset, 0)
        XCTAssertEqual(response.albums?.items.first?.artworkURL?.absoluteString, "https://img.example/album-medium.jpg")
        XCTAssertEqual(response.artists?.items.first?.artworkURL?.absoluteString, "https://img.example/artist.jpg")
        XCTAssertEqual(response.tracks?.items.first?.album?.imageURL?.absoluteString, "https://img.example/cover.jpg")
    }

    func testQobuzMalformedCatalogPageDoesNotBecomeEmptySuccess() {
        let malformed = Data(#"{"items":[{"id":"broken","artists":[{"id":42,"name":{"unexpected":"shape"}}]}],"has_more":false}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(QobuzCatalogPage<QobuzCatalogDiscoveryAlbum>.self, from: malformed))
        let malformedFavorites = Data(#"{"albums":{"items":[{"id":1}],"total":1}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(QobuzCatalogLibraryResponse.self, from: malformedFavorites))
    }

    func testQobuzModernArtistTopTracksMapNamesRightsAndAlbumArtwork() throws {
        let page = try JSONDecoder().decode(QobuzCatalogArtistPage.self, from: modernArtistPageFixture)
        let profile = QobuzCatalogMapper.profile(QobuzCatalogMapper.artistPage(page, releases: nil))
        XCTAssertEqual(page.topTracks.count, 2)
        XCTAssertEqual(page.topTracks.first?.streamable, true)
        XCTAssertEqual(page.topTracks.last?.streamable, false)
        XCTAssertEqual(profile.tracks.map(\.id), ["701"])
        XCTAssertEqual(profile.tracks.first?.artist, "Ada Rivers")
        XCTAssertEqual(profile.tracks.first?.catalogArtistID, "42")
        XCTAssertEqual(profile.tracks.first?.catalogAlbumID, "top-album")
        XCTAssertEqual(profile.tracks.first?.artworkURL?.absoluteString, "https://img.example/top-cover.jpg")
        XCTAssertEqual(profile.tracks.first?.duration, 215)
        XCTAssertEqual(profile.subtitle, "Artist on Qobuz")
        XCTAssertEqual(profile.information, "Biography still works")
    }

    func testQobuzArtistPortraitFallbackAndUnknownAlbumCount() throws {
        let direct = Data(#"{"id":42,"name":"Ada Rivers","images":{"portrait":{"hash":"","format":""}},"image":{"large":"https://img.example/direct-portrait.jpg"}}"#.utf8)
        let directPage = try JSONDecoder().decode(QobuzCatalogArtistPage.self, from: direct)
        XCTAssertEqual(directPage.portraitURL?.absoluteString, "https://img.example/direct-portrait.jpg")
        let missing = Data(#"{"id":42,"name":{"display":"Ada Rivers"},"images":{"portrait":{"hash":"bad/path","format":"jpg"}}}"#.utf8)
        let missingPage = try JSONDecoder().decode(QobuzCatalogArtistPage.self, from: missing)
        XCTAssertNil(missingPage.portraitURL)
        let mapped = QobuzCatalogMapper.artistPage(missingPage, releases: nil)
        XCTAssertNil(mapped.albumsCount)
        XCTAssertEqual(QobuzCatalogMapper.profile(mapped).subtitle, "Artist on Qobuz")
        let empty = QobuzCatalogMapper.artistPage(missingPage, releases: QobuzCatalogPage(items: [], total: 0))
        XCTAssertEqual(QobuzCatalogMapper.profile(empty).subtitle, "0 albums")
    }

    func testQobuzArtworkUsesSecureVariantAndSupportsLegacyImageSpelling() throws {
        let variants = ["extralarge", "extraLarge", "extaLarge"]
        for key in variants {
            let json = "{\"id\":8,\"title\":\"Track\",\"album\":{\"title\":\"Album\",\"image\":{\"\(key)\":\"https://img.example/large.jpg\",\"large\":\"http://img.example/legacy.jpg\"}}}"
            let track = try JSONDecoder().decode(QobuzSearchTrack.self, from: Data(json.utf8))
            XCTAssertEqual(track.album?.imageURL?.absoluteString, "https://img.example/large.jpg")
        }
        XCTAssertEqual(["https:///missing-host", "http://img.example/fallback.jpg"].map(Optional.some).catalogArtworkURL?.absoluteString, "https://img.example/fallback.jpg")
        XCTAssertNil(["file:///private/image.jpg", ""].map(Optional.some).catalogArtworkURL)
    }

    func testQobuzSavedLibraryRequestsAuthenticatedFavoritesAndPaginatesEveryGroup() throws {
        var requestedOffsets: [Int] = []
        let session = catalogTestSession { request in
            XCTAssertEqual(request.url?.path, "/api.json/0.2/favorite/getUserFavorites")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-App-Id"), "test-app-id")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-User-Auth-Token"), "test-token")
            let query = self.queryValues(request)
            XCTAssertEqual(query["limit"], "1000")
            let offset = Int(query["offset"] ?? "") ?? -1
            requestedOffsets.append(offset)
            func page(total: Int, cap: Int, makeItem: (Int) -> [String: Any]) -> [String: Any] {
                let end = min(total, offset + cap)
                let items = offset < end ? (offset..<end).map(makeItem) : []
                return ["items": items, "total": total, "offset": offset, "limit": cap]
            }
            let response: [String: Any] = [
                "albums": page(total: 4, cap: 2) { ["id": "album-\($0)", "title": "Album \($0)"] },
                "artists": page(total: 3, cap: 1) { ["id": $0 + 10, "name": "Artist \($0)"] },
                "tracks": page(total: 2, cap: 1) { ["id": $0 + 100, "title": "Track \($0)"] }
            ]
            return (200, try JSONSerialization.data(withJSONObject: response))
        }
        defer { session.invalidateAndCancel(); QobuzCatalogURLProtocol.handler = nil }
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "test-token", userID: 1), session: session, catalogAppID: "test-app-id")
        let loaded = expectation(description: "all favorites loaded")
        var result: Result<QobuzCatalogLibraryResponse, Error>?
        client.library { result = $0; loaded.fulfill() }
        wait(for: [loaded], timeout: 3)
        let response = try XCTUnwrap(result).get()
        XCTAssertEqual(requestedOffsets, [0, 1, 2])
        XCTAssertEqual(response.albums?.items.map(\.id), ["album-0", "album-1", "album-2", "album-3"])
        XCTAssertEqual(response.artists?.items.map(\.id), ["10", "11", "12"])
        XCTAssertEqual(response.tracks?.items.map(\.id), [100, 101])
        XCTAssertEqual(response.albums?.total, 4)
    }

    func testQobuzSavedLibraryFailsInsteadOfTruncatingRepeatedPages() {
        var count = 0
        let session = catalogTestSession { _ in
            count += 1
            return (200, Data(#"{"albums":{"items":[{"id":"one","title":"Album"}],"total":2,"limit":1}}"#.utf8))
        }
        defer { session.invalidateAndCancel(); QobuzCatalogURLProtocol.handler = nil }
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "test-token", userID: 1), session: session, catalogAppID: "test-app-id")
        let loaded = expectation(description: "incomplete favorites fail")
        client.library { result in
            guard case .failure = result else { XCTFail("Repeated page must not look like a complete library"); loaded.fulfill(); return }
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 3)
        XCTAssertEqual(count, 2)
    }

    func testQobuzSavedLibraryRejectsEmptyCredentialsWithoutNetwork() {
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "", userID: 0), catalogAppID: "test-app-id")
        client.library { result in
            guard case .failure(let error) = result else { return XCTFail("Expected authentication failure") }
            XCTAssertEqual(error.localizedDescription, QobuzStreamingError.notAuthenticated.localizedDescription)
        }
    }

    func testQobuzArtistLoadsHasMorePagesAndAllReleaseCategories() throws {
        var releaseRequests: [String] = []
        let session = catalogTestSession { request in
            let query = self.queryValues(request)
            if request.url?.path.hasSuffix("artist/page") == true {
                XCTAssertEqual(query["sort"], "relevant")
                XCTAssertEqual(query["app_id"], "test-app-id")
                return (200, self.modernArtistPageFixture)
            }
            XCTAssertEqual(request.url?.path, "/api.json/0.2/artist/getReleasesList")
            XCTAssertEqual(query["sort"], "release_date")
            XCTAssertEqual(query["limit"], "100")
            XCTAssertEqual(query["track_size"], "1")
            let category = query["release_type"] ?? ""
            let offset = query["offset"] ?? ""
            releaseRequests.append("\(category):\(offset)")
            let more = category == "album" && offset == "0"
            let id = category + offset
            let response: [String: Any] = ["has_more": more, "items": [["id": id, "title": id, "artists": [["id": 42, "name": "Ada Rivers"]], "image": ["large": "https://img.example/release.jpg"], "dates": ["original": "2024-04-05"]]]]
            return (200, try JSONSerialization.data(withJSONObject: response))
        }
        defer { session.invalidateAndCancel(); QobuzCatalogURLProtocol.handler = nil }
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "test-token", userID: 1), session: session, catalogAppID: "test-app-id")
        let loaded = expectation(description: "artist releases loaded")
        var result: Result<QobuzCatalogArtist, Error>?
        client.artist(id: "42") { result = $0; loaded.fulfill() }
        wait(for: [loaded], timeout: 3)
        let artist = try XCTUnwrap(result).get()
        XCTAssertEqual(releaseRequests, ["album:0", "album:1", "epSingle:0", "live:0", "compilation:0"])
        XCTAssertEqual(artist.albums?.items.map(\.id), ["album0", "album1", "epSingle0", "live0", "compilation0"])
        XCTAssertEqual(artist.albumsCount, 5)
        XCTAssertNil(artist.releasesError)
        XCTAssertEqual(QobuzCatalogMapper.profile(artist).tracks.map(\.id), ["701"])
    }

    func testQobuzArtistPartialReleaseFailurePreservesProfileAndTopTracks() throws {
        let session = catalogTestSession { request in
            if request.url?.path.hasSuffix("artist/page") == true { return (200, self.modernArtistPageFixture) }
            let query = self.queryValues(request)
            if query["release_type"] == "album" {
                if query["offset"] == "0" {
                    return (200, Data(#"{"has_more":true,"items":[{"id":"first-page","title":"First Page"}]}"#.utf8))
                }
                return (500, Data(#"{"message":"Unavailable"}"#.utf8))
            }
            if query["release_type"] == "live" {
                return (200, Data(#"{"has_more":false,"items":[{"id":"broken-release"}]}"#.utf8))
            }
            return (200, Data(#"{"has_more":false,"items":[]}"#.utf8))
        }
        defer { session.invalidateAndCancel(); QobuzCatalogURLProtocol.handler = nil }
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "test-token", userID: 1), session: session, catalogAppID: "test-app-id")
        let loaded = expectation(description: "partial artist loads")
        var result: Result<QobuzCatalogArtist, Error>?
        client.artist(id: "42") { result = $0; loaded.fulfill() }
        wait(for: [loaded], timeout: 3)
        let artist = try XCTUnwrap(result).get()
        let profile = QobuzCatalogMapper.profile(artist)
        XCTAssertEqual(artist.albums?.items.map(\.id), ["first-page"])
        XCTAssertNil(artist.albumsCount)
        XCTAssertTrue(artist.releasesError?.contains("album, live") == true)
        XCTAssertEqual(profile.tracks.map(\.id), ["701"])
        XCTAssertEqual(profile.information, "Biography still works")
        XCTAssertEqual(profile.artworkURL?.absoluteString, "https://static.qobuz.com/images/artists/covers/large/portrait-hash.jpg")
        XCTAssertEqual(profile.subtitle, "Artist on Qobuz • Releases incomplete")
    }

    private var modernArtistPageFixture: Data {
        Data(#"{"id":42,"name":{"display":"Ada Rivers"},"images":{"portrait":{"hash":"portrait-hash","format":"jpg"}},"biography":{"content":"Biography still works"},"top_tracks":[{"id":701,"title":"Top Song","artist":{"id":42,"name":{"display":"Ada Rivers"}},"duration":215,"rights":{"streamable":true,"hires_streamable":true},"album":{"id":"top-album","title":"Top Album","image":{"large":"https://img.example/top-cover.jpg"}},"physical_support":{"media_number":1,"track_number":1}},{"id":702,"title":"Unavailable Song","artist":{"id":42,"name":{"display":"Ada Rivers"}},"rights":{"streamable":false,"hires_streamable":false},"album":{"id":"top-album","title":"Top Album"}}]}"#.utf8)
    }

    private func catalogTestSession(handler: @escaping (URLRequest) throws -> (Int, Data)) -> URLSession {
        QobuzCatalogURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QobuzCatalogURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func queryValues(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
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


    func testSavedLibraryModesRequestFavoritesAndFilterLocally() throws {
        // No artwork URLs: laying out visible rows cannot trigger image requests.
        let response = Data(#"{"albums":{"items":[{"id":"a1","title":"Café Sessions","artist":{"id":42,"name":"Ada Rivers"},"release_date_original":"2024-04-05"},{"id":"a2","title":"Nightfall","artist":{"id":43,"name":"Other Artist"}}],"total":2},"artists":{"items":[{"id":42,"name":"Café Artist"},{"id":43,"name":"Other Artist"}],"total":2},"tracks":{"items":[{"id":701,"title":"Café Song","performer":{"id":42,"name":"Ada Rivers"},"album":{"id":"a1","title":"Café Sessions"}},{"id":702,"title":"Night Song","performer":{"id":43,"name":"Other Artist"},"album":{"id":"a2","title":"Nightfall"}}],"total":2}}"#.utf8)
        let lock = NSLock()
        var requestedPaths: [String] = []
        let session = catalogTestSession { request in
            let path = request.url?.path ?? ""
            lock.lock(); requestedPaths.append(path); lock.unlock()
            XCTAssertEqual(path, "/api.json/0.2/favorite/getUserFavorites", "Saved tabs must never request featured items or catalog search")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-App-Id"), "test-app-id")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-User-Auth-Token"), "test-token")
            return (200, response)
        }
        defer { session.invalidateAndCancel(); QobuzCatalogURLProtocol.handler = nil }
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "test-token", userID: 1), session: session, catalogAppID: "test-app-id")
        let cases: [(QobuzCatalogViewController.Mode, String, String)] = [(.albums, "Café Sessions", "Nightfall"), (.artists, "Café Artist", "Other Artist"), (.tracks, "Café Song", "Night Song")]
        for (index, testCase) in cases.enumerated() {
            let controller = QobuzCatalogViewController(mode: testCase.0, client: client)
            layout(controller, size: CGSize(width: 320, height: 568))
            let table = descendants(of: controller.view).compactMap { $0 as? UITableView }.first
            let collection = descendants(of: controller.view).compactMap { $0 as? UICollectionView }.first
            if testCase.0 == .albums {
                XCTAssertNotNil(collection, "Saved albums must be a collection grid, not table rows")
                XCTAssertNil(table)
            } else {
                XCTAssertNotNil(table)
                XCTAssertNil(collection)
            }
            func itemCount() -> Int { collection?.numberOfItems(inSection: 0) ?? table?.numberOfRows(inSection: 0) ?? -1 }
            func firstItem() -> UIView? {
                collection?.layoutIfNeeded(); table?.layoutIfNeeded()
                if let collection = collection { return collection.cellForItem(at: IndexPath(item: 0, section: 0)) }
                return table?.cellForRow(at: IndexPath(row: 0, section: 0))
            }
            func assertFirstTitle(_ expected: String, file: StaticString = #filePath, line: UInt = #line) throws {
                let cell = try XCTUnwrap(firstItem(), file: file, line: line)
                XCTAssertTrue(descendants(of: cell).compactMap { $0 as? UILabel }.contains { $0.text == expected }, "Expected displayed title: \(expected)", file: file, line: line)
            }
            let search = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? UISearchBar }.first)
            let tools = try XCTUnwrap(descendants(of: controller.view).first { $0.accessibilityIdentifier == "qobuz.library.tools" })
            let sort = try XCTUnwrap(descendants(of: tools).compactMap { $0 as? UISegmentedControl }.first)
            let refresh = try XCTUnwrap(descendants(of: tools).first { $0.accessibilityIdentifier == "qobuz.library.refresh" } as? UIButton)
            waitForMainCondition("saved library items load") { itemCount() == 2 }
            XCTAssertNil(table?.refreshControl, "Pull-down reveals tools; refresh is an explicit button")
            XCTAssertNil(collection?.refreshControl)
            XCTAssertEqual(tools.bounds.height, 0, accuracy: 0.5)
            XCTAssertEqual(sort.accessibilityIdentifier, "qobuz.library.sort")
            XCTAssertEqual((0..<sort.numberOfSegments).compactMap { sort.titleForSegment(at: $0) }, ["All", "A–Z", "Z–A"])
            XCTAssertEqual(sort.selectedSegmentIndex, 0)
            XCTAssertTrue(search.placeholder?.hasPrefix("Search saved ") == true)
            controller.setLibraryToolsVisible(true, animated: false)
            XCTAssertGreaterThan(tools.bounds.height, 0)
            search.text = "  CAFE  "
            controller.searchBar(search, textDidChange: search.text!)
            XCTAssertEqual(itemCount(), 1)
            try assertFirstTitle(testCase.1)
            controller.searchBarSearchButtonClicked(search)
            XCTAssertEqual(itemCount(), 1)
            if testCase.0 != .artists {
                search.text = "ADA RIVERS"
                controller.searchBar(search, textDidChange: "ADA RIVERS")
                XCTAssertEqual(itemCount(), 1, "Local filtering must also match the saved artist name")
                try assertFirstTitle(testCase.1)
            }
            controller.setLibraryToolsVisible(false, animated: false)
            XCTAssertEqual(tools.bounds.height, 0, accuracy: 0.5)
            XCTAssertEqual(itemCount(), 1, "Hiding tools must not reset a saved-library filter")
            controller.setLibraryToolsVisible(true, animated: false)
            search.text = "not in this saved library"
            controller.searchBar(search, textDidChange: search.text!)
            XCTAssertEqual(itemCount(), 0)
            search.text = ""
            controller.searchBar(search, textDidChange: "")
            XCTAssertEqual(itemCount(), 2)
            for segment in [1, 2, 0] {
                sort.selectedSegmentIndex = segment
                sort.sendActions(for: .valueChanged)
                XCTAssertEqual(itemCount(), 2)
                try assertFirstTitle(segment == 2 ? testCase.2 : testCase.1)
            }
            drainMainQueue()
            lock.lock(); let paths = requestedPaths; lock.unlock()
            XCTAssertEqual(paths, Array(repeating: "/api.json/0.2/favorite/getUserFavorites", count: index * 2 + 1), "Typing, submitting, clearing, sorting, and revealing tools must not make requests")
            search.text = "CAFE"
            controller.searchBar(search, textDidChange: "CAFE")
            sort.selectedSegmentIndex = 2
            sort.sendActions(for: .valueChanged)
            let status = try XCTUnwrap(descendants(of: controller.view).first { $0.accessibilityIdentifier?.hasSuffix(".status") == true } as? UILabel)
            refresh.sendActions(for: .touchUpInside)
            waitForMainCondition("explicit refresh completes") {
                lock.lock(); let count = requestedPaths.count; lock.unlock()
                return count == index * 2 + 2 && refresh.isEnabled && status.text?.hasPrefix("1 saved ") == true
            }
            XCTAssertEqual(itemCount(), 1)
            XCTAssertEqual(search.text, "CAFE", "Explicit refresh must preserve the local query")
            XCTAssertEqual(sort.selectedSegmentIndex, 2, "Explicit refresh must preserve the local sort")
            try assertFirstTitle(testCase.1)
            lock.lock(); let refreshedPaths = requestedPaths; lock.unlock()
            XCTAssertEqual(refreshedPaths, Array(repeating: "/api.json/0.2/favorite/getUserFavorites", count: index * 2 + 2), "Only explicit refresh adds one authenticated favorites request")
        }
    }

    func testSavedTracksSelectionCallsBackWithTheFilteredTrack() throws {
        let session = catalogTestSession { request in
            XCTAssertEqual(request.url?.path, "/api.json/0.2/favorite/getUserFavorites")
            return (200, Data(#"{"tracks":{"items":[{"id":701,"title":"First Song","performer":{"id":42,"name":"Ada Rivers"},"album":{"id":"first-album","title":"First Album"}},{"id":702,"title":"Chosen Song","performer":{"id":43,"name":"Other Artist"},"album":{"id":"chosen-album","title":"Chosen Album"},"duration":215}],"total":2}}"#.utf8))
        }
        defer { session.invalidateAndCancel(); QobuzCatalogURLProtocol.handler = nil }
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "test-token", userID: 1), session: session, catalogAppID: "test-app-id")
        let controller = QobuzCatalogViewController(mode: .tracks, client: client)
        var selected: [ScreenTrack] = []
        controller.onTrackSelected = { selected.append($0) }
        layout(controller, size: CGSize(width: 375, height: 667))
        let table = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
        let search = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? UISearchBar }.first)
        waitForMainCondition("saved tracks load") { table.numberOfRows(inSection: 0) == 2 }
        search.text = "Chosen Album"
        controller.searchBar(search, textDidChange: "Chosen Album")
        XCTAssertEqual(table.numberOfRows(inSection: 0), 1)
        controller.tableView(table, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(selected.map(\.id), ["702"])
        XCTAssertEqual(selected.first?.title, "Chosen Song")
        XCTAssertEqual(selected.first?.artist, "Other Artist")
        XCTAssertEqual(selected.first?.catalogAlbumID, "chosen-album")
        XCTAssertEqual(selected.first?.catalogArtistID, "43")
        XCTAssertEqual(selected.first?.duration, 215)
    }

    // Deliberately unsorted, with a nonmatching track between saved matches.
    private var savedTrackInteractionFixture: Data {
        Data(#"{"tracks":{"items":[{"id":701,"title":"Cedar Song","performer":{"id":42,"name":"Ada Rivers"},"album":{"id":"keep","title":"Keep Album"}},{"id":702,"title":"Zulu Song","performer":{"id":42,"name":"Ada Rivers"},"album":{"id":"keep","title":"Keep Album"}},{"id":703,"title":"Hidden Song","performer":{"id":43,"name":"Other Artist"},"album":{"id":"other","title":"Other Album"}},{"id":704,"title":"Alpha Song","performer":{"id":42,"name":"Ada Rivers"},"album":{"id":"keep","title":"Keep Album"}},{"id":705,"title":"Echo Song","performer":{"id":42,"name":"Ada Rivers"},"album":{"id":"keep","title":"Keep Album"}}],"total":5}}"#.utf8)
    }

    func testSavedTrackSelectionQueuesOnlyTheFilteredSortedSuffix() throws {
        let lock = NSLock()
        var requestCount = 0
        let session = catalogTestSession { request in
            XCTAssertEqual(request.url?.path, "/api.json/0.2/favorite/getUserFavorites")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-App-Id"), "test-app-id")
            lock.lock(); requestCount += 1; lock.unlock()
            return (200, self.savedTrackInteractionFixture)
        }
        defer { session.invalidateAndCancel(); QobuzCatalogURLProtocol.handler = nil }
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "test-token", userID: 1), session: session, catalogAppID: "test-app-id")
        let controller = QobuzCatalogViewController(mode: .tracks, client: client)
        var selections: [[String]] = []
        var fallbackSelections: [String] = []
        controller.onTracksSelected = { selections.append($0.map(\.id)) }
        controller.onTrackSelected = { fallbackSelections.append($0.id) }
        layout(controller, size: CGSize(width: 375, height: 667))
        let table = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? UITableView }.first)
        let search = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? UISearchBar }.first)
        let sort = try XCTUnwrap(descendants(of: controller.view).first { $0.accessibilityIdentifier == "qobuz.library.sort" } as? UISegmentedControl)
        waitForMainCondition("saved tracks load") { table.numberOfRows(inSection: 0) == 5 }
        controller.setLibraryToolsVisible(true, animated: false)
        search.text = "  KEEP ALBUM  "
        controller.searchBar(search, textDidChange: search.text!)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 4)
        controller.tableView(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(selections, [["702", "704", "705"]], "Do not queue preceding saved matches or tracks excluded by the filter")
        sort.selectedSegmentIndex = 1
        sort.sendActions(for: .valueChanged)
        controller.tableView(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(selections.last, ["701", "705", "702"], "A–Z selection must use displayed order, not original favorites order")
        sort.selectedSegmentIndex = 2
        sort.sendActions(for: .valueChanged)
        controller.tableView(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(selections.last, ["705", "701", "704"], "Z–A selection must use displayed order")
        controller.tableView(table, didSelectRowAt: IndexPath(row: 3, section: 0))
        XCTAssertEqual(selections.last, ["704"], "The final row queues exactly itself")
        sort.selectedSegmentIndex = 0
        sort.sendActions(for: .valueChanged)
        controller.tableView(table, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(selections.last, ["702", "704", "705"], "All restores saved order")
        XCTAssertTrue(fallbackSelections.isEmpty, "The single-track callback is only a fallback, not a second playback request")
        drainMainQueue()
        lock.lock(); let count = requestCount; lock.unlock()
        XCTAssertEqual(count, 1, "Filter, sort, and selection are local operations")
    }

    func testSavedTrackRowsUseHistoricalLayoutAndRouteSwipeAndLongPressActions() throws {
        let session = catalogTestSession { request in
            XCTAssertEqual(request.url?.path, "/api.json/0.2/favorite/getUserFavorites")
            return (200, self.savedTrackInteractionFixture)
        }
        defer { session.invalidateAndCancel(); QobuzCatalogURLProtocol.handler = nil }
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "test-token", userID: 1), session: session, catalogAppID: "test-app-id")
        let controller = QobuzCatalogViewController(mode: .tracks, client: client)
        var actions: [SongSwipeAction] = []
        var navigations: [String] = []
        controller.onSongSwipeAction = { track, action in
            XCTAssertEqual(track.id, "704", "Actions must address the displayed filtered track")
            actions.append(action)
        }
        controller.onTrackNavigationRequested = { navigations.append($0.id) }
        layout(controller, size: CGSize(width: 320, height: 568))
        let table = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? UITableView }.first)
        let search = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? UISearchBar }.first)
        waitForMainCondition("saved action tracks load") { table.numberOfRows(inSection: 0) == 5 }
        search.text = "Alpha"
        controller.searchBar(search, textDidChange: "Alpha")
        table.layoutIfNeeded()
        let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)) as? SongSwipeActionCell)
        cell.layoutIfNeeded()
        XCTAssertEqual(table.rowHeight, 78, accuracy: 0.5)
        XCTAssertEqual(cell.bounds.height, 78, accuracy: 0.5)
        let art = try XCTUnwrap(descendants(of: cell).compactMap { $0 as? ArtworkView }.first)
        XCTAssertEqual(art.bounds.width, 54, accuracy: 0.5)
        XCTAssertEqual(art.bounds.height, 54, accuracy: 0.5)
        XCTAssertEqual(art.layer.cornerRadius, DesignSystem.albumArtworkCornerRadius, accuracy: 0.5)
        let labels = descendants(of: cell).compactMap { $0 as? UILabel }
        let title = try XCTUnwrap(labels.first { $0.text == "Alpha Song" })
        let subtitle = try XCTUnwrap(labels.first { $0.text?.contains("Ada Rivers") == true && $0.text?.contains("Keep Album") == true })
        XCTAssertEqual(title.font.pointSize, 18, accuracy: 0.1)
        XCTAssertEqual(subtitle.font.pointSize, 14, accuracy: 0.1)
        XCTAssertEqual(title.font, UIFont.systemFont(ofSize: 18))
        XCTAssertEqual(art.convert(art.bounds, to: cell.contentView).minX, 8, accuracy: 0.5)
        XCTAssertEqual(title.convert(title.bounds, to: cell.contentView).minX - art.convert(art.bounds, to: cell.contentView).maxX, 14, accuracy: 0.5)
        // VoiceOver focuses the row as one element, not its implementation labels.
        assertGroupedAccessibility(cell, contains: ["Alpha Song", "Ada Rivers", "Keep Album"])
        XCTAssertEqual(cell.accessibilityCustomActions?.map(\.name) ?? [], [], "Catalog currently exposes gesture callbacks, not custom VoiceOver actions")
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667)] {
            layout(controller, size: size)
            retainVisualCapture(controller.view, name: "Saved tracks custom row \(Int(size.width))")
        }
        XCTAssertTrue((table.gestureRecognizers ?? []).contains { $0 is UIPanGestureRecognizer && $0.delegate is SongListSwipeCoordinator }, "Real track tables must install the song-swipe coordinator")
        cell.finishSwipe(translation: -cell.bounds.width * 0.10)
        XCTAssertTrue(actions.isEmpty, "A below-threshold drag must not enqueue")
        for translation in [-0.35, -0.75, 0.35, 0.75] {
            cell.updateSwipe(translation: cell.bounds.width * CGFloat(translation))
            cell.finishSwipe(translation: cell.bounds.width * CGFloat(translation))
        }
        cell.onLongPress?()
        XCTAssertEqual(actions, [.enqueue, .playNext, .toggleLike, .more])
        XCTAssertEqual(navigations, ["704"])
        XCTAssertTrue((cell.gestureRecognizers ?? []).contains { ($0 as? UILongPressGestureRecognizer)?.minimumPressDuration == 0.45 })
        cell.prepareForReuse()
        XCTAssertNil(cell.onLongPress)
        XCTAssertNil(cell.onSwipeAction)
    }

    func testSavedArtistRowsKeepHistoricalTypographyAndRoundArtwork() throws {
        let session = catalogTestSession { request in
            XCTAssertEqual(request.url?.path, "/api.json/0.2/favorite/getUserFavorites")
            return (200, Data(#"{"artists":{"items":[{"id":42,"name":"Ada Rivers","albums_count":17}],"total":1}}"#.utf8))
        }
        defer { session.invalidateAndCancel(); QobuzCatalogURLProtocol.handler = nil }
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "test-token", userID: 1), session: session, catalogAppID: "test-app-id")
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667)] {
            let controller = QobuzCatalogViewController(mode: .artists, client: client)
            var selected: [String] = []
            controller.onArtistSelected = { selected.append($0.id) }
            layout(controller, size: size)
            let table = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? UITableView }.first)
            waitForMainCondition("saved artist loads") { table.numberOfRows(inSection: 0) == 1 }
            table.layoutIfNeeded()
            let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)))
            cell.layoutIfNeeded()
            let title = try XCTUnwrap(descendants(of: cell).compactMap { $0 as? UILabel }.first { $0.text == "Ada Rivers" })
            let art = try XCTUnwrap(descendants(of: cell).compactMap { $0 as? ArtworkView }.first)
            XCTAssertEqual(cell.bounds.height, 78, accuracy: 0.5)
            XCTAssertEqual(art.bounds.width, 54, accuracy: 0.5)
            XCTAssertEqual(art.bounds.height, 54, accuracy: 0.5)
            XCTAssertEqual(art.layer.cornerRadius, 27, accuracy: 0.5)
            XCTAssertEqual(title.font.pointSize, 18, accuracy: 0.1)
            XCTAssertEqual(title.font, UIFont.systemFont(ofSize: 18))
            XCTAssertEqual(title.convert(title.bounds, to: cell.contentView).midY, cell.contentView.bounds.midY, accuracy: 0.5)
            assertGroupedAccessibility(cell, contains: ["Ada Rivers"])
            XCTAssertEqual(cell.accessibilityCustomActions?.map(\.name) ?? [], [], "Artist rows open on activation; track-specific actions must not leak through reuse")
            let visibleLabels = descendants(of: cell).compactMap { $0 as? UILabel }.filter { !$0.isHidden && !($0.text ?? "").isEmpty }
            XCTAssertEqual(visibleLabels.map(\.text), ["Ada Rivers"], "Saved artists have a single centered name, not catalog count metadata")
            XCTAssertFalse(art.hasAmbiguousLayout)
            XCTAssertFalse(title.hasAmbiguousLayout)
            XCTAssertGreaterThan(title.bounds.width, 100)
            controller.tableView(table, didSelectRowAt: IndexPath(row: 0, section: 0))
            XCTAssertEqual(selected, ["42"])
            retainVisualCapture(controller.view, name: "Saved artists custom row \(Int(size.width))")
        }
    }

    func testSavedAlbumGridUsesHistoricalTwoColumnSpacingAndSizedArtworkCache() throws {
        XCTAssertTrue(URLProtocol.registerClass(UnexpectedArtworkURLProtocol.self))
        defer { URLProtocol.unregisterClass(UnexpectedArtworkURLProtocol.self); ArtworkImagePipeline.shared.removeAll() }
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667)] {
            let url = URL(string: "https://artwork-regression.invalid/library-cover-\(UUID().uuidString).jpg")!
            let cardWidth = floor((size.width - 44) / 2)
            let cached = preloadArtwork(url: url, pointSize: cardWidth, color: .green)
            let session = catalogTestSession { request in
                XCTAssertEqual(request.url?.path, "/api.json/0.2/favorite/getUserFavorites")
                let albums: [[String: Any]] = (0..<3).map { index in
                    ["id": "a\(index)", "title": "Saved Album \(index)", "artist": ["id": 42, "name": "Ada Rivers"], "image": ["large": url.absoluteString], "release_date_original": "2024-04-05"]
                }
                return (200, try JSONSerialization.data(withJSONObject: ["albums": ["items": albums, "total": 3]]))
            }
            defer { session.invalidateAndCancel(); QobuzCatalogURLProtocol.handler = nil }
            let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "test-token", userID: 1), session: session, catalogAppID: "test-app-id")
            let controller = QobuzCatalogViewController(mode: .albums, client: client)
            var selected: [String] = []
            controller.onAlbumSelected = { selected.append($0.id) }
            layout(controller, size: size)
            XCTAssertTrue(descendants(of: controller.view).compactMap { $0 as? UITableView }.isEmpty)
            let collection = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? UICollectionView }.first)
            waitForMainCondition("saved album grid loads") { collection.numberOfItems(inSection: 0) == 3 }
            collection.layoutIfNeeded()
            drainMainQueue()
            let flow = try XCTUnwrap(collection.collectionViewLayout as? UICollectionViewFlowLayout)
            XCTAssertEqual(flow.minimumInteritemSpacing, 16, accuracy: 0.5)
            XCTAssertEqual(flow.minimumLineSpacing, 28, accuracy: 0.5)
            XCTAssertEqual(flow.sectionInset.left, 14, accuracy: 0.5)
            XCTAssertEqual(flow.sectionInset.right, 14, accuracy: 0.5)
            XCTAssertEqual(flow.sectionInset.top, 18, accuracy: 0.5)
            XCTAssertEqual(flow.sectionInset.bottom, 102, accuracy: 0.5)
            let first = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 0, section: 0)))
            let second = try XCTUnwrap(collection.cellForItem(at: IndexPath(item: 1, section: 0)))
            let thirdAttributes = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 2, section: 0)))
            first.layoutIfNeeded(); second.layoutIfNeeded()
            XCTAssertEqual(collection.bounds.width, size.width, accuracy: 0.5)
            XCTAssertEqual(first.bounds.width, cardWidth, accuracy: 0.5)
            XCTAssertEqual(first.bounds.height, cardWidth + 50, accuracy: 0.5)
            XCTAssertEqual(second.frame.minY, first.frame.minY, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(second.frame.minX - first.frame.maxX, 16 - 0.5)
            XCTAssertEqual(thirdAttributes.frame.minX, first.frame.minX, accuracy: 0.5)
            XCTAssertEqual(thirdAttributes.frame.minY - first.frame.maxY, 28, accuracy: 0.5)
            let art = try XCTUnwrap(descendants(of: first).compactMap { $0 as? ArtworkView }.first)
            XCTAssertEqual(art.bounds.width, cardWidth, accuracy: 0.5)
            XCTAssertEqual(art.bounds.height, cardWidth, accuracy: 0.5)
            XCTAssertTrue(art.image === cached, "Grid covers must use the final square point size, not the old 54 pt table image or unsized cache")
            XCTAssertFalse(art.hasAmbiguousLayout)
            let labels = descendants(of: first).compactMap { $0 as? UILabel }
            let title = try XCTUnwrap(labels.first { $0.text == "Saved Album 0" })
            let metadata = try XCTUnwrap(labels.first { $0.text?.contains("Ada Rivers") == true })
            XCTAssertEqual(title.font.pointSize, 17, accuracy: 0.1)
            XCTAssertEqual(title.font, UIFont.systemFont(ofSize: 17, weight: .semibold))
            XCTAssertEqual(metadata.font.pointSize, 14, accuracy: 0.1)
            XCTAssertTrue(metadata.text?.contains("2024") == true)
            assertGroupedAccessibility(first, contains: ["Saved Album 0", "Ada Rivers", "2024"])
            XCTAssertTrue(first.accessibilityTraits.contains(.button))
            XCTAssertEqual(first.accessibilityCustomActions?.map(\.name) ?? [], [])
            retainVisualCapture(controller.view, name: "Saved albums two-column grid \(Int(size.width))")
            controller.collectionView(collection, didSelectItemAt: IndexPath(item: 1, section: 0))
            XCTAssertEqual(selected, ["a1"])
            // Cached completions are still asynchronous: reuse must invalidate
            // the old configuration even when the URL/index path has not changed.
            art.image = nil
            controller.collectionView(collection, willDisplay: first, forItemAt: IndexPath(item: 0, section: 0))
            first.prepareForReuse()
            drainMainQueue()
            XCTAssertNil(art.image, "A stale artwork completion must not paint a reused card")
        }
    }

    func testSavedAlbumSelectionAndLongPressUseFilteredSortedCards() throws {
        let session = catalogTestSession { request in
            XCTAssertEqual(request.url?.path, "/api.json/0.2/favorite/getUserFavorites")
            return (200, Data(#"{"albums":{"items":[{"id":"cedar","title":"Keep Cedar","artist":{"id":42,"name":"Ada Rivers"}},{"id":"hidden","title":"Excluded Album","artist":{"id":43,"name":"Other Artist"}},{"id":"alpha","title":"Keep Alpha","artist":{"id":42,"name":"Ada Rivers"}},{"id":"echo","title":"Keep Echo","artist":{"id":42,"name":"Ada Rivers"}}],"total":4}}"#.utf8))
        }
        defer { session.invalidateAndCancel(); QobuzCatalogURLProtocol.handler = nil }
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "test-token", userID: 1), session: session, catalogAppID: "test-app-id")
        let controller = QobuzCatalogViewController(mode: .albums, client: client)
        var selected: [String] = []
        var queued: [String] = []
        controller.onAlbumSelected = { selected.append($0.id) }
        controller.onAlbumQueueRequested = { queued.append($0.id) }
        layout(controller, size: CGSize(width: 375, height: 667))
        let collection = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? UICollectionView }.first)
        let search = try XCTUnwrap(descendants(of: controller.view).compactMap { $0 as? UISearchBar }.first)
        let sort = try XCTUnwrap(descendants(of: controller.view).first { $0.accessibilityIdentifier == "qobuz.library.sort" } as? UISegmentedControl)
        waitForMainCondition("saved queue albums load") { collection.numberOfItems(inSection: 0) == 4 }
        controller.setLibraryToolsVisible(true, animated: false)
        search.text = "Keep"
        controller.searchBar(search, textDidChange: "Keep")
        sort.selectedSegmentIndex = 2
        sort.sendActions(for: .valueChanged)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 3)
        collection.layoutIfNeeded()
        controller.collectionView(collection, didSelectItemAt: IndexPath(item: 1, section: 0))
        XCTAssertEqual(selected, ["cedar"])
        let recognizer = try XCTUnwrap((collection.gestureRecognizers ?? []).compactMap { $0 as? UILongPressGestureRecognizer }.first { $0.name == "qobuz.albums.queueLongPress" })
        XCTAssertEqual(recognizer.minimumPressDuration, 0.45, accuracy: 0.01)
        let first = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let gesture = TestAlbumLongPressRecognizer()
        gesture.simulatedLocation = CGPoint(x: first.frame.midX, y: first.frame.midY)
        let selector = NSSelectorFromString("albumLongPressed:")
        XCTAssertTrue(controller.responds(to: selector))
        guard controller.responds(to: selector) else { return }
        _ = controller.perform(selector, with: gesture)
        XCTAssertEqual(queued, ["echo"], "Long press must queue the displayed card, not the original favorites index")
        XCTAssertEqual(selected, ["cedar"], "Long press is not an album-open tap")
        gesture.simulatedState = .changed
        _ = controller.perform(selector, with: gesture)
        gesture.simulatedState = .ended
        _ = controller.perform(selector, with: gesture)
        XCTAssertEqual(queued, ["echo"], "A single long press must not emit duplicate queue menus")
        gesture.simulatedState = .began
        gesture.simulatedLocation = CGPoint(x: -10, y: -10)
        _ = controller.perform(selector, with: gesture)
        XCTAssertEqual(queued, ["echo"], "Pressing outside a card must do nothing")
    }

    func testDiscoveryAndSearchDoNotExposeSavedLibraryTools() throws {
        let lock = NSLock()
        var requestCount = 0
        let session = catalogTestSession { request in
            lock.lock(); requestCount += 1; lock.unlock()
            XCTAssertNotEqual(request.url?.path, "/api.json/0.2/favorite/getUserFavorites")
            // Discovery currently uses web-player configuration rather than the
            // library's injected app ID. Intercept that too, without populating
            // or clearing a user's persistent signing-configuration cache.
            if request.url?.host == "play.qobuz.com" {
                return (503, Data(#"{"message":"Web-player discovery disabled in this UI test"}"#.utf8))
            }
            XCTAssertTrue(["/api.json/0.2/genre/list", "/api.json/0.2/discover/index", "/api.json/0.2/discover/playlists"].contains(request.url?.path ?? ""))
            return (200, Data(#"{"containers":{},"genres":{"items":[]},"items":[],"total":0}"#.utf8))
        }
        defer { session.invalidateAndCancel(); QobuzCatalogURLProtocol.handler = nil }
        let client = QobuzStreamingClient(credentials: QobuzCredentials(userAuthToken: "test-token", userID: 1), session: session, catalogAppID: "test-app-id")
        for mode in [QobuzCatalogViewController.Mode.discover, .search] {
            let controller = QobuzCatalogViewController(mode: mode, client: client)
            layout(controller, size: CGSize(width: 320, height: 568))
            let views = descendants(of: controller.view)
            for identifier in ["qobuz.library.tools", "qobuz.library.sort", "qobuz.library.refresh"] {
                XCTAssertFalse(views.contains { $0.accessibilityIdentifier == identifier }, "Discovery filters and catalog search are not library tools")
            }
            let table = try XCTUnwrap(views.compactMap { $0 as? UITableView }.first)
            XCTAssertNil(table.refreshControl)
            if mode == .search {
                let search = try XCTUnwrap(views.compactMap { $0 as? UISearchBar }.first)
                XCTAssertFalse(search.isHidden)
                XCTAssertGreaterThan(search.bounds.height, 0)
                XCTAssertEqual(search.accessibilityIdentifier, "qobuz.search.search")
            } else {
                let status = try XCTUnwrap(views.first { $0.accessibilityIdentifier == "qobuz.discover.status" } as? UILabel)
                waitForMainCondition("mocked discovery completes without live configuration requests") {
                    lock.lock(); let count = requestCount; lock.unlock()
                    return count == 3 && status.text != "Loading Qobuz discovery…"
                }
            }
        }
        drainMainQueue()
    }

    func testProfileTopTrackSelectionAndActionsUseTrackSection() throws {
        // Use the modern artist shape, but omit remote artwork from the UI fixture.
        let source = try JSONDecoder().decode(QobuzCatalogArtistPage.self, from: Data(#"{"id":42,"name":{"display":"Ada Rivers"},"top_tracks":[{"id":701,"title":"Top Song","artist":{"id":42,"name":{"display":"Ada Rivers"}},"rights":{"streamable":true},"album":{"id":"top-album","title":"Top Album"}},{"id":702,"title":"Unavailable Song","rights":{"streamable":false}}]}"#.utf8))
        let mapped = QobuzCatalogMapper.profile(QobuzCatalogMapper.artistPage(source, releases: nil))
        let album = ScreenAlbum(id: "release", title: "Release", artist: "Ada Rivers", year: "2024")
        let profile = ScreenProfile(id: mapped.id, name: mapped.name, subtitle: mapped.subtitle, information: mapped.information, albums: [album], tracks: mapped.tracks)
        let controller = ProfileDetailViewController(profile: profile)
        var selections: [String] = []
        var navigations: [String] = []
        var swipes: [SongSwipeAction] = []
        controller.onTrackSelected = { selections.append($0.id) }
        controller.onTrackNavigationRequested = { navigations.append($0.id) }
        controller.onSongSwipeAction = { track, action in XCTAssertEqual(track.id, "701"); swipes.append(action) }
        layout(controller, size: CGSize(width: 320, height: 568))
        let table = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
        XCTAssertEqual(table.numberOfSections, 2)
        XCTAssertEqual(table.numberOfRows(inSection: 0), 1, "Only playable top tracks should be shown")
        XCTAssertEqual(table.numberOfRows(inSection: 1), 1)
        let header = try XCTUnwrap(controller.tableView(table, viewForHeaderInSection: 0))
        XCTAssertEqual(descendants(of: header).compactMap { $0 as? UILabel }.first?.text, "Top Tracks")
        controller.tableView(table, didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(selections, ["701"])
        table.layoutIfNeeded()
        let cell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)) as? SongSwipeActionCell)
        cell.onLongPress?()
        cell.onSwipeAction?(.enqueue)
        XCTAssertEqual(navigations, ["701"])
        XCTAssertEqual(swipes, [.enqueue])
        controller.tableView(table, didSelectRowAt: IndexPath(row: 0, section: 1))
        XCTAssertEqual(selections, ["701"], "Release grid taps must not select a top track")
    }

    func testAlbumDetailArtworkUsesSizeSpecificCacheOnSmallScreens() throws {
        XCTAssertTrue(URLProtocol.registerClass(UnexpectedArtworkURLProtocol.self))
        defer { URLProtocol.unregisterClass(UnexpectedArtworkURLProtocol.self); ArtworkImagePipeline.shared.removeAll() }
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667)] {
            let url = URL(string: "https://artwork-regression.invalid/album-\(UUID().uuidString).jpg")!
            let cached = preloadArtwork(url: url, pointSize: 102, color: .red)
            let track = ScreenTrack(id: "701", title: "Top Song", artist: "Ada Rivers", album: "Album")
            let album = ScreenAlbum(id: "album", title: "Small Screen Album", artist: "Ada Rivers", year: "2024", artworkURL: url, tracks: [track])
            let controller = AlbumDetailViewController(album: album)
            layout(controller, size: size)
            drainMainQueue()
            let table = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
            let header = try XCTUnwrap(table.tableHeaderView)
            let art = try XCTUnwrap(descendants(of: header).compactMap { $0 as? ArtworkView }.first)
            XCTAssertEqual(header.accessibilityIdentifier, "albumDetail.header")
            XCTAssertEqual(header.bounds.width, size.width - 24, accuracy: 0.5)
            XCTAssertEqual(art.bounds.width, 102, accuracy: 0.5)
            XCTAssertEqual(art.bounds.height, 102, accuracy: 0.5)
            XCTAssertTrue(art.image === cached, "An unsized URL cache entry or placeholder must not replace the correctly downsampled cover")
            XCTAssertFalse(art.hasAmbiguousLayout)
            let title = try XCTUnwrap(descendants(of: header).first { $0.accessibilityIdentifier == "albumDetail.title" })
            XCTAssertGreaterThan(title.bounds.width, 100)
            XCTAssertLessThanOrEqual(art.convert(art.bounds, to: header).maxX, header.bounds.maxX)
        }
    }

    func testProfileArtworkAndReleaseCardsUseLayoutSizedCacheOnSmallScreens() throws {
        XCTAssertTrue(URLProtocol.registerClass(UnexpectedArtworkURLProtocol.self))
        defer { URLProtocol.unregisterClass(UnexpectedArtworkURLProtocol.self); ArtworkImagePipeline.shared.removeAll() }
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667)] {
            let portraitURL = URL(string: "https://artwork-regression.invalid/portrait-\(UUID().uuidString).jpg")!
            let coverURL = URL(string: "https://artwork-regression.invalid/release-\(UUID().uuidString).jpg")!
            let portraitImage = preloadArtwork(url: portraitURL, pointSize: 72, color: .blue)
            // ProfileAlbumRowCell has 14 pt side margins and a 16 pt inter-card gap.
            let cardWidth = (size.width - 44) / 2
            let coverImage = preloadArtwork(url: coverURL, pointSize: cardWidth, color: .green)
            let album = ScreenAlbum(id: "release", title: "Release", artist: "Ada Rivers", year: "2024", artworkURL: coverURL)
            let profile = ScreenProfile(id: "42", name: "Ada Rivers", subtitle: "1 albums", information: "Biography", artworkURL: portraitURL, albums: [album])
            let controller = ProfileDetailViewController(profile: profile)
            layout(controller, size: size)
            drainMainQueue()
            let table = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
            let header = try XCTUnwrap(table.tableHeaderView)
            let portrait = try XCTUnwrap(descendants(of: header).compactMap { $0 as? ArtworkView }.first)
            XCTAssertEqual(header.accessibilityIdentifier, "profileDetail.header")
            XCTAssertEqual(header.bounds.width, size.width, accuracy: 0.5)
            XCTAssertGreaterThan(header.bounds.height, 150)
            XCTAssertEqual(portrait.bounds.width, 72, accuracy: 0.5)
            XCTAssertTrue(portrait.image === portraitImage)
            XCTAssertFalse(portrait.hasAmbiguousLayout)
            let rowPath = IndexPath(row: 0, section: 0)
            table.scrollToRow(at: rowPath, at: .middle, animated: false)
            table.layoutIfNeeded()
            let cell = try XCTUnwrap(table.cellForRow(at: rowPath))
            cell.layoutIfNeeded()
            drainMainQueue()
            let art = try XCTUnwrap(descendants(of: cell).compactMap { $0 as? ArtworkView }.first)
            XCTAssertEqual(art.bounds.width, cardWidth, accuracy: 0.5, "Odd release counts must still use a half-width card")
            XCTAssertEqual(art.bounds.height, cardWidth, accuracy: 0.5)
            XCTAssertTrue(art.image === coverImage, "Release artwork cache size must come from final card bounds, including fractional widths")
            XCTAssertFalse(art.hasAmbiguousLayout)
            XCTAssertLessThanOrEqual(art.convert(art.bounds, to: cell).maxX, cell.bounds.maxX)
        }
    }

    func testContentEdgeTabSwipeDirectionHonorsHistoricalEdgesAndThresholds() {
        for width: CGFloat in [320, 375] {
            for left in [CGFloat(0), 12, 24] {
                XCTAssertEqual(EdgeTabSwipeCoordinator.resolvedDirection(startX: left, width: width, translation: CGPoint(x: 46, y: 0)), .previous)
                XCTAssertNil(EdgeTabSwipeCoordinator.resolvedDirection(startX: left, width: width, translation: CGPoint(x: -100, y: 0)), "Outward left-edge motion is not tab navigation")
            }
            for right in [width - 24, width - 12, width] {
                XCTAssertEqual(EdgeTabSwipeCoordinator.resolvedDirection(startX: right, width: width, translation: CGPoint(x: -46, y: 0)), .next)
                XCTAssertNil(EdgeTabSwipeCoordinator.resolvedDirection(startX: right, width: width, translation: CGPoint(x: 100, y: 0)), "Outward right-edge motion is not tab navigation")
            }
            for interior in [CGFloat(25), width / 2, width - 25] {
                XCTAssertNil(EdgeTabSwipeCoordinator.resolvedDirection(startX: interior, width: width, translation: CGPoint(x: 200, y: 0)), "Interior gestures belong to rows, not tabs")
                XCTAssertNil(EdgeTabSwipeCoordinator.resolvedDirection(startX: interior, width: width, translation: CGPoint(x: -200, y: 0)))
            }
            for distance: CGFloat in [0, 20, 45] {
                XCTAssertNil(EdgeTabSwipeCoordinator.resolvedDirection(startX: 0, width: width, translation: CGPoint(x: distance, y: 0)))
                XCTAssertNil(EdgeTabSwipeCoordinator.resolvedDirection(startX: width, width: width, translation: CGPoint(x: -distance, y: 0)))
            }
            for vertical: CGFloat in [-100, -60, 60, 100] {
                XCTAssertNil(EdgeTabSwipeCoordinator.resolvedDirection(startX: 0, width: width, translation: CGPoint(x: 60, y: vertical)), "Vertical or diagonal scrolling must not switch tabs")
                XCTAssertNil(EdgeTabSwipeCoordinator.resolvedDirection(startX: width, width: width, translation: CGPoint(x: -60, y: vertical)))
            }
            XCTAssertNil(EdgeTabSwipeCoordinator.resolvedDirection(startX: -1, width: width, translation: CGPoint(x: 100, y: 0)))
            XCTAssertNil(EdgeTabSwipeCoordinator.resolvedDirection(startX: width + 1, width: width, translation: CGPoint(x: -100, y: 0)))
        }
        for width: CGFloat in [0, 24, 48] {
            XCTAssertNil(EdgeTabSwipeCoordinator.resolvedDirection(startX: 0, width: width, translation: CGPoint(x: 100, y: 0)))
        }
    }

    func testFiveTabStripFitsOrScrollsWithoutSqueezingLabelsAndSelectsTracks() throws {
        let tabs = TabConfiguration().enabledTabs
        XCTAssertEqual(tabs, [.discover, .search, .albums, .artists, .tracks])
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667)] {
            let host = UIView(frame: CGRect(origin: .zero, size: size))
            let strip = TabStripView()
            strip.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(strip)
            NSLayoutConstraint.activate([
                strip.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                strip.topAnchor.constraint(equalTo: host.topAnchor)
            ])
            strip.configure(titles: tabs.map(\.title))
            host.layoutIfNeeded()
            strip.layoutIfNeeded()
            let scroll = try XCTUnwrap(strip.subviews.compactMap { $0 as? UIScrollView }.first)
            let stack = try XCTUnwrap(scroll.subviews.compactMap { $0 as? UIStackView }.first)
            let buttons = stack.arrangedSubviews.compactMap { $0 as? UIButton }
            XCTAssertEqual(buttons.count, 5)
            XCTAssertEqual(strip.bounds.width, size.width, accuracy: 0.5)
            XCTAssertEqual(strip.bounds.height, 44, accuracy: 0.5)
            XCTAssertEqual(stack.bounds.width, max(size.width, 360), accuracy: 0.5)
            XCTAssertEqual(scroll.contentSize.width, stack.bounds.width, accuracy: 0.5)
            XCTAssertFalse(strip.hasAmbiguousLayout)
            XCTAssertFalse(stack.hasAmbiguousLayout)
            for button in buttons {
                XCTAssertFalse(button.hasAmbiguousLayout)
                XCTAssertGreaterThanOrEqual(button.bounds.width, 72 - 0.5)
                XCTAssertEqual(button.bounds.width, stack.bounds.width / 5, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(button.frame.minX, -0.5)
                XCTAssertLessThanOrEqual(button.frame.maxX, stack.bounds.maxX + 0.5)
                XCTAssertEqual(button.bounds.height, 44, accuracy: 0.5)
                let label = try XCTUnwrap(button.titleLabel)
                XCTAssertGreaterThanOrEqual(label.bounds.width + 0.5, label.intrinsicContentSize.width, "\(button.currentTitle ?? "") must not be truncated")
            }
            let tracksIndex = try XCTUnwrap(tabs.firstIndex(of: .tracks))
            let tracksButton = buttons[tracksIndex]
            var selections: [LibraryTab] = []
            strip.onSelectionChanged = { selections.append(tabs[$0]) }
            // First select without animation to inspect the scrolled-to-visible result.
            strip.setSelectedIndex(tracksIndex, animated: false)
            host.layoutIfNeeded()
            let visible = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
            XCTAssertGreaterThanOrEqual(tracksButton.frame.minX + 0.5, visible.minX)
            XCTAssertLessThanOrEqual(tracksButton.frame.maxX, visible.maxX + 0.5)
            tracksButton.sendActions(for: .touchUpInside)
            drainMainQueue()
            XCTAssertEqual(strip.selectedIndex, tracksIndex)
            XCTAssertEqual(selections, [.tracks])
            XCTAssertTrue(tracksButton.accessibilityTraits.contains(.selected))
            XCTAssertTrue(buttons.dropLast().allSatisfy { !$0.accessibilityTraits.contains(.selected) })
        }
    }

    func testQueueArtworkUsesHeaderAndRowSizedCacheAndLoadsOnlyDisplayedCells() throws {
        XCTAssertTrue(URLProtocol.registerClass(UnexpectedArtworkURLProtocol.self))
        defer { URLProtocol.unregisterClass(UnexpectedArtworkURLProtocol.self); ArtworkImagePipeline.shared.removeAll() }
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667)] {
            let url = artworkTestURL("queue-sized")
            let headerImage = preloadArtwork(url: url, pointSize: 62, color: .blue)
            let rowImage = preloadArtwork(url: url, pointSize: 60, color: .green)
            let tracks = (0..<80).map { index in
                ScreenTrack(id: "\(index)", title: "Queue Song \(index)", artist: "Ada Rivers", album: "Queue Album", artworkURL: url, duration: 215)
            }
            let controller = QueueViewController(tracks: tracks, currentIndex: 0)
            layout(controller, size: size)
            let table = try queueTable(controller)
            let header = try XCTUnwrap(table.tableHeaderView)
            header.layoutIfNeeded()
            let headerArt = try XCTUnwrap(descendants(of: header).compactMap { $0 as? UIImageView }.first { $0.bounds.width == 62 })
            XCTAssertEqual(headerArt.bounds.height, 62, accuracy: 0.5)
            XCTAssertTrue(headerArt.image === headerImage, "Current cover has its own 62 pt cache key")
            XCTAssertEqual(table.numberOfRows(inSection: 0), 79)
            XCTAssertGreaterThan(table.visibleCells.count, 0)
            XCTAssertLessThan(table.visibleCells.count, 10, "Long queues must not instantiate all artwork views")
            for cell in table.visibleCells {
                cell.layoutIfNeeded()
                let art = try queueRowArtwork(cell)
                XCTAssertEqual(art.bounds.width, 60, accuracy: 0.5)
                XCTAssertEqual(art.bounds.height, 60, accuracy: 0.5)
                XCTAssertTrue(art.image === rowImage, "Visible rows use 60 pt, not player/header/unsized artwork")
            }
            retainVisualCapture(controller.view, name: "Queue sized covers \(Int(size.width))")

            // Simulate UIKit prefetch creating a cell without displaying it.
            // A synchronous cache hit is deliberately available: configuring
            // metadata alone must still leave the offscreen image unretained.
            let path = IndexPath(row: 55, section: 0)
            let offscreen = controller.tableView(table, cellForRowAt: path)
            let offscreenArt = try queueRowArtwork(offscreen)
            XCTAssertNil(offscreenArt.image, "No decoded cover is retained by an undisplayed row")
            controller.tableView(table, willDisplay: offscreen, forRowAt: path)
            XCTAssertTrue(offscreenArt.image === rowImage)
            controller.tableView(table, didEndDisplaying: offscreen, forRowAt: path)
            XCTAssertNil(offscreenArt.image, "Leaving the viewport releases the row's decoded cover")
            controller.tableView(table, willDisplay: offscreen, forRowAt: path)
            XCTAssertTrue(offscreenArt.image === rowImage, "Redisplay can load the cached cover again")
            offscreen.prepareForReuse()
            XCTAssertNil(offscreenArt.image)
            let swipeCell = try XCTUnwrap(offscreen as? SongSwipeActionCell)
            XCTAssertNil(swipeCell.onLongPress)
            XCTAssertNil(swipeCell.onSwipeAction)
        }
    }

    func testQueueOffscreenArtworkDoesNotRequestUntilWillDisplay() throws {
        XCTAssertTrue(URLProtocol.registerClass(ControlledArtworkURLProtocol.self))
        defer {
            ControlledArtworkURLProtocol.reset()
            URLProtocol.unregisterClass(ControlledArtworkURLProtocol.self)
            ArtworkImagePipeline.shared.removeAll()
        }
        let url = artworkTestURL("queue-lazy")
        // All initially visible tracks use local/no artwork. Only the distant
        // track has a URL, so any observed request before willDisplay is eager.
        var tracks = (0..<80).map { ScreenTrack(id: "\($0)", title: "Song \($0)", artist: "Ada Rivers", album: "Queue") }
        tracks[56] = ScreenTrack(id: "56", title: "Distant Song", artist: "Ada Rivers", album: "Queue", artworkURL: url)
        let controller = QueueViewController(tracks: tracks, currentIndex: 0)
        layout(controller, size: CGSize(width: 320, height: 568))
        let table = try queueTable(controller)
        let path = IndexPath(row: 55, section: 0)
        let cell = controller.tableView(table, cellForRowAt: path)
        let art = try queueRowArtwork(cell)
        drainMainQueue()
        XCTAssertTrue(ControlledArtworkURLProtocol.requestedURLs.isEmpty)
        XCTAssertNil(art.image)
        controller.tableView(table, willDisplay: cell, forRowAt: path)
        controller.tableView(table, willDisplay: cell, forRowAt: path)
        waitForMainCondition("display starts one intercepted request") { ControlledArtworkURLProtocol.hasPending(url) }
        XCTAssertEqual(ControlledArtworkURLProtocol.requestedURLs, [url], "Repeated display must coalesce the size-specific request")
        let pixels = artworkPixels(60)
        let delivered = expectation(description: "lazy remote artwork decoded")
        ArtworkImagePipeline.shared.image(forRemoteURL: url, maximumPixelSize: pixels) { image in
            XCTAssertNotNil(image)
            XCTAssertTrue(art.image === image)
            XCTAssertEqual(image?.cgImage?.width, pixels)
            delivered.fulfill()
        }
        ControlledArtworkURLProtocol.complete(url, data: artworkPNG(color: .green))
        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(ControlledArtworkURLProtocol.requestedURLs, [url])
    }

    func testQueuePendingArtworkCompletionCannotPaintAReusedOrEndedCell() throws {
        XCTAssertTrue(URLProtocol.registerClass(ControlledArtworkURLProtocol.self))
        defer {
            ControlledArtworkURLProtocol.reset()
            URLProtocol.unregisterClass(ControlledArtworkURLProtocol.self)
            ArtworkImagePipeline.shared.removeAll()
        }
        for reuse in [false, true] {
            let url = artworkTestURL(reuse ? "queue-reuse" : "queue-ended")
            let tracks = [
                ScreenTrack(id: "current", title: "Current Song", artist: "Ada Rivers", album: "Queue"),
                ScreenTrack(id: "next", title: "Next Song", artist: "Ada Rivers", album: "Queue", artworkURL: url)
            ]
            let controller = QueueViewController(tracks: tracks, currentIndex: 0)
            layout(controller, size: CGSize(width: 375, height: 667))
            let table = try queueTable(controller)
            let path = IndexPath(row: 0, section: 0)
            let cell = try XCTUnwrap(table.cellForRow(at: path))
            let art = try queueRowArtwork(cell)
            waitForMainCondition("pending artwork before cancellation") { ControlledArtworkURLProtocol.hasPending(url) }
            let delivered = expectation(description: "cancelled view's artwork completes in pipeline")
            ArtworkImagePipeline.shared.image(forRemoteURL: url, maximumPixelSize: artworkPixels(60)) { image in
                XCTAssertNotNil(image, "The shared cache may finish even after the view stops displaying")
                XCTAssertNil(art.image, "A cancelled generation must not receive the old decoded image")
                delivered.fulfill()
            }
            if reuse { cell.prepareForReuse() }
            else { controller.tableView(table, didEndDisplaying: cell, forRowAt: path) }
            ControlledArtworkURLProtocol.complete(url, data: artworkPNG(color: .red))
            wait(for: [delivered], timeout: 3)
            XCTAssertNil(art.image)
        }
    }

    func testQueueSameIDNewArtworkURLRejectsOldCompletionAndKeepsVisibleRow() throws {
        XCTAssertTrue(URLProtocol.registerClass(ControlledArtworkURLProtocol.self))
        defer {
            ControlledArtworkURLProtocol.reset()
            URLProtocol.unregisterClass(ControlledArtworkURLProtocol.self)
            ArtworkImagePipeline.shared.removeAll()
        }
        let oldURL = artworkTestURL("queue-old")
        let newURL = artworkTestURL("queue-new")
        let current = ScreenTrack(id: "current", title: "Current Song", artist: "Ada Rivers", album: "Queue")
        let old = ScreenTrack(id: "next", title: "Old Song", artist: "Ada Rivers", album: "Queue", artworkURL: oldURL, duration: 120)
        let updated = ScreenTrack(id: old.id, title: "Updated Song", artist: "New Artist", album: "Queue", artworkURL: newURL, duration: 215)
        let newImage = preloadArtwork(url: newURL, pointSize: 60, color: .green)
        let controller = QueueViewController(tracks: [current, old], currentIndex: 0)
        layout(controller, size: CGSize(width: 375, height: 667))
        let table = try queueTable(controller)
        let path = IndexPath(row: 0, section: 0)
        let cell = try XCTUnwrap(table.cellForRow(at: path) as? SongSwipeActionCell)
        let art = try queueRowArtwork(cell)
        let header = try XCTUnwrap(table.tableHeaderView)
        waitForMainCondition("old artwork is pending") { ControlledArtworkURLProtocol.hasPending(oldURL) }
        let delivered = expectation(description: "old URL completes after same-ID metadata update")
        ArtworkImagePipeline.shared.image(forRemoteURL: oldURL, maximumPixelSize: artworkPixels(60)) { image in
            XCTAssertNotNil(image)
            XCTAssertTrue(art.image === newImage, "Same-ID old-URL completion must not overwrite the new cover")
            delivered.fulfill()
        }
        var navigated: [ScreenTrack] = []
        controller.onTrackNavigationRequested = { navigated.append($0) }
        controller.update(tracks: [current, updated], currentIndex: 0)
        XCTAssertTrue(table.cellForRow(at: path) === cell, "Metadata-only changes update visible cells in place")
        XCTAssertTrue(table.tableHeaderView === header, "An upcoming track change must not rebuild Now Playing")
        XCTAssertTrue(art.image === newImage)
        XCTAssertTrue(descendants(of: cell).compactMap { $0 as? UILabel }.contains { $0.text == "Updated Song" })
        XCTAssertTrue(descendants(of: cell).compactMap { $0 as? UILabel }.contains { $0.text == "New Artist · 3:35" })
        cell.onLongPress?()
        XCTAssertEqual(navigated.first?.title, "Updated Song", "Reconfigured callbacks must capture the updated metadata")
        ControlledArtworkURLProtocol.complete(oldURL, data: artworkPNG(color: .red))
        wait(for: [delivered], timeout: 3)
        XCTAssertTrue(art.image === newImage)
        XCTAssertEqual(ControlledArtworkURLProtocol.requestedURLs, [oldURL], "The new size-specific cache hit must not request")
    }

    func testQueueMetadataGatePreservesHeaderRowsScrollAndSwipeUntilPresentationChanges() throws {
        let current = ScreenTrack(id: "current", title: "Current Song", artist: "Ada Rivers", album: "Queue", duration: 120)
        let upcoming = (0..<30).map { ScreenTrack(id: "next-\($0)", title: "Next Song \($0)", artist: "Ada Rivers", album: "Queue", duration: 215) }
        let controller = QueueViewController(tracks: [current] + upcoming, currentIndex: 0)
        layout(controller, size: CGSize(width: 320, height: 568))
        let table = try queueTable(controller)
        table.setContentOffset(CGPoint(x: 0, y: 220), animated: false)
        table.layoutIfNeeded()
        let path = try XCTUnwrap(table.indexPathsForVisibleRows?.first)
        let cell = try XCTUnwrap(table.cellForRow(at: path) as? SongSwipeActionCell)
        let header = try XCTUnwrap(table.tableHeaderView)
        cell.updateSwipe(translation: 40)
        let offset = table.contentOffset
        let transform = cell.contentView.transform
        // Fresh equivalent value structs must also pass the presentation gate.
        for _ in 0..<4 {
            let sameCurrent = ScreenTrack(id: current.id, title: current.title, artist: current.artist, album: current.album, duration: current.duration)
            controller.update(tracks: [sameCurrent] + upcoming, currentIndex: 0)
        }
        XCTAssertTrue(table.tableHeaderView === header)
        XCTAssertTrue(table.cellForRow(at: path) === cell)
        XCTAssertEqual(table.contentOffset, offset)
        XCTAssertEqual(cell.contentView.transform, transform, "No-op updates must not interrupt a swipe")
        let edited = ScreenTrack(id: current.id, title: "Renamed Current Song", artist: "New Artist", album: "Queue", duration: 180)
        controller.update(tracks: [edited] + upcoming, currentIndex: 0)
        XCTAssertFalse(table.tableHeaderView === header, "Same-ID current metadata changes must refresh the header")
        let changedHeader = try XCTUnwrap(table.tableHeaderView)
        XCTAssertTrue(descendants(of: changedHeader).compactMap { $0 as? UILabel }.contains { $0.text == edited.title })
        XCTAssertTrue(table.cellForRow(at: path) === cell)
        XCTAssertEqual(table.contentOffset, offset)
        XCTAssertEqual(cell.contentView.transform, transform)
    }

    func testRootPlayerToQueuePreservesUnavailablePositionsAndSkipsMetadataWorkOnPlaybackTicks() throws {
        // Root normally opens the user's catalog, which may be authenticated.
        // Temporarily choose the inert settings screen instead; restore every
        // touched preference and never mutate the credentials store.
        let defaults = UserDefaults.standard
        let preferenceKeys = ["Music.AppState.tabConfiguration", "Music.AppState.queueState"]
        let savedPreferences = preferenceKeys.map { defaults.object(forKey: $0) }
        let oldKeyWindow = UIApplication.shared.windows.first { $0.isKeyWindow }
        let animationsEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defaults.set(Data(#"{"enabledTabs":["settings"],"libraryTabsVersion":1}"#.utf8), forKey: preferenceKeys[0])
        XCTAssertTrue(URLProtocol.registerClass(UnexpectedArtworkURLProtocol.self))
        defer {
            for (key, value) in zip(preferenceKeys, savedPreferences) {
                if let value = value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            UIView.setAnimationsEnabled(animationsEnabled)
            oldKeyWindow?.makeKey()
            URLProtocol.unregisterClass(UnexpectedArtworkURLProtocol.self)
            ArtworkImagePipeline.shared.removeAll()
        }
        for size in [CGSize(width: 320, height: 568), CGSize(width: 375, height: 667)] {
            let currentURL = artworkTestURL("root-current")
            let upcomingURL = artworkTestURL("root-upcoming")
            let current = ScreenTrack(id: "current", title: "Current Song", artist: "Ada Rivers", album: "Player Album", artworkURL: currentURL, duration: 215)
            let upcoming = ScreenTrack(id: "upcoming", title: "Known Upcoming Song", artist: "Ada Rivers", album: "Queue Album", artworkURL: upcomingURL, duration: 180)
            var providerCalls: [String] = []
            let backend = StubPresentationPlayback()
            let root = RootViewController(playbackBackend: backend, presentationTrackProvider: { id in
                providerCalls.append(id)
                return id == current.id ? current : (id == upcoming.id ? upcoming : nil)
            })
            let window = UIWindow(frame: CGRect(origin: .zero, size: size))
            window.rootViewController = root
            window.makeKeyAndVisible()
            layout(root, size: size)
            defer {
                root.dismiss(animated: false)
                window.isHidden = true
                window.rootViewController = nil
                backend.onStateChange = nil
            }
            // Root's player loader uses root width; the queue uses only 62/60.
            let playerImage = preloadArtwork(url: currentURL, pointSize: root.view.bounds.width, color: .blue)
            let headerImage = preloadArtwork(url: currentURL, pointSize: 62, color: .green)
            let rowImage = preloadArtwork(url: upcomingURL, pointSize: 60, color: .orange)
            _ = preloadArtwork(url: upcomingURL, pointSize: root.view.bounds.width, color: .orange)
            _ = preloadArtwork(url: upcomingURL, pointSize: 62, color: .orange)
            let ids = [current.id, "missing", upcoming.id]
            backend.emit(QueueState(trackIDs: ids, currentIndex: 0, elapsed: 15, isPlaying: true))
            let mini = try XCTUnwrap(descendants(of: root.view).compactMap { $0 as? MiniPlayerView }.first)
            XCTAssertEqual(mini.titleLabel.text, current.title)
            XCTAssertTrue(mini.artworkImageView.image === playerImage)
            mini.onOpenPlayer?()
            waitForMainCondition("root presents injected current player") { root.presentedViewController is PlayerViewController }
            let player = try XCTUnwrap(root.presentedViewController as? PlayerViewController)
            layout(player, size: size)
            XCTAssertTrue(descendants(of: player.view).compactMap { $0 as? UILabel }.contains { $0.text == current.title })
            XCTAssertTrue(descendants(of: player.view).compactMap { $0 as? UIImageView }.contains { $0.image === playerImage })
            retainVisualCapture(player.view, name: "Injected root player \(Int(size.width))")
            player.onOpenQueue?()
            waitForMainCondition("player presents positional queue") { player.presentedViewController is QueueViewController }
            let queue = try XCTUnwrap(player.presentedViewController as? QueueViewController)
            layout(queue, size: size)
            let table = try queueTable(queue)
            let header = try XCTUnwrap(table.tableHeaderView)
            XCTAssertEqual(table.numberOfRows(inSection: 0), 2, "An unresolved ID must remain a row, not shift subsequent selections")
            let missingCell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 0, section: 0)))
            let knownCell = try XCTUnwrap(table.cellForRow(at: IndexPath(row: 1, section: 0)) as? SongSwipeActionCell)
            XCTAssertTrue(descendants(of: missingCell).compactMap { $0 as? UILabel }.contains { $0.text == "Unavailable Track" })
            XCTAssertTrue(try queueRowArtwork(knownCell).image === rowImage)
            XCTAssertTrue(descendants(of: header).compactMap { $0 as? UIImageView }.contains { $0.image === headerImage })
            retainVisualCapture(queue.view, name: "Root player to queue \(Int(size.width))")
            knownCell.updateSwipe(translation: 40)
            let transform = knownCell.contentView.transform
            let offset = table.contentOffset
            providerCalls.removeAll()
            for elapsed in [16.0, 17.0, 18.0, 19.0] {
                backend.emit(QueueState(trackIDs: ids, currentIndex: 0, elapsed: elapsed, isPlaying: elapsed != 18))
            }
            XCTAssertFalse(providerCalls.contains("missing"), "Elapsed/play-pause ticks must not rebuild queue presentation metadata")
            XCTAssertFalse(providerCalls.contains(upcoming.id), "Only current player metadata is needed on playback ticks")
            XCTAssertTrue(table.tableHeaderView === header)
            XCTAssertTrue(table.cellForRow(at: IndexPath(row: 1, section: 0)) === knownCell)
            XCTAssertEqual(knownCell.contentView.transform, transform)
            XCTAssertEqual(table.contentOffset, offset)
            queue.tableView(table, didSelectRowAt: IndexPath(row: 1, section: 0))
            XCTAssertEqual(backend.selections.last, 2, "The known row after an unresolved ID must select the original queue position")
            XCTAssertEqual(backend.queueState.currentTrackID, upcoming.id)
            XCTAssertTrue(backend.queueState.isPlaying, "Selecting an upcoming row preserves active transport")
            waitForMainCondition("queue selection dismisses queue back to player") { player.presentedViewController == nil }
            let dismissed = expectation(description: "root regression modal cleanup")
            root.dismiss(animated: false) { dismissed.fulfill() }
            wait(for: [dismissed], timeout: 3)
        }
    }

    private func artworkTestURL(_ prefix: String) -> URL {
        URL(string: "https://artwork-regression.invalid/\(prefix)-\(UUID().uuidString).png")!
    }

    private func artworkPixels(_ pointSize: CGFloat) -> Int {
        max(1, Int(ceil(pointSize * UIScreen.main.scale)))
    }

    private func artworkPNG(color: UIColor) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        return image.pngData()!
    }

    private func queueTable(_ controller: QueueViewController) throws -> UITableView {
        try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
    }

    private func queueRowArtwork(_ cell: UITableViewCell) throws -> UIImageView {
        try XCTUnwrap(descendants(of: cell.contentView).compactMap { $0 as? UIImageView }.first)
    }

    private func assertGroupedAccessibility(_ view: UIView, contains values: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(view.isAccessibilityElement, "The whole card/row is the VoiceOver focus target", file: file, line: line)
        for value in values {
            XCTAssertTrue(view.accessibilityLabel?.contains(value) == true, "Grouped label must include \(value)", file: file, line: line)
        }
    }

    private func retainVisualCapture(_ view: UIView, name: String) {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func layout(_ controller: UIViewController, size: CGSize) {
        XCTAssertTrue(Thread.isMainThread)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.viewDidLayoutSubviews()
        controller.view.layoutIfNeeded()
    }

    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func waitForMainCondition(_ description: String, condition: @escaping () -> Bool) {
        let completed = expectation(description: description)
        let deadline = Date().addingTimeInterval(3)
        func poll() {
            XCTAssertTrue(Thread.isMainThread)
            if condition() { completed.fulfill(); return }
            guard Date() < deadline else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        DispatchQueue.main.async(execute: poll)
        wait(for: [completed], timeout: 3.5)
    }

    private func drainMainQueue() {
        let completed = expectation(description: "main-queue UI completions")
        DispatchQueue.main.async {
            XCTAssertTrue(Thread.isMainThread)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    private func preloadArtwork(url: URL, pointSize: CGFloat, color: UIColor) -> UIImage {
        let pixels = max(1, Int(ceil(pointSize * UIScreen.main.scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(pixels), height: CGFloat(pixels)), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        }
        let key = "remote|\(url.absoluteString)|\(pixels)"
        ArtworkImagePipeline.shared.cache(image, for: key)
        XCTAssertTrue(ArtworkImagePipeline.shared.cachedImage(for: key) === image)
        let completed = expectation(description: "size-specific cached artwork completes on main")
        ArtworkImagePipeline.shared.image(forRemoteURL: url, maximumPixelSize: pixels) { loaded in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(loaded === image)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        // A conflicting old unsized cache entry catches regressions to the wrong key.
        ArtworkImagePipeline.shared.cache(UIImage(), for: url.absoluteString)
        return image
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

    func testDefaultTracksTabPersistsAndReloads() throws {
        let suiteName = "MusicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults)
        let expected: [LibraryTab] = [.discover, .search, .albums, .artists, .tracks]
        XCTAssertEqual(state.tabConfiguration.enabledTabs, expected)
        state.updateTabConfiguration(state.tabConfiguration)
        let data = try XCTUnwrap(defaults.data(forKey: "Music.AppState.tabConfiguration"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(saved["enabledTabs"] as? [String], expected.map(\.rawValue))
        XCTAssertEqual(saved["libraryTabsVersion"] as? Int, 1)
        XCTAssertEqual(AppState(defaults: defaults).tabConfiguration.enabledTabs, expected)
    }

    func testUnversionedCustomTabsAddTracksWithoutRestoringHiddenOldTabs() throws {
        let suiteName = "MusicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data(#"{"enabledTabs":["artists","albums"]}"#.utf8), forKey: "Music.AppState.tabConfiguration")
        let state = AppState(defaults: defaults)
        XCTAssertEqual(state.tabConfiguration.enabledTabs, [.artists, .albums, .tracks])
        XCTAssertFalse(state.tabConfiguration.enabledTabs.contains(.discover))
        XCTAssertFalse(state.tabConfiguration.enabledTabs.contains(.search))
        let data = try XCTUnwrap(defaults.data(forKey: "Music.AppState.tabConfiguration"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(saved["enabledTabs"] as? [String], ["artists", "albums", "tracks"])
        XCTAssertEqual(saved["libraryTabsVersion"] as? Int, 1)
        XCTAssertEqual(AppState(defaults: defaults).tabConfiguration.enabledTabs, [.artists, .albums, .tracks])
    }

    func testVersionedSettingsWithHiddenTracksRemainHiddenAfterRoundTrip() throws {
        let suiteName = "MusicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data(#"{"enabledTabs":["settings","artists","albums"],"libraryTabsVersion":1}"#.utf8), forKey: "Music.AppState.tabConfiguration")
        let state = AppState(defaults: defaults)
        let expected: [LibraryTab] = [.settings, .artists, .albums]
        XCTAssertEqual(state.tabConfiguration.enabledTabs, expected)
        state.updateTabConfiguration(state.tabConfiguration)
        let data = try XCTUnwrap(defaults.data(forKey: "Music.AppState.tabConfiguration"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(saved["enabledTabs"] as? [String], expected.map(\.rawValue))
        XCTAssertEqual(saved["libraryTabsVersion"] as? Int, 1)
        let reloaded = AppState(defaults: defaults)
        XCTAssertEqual(reloaded.tabConfiguration.enabledTabs, expected)
        XCTAssertFalse(reloaded.tabConfiguration.enabledTabs.contains(.tracks))
    }

    func testLegacyLocalTabsAreRemovedFromPersistedPreferences() throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data(#"{"enabledTabs":["genres","tracks","playlists"]}"#.utf8), forKey: "Music.AppState.tabConfiguration")

        let state = AppState(defaults: defaults)

        XCTAssertEqual(state.tabConfiguration.enabledTabs, [.tracks])
        let data = try XCTUnwrap(defaults.data(forKey: "Music.AppState.tabConfiguration"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(saved["enabledTabs"] as? [String], ["tracks"])
        XCTAssertEqual(saved["libraryTabsVersion"] as? Int, 1)
        XCTAssertEqual(AppState(defaults: defaults).tabConfiguration.enabledTabs, [.tracks])
    }
}
