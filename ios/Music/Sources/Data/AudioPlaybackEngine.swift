import AVFoundation
import Foundation
import MediaPlayer

/// Real local-file playback for iOS 12.
///
/// Files are scheduled back-to-back on one player node, so tracks with a
/// compatible format cross their boundary without stopping the render graph.
/// The audio session requests the current source rate and intentionally applies
/// no app-side EQ, gain, crossfade, or other DSP.
final class AudioPlaybackEngine: NSObject, PlaybackControlling {
    private static let fallbackDuration: TimeInterval = 180

    private let trackProvider: (String) -> Track?
    private let fileURLProvider: (String) -> URL?
    private let audioSession = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private var state = QueueState()
    private var timer: Timer?
    private var lastTimerDate: Date?
    private var scheduleGeneration = 0
    private var scheduledFiles: [AVAudioFile] = []
    private var hasScheduledAudio = false
    private var interruptionWasPlaying = false
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []

    var onStateChange: ((QueueState) -> Void)?
    var queueState: QueueState { return state }

    init(
        trackProvider: @escaping (String) -> Track?,
        fileURLProvider: @escaping (String) -> URL?
    ) {
        self.trackProvider = trackProvider
        self.fileURLProvider = fileURLProvider
        super.init()

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 1
        player.volume = 1

        observeAudioSession()
        configureRemoteCommands()
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        for (command, target) in remoteCommandTargets {
            command.removeTarget(target)
        }
        player.stop()
        engine.stop()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func setQueue(trackIDs: [String], startingAt index: Int = 0) {
        let shuffled = state.isShuffled
        state = QueueState(
            trackIDs: trackIDs,
            currentIndex: min(max(0, index), max(0, trackIDs.count - 1)),
            elapsed: 0,
            isPlaying: false,
            isShuffled: shuffled
        )
        stopProgressTimer()
        rebuildSchedule(autoplay: false)
        notifyStateChange()
    }

    func enqueue(trackID: String) {
        guard state.currentTrackID != nil else {
            setQueue(trackIDs: [trackID], startingAt: 0)
            return
        }

        state.trackIDs.append(trackID)
        // Appending can be added to the player node without disturbing audio.
        if hasScheduledAudio {
            scheduleTrack(at: state.trackIDs.count - 1, generation: scheduleGeneration)
        }
        notifyStateChange()
    }

    func playNext(trackID: String) {
        guard state.currentTrackID != nil else {
            setQueue(trackIDs: [trackID], startingAt: 0)
            return
        }
        state.trackIDs.insert(trackID, at: min(state.currentIndex + 1, state.trackIDs.count))
        rebuildSchedule(autoplay: state.isPlaying)
        notifyStateChange()
    }

    func togglePlayPause() {
        state.isPlaying ? pause() : play()
    }

    func play() {
        guard state.currentTrackID != nil else { return }
        if !hasScheduledAudio {
            rebuildSchedule(autoplay: false)
        }

        state.isPlaying = true
        lastTimerDate = Date()
        if hasScheduledAudio {
            startEngineIfNeeded()
            player.play()
        }
        startProgressTimer()
        notifyStateChange()
    }

    func pause() {
        guard state.isPlaying else { return }
        updateElapsedFromClock()
        state.isPlaying = false
        player.pause()
        stopProgressTimer()
        notifyStateChange()
    }

    func seek(to elapsed: TimeInterval) {
        guard state.currentTrackID != nil else { return }
        let duration = currentDuration()
        state.elapsed = min(max(0, elapsed), duration)
        rebuildSchedule(autoplay: state.isPlaying)
        notifyStateChange()
    }

    func next() {
        guard !state.trackIDs.isEmpty else { return }
        let autoplay = state.isPlaying
        if state.currentIndex + 1 < state.trackIDs.count {
            state.currentIndex += 1
            state.elapsed = 0
            rebuildSchedule(autoplay: autoplay)
        } else {
            state.elapsed = currentDuration()
            state.isPlaying = false
            player.stop()
            stopProgressTimer()
        }
        notifyStateChange()
    }

    func previous() {
        guard !state.trackIDs.isEmpty else { return }
        let autoplay = state.isPlaying
        if state.elapsed > 3 {
            state.elapsed = 0
        } else {
            state.currentIndex = max(0, state.currentIndex - 1)
            state.elapsed = 0
        }
        rebuildSchedule(autoplay: autoplay)
        notifyStateChange()
    }

    func setShuffled(_ shuffled: Bool) {
        state.isShuffled = shuffled
        notifyStateChange()
    }

    func clearQueue() {
        scheduleGeneration += 1
        player.stop()
        state = QueueState()
        scheduledFiles.removeAll()
        hasScheduledAudio = false
        stopProgressTimer()
        updateNowPlayingInfo()
        notifyStateChange()
    }

    private func rebuildSchedule(autoplay: Bool) {
        scheduleGeneration += 1
        let generation = scheduleGeneration
        player.stop()
        scheduledFiles.removeAll()
        hasScheduledAudio = false

        guard state.currentTrackID != nil else { return }
        configureSessionForCurrentTrack()
        startEngineIfNeeded()

        for index in state.currentIndex..<state.trackIDs.count {
            if !scheduleTrack(at: index, generation: generation) {
                // Do not schedule past an unreadable file; this keeps the UI
                // queue aligned with what is actually reaching the output.
                break
            }
        }

        if autoplay {
            state.isPlaying = true
            lastTimerDate = Date()
            if hasScheduledAudio { player.play() }
            startProgressTimer()
        }
    }

    @discardableResult
    private func scheduleTrack(at index: Int, generation: Int) -> Bool {
        guard state.trackIDs.indices.contains(index),
              let url = fileURLProvider(state.trackIDs[index]) else {
            return false
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            NSLog("Music cannot decode %@: %@", url.lastPathComponent, error.localizedDescription)
            return false
        }

        let startFrame: AVAudioFramePosition
        if index == state.currentIndex, state.elapsed > 0 {
            let requested = AVAudioFramePosition(state.elapsed * file.processingFormat.sampleRate)
            startFrame = min(max(0, requested), file.length)
        } else {
            startFrame = 0
        }
        let remaining = file.length - startFrame
        guard remaining > 0 else { return false }

        scheduledFiles.append(file)
        hasScheduledAudio = true
        #if DEBUG
        UserDefaults.standard.set(true, forKey: "diagnostics.audioFileScheduled")
        UserDefaults.standard.set(
            file.processingFormat.sampleRate,
            forKey: "diagnostics.sourceSampleRate"
        )
        #endif
        let frameCount = AVAudioFrameCount(min(
            AVAudioFramePosition(UInt32.max),
            remaining
        ))
        player.scheduleSegment(
            file,
            startingFrame: startFrame,
            frameCount: frameCount,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.scheduledTrackDidFinish(index: index, generation: generation)
            }
        }
        NSLog(
            "Music scheduled %@ at %.0f Hz (%lld frames)",
            url.lastPathComponent,
            file.processingFormat.sampleRate,
            remaining
        )
        return true
    }

