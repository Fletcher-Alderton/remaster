import Foundation
#if canImport(UIKit)
import UIKit
#endif

protocol PlaybackControlling: AnyObject {
    var queueState: QueueState { get }
    var onStateChange: ((QueueState) -> Void)? { get set }
    func setQueue(trackIDs: [String], startingAt index: Int)
    func enqueue(trackID: String)
    func playNext(trackID: String)
    func togglePlayPause()
    func play()
    func pause()
    func seek(to elapsed: TimeInterval)
    func next()
    func previous()
    func setShuffled(_ shuffled: Bool)
    func clearQueue()
}


/// Queue and AVPlayer transport combined behind the interface used by the app UI.
final class QobuzPlaybackController: PlaybackControlling {
    private let client: QobuzStreamResolving
    private let player = QobuzStreamPlayer()
    private let quality: () -> QobuzStreamQuality
    private let offlineStream: (Int64, QobuzStreamQuality) -> QobuzTrackURL?
    private let trackProvider: (String) -> ScreenTrack?
    private var presentationTracks: [String: ScreenTrack] = [:]
    private var state = QueueState()
    private var pendingTrackID: String?
    private var loadedTrackID: String?
    private var playbackRequested = false
    private var generation = 0
    /// Next queue occurrence whose stream is resolved (or resolving) and queued in the player.
    private struct Preload {
        let index: Int
        let trackID: String
        let quality: QobuzStreamQuality
        var stream: QobuzTrackURL?
        var failed = false
    }
    private var preload: Preload?
    private var preloadGeneration = 0
    /// Start resolving the next track this many seconds before the current one ends,
    /// so the hand-off happens without the app needing to restart audio from the background.
    static let preloadLeadTime: TimeInterval = 30
    var onStateChange: ((QueueState) -> Void)?
    var onError: ((Error) -> Void)?
    var onProgress: ((String) -> Void)?
    var onStreamResolved: ((String, QobuzStreamQuality, QobuzTrackURL) -> Void)?

    init(
        client: QobuzStreamResolving,
        quality: @escaping () -> QobuzStreamQuality,
        trackProvider: @escaping (String) -> ScreenTrack?,
        initialState: QueueState = QueueState(),
        offlineStream: @escaping (Int64, QobuzStreamQuality) -> QobuzTrackURL? = { _, _ in nil }
    ) {
        self.offlineStream = offlineStream
        self.client = client
        self.quality = quality
        self.trackProvider = trackProvider
        restoreQueue(initialState)
        player.onTimeChange = { [weak self] elapsed, duration in
            guard let self = self, self.state.currentTrackID != nil else { return }
            self.state.elapsed = min(max(0, elapsed), duration)
            self.notifyStateChange()
            if duration - elapsed <= Self.preloadLeadTime { self.preloadNextIfNeeded() }
        }
        player.onEnded = { [weak self] in self?.advanceAfterEnd() }
        player.onAdvancedToPreloaded = { [weak self] in self?.didAdvanceToPreloaded() }
        player.onStatusChange = { [weak self] status in
            guard let self = self else { return }
            switch status {
            case .failed(let error):
                self.playbackRequested = false
                self.state.isPlaying = false
                self.notifyStateChange()
                self.onError?(error)
            case .playing:
                if self.pendingTrackID == nil {
                    self.state.isPlaying = true
                    self.notifyStateChange()
                }
            case .paused:
                self.state.isPlaying = false
                self.notifyStateChange()
            }
        }
    }

    deinit { player.stop() }

    var queueState: QueueState { state }

    func setQueue(trackIDs: [String], startingAt index: Int = 0) {
        generation += 1
        stopPlayer()
        pendingTrackID = nil
        loadedTrackID = nil
        state = QueueState(
            trackIDs: trackIDs,
            currentIndex: min(max(0, index), max(0, trackIDs.count - 1)),
            elapsed: 0,
            isPlaying: false,
            isShuffled: state.isShuffled
        )
        playbackRequested = false
        notifyStateChange()
    }

    func enqueue(trackID: String) {
        if state.currentTrackID == nil {
            setQueue(trackIDs: [trackID], startingAt: 0)
            return
        }
        state.trackIDs.append(trackID)
        notifyStateChange()
    }

    func playNext(trackID: String) {
        guard state.currentTrackID != nil else {
            setQueue(trackIDs: [trackID], startingAt: 0)
            return
        }
        state.trackIDs.insert(trackID, at: min(state.currentIndex + 1, state.trackIDs.count))
        notifyStateChange()
    }

    func togglePlayPause() { state.isPlaying ? pause() : play() }

    func play() {
        guard state.currentTrackID != nil else { return }
        playbackRequested = true
        state.isPlaying = true
        notifyStateChange()
        startCurrentTrackIfNeeded()
    }

    func pause() {
        playbackRequested = false
        state.isPlaying = false
        if pendingTrackID != nil {
            generation += 1
            pendingTrackID = nil
        }
        player.pause()
        notifyStateChange()
    }

