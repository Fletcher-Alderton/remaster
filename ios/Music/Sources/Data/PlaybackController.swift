import Foundation

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
    private let trackProvider: (String) -> ScreenTrack?
    private var presentationTracks: [String: ScreenTrack] = [:]
    private var state = QueueState()
    private var pendingTrackID: String?
    private var loadedTrackID: String?
    private var playbackRequested = false
    private var generation = 0
    var onStateChange: ((QueueState) -> Void)?
    var onError: ((Error) -> Void)?
    var onProgress: ((String) -> Void)?
    var onStreamResolved: ((String, QobuzStreamQuality, QobuzTrackURL) -> Void)?

    init(
        client: QobuzStreamResolving,
        quality: @escaping () -> QobuzStreamQuality,
        trackProvider: @escaping (String) -> ScreenTrack?
    ) {
        self.client = client
        self.quality = quality
        self.trackProvider = trackProvider
        player.onTimeChange = { [weak self] elapsed, duration in
            guard let self = self, self.state.currentTrackID != nil else { return }
            self.state.elapsed = min(max(0, elapsed), duration)
            self.notifyStateChange()
        }
        player.onEnded = { [weak self] in self?.advanceAfterEnd() }
        player.onStatusChange = { [weak self] status in
            guard let self = self else { return }
            switch status {
            case .failed(let error): self.onError?(error)
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
        player.stop()
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
        guard let track = currentTrackID.flatMap(trackProvider), track.duration > 0 else { return }
        let position = min(max(0, elapsed), track.duration)
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
        player.stop()
        state = QueueState()
        playbackRequested = false
        pendingTrackID = nil
        loadedTrackID = nil
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
        player.stop()
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
                        self.onStreamResolved?(id, requestedQuality, stream)
                        self.player.play(url: stream.url)
                    }
                }
            }
        )
    }

    private func transition(to index: Int, shouldPlay: Bool) {
        generation += 1
        player.stop()
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
            player.stop()
            loadedTrackID = nil
            notifyStateChange()
        }
    }

    private func notifyStateChange() {
        let snapshot = state
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(snapshot) }
    }
}
