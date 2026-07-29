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

final class PlaybackSimulator: PlaybackControlling {
    private static let fallbackDuration: TimeInterval = 180

    private let stateQueue = DispatchQueue(label: "Music.PlaybackSimulator")
    private var timer: Timer?
    private let durationProvider: (String) -> TimeInterval
    private var state = QueueState()
    var onStateChange: ((QueueState) -> Void)?

    init(durationProvider: @escaping (String) -> TimeInterval) {
        self.durationProvider = durationProvider
    }

    deinit { timer?.invalidate() }

    var queueState: QueueState { return stateQueue.sync { state } }

    func setQueue(trackIDs: [String], startingAt index: Int = 0) {
        stateQueue.sync {
            state.trackIDs = trackIDs
            state.currentIndex = min(max(0, index), max(0, trackIDs.count - 1))
            state.elapsed = 0
            state.isPlaying = false
        }
        stopTimer()
        notifyStateChange()
    }

    func enqueue(trackID: String) {
        stateQueue.sync {
            if state.currentTrackID == nil {
                state.trackIDs = [trackID]
                state.currentIndex = 0
                state.elapsed = 0
            } else {
                state.trackIDs.append(trackID)
            }
        }
        notifyStateChange()
    }

    func playNext(trackID: String) {
        stateQueue.sync {
            guard state.currentTrackID != nil else {
                state.trackIDs = [trackID]
                state.currentIndex = 0
                state.elapsed = 0
                return
            }
            state.trackIDs.insert(trackID, at: min(state.currentIndex + 1, state.trackIDs.count))
        }
        notifyStateChange()
    }

    func togglePlayPause() { queueState.isPlaying ? pause() : play() }

    func play() {
        guard queueState.currentTrackID != nil else { return }
        stateQueue.sync { state.isPlaying = true }
        startTimer()
        notifyStateChange()
    }

    func pause() {
        stateQueue.sync { state.isPlaying = false }
        stopTimer()
        notifyStateChange()
    }

    func seek(to elapsed: TimeInterval) {
        stateQueue.sync {
            let duration = currentDurationLocked()
            state.elapsed = min(max(0, elapsed), duration)
        }
        notifyStateChange()
    }

    func next() {
        var shouldPause = false
        stateQueue.sync {
            guard !state.trackIDs.isEmpty else { return }
            if state.currentIndex + 1 < state.trackIDs.count {
                state.currentIndex += 1
                state.elapsed = 0
            } else {
                state.currentIndex = 0
                state.elapsed = 0
                state.isPlaying = false
                shouldPause = true
            }
        }
        if shouldPause { stopTimer() }
        notifyStateChange()
    }

    func previous() {
        stateQueue.sync {
            guard !state.trackIDs.isEmpty else { return }
            if state.elapsed > 3 { state.elapsed = 0 }
            else { state.currentIndex = max(0, state.currentIndex - 1); state.elapsed = 0 }
        }
        notifyStateChange()
    }

    func setShuffled(_ shuffled: Bool) {
        stateQueue.sync { state.isShuffled = shuffled }
        notifyStateChange()
    }

    func clearQueue() {
        stateQueue.sync { state = QueueState() }
        stopTimer()
        notifyStateChange()
    }

    private func startTimer() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.timer == nil,
                  self.queueState.isPlaying else { return }
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.timerDidFire()
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.timer?.invalidate()
            self?.timer = nil
        }
    }

    private func timerDidFire() {
        let advance = stateQueue.sync { () -> Bool in
            guard state.isPlaying, state.currentTrackID != nil else { return false }
            state.elapsed += 0.25
            return state.elapsed >= currentDurationLocked()
        }
        if advance { next() } else { notifyStateChange() }
    }

    private func currentDurationLocked() -> TimeInterval {
        guard let id = state.currentTrackID else { return 0 }
        let duration = durationProvider(id)
        return duration.isFinite && duration > 0 ? duration : PlaybackSimulator.fallbackDuration
    }

    private func notifyStateChange() {
        let snapshot = queueState
        DispatchQueue.main.async { [weak self] in self?.onStateChange?(snapshot) }
    }
}
