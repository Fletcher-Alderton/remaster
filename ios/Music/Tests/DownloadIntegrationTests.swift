import UIKit
import XCTest
@testable import Music

@MainActor
final class DownloadIntegrationTests: XCTestCase {
    func testOfflineLookupPrecedesResolverAndReportsActualFormatForDuplicateOccurrences() {
        let resolver = IntegrationResolver()
        let file = URL(fileURLWithPath: "/tmp/offline-integration.flac")
        var lookups: [(Int64, QobuzStreamQuality)] = []
        let controller = QobuzPlaybackController(client: resolver, quality: { .hiRes192 },
            trackProvider: { _ in nil },
            initialState: QueueState(trackIDs: ["41", "42", "41"], currentIndex: 2, elapsed: 47),
            offlineStream: { id, quality in
                lookups.append((id, quality))
                return QobuzTrackURL(url: file, formatID: 6, mimeType: "audio/flac", samplingRate: 44.1, bitDepth: 16)
            })
        var formats: [Int] = []
        controller.onStreamResolved = { _, requested, stream in
            XCTAssertEqual(requested, .hiRes192)
            formats.append(stream.formatID)
        }
        XCTAssertTrue(lookups.isEmpty)
        XCTAssertEqual(controller.queueState.elapsed, 47)
        controller.play()
        XCTAssertEqual(resolver.requests, 0)
        XCTAssertEqual(lookups.map { $0.0 }, [41])
        XCTAssertEqual(lookups.first?.1, .hiRes192)
        XCTAssertEqual(formats, [6])
        controller.selectTrack(at: 0)
        XCTAssertEqual(lookups.map { $0.0 }, [41, 41])
        XCTAssertEqual(formats, [6, 6])
        XCTAssertEqual(controller.queueState.elapsed, 0)
        controller.pause()
    }

    func testAlbumDownloadControlsOperateOnFullListAndRetryOnlyFailures() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = IntegrationResolver()
        let session = IntegrationSession()
        let manager = try QobuzDownloadManager(directory: directory, session: session, maximumConcurrentDownloads: 1)
        manager.setAccount(id: 11, resolver: resolver)
        let tracks = try [41, 42].map { id in
            try JSONDecoder().decode(QobuzSearchTrack.self, from: Data("{\"id\":\(id),\"title\":\"Track \(id)\",\"duration\":180}".utf8))
        }
        let album = ScreenAlbum(id: "a", title: "Ordered Album", artist: "Artist", year: "2026",
            tracks: tracks.map { ScreenTrack(id: String($0.id), title: $0.title, artist: "Artist", album: "Ordered Album", duration: 180) })
        let controller = AlbumDetailViewController(album: album)
        controller.configureLibrary(isSaved: false)
        controller.onLibraryChangeRequested = { _, _, callback in callback(.success(())) }
        controller.configureDownloads(manager: manager, tracks: tracks, quality: .cd)
        controller.loadViewIfNeeded()
        func find(_ id: String, _ view: UIView) -> UIView? {
            if view.accessibilityIdentifier == id { return view }
            return view.subviews.compactMap { find(id, $0) }.first
        }
        func action() throws -> UIButton { try XCTUnwrap(find("albumDetail.download", controller.view) as? UIButton) }
        func refresh() { controller.configureDownloads(manager: manager, tracks: tracks, quality: .cd) }
        controller.confirm = { _, _, confirmed in confirmed() }
        XCTAssertEqual(try action().title(for: .normal), "DOWNLOAD")
        try action().sendActions(for: .touchUpInside)
        XCTAssertEqual(resolver.ids, [41])
        XCTAssertEqual(try action().title(for: .normal), "DOWNLOADING 0%")
        XCTAssertEqual(try action().accessibilityHint, "Cancels the download")
        try action().sendActions(for: .touchUpInside)
        XCTAssertEqual(manager.state(trackID: 41, quality: .cd), .cancelled)
        XCTAssertEqual(manager.state(trackID: 42, quality: .cd), .cancelled)
        XCTAssertEqual(try action().title(for: .normal), "RETRY DOWNLOAD")
        try action().sendActions(for: .touchUpInside)
        resolver.succeedLast()
        session.finishLast()
        resolver.failLast()
        refresh()
        XCTAssertNotNil(manager.fileURL(trackID: 41, quality: .cd))
        XCTAssertNil(manager.fileURL(trackID: 42, quality: .cd))
        XCTAssertEqual(try action().title(for: .normal), "RETRY · 1 FAILED")
        let before = resolver.ids.count
        try action().sendActions(for: .touchUpInside)
        XCTAssertEqual(Array(resolver.ids.dropFirst(before)), [42])
        resolver.succeedLast()
        session.finishLast()
        refresh()
        XCTAssertEqual(try action().title(for: .normal), "DOWNLOADED")
        // Deleting files is a separate, confirmed menu action, never a tap on the status.
        try action().sendActions(for: .touchUpInside)
        XCTAssertNotNil(manager.fileURL(trackID: 41, quality: .cd))
        let remove = try XCTUnwrap(controller.albumActions().first { $0.id == .removeDownload })
        XCTAssertTrue(remove.isDestructive)
        remove.perform()
        XCTAssertNil(manager.fileURL(trackID: 41, quality: .cd))
        XCTAssertNil(manager.fileURL(trackID: 42, quality: .cd))
        XCTAssertEqual(try action().title(for: .normal), "DOWNLOAD")
    }

    func testMissingExactQualityFallsThroughToNetwork() {
        let resolver = IntegrationResolver()
        let controller = QobuzPlaybackController(client: resolver, quality: { .hiRes96 },
            trackProvider: { _ in nil }, initialState: QueueState(trackIDs: ["41"]),
            offlineStream: { _, requested in
                XCTAssertEqual(requested, .hiRes96)
                return nil
            })
        controller.play()
        XCTAssertEqual(resolver.requests, 1)
        controller.pause()
    }
}

private final class IntegrationResolver: QobuzStreamResolving {
    var requests = 0
    var ids: [Int64] = []
    var completions: [(Result<QobuzTrackURL, Error>) -> Void] = []
    func succeedLast() { completions.last?(.success(QobuzTrackURL(url: URL(string: "https://example.invalid/audio")!, formatID: 6, mimeType: "audio/flac", samplingRate: 44.1, bitDepth: 16))) }
    func failLast() { completions.last?(.failure(URLError(.notConnectedToInternet))) }
    func requestStreamURL(trackID: Int64, quality: QobuzStreamQuality,
        progress: @escaping (String) -> Void, completion: @escaping (Result<QobuzTrackURL, Error>) -> Void) {
        requests += 1
        ids.append(trackID)
        completions.append(completion)
    }
}

private final class IntegrationSession: URLSession, @unchecked Sendable {
    var completions: [(@Sendable (URL?, URLResponse?, Error?) -> Void)] = []
    override func downloadTask(with url: URL, completionHandler: @escaping @Sendable (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {
        completions.append(completionHandler)
        return IntegrationTask()
    }
    func finishLast() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data([0x66, 0x4c, 0x61, 0x43] + Array(repeating: 0, count: 128))
        try! data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let response = HTTPURLResponse(url: URL(string: "https://example.invalid/audio")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/flac", "Content-Length": String(data.count)])!
        completions.last?(file, response, nil)
    }
}
private final class IntegrationTask: URLSessionDownloadTask, @unchecked Sendable {
    override func resume() {}
    override func cancel() {}
}
