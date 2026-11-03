import Foundation
import XCTest
#if !DOWNLOAD_STANDALONE
@testable import Music
#endif

final class DownloadTests: XCTestCase {
    private var directory: URL!
    private var resolver: DownloadResolver!
    private var session: DownloadSession!
    private var manager: QobuzDownloadManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resolver = DownloadResolver()
        session = DownloadSession()
        manager = try QobuzDownloadManager(directory: directory, session: session, maximumConcurrentDownloads: 1)
        manager.setAccount(id: 11, resolver: resolver)
    }

    override func tearDownWithError() throws {
        manager.setAccount(id: nil, resolver: nil)
        try? FileManager.default.removeItem(at: directory)
    }

    private func track(_ id: Int64 = 41) throws -> QobuzSearchTrack {
        try JSONDecoder().decode(QobuzSearchTrack.self, from: Data("{\"id\":\(id),\"title\":\"Track \(id)\",\"album_id\":\"album-A\",\"duration\":123}".utf8))
    }

    func testDurableQualityAndAccountScopedLookupAndDelete() throws {
        try manager.download(track: track(), quality: .cd)
        resolver.succeed()
        session.finish()
        let file = try XCTUnwrap(manager.fileURL(trackID: 41, quality: .cd))
        XCTAssertEqual(try Data(contentsOf: file), DownloadSession.audio)
        XCTAssertNil(manager.fileURL(trackID: 41, quality: .mp3))
        let restarted = try QobuzDownloadManager(directory: directory, session: session)
        restarted.setAccount(id: 11, resolver: resolver)
        XCTAssertEqual(restarted.record(trackID: 41, quality: .cd)?.title, "Track 41")
        XCTAssertEqual(restarted.fileURL(trackID: 41, quality: .cd), file)
        restarted.setAccount(id: 12, resolver: resolver)
        XCTAssertNil(restarted.fileURL(trackID: 41, quality: .cd))
        restarted.setAccount(id: 11, resolver: resolver)
        let manifest = try String(contentsOf: directory.appendingPathComponent("downloads.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("signed-secret"))
        XCTAssertFalse(manifest.contains("https:"))
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try restarted.delete(trackID: 41, quality: .cd)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(restarted.fileURL(trackID: 41, quality: .cd))
    }

    func testRejectsHTTPPartialHTMLAndEmptyThenRetries() throws {
        let invalidResponses = [(403, "audio/flac", DownloadSession.audio), (206, "audio/flac", DownloadSession.audio), (200, "text/html", Data("error".utf8)), (200, "audio/flac", Data()), (200, "audio/flac", Data("{\"error\":true}".utf8))]
        for (index, response) in invalidResponses.enumerated() {
            try manager.download(track: track(), quality: .cd)
            resolver.succeed(index: index)
            session.finish(index: index, status: response.0, mime: response.1, data: response.2)
            XCTAssertNil(manager.fileURL(trackID: 41, quality: .cd))
            guard case .failed = manager.state(trackID: 41, quality: .cd) else { return XCTFail("Rejected body must be failed, not downloaded") }
        }
        try manager.download(track: track(), quality: .cd)
        resolver.succeed(index: invalidResponses.count)
        session.finish(index: invalidResponses.count)
        XCTAssertNotNil(manager.fileURL(trackID: 41, quality: .cd))
    }

    func testAlbumDedupeBoundAndCancellationIgnoreStaleResolution() throws {
        try manager.downloadAlbum(tracks: [track(), track(), track(42)], quality: .cd)
        XCTAssertEqual(resolver.requests.count, 1)
        manager.cancel(trackID: 41, quality: .cd)
        XCTAssertEqual(resolver.requests.count, 2)
        resolver.succeed(index: 0)
        XCTAssertEqual(session.downloadTasks.count, 0)
        resolver.succeed(index: 1)
        XCTAssertEqual(session.downloadTasks.count, 1)
        session.finish()
        XCTAssertNotNil(manager.fileURL(trackID: 42, quality: .cd))
        XCTAssertNil(manager.fileURL(trackID: 41, quality: .cd))
    }

    func testStaleDownloadCannotPublishAfterSignoutOrRetry() throws {
        try manager.download(track: track(), quality: .cd)
        resolver.succeed()
        manager.setAccount(id: nil, resolver: nil)
        XCTAssertTrue(session.downloadTasks[0].wasCancelled)
        manager.setAccount(id: 11, resolver: resolver)
        try manager.download(track: track(), quality: .cd)
        resolver.succeed(index: 1)
        session.finish(index: 0)
        XCTAssertNil(manager.fileURL(trackID: 41, quality: .cd))
        session.finish(index: 1)
        XCTAssertNotNil(manager.fileURL(trackID: 41, quality: .cd))
    }

    func testMissingFileAndDiskFailureNeverAppearDownloaded() throws {
        try manager.download(track: track(), quality: .cd)
        resolver.succeed()
        session.finish()
        let file = try XCTUnwrap(manager.fileURL(trackID: 41, quality: .cd))
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(manager.record(trackID: 41, quality: .cd))
        XCTAssertEqual(manager.state(trackID: 41, quality: .cd), .notDownloaded)
        try manager.download(track: track(), quality: .cd)
        resolver.succeed(index: 1)
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)
        session.finish(index: 1)
        XCTAssertNil(manager.fileURL(trackID: 41, quality: .cd))
        guard case .failed = manager.state(trackID: 41, quality: .cd) else { return XCTFail("Disk failure must be reported") }
    }

    func testProgressTransportFailureAndCancelRetry() throws {
        try manager.download(track: track(), quality: .cd)
        resolver.succeed()
        session.downloadTasks[0].progress.totalUnitCount = 100
        session.downloadTasks[0].progress.completedUnitCount = 37
        guard case .downloading(let fraction) = manager.state(trackID: 41, quality: .cd) else { return XCTFail("Expected download progress") }
        XCTAssertEqual(fraction, 0.37, accuracy: 0.001)
        manager.cancel(trackID: 41, quality: .cd)
        XCTAssertEqual(manager.state(trackID: 41, quality: .cd), .cancelled)
        try manager.download(track: track(), quality: .cd)
        resolver.succeed(index: 1)
        session.fail(index: 1)
        guard case .failed = manager.state(trackID: 41, quality: .cd) else { return XCTFail("Expected network failure") }
        XCTAssertNil(manager.fileURL(trackID: 41, quality: .cd))
        try manager.download(track: track(), quality: .cd)
        resolver.succeed(index: 2)
        session.finish(index: 0)
        XCTAssertNil(manager.fileURL(trackID: 41, quality: .cd))
        session.finish(index: 2)
        XCTAssertNotNil(manager.fileURL(trackID: 41, quality: .cd))
    }

    func testManifestFailureRollsBackAndRestartPrunesOrphanAndMissingFile() throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("downloads.json"), withIntermediateDirectories: true)
        try manager.download(track: track(), quality: .cd)
        resolver.succeed()
        session.finish()
        XCTAssertNil(manager.fileURL(trackID: 41, quality: .cd))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["downloads.json"])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("downloads.json"))
        try manager.download(track: track(), quality: .cd)
        resolver.succeed(index: 1)
        session.finish(index: 1)
        let file = try XCTUnwrap(manager.fileURL(trackID: 41, quality: .cd))
        try FileManager.default.removeItem(at: file)
        let orphan = directory.appendingPathComponent(UUID().uuidString + ".flac")
        try DownloadSession.audio.write(to: orphan)
        let restarted = try QobuzDownloadManager(directory: directory, session: session)
        restarted.setAccount(id: 11, resolver: resolver)
        XCTAssertNil(restarted.record(trackID: 41, quality: .cd))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testRestartDoesNotRestoreIncompleteWorkAndRequiresAccount() throws {
        manager.setAccount(id: nil, resolver: nil)
        XCTAssertThrowsError(try manager.download(track: track(), quality: .cd))
        manager.setAccount(id: 11, resolver: resolver)
        try manager.download(track: track(), quality: .cd)
        resolver.succeed()
        let restarted = try QobuzDownloadManager(directory: directory, session: session)
        restarted.setAccount(id: 11, resolver: resolver)
        XCTAssertNil(restarted.fileURL(trackID: 41, quality: .cd))
        XCTAssertEqual(restarted.state(trackID: 41, quality: .cd), .notDownloaded)
    }
}

