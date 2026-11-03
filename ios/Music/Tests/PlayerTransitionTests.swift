import XCTest
import UIKit
@testable import Music

@MainActor
final class PlayerTransitionTests: XCTestCase {
    private let animationKey = "transition"
    private var window: UIWindow!

    private func state(_ id: String, playing: Bool = true, elapsed: TimeInterval = 0, artwork: UIImage? = nil) -> PlayerScreenState {
        PlayerScreenState(track: ScreenTrack(id: id, title: "Title \(id)", artist: "Artist \(id)", album: "Album \(id)", artwork: artwork, duration: 180), isPlaying: playing, elapsed: elapsed)
    }

    private func player() -> PlayerViewController {
        let controller = PlayerViewController(state: state("a"))
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        CATransaction.flush()
        return controller
    }

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func find(_ id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        return view.subviews.compactMap { find(id, in: $0) }.first
    }

    private func content(_ controller: PlayerViewController) throws -> [UIView] {
        let artwork = try XCTUnwrap(find("player.artwork", in: controller.view)?.subviews.first)
        let title = try XCTUnwrap(find("player.title", in: controller.view))
        let metadata = try XCTUnwrap(find("player.metadata", in: controller.view))
        return [artwork, title, metadata]
    }

    func testActualSongChangeAnimatesArtworkAndMetadataLayers() throws {
        let controller = player()
        XCTAssertTrue(try content(controller).allSatisfy { $0.layer.animation(forKey: animationKey) == nil })
        controller.update(state: state("b"))
        for view in try content(controller) {
            let transition = try XCTUnwrap(view.layer.animation(forKey: animationKey) as? CATransition)
            XCTAssertGreaterThan(transition.duration, 0)
            XCTAssertLessThanOrEqual(transition.duration, 0.35)
        }
    }

    func testTicksPauseAndLateArtworkDoNotStartSongTransition() throws {
        let controller = player()
        controller.update(state: state("a", elapsed: 45))
        controller.update(state: state("a", playing: false, elapsed: 46))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        controller.update(state: state("a", playing: false, elapsed: 46, artwork: image))
        XCTAssertTrue(try content(controller).allSatisfy { $0.layer.animation(forKey: animationKey) == nil })
        XCTAssertTrue((try content(controller).first as? UIImageView)?.image === image)
        controller.view.layoutIfNeeded()
        XCTAssertEqual(try XCTUnwrap(find("player.artwork", in: controller.view)).frame.width, 252, accuracy: 0.5)
    }

    func testRapidSkipsReplaceTransitionAndKeepLatestContent() throws {
        let controller = player()
        for id in ["b", "c", "d"] { controller.update(state: state(id)) }
        let views = try content(controller)
        XCTAssertEqual((views[1] as? UILabel)?.text, "Title d")
        XCTAssertEqual((views[2] as? UILabel)?.text, "Artist d — Album d")
        for view in views {
            XCTAssertEqual(view.layer.animationKeys()?.filter { $0 == animationKey }.count, 1)
            XCTAssertEqual(view.alpha, 1)
            XCTAssertEqual(view.transform, .identity)
        }
    }

