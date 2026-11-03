// Standalone controller contract checks: swiftc -D QUEUE_REGRESSION Sources/Data/{Models,AppState,PlaybackController}.swift Tests/QueueRegressionTests.swift -o /tmp/queue-regression
#if QUEUE_REGRESSION
import Foundation

struct ScreenTrack { let duration: TimeInterval }
enum QobuzStreamQuality { case cd }
struct QobuzTrackURL { let url: URL }
enum QobuzStreamingError: Error { case invalidQobuzTrackID }
protocol QobuzStreamResolving {
    func requestStreamURL(trackID: Int64, quality: QobuzStreamQuality, progress: @escaping (String) -> Void, completion: @escaping (Result<QobuzTrackURL, Error>) -> Void)
}
final class QobuzStreamPlayer {
    enum Status { case failed(Error), playing, paused }
    var onTimeChange: ((TimeInterval, TimeInterval) -> Void)?
    var onEnded: (() -> Void)?
    var onAdvancedToPreloaded: (() -> Void)?
    var onStatusChange: ((Status) -> Void)?
    func preload(url: URL) {}
    func cancelPreload() {}
    func stop() {}
    func play() {}
    func play(url: URL, startingAt elapsed: TimeInterval = 0) {}
    func pause() {}
    func seek(to elapsed: TimeInterval) {}
}
final class QueueResolver: QobuzStreamResolving {
    var requests: [Int64] = []
    var completions: [(Result<QobuzTrackURL, Error>) -> Void] = []
    func requestStreamURL(trackID: Int64, quality: QobuzStreamQuality, progress: @escaping (String) -> Void, completion: @escaping (Result<QobuzTrackURL, Error>) -> Void) {
        requests.append(trackID); completions.append(completion)
    }
}
@main struct QueueRegressionTests {
    static func main() {
        let name = "QueueRegressionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let app = AppState(defaults: defaults)
        app.updateQueueState(QueueState(trackIDs: ["11", "22", "11"], currentIndex: 2, elapsed: 47, isPlaying: true, isShuffled: true))
        let restored = AppState(defaults: defaults).queueState
        precondition(restored.trackIDs == ["11", "22", "11"] && restored.currentIndex == 2 && restored.elapsed == 47)
        precondition(!restored.isPlaying, "Restoring persisted playback must not autoplay")
        print("PASS persisted queue restores paused with duplicate position and elapsed")
        let resolver = QueueResolver()
        let controller = QobuzPlaybackController(client: resolver, quality: { .cd }, trackProvider: { _ in ScreenTrack(duration: 180) }, initialState: restored)
        precondition(controller.queueState.elapsed == 47 && !controller.queueState.isPlaying && resolver.requests.isEmpty)
        controller.play()
        precondition(resolver.requests == [11])
        controller.moveTrack(from: 2, to: 0)
        precondition(controller.queueState.currentIndex == 0 && controller.queueState.elapsed == 47)
        controller.removeTrack(at: 1)
        controller.playNext(trackID: "33")
        controller.enqueue(trackID: "44")
        precondition(controller.queueState.trackIDs == ["11", "33", "22", "44"])
        controller.clearUpcoming()
        precondition(controller.queueState.trackIDs == ["11"] && controller.queueState.elapsed == 47 && controller.queueState.isPlaying)
        precondition(resolver.requests.count == 1, "Noncurrent edits must preserve pending current resolution")
        var resolved = 0
        controller.onStreamResolved = { _, _, _ in resolved += 1 }
        resolver.completions[0](.success(QobuzTrackURL(url: URL(string: "https://example.invalid/audio")!)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        precondition(resolved == 1)
        controller.setQueue(trackIDs: ["11", "22", "11"], startingAt: 0)
        controller.play()
        controller.selectTrack(at: 2)
        precondition(resolver.requests == [11, 11, 11], "Selecting a duplicate is a new occurrence")
        resolver.completions[1](.success(QobuzTrackURL(url: URL(string: "https://example.invalid/stale")!)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        precondition(resolved == 1, "Old duplicate occurrence resolution must be ignored")
        controller.removeTrack(at: 0)
        precondition(controller.queueState.currentIndex == 1)
        controller.removeTrack(at: 1)
        precondition(controller.queueState.currentTrackID == "22" && controller.queueState.currentIndex == 0 && controller.queueState.elapsed == 0)
        resolver.completions[2](.success(QobuzTrackURL(url: URL(string: "https://example.invalid/removed")!)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        precondition(resolved == 1)
        controller.pause()
        resolver.completions.last?(.success(QobuzTrackURL(url: URL(string: "https://example.invalid/paused")!)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        precondition(resolved == 1 && !controller.queueState.isPlaying)
        controller.seek(to: 200)
        precondition(controller.queueState.elapsed == 180)
        controller.previous()
        precondition(controller.queueState.elapsed == 0)
        controller.enqueue(trackID: "55")
        controller.next()
        precondition(controller.queueState.currentTrackID == "55" && !controller.queueState.isPlaying)
        controller.next()
        precondition(controller.queueState.currentTrackID == "22")
        controller.togglePlayPause()
        precondition(controller.queueState.isPlaying)
        controller.togglePlayPause()
        precondition(!controller.queueState.isPlaying)
        controller.clearQueue()
        precondition(controller.queueState == QueueState())
        print("PASS restoration, positional duplicate selection/removal/reorder, clear Up Next, stale resolution, transport and enqueue/play-next contracts")
    }
}
#endif
