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
        let cases: [(QobuzCatalogViewController.Mode, String)] = [(.albums, "Café Sessions"), (.artists, "Café Artist"), (.tracks, "Café Song")]
        for (index, testCase) in cases.enumerated() {
            let controller = QobuzCatalogViewController(mode: testCase.0, client: client)
            layout(controller, size: CGSize(width: 320, height: 568))
            let table = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UITableView }.first)
            let search = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UISearchBar }.first)
            waitForMainCondition("saved library rows load") { table.numberOfRows(inSection: 0) == 2 }
            XCTAssertNotNil(table.refreshControl)
            XCTAssertTrue(search.placeholder?.hasPrefix("Search saved ") == true)
            search.text = "  CAFE  "
            controller.searchBar(search, textDidChange: search.text!)
            XCTAssertEqual(table.numberOfRows(inSection: 0), 1)
            table.layoutIfNeeded()
            XCTAssertEqual(table.cellForRow(at: IndexPath(row: 0, section: 0))?.textLabel?.text, testCase.1)
            controller.searchBarSearchButtonClicked(search)
            XCTAssertEqual(table.numberOfRows(inSection: 0), 1)
            if testCase.0 != .artists {
                search.text = "ADA RIVERS"
                controller.searchBar(search, textDidChange: "ADA RIVERS")
                XCTAssertEqual(table.numberOfRows(inSection: 0), 1, "Local filtering must also match the saved artist name")
                table.layoutIfNeeded()
                XCTAssertEqual(table.cellForRow(at: IndexPath(row: 0, section: 0))?.textLabel?.text, testCase.1)
            }
            search.text = "not in this saved library"
            controller.searchBar(search, textDidChange: search.text!)
            XCTAssertEqual(table.numberOfRows(inSection: 0), 0)
            search.text = ""
            controller.searchBar(search, textDidChange: "")
            XCTAssertEqual(table.numberOfRows(inSection: 0), 2)
            drainMainQueue()
            lock.lock(); let paths = requestedPaths; lock.unlock()
            XCTAssertEqual(paths, Array(repeating: "/api.json/0.2/favorite/getUserFavorites", count: index + 1), "Typing, submitting, and clearing a saved-library filter must not make requests")
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
        let search = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? UISearchBar }.first)
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