    func seek(to elapsed: TimeInterval) {
        guard elapsed.isFinite, currentTrackID != nil else { return }
        let duration = currentTrackID.flatMap(trackProvider)?.duration ?? 0
        let position = duration > 0 ? min(max(0, elapsed), duration) : max(0, elapsed)
        player.seek(to: position)
        state.elapsed = position
        notifyStateChange()
    }

    func next() {
        guard !state.trackIDs.isEmpty else { return }
        transition(to: state.currentIndex + 1 < state.trackIDs.count ? state.currentIndex + 1 : 0, shouldPlay: playbackRequested)
    }

    func previous() {
        guard !state.trackIDs.isEmpty else { return }
        if state.elapsed > 3 {
            seek(to: 0)
        } else {
            transition(to: max(0, state.currentIndex - 1), shouldPlay: playbackRequested)
        }
    }

    func setShuffled(_ shuffled: Bool) {
        state.isShuffled = shuffled
        notifyStateChange()
    }

    func clearQueue() {
        generation += 1
        stopPlayer()
        state = QueueState()
        playbackRequested = false
        pendingTrackID = nil
        loadedTrackID = nil
        notifyStateChange()
    }

    /// Restoration is always paused; only an explicit play resolves a URL.
    func restoreQueue(_ saved: QueueState) {
        generation += 1
        stopPlayer()
        pendingTrackID = nil
        loadedTrackID = nil
        playbackRequested = false
        state = saved
        state.currentIndex = min(max(0, saved.currentIndex), max(0, saved.trackIDs.count - 1))
        state.elapsed = saved.elapsed.isFinite ? max(0, saved.elapsed) : 0
        state.isPlaying = false
        if state.trackIDs.isEmpty { state.elapsed = 0 }
        notifyStateChange()
    }

    func selectTrack(at index: Int) {
        guard state.trackIDs.indices.contains(index), index != state.currentIndex else { return }
        transition(to: index, shouldPlay: playbackRequested)
    }

    func removeTrack(at index: Int) {
        guard state.trackIDs.indices.contains(index) else { return }
        if index == state.currentIndex {
            let shouldPlay = playbackRequested
            state.trackIDs.remove(at: index)
            if state.trackIDs.isEmpty { clearQueue() }
            else { transition(to: min(index, state.trackIDs.count - 1), shouldPlay: shouldPlay) }
        } else {
            state.trackIDs.remove(at: index)
            if index < state.currentIndex { state.currentIndex -= 1 }
            notifyStateChange()
        }
    }

    /// Destination is the final absolute queue position, not a track ID.
    func moveTrack(from source: Int, to destination: Int) {
        guard state.trackIDs.indices.contains(source), state.trackIDs.indices.contains(destination), source != destination else { return }
        let track = state.trackIDs.remove(at: source)
        state.trackIDs.insert(track, at: destination)
        if state.currentIndex == source { state.currentIndex = destination }
        else if source < state.currentIndex && destination >= state.currentIndex { state.currentIndex -= 1 }
        else if source > state.currentIndex && destination <= state.currentIndex { state.currentIndex += 1 }
        notifyStateChange()
    }

    /// Clear Up Next without replacing or restarting the current player item.
    func clearUpcoming() {
        guard state.currentTrackID != nil else { return }
        state.trackIDs.removeSubrange((state.currentIndex + 1)..<state.trackIDs.count)
        notifyStateChange()
    }

    func shuffleUpcoming() {
        guard state.currentTrackID != nil else { return }
        let range = (state.currentIndex + 1)..<state.trackIDs.count
        state.trackIDs.replaceSubrange(range, with: state.trackIDs[range].shuffled())
        notifyStateChange()
    }

    private var currentTrackID: String? { state.currentTrackID }