    private func scheduledTrackDidFinish(index: Int, generation: Int) {
        guard generation == scheduleGeneration, index == state.currentIndex else { return }
        if index + 1 < state.trackIDs.count {
            state.currentIndex = index + 1
            state.elapsed = 0
            lastTimerDate = Date()
        } else {
            state.elapsed = currentDuration()
            state.isPlaying = false
            stopProgressTimer()
        }
        notifyStateChange()
    }

    private func configureSessionForCurrentTrack() {
        guard let id = state.currentTrackID,
              let url = fileURLProvider(id),
              let file = try? AVAudioFile(forReading: url) else { return }
        let sourceRate = file.processingFormat.sampleRate

        do {
            engine.pause()
            try audioSession.setActive(false)
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setPreferredSampleRate(sourceRate)
            try audioSession.setActive(true)
        } catch {
            // Playback may still succeed using the route's existing format.
            NSLog("Music audio-session configuration failed: %@", error.localizedDescription)
        }
    }

    private func startEngineIfNeeded() {
        guard hasScheduledAudio || fileURLProvider(state.currentTrackID ?? "") != nil else { return }
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            #if DEBUG
            UserDefaults.standard.set(engine.isRunning, forKey: "diagnostics.audioEngineRunning")
            UserDefaults.standard.set(audioSession.sampleRate, forKey: "diagnostics.routeSampleRate")
            #endif
        } catch {
            hasScheduledAudio = false
            NSLog("Music audio engine failed to start: %@", error.localizedDescription)
        }
    }

    private func startProgressTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.progressTimerDidFire()
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopProgressTimer() {
        timer?.invalidate()
        timer = nil
        lastTimerDate = nil
    }

    private func progressTimerDidFire() {
        guard state.isPlaying else { return }
        updateElapsedFromClock()
        let duration = currentDuration()
        if !hasScheduledAudio, state.elapsed >= duration {
            next()
            return
        }
        state.elapsed = min(state.elapsed, duration)
        notifyStateChange()
    }

    private func updateElapsedFromClock() {
        guard state.isPlaying else { return }
        let now = Date()
        if let previous = lastTimerDate {
            state.elapsed += now.timeIntervalSince(previous)
        }
        lastTimerDate = now
    }

    private func currentDuration() -> TimeInterval {
        guard let id = state.currentTrackID else { return 0 }
        let duration = trackProvider(id)?.duration ?? 0
        return duration.isFinite && duration > 0 ? duration : AudioPlaybackEngine.fallbackDuration
    }

    private func notifyStateChange() {
        updateNowPlayingInfo()
        let snapshot = state
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(snapshot)
        }
    }

    private func observeAudioSession() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: audioSession
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            interruptionWasPlaying = state.isPlaying
            if state.isPlaying { pause() }
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if interruptionWasPlaying && options.contains(.shouldResume) {
                try? audioSession.setActive(true)
                play()
            }
            interruptionWasPlaying = false
        @unknown default:
            break
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else { return }
        if reason == .oldDeviceUnavailable {
            pause()
        } else if state.isPlaying {
            rebuildSchedule(autoplay: true)
            notifyStateChange()
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        addRemoteTarget(to: center.playCommand) { [weak self] _ in
            self?.play()
            return self?.queueState.currentTrackID == nil ? .noActionableNowPlayingItem : .success
        }
        addRemoteTarget(to: center.pauseCommand) { [weak self] _ in
            self?.pause()
            return .success
        }
        addRemoteTarget(to: center.nextTrackCommand) { [weak self] _ in
            self?.next()
            return .success
        }
        addRemoteTarget(to: center.previousTrackCommand) { [weak self] _ in
            self?.previous()
            return .success
        }
        addRemoteTarget(to: center.changePlaybackPositionCommand) { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self?.seek(to: positionEvent.positionTime)
            return .success
        }
    }

    private func addRemoteTarget(
        to command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let target = command.addTarget(handler: handler)
        remoteCommandTargets.append((command, target))
    }

    private func updateNowPlayingInfo() {
        guard let id = state.currentTrackID, let track = trackProvider(id) else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.albumTitle,
            MPMediaItemPropertyPlaybackDuration: currentDuration(),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0
        ]
    }
}