private final class DownloadResolver: QobuzStreamResolving {
    var requests: [(Int64, QobuzStreamQuality, (Result<QobuzTrackURL, Error>) -> Void)] = []
    func requestStreamURL(trackID: Int64, quality: QobuzStreamQuality, progress: @escaping (String) -> Void, completion: @escaping (Result<QobuzTrackURL, Error>) -> Void) {
        requests.append((trackID, quality, completion))
    }
    func succeed(index: Int = 0) {
        guard requests.indices.contains(index) else { XCTFail("No stream resolution requested"); return }
        let request = requests[index]
        request.2(.success(QobuzTrackURL(url: URL(string: "https://media.example/track?token=signed-secret")!, formatID: request.1.rawValue, mimeType: "audio/flac", samplingRate: 44.1, bitDepth: 16)))
    }
}

private final class DownloadTask: URLSessionDownloadTask, @unchecked Sendable {
    var wasCancelled = false
    override func resume() {}
    override func cancel() { wasCancelled = true }
}

private final class DownloadSession: URLSession, @unchecked Sendable {
    static let audio = Data([0x66, 0x4c, 0x61, 0x43] + Array(repeating: 0, count: 128))
    var downloadTasks: [DownloadTask] = []
    private var completions: [(URL?, URLResponse?, Error?) -> Void] = []
    func fail(index: Int) { completions[index](nil, nil, URLError(.networkConnectionLost)) }
    override func downloadTask(with url: URL, completionHandler: @escaping @Sendable (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {
        let task = DownloadTask()
        downloadTasks.append(task)
        completions.append(completionHandler)
        return task
    }
    func finish(index: Int = 0, status: Int = 200, mime: String = "audio/flac", data: Data = DownloadSession.audio) {
        guard completions.indices.contains(index) else { XCTFail("No download task started"); return }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        completions[index](temporary, HTTPURLResponse(url: URL(string: "https://media.example")!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mime, "Content-Length": String(data.count)])!, nil)
    }
}

#if DOWNLOAD_STANDALONE
extension DownloadTests {
    static var allTests = [
        ("durable quality/account lookup and delete", testDurableQualityAndAccountScopedLookupAndDelete),
        ("reject invalid content and retry", testRejectsHTTPPartialHTMLAndEmptyThenRetries),
        ("dedupe bounds cancellation", testAlbumDedupeBoundAndCancellationIgnoreStaleResolution),
        ("stale download after signout", testStaleDownloadCannotPublishAfterSignoutOrRetry),
        ("missing file and disk failure", testMissingFileAndDiskFailureNeverAppearDownloaded),
        ("restart incomplete and account required", testRestartDoesNotRestoreIncompleteWorkAndRequiresAccount)
    ]
}
#endif