    private func startCurrentTrackIfNeeded() {
        guard let id = currentTrackID, playbackRequested else { return }
        guard let trackID = Int64(id), trackID > 0 else {
            playbackRequested = false
            state.isPlaying = false
            notifyStateChange()
            onError?(QobuzStreamingError.invalidQobuzTrackID)
            return
        }
        if loadedTrackID == id {
            player.play()
            return
        }
        guard pendingTrackID != id else { return }
        generation += 1
        let requestGeneration = generation
        let requestedQuality = quality()
        pendingTrackID = id
        stopPlayer()
        if let stream = offlineStream(trackID, requestedQuality) {
            pendingTrackID = nil
            loadedTrackID = id
            publishResolvedStream(id, requestedQuality, stream)
            guard generation == requestGeneration, playbackRequested else { return }
            player.play(url: stream.url, startingAt: state.elapsed)
            return
        }
        let resolutionTask = BackgroundTaskToken(name: "Qobuz stream resolution")
        client.requestStreamURL(
            trackID: trackID,
            quality: requestedQuality,
            progress: { [weak self] message in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    guard self.generation == requestGeneration,
                          self.currentTrackID == id,
                          self.playbackRequested else { return }
                    self.onProgress?(message)
                }
            },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    resolutionTask.end()
                    guard let self = self,
                          self.generation == requestGeneration,
                          self.currentTrackID == id,
                          self.playbackRequested else { return }
                    self.pendingTrackID = nil
                    switch result {
                    case .failure(let error):
                        self.playbackRequested = false
                        self.state.isPlaying = false
                        self.notifyStateChange()
                        self.onError?(error)
                    case .success(let stream):
                        self.loadedTrackID = id
                        self.publishResolvedStream(id, requestedQuality, stream)
                        guard self.generation == requestGeneration, self.playbackRequested else { return }
                        self.player.play(url: stream.url, startingAt: self.state.elapsed)
                    }
                }
            }
        )
    }

    private func transition(to index: Int, shouldPlay: Bool) {
        NSLog("NPDIAG backend.transition from=%d to=%d play=%@", state.currentIndex, index, shouldPlay ? "yes" : "no")
        generation += 1
        stopPlayer()
        pendingTrackID = nil
        loadedTrackID = nil
        state.currentIndex = min(max(0, index), state.trackIDs.count - 1)
        state.elapsed = 0
        playbackRequested = shouldPlay
        state.isPlaying = shouldPlay
        notifyStateChange()
        if shouldPlay { startCurrentTrackIfNeeded() }
    }

    private func advanceAfterEnd() {
        guard !state.trackIDs.isEmpty else { return }
        if state.currentIndex + 1 < state.trackIDs.count {
            transition(to: state.currentIndex + 1, shouldPlay: true)
        } else {
            playbackRequested = false
            state.isPlaying = false
            state.elapsed = 0
            stopPlayer()
            loadedTrackID = nil
            notifyStateChange()
        }
    }

    private func notifyStateChange() {
        syncPreload()
        let snapshot = state
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(snapshot) }
    }

    // MARK: - Next-track preloading

    /// Stops the transport and forgets any queued next item.
    private func stopPlayer() {
        preloadGeneration += 1
        preload = nil
        player.stop()
    }

    private var nextIndex: Int? {
        let index = state.currentIndex + 1
        return state.trackIDs.indices.contains(index) ? index : nil
    }

    /// Drop a queued next item that no longer matches the queue (reorder, removal, clear...).
    private func syncPreload() {
        guard let preload = preload else { return }
        let stillValid = loadedTrackID != nil
            && loadedTrackID == currentTrackID
            && nextIndex == preload.index
            && state.trackIDs[preload.index] == preload.trackID
        guard !stillValid else { return }
        preloadGeneration += 1
        self.preload = nil
        player.cancelPreload()
    }

    /// Resolve and queue the next track while the current one is still playing, so the
    /// transition never has to restart audio while the app is suspended (device locked).
    private func preloadNextIfNeeded() {
        guard playbackRequested, preload == nil, pendingTrackID == nil,
              let current = currentTrackID, loadedTrackID == current,
              let index = nextIndex else { return }
        let id = state.trackIDs[index]
        guard let trackID = Int64(id), trackID > 0 else { return }
        let requestedQuality = quality()
        preloadGeneration += 1
        let requestGeneration = preloadGeneration
        preload = Preload(index: index, trackID: id, quality: requestedQuality)
        if let stream = offlineStream(trackID, requestedQuality) {
            preload?.stream = stream
            player.preload(url: stream.url)
            return
        }
        client.requestStreamURL(
            trackID: trackID,
            quality: requestedQuality,
            progress: { _ in },
            completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self, self.preloadGeneration == requestGeneration,
                          self.preload?.trackID == id else { return }
                    switch result {
                    case .failure:
                        // Fall back to resolving at the track boundary; don't retry every tick.
                        self.preload?.failed = true
                    case .success(let stream):
                        self.preload?.stream = stream
                        self.player.preload(url: stream.url)
                    }
                }
            }
        )
    }

    /// Single notification point for a resolved stream: the app-level observer and the
    /// audio-path report both need it, for live, offline and promoted-preload tracks.
    private func publishResolvedStream(_ trackID: String,
                                       _ quality: QobuzStreamQuality,
                                       _ stream: QobuzTrackURL) {
        onStreamResolved?(trackID, quality, stream)
        AudioPathMonitor.shared.updateSource(StreamFormatSummary.from(stream))
    }

    /// The transport moved into the queued next item on its own.
    private func didAdvanceToPreloaded() {
        NSLog("NPDIAG backend.didAdvanceToPreloaded preload=%@ next=%d", preload?.trackID ?? "nil", nextIndex ?? -1)
        guard let preload = preload, let stream = preload.stream,
              nextIndex == preload.index, state.trackIDs[preload.index] == preload.trackID else {
            advanceAfterEnd()
            return
        }
        generation += 1
        self.preload = nil
        state.currentIndex = preload.index
        state.elapsed = 0
        pendingTrackID = nil
        loadedTrackID = preload.trackID
        state.isPlaying = playbackRequested
        publishResolvedStream(preload.trackID, preload.quality, stream)
        notifyStateChange()
    }
}

/// Keeps the app running briefly while a stream URL is resolved, e.g. when a track
/// boundary is reached with the device locked and nothing was preloaded.
final class BackgroundTaskToken {
    #if canImport(UIKit)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(name: String) {
        #if canImport(UIKit)
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
        #endif
    }

    deinit { end() }

    func end() {
        #if canImport(UIKit)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        #endif
    }
}