    func testRapidSkipsSettleWithoutStaleContentAfterAnimationsFinish() throws {
        let controller = player()
        controller.update(state: state("b"))
        controller.update(state: state("c"))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        controller.update(state: state("d", artwork: image))
        CATransaction.flush()
        let settled = expectation(description: "Song transition finishes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        let views = try content(controller)
        XCTAssertEqual((views[1] as? UILabel)?.text, "Title d")
        XCTAssertEqual((views[2] as? UILabel)?.text, "Artist d — Album d")
        XCTAssertTrue((views[0] as? UIImageView)?.image === image)
        XCTAssertTrue(views.allSatisfy { $0.alpha == 1 && $0.transform == .identity })
    }

    func testExplicitNonanimatedAndOffscreenUpdatesDoNotTransition() throws {
        let controller = player()
        controller.update(state: state("b"), animated: false)
        XCTAssertTrue(try content(controller).allSatisfy { $0.layer.animation(forKey: animationKey) == nil })
        window.isHidden = true
        window.rootViewController = nil
        controller.update(state: state("c"))
        XCTAssertTrue(try content(controller).allSatisfy { $0.layer.animation(forKey: animationKey) == nil })
    }

    func testReduceMotionUsesFadeEvenForKnownDirection() throws {
        let controller = PlayerViewController(state: state("a"), reduceMotionEnabled: { true })
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        controller.onSkip = { controller.update(state: self.state("b")) }
        controller.perform(NSSelectorFromString("swipedLeft"))
        for view in try content(controller) {
            let transition = try XCTUnwrap(view.layer.animation(forKey: animationKey) as? CATransition)
            XCTAssertEqual(transition.type, .fade)
            XCTAssertNil(transition.subtype)
        }
    }

    func testDifferentOccurrenceOfSameSongTransitionsButSameOccurrenceDoesNotRestart() throws {
        let controller = player()
        controller.update(state: state("a"), occurrenceID: "position-1", animated: false)
        controller.update(state: state("a"), occurrenceID: "position-2")
        let title = try content(controller)[1]
        let first = try XCTUnwrap(title.layer.animation(forKey: animationKey) as? CATransition)
        controller.update(state: state("a", elapsed: 2), occurrenceID: "position-2")
        let second = try XCTUnwrap(title.layer.animation(forKey: animationKey) as? CATransition)
        XCTAssertEqual(first.beginTime, second.beginTime)
    }

    func testUnknownReplacementFadesAndNoopSwipeDoesNotLeakDirection() throws {
        let controller = player()
        controller.onRewind = { controller.update(state: self.state("a", elapsed: 0)) }
        controller.perform(NSSelectorFromString("swipedRight"))
        controller.update(state: state("b"))
        let transition = try XCTUnwrap(try content(controller)[1].layer.animation(forKey: animationKey) as? CATransition)
        XCTAssertEqual(transition.type, .fade)
        XCTAssertNil(transition.subtype)
    }

    func testSwipeDirectionReachesRealTransition() throws {
        let controller = player()
        controller.onSkip = { controller.update(state: self.state("b")) }
        controller.perform(NSSelectorFromString("swipedLeft"))
        let forward = try XCTUnwrap(try content(controller)[1].layer.animation(forKey: animationKey) as? CATransition)
        XCTAssertEqual(forward.type, UIAccessibility.isReduceMotionEnabled ? .fade : .push)
        if !UIAccessibility.isReduceMotionEnabled { XCTAssertEqual(forward.subtype, .fromRight) }
        controller.onRewind = { controller.update(state: self.state("a")) }
        controller.perform(NSSelectorFromString("swipedRight"))
        let backward = try XCTUnwrap(try content(controller)[1].layer.animation(forKey: animationKey) as? CATransition)
        if !UIAccessibility.isReduceMotionEnabled { XCTAssertEqual(backward.subtype, .fromLeft) }
    }
}

import AVFoundation

/// Real AVQueuePlayer hand-off between short local files: each song change must reach
/// the queue state the Now Playing screen renders from (index, playing, elapsed reset).
@MainActor
final class AutoAdvanceIntegrationTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("advance-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func tone(_ name: String, seconds: Double = 1.5) throws -> URL {
        let url = directory.appendingPathComponent("\(name).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = 0.05 * sin(Float(frame) * 0.06) }
        try file.write(from: buffer)
        return url
    }

    func testAutomaticSongChangesReachNowPlayingState() throws {
        let files = try ["11": tone("a"), "22": tone("b"), "33": tone("c")]
        let controller = QobuzPlaybackController(
            client: NeverResolver(), quality: { .cd }, trackProvider: { _ in ScreenTrack(id: "", title: "", artist: "", album: "", duration: 1.5) },
            offlineStream: { id, _ in files[String(id)].map { QobuzTrackURL(url: $0, formatID: 6, mimeType: "audio/x-caf", samplingRate: 44.1, bitDepth: 16) } })
        var states: [QueueState] = []
        var resolved: [String] = []
        controller.onStateChange = { states.append($0) }
        controller.onStreamResolved = { id, _, _ in resolved.append(id) }
        var errors: [Error] = []
        controller.onError = { errors.append($0) }
        controller.setQueue(trackIDs: ["11", "22", "33"], startingAt: 0)
        controller.play()

        let reachedLast = expectation(description: "advanced to the third song")
        var fulfilled = false
        func poll() {
            if states.last?.currentIndex == 2 && !fulfilled { fulfilled = true; reachedLast.fulfill(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: poll)
        }
        poll()
        wait(for: [reachedLast], timeout: 12)
        controller.pause()

        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(resolved, ["11", "22", "33"], "Every song change reports its stream once")
        for index in [1, 2] {
            let first = try XCTUnwrap(states.firstIndex { $0.currentIndex == index }, "no state for song \(index)")
            XCTAssertTrue(states[first].isPlaying, "song \(index) must show as playing")
            XCTAssertLessThan(states[first].elapsed, 0.5, "song \(index) must start from 0:00")
            // Once the new song is current, no stale tick from the previous song may move it back.
            for later in states[first...] {
                XCTAssertEqual(later.currentIndex >= index, true, "UI went back to an earlier song after advancing")
            }
        }
        // The elapsed time shown for the new song must track the new song, not jump to the old one's end.
        let afterSecond = states.drop { $0.currentIndex < 1 }.prefix { $0.currentIndex == 1 }
        XCTAssertFalse(afterSecond.contains { $0.elapsed > 1.45 && $0 == afterSecond.first }, "stale elapsed carried over")
    }
}

private final class NeverResolver: QobuzStreamResolving {
    func requestStreamURL(trackID: Int64, quality: QobuzStreamQuality, progress: @escaping (String) -> Void,
                          completion: @escaping (Result<QobuzTrackURL, Error>) -> Void) {}
}
