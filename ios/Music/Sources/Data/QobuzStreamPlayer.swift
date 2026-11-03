import AVFoundation
import Foundation

/// Shared AVPlayer transport for resolved Qobuz stream URLs. Queue and app UI state
/// remain owned by the playback controller that embeds this transport.
///
/// A single long-lived `AVQueuePlayer` is used for the lifetime of the transport so that
/// track changes never tear down audio output. When the device is locked the app runs in
/// the background, and iOS refuses to (re)activate a non-mixable audio session for an app
/// that has stopped producing audio (`AVAudioSession.ErrorCode.cannotInterruptOthers`,
/// OSStatus 560557684 / '!int'). Keeping the session active and queueing the next item
/// ahead of time lets AVFoundation advance between tracks without that reactivation.
final class QobuzStreamPlayer {
    enum Status {
        case failed(Error)
        case playing
        case paused
    }

    static func configurePlaybackAudioSession() throws {
        // Share the music route selected in Control Center, including AirPlay.
        try AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .default, policy: .longFormAudio, options: []
        )
    }

    var onStatusChange: ((Status) -> Void)?
    var onTimeChange: ((TimeInterval, TimeInterval) -> Void)?
    /// The current item finished and no preloaded item followed it.
    var onEnded: (() -> Void)?
    /// The current item finished and playback continued into the preloaded item.
    var onAdvancedToPreloaded: (() -> Void)?

    private let player = AVQueuePlayer()
    private var currentItem: AVPlayerItem?
    private var preloadedItem: AVPlayerItem?
    private var playbackRequested = false
    private var sessionActive = false
    private var itemObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var timeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var eqObservers: [NSObjectProtocol] = []

    init() {
        player.actionAtItemEnd = .advance
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self = self, let item = self.currentItem, self.player.currentItem === item else { return }
            let elapsed = CMTimeGetSeconds(time)
            let duration = CMTimeGetSeconds(item.duration)
            guard elapsed.isFinite, duration.isFinite, duration > 0 else { return }
            self.onTimeChange?(elapsed, duration)
        }
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            guard let self = self, let item = note.object as? AVPlayerItem, item === self.currentItem else { return }
            self.currentItemDidEnd()
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            // The system deactivated the session; the next play request must reactivate it.
            self?.sessionActive = false
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.sessionActive = false
        })
        // Broadcast, not a closure: two transports exist (the playback controller and
        // the streaming test screen) and a single closure would be overwritten.
        eqObservers.append(center.addObserver(
            forName: EQChainRuntime.installStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshEQAttachment()
        })
        // Toggling a profile does not change the install state, but it does change the
        // chain. Re-attach only when an item never got a mix, which is the safe case.
        eqObservers.append(center.addObserver(
            forName: EQChainRuntime.chainDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshEQAttachment()
        })
    }

    deinit {
        stop()
        if let timeObserver = timeObserver { player.removeTimeObserver(timeObserver) }
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        eqObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func play(url: URL, startingAt elapsed: TimeInterval = 0) {
        stop()
        playbackRequested = true
        activateSessionIfNeeded()
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        currentItem = item
        attachEQ(to: item, asset: asset)
        observe(item)
        player.insert(item, after: nil)
        if elapsed.isFinite && elapsed > 0 {
            player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600))
        }
        player.play()
    }

    /// Queue the stream that should follow the current item so the transition happens
    /// inside AVFoundation, even while the app is suspended behind the lock screen.
    func preload(url: URL) {
        guard let current = currentItem, player.currentItem === current else { return }
        cancelPreload()
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        guard player.canInsert(item, after: current) else { return }
        preloadedItem = item
        // Attached now, with roughly 30 seconds of lead, so the equaliser is running
        // before this item ever becomes current.
        attachEQ(to: item, asset: asset)
        observe(item)
        player.insert(item, after: current)
    }

    func cancelPreload() {
        guard let item = preloadedItem else { return }
        preloadedItem = nil
        stopObserving(item)
        if player.items().contains(where: { $0 === item }) { player.remove(item) }
    }

    var hasPreloadedItem: Bool { preloadedItem != nil }

    func play() {
        playbackRequested = true
        guard currentItem != nil else { return }
        activateSessionIfNeeded()
        player.play()
        onStatusChange?(.playing)
    }

    func pause() {
        playbackRequested = false
        guard currentItem != nil else { return }
        player.pause()
        onStatusChange?(.paused)
    }

    func togglePlayback() {
        guard currentItem != nil else { return }
        if player.rate == 0 { play() } else { pause() }
    }

    func seek(to elapsed: TimeInterval) {
        guard elapsed.isFinite, currentItem != nil else { return }
        player.seek(to: CMTime(seconds: max(0, elapsed), preferredTimescale: 600))
    }

    func seek(to ratio: Float) {
        guard let duration = currentItem?.duration else { return }
        let seconds = CMTimeGetSeconds(duration) * Double(min(max(ratio, 0), 1))
        guard seconds.isFinite else { return }
        seek(to: seconds)
    }

    /// Drops all items but keeps the player and audio session alive, so the next
    /// `play(url:)` does not need to reactivate the session from the background.
    func stop() {
        playbackRequested = false
        itemObservations.values.forEach { $0.invalidate() }
        itemObservations.removeAll()
        currentItem = nil
        preloadedItem = nil
        player.pause()
        player.removeAllItems()
    }

    // MARK: - Private

    private func activateSessionIfNeeded() {
        guard !sessionActive else { return }
        do {
            try Self.configurePlaybackAudioSession()
            // The rate request is applied here, never mid-render: changing it while audio
            // is running can reconfigure the route and interrupt playback.
            let preferences = AudioPathPreferences.shared
            preferences.apply(to: AVAudioSession.sharedInstance())
            try AVAudioSession.sharedInstance().setActive(true)
            sessionActive = true
            AudioPathMonitor.shared.noteAppliedOption(preferences.option)
            AudioPathMonitor.shared.refreshSession()
        } catch {
            // Not fatal: if the session is still usable (e.g. it was never actually
            // deactivated) AVPlayer keeps playing. A genuinely unusable item surfaces
            // through the item status observation instead of aborting playback here.
            NSLog("QobuzStreamPlayer: audio session activation failed: \(error)")
        }
    }

    // MARK: - Equaliser attachment

    /// Installs a post-effects tap on `item` when at least one profile is stored.
    ///
    /// Local files resolve their tracks synchronously, so the mix is in place before
    /// the item is inserted. Remote assets load metadata off the main thread and attach
    /// afterwards; for preloaded items that happens tens of seconds before the item is
    /// used.
    private func attachEQ(to item: AVPlayerItem, asset: AVURLAsset) {
        let runtime = EQChainRuntime.shared
        guard runtime.isInstalled else {
            AudioPathMonitor.shared.noteEQAttachment(.none)
            return
        }

        if asset.url.isFileURL {
            guard let track = asset.tracks(withMediaType: .audio).first else {
                NSLog("EQ: local asset has no audio track")
                AudioPathMonitor.shared.noteEQAttachment(.failed)
                return
            }
            guard let mix = EQAudioMixFactory.makeAudioMix(for: track, source: runtime) else {
                NSLog("EQ: could not create a tap for the local asset")
                AudioPathMonitor.shared.noteEQAttachment(.failed)
                return
            }
            item.audioMix = mix
            NSLog("EQ: tap attached to a local asset")
            AudioPathMonitor.shared.noteEQAttachment(.attached)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak item] in
            guard let track = asset.tracks(withMediaType: .audio).first else {
                NSLog("EQ: remote asset has no audio track")
                DispatchQueue.main.async { AudioPathMonitor.shared.noteEQAttachment(.failed) }
                return
            }
            guard let mix = EQAudioMixFactory.makeAudioMix(for: track, source: EQChainRuntime.shared) else {
                NSLog("EQ: could not create a tap for the remote asset")
                DispatchQueue.main.async { AudioPathMonitor.shared.noteEQAttachment(.failed) }
                return
            }
            DispatchQueue.main.async {
                guard let self = self, let item = item else { return }
                guard item === self.currentItem || item === self.preloadedItem else { return }
                item.audioMix = mix
                NSLog("EQ: tap attached to a remote asset")
                AudioPathMonitor.shared.noteEQAttachment(.attached)
            }
        }
    }

    /// A profile was added for the first time, or the last one was deleted.
    private func refreshEQAttachment() {
        guard EQChainRuntime.shared.isInstalled else {
            currentItem?.audioMix = nil
            preloadedItem?.audioMix = nil
            AudioPathMonitor.shared.noteEQAttachment(.none)
            return
        }
        for item in [currentItem, preloadedItem].compactMap({ $0 }) where item.audioMix == nil {
            guard let asset = item.asset as? AVURLAsset else { continue }
            attachEQ(to: item, asset: asset)
        }
    }

    private func currentItemDidEnd() {
        if let ended = currentItem { stopObserving(ended) }
        guard let next = preloadedItem else {
            currentItem = nil
            onEnded?()
            return
        }
        currentItem = next
        preloadedItem = nil
        if player.currentItem !== next {
            // Normally AVQueuePlayer has already advanced; make sure it does.
            if player.items().contains(where: { $0 === next }) { player.advanceToNextItem() }
            else { player.insert(next, after: nil) }
        }
        if playbackRequested { player.play() }
        onAdvancedToPreloaded?()
        if next.status == .failed {
            onStatusChange?(.failed(next.error ?? QobuzStreamingError.invalidResponse))
        }
    }

    private func observe(_ item: AVPlayerItem) {
        itemObservations[ObjectIdentifier(item)] = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] observedItem, _ in
            DispatchQueue.main.async {
                guard let self = self, let item = item, self.itemObservations[ObjectIdentifier(item)] != nil else { return }
                // A preloaded item reports its status once it becomes the current item.
                guard item === self.currentItem else { return }
                switch observedItem.status {
                case .readyToPlay:
                    if self.playbackRequested {
                        if self.player.rate == 0 { self.player.play() }
                        self.onStatusChange?(.playing)
                    }
                case .failed:
                    self.onStatusChange?(.failed(observedItem.error ?? QobuzStreamingError.invalidResponse))
                default:
                    break
                }
            }
        }
    }

    private func stopObserving(_ item: AVPlayerItem) {
        itemObservations.removeValue(forKey: ObjectIdentifier(item))?.invalidate()
    }
}
