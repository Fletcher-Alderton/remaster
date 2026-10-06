import AVFoundation
import Foundation

/// Shared AVPlayer transport for resolved Qobuz stream URLs. Queue and app UI state
/// remain owned by the playback controller that embeds this transport.
final class QobuzStreamPlayer {
    enum Status {
        case failed(Error)
        case playing
        case paused
    }

    var onStatusChange: ((Status) -> Void)?
    var onTimeChange: ((TimeInterval, TimeInterval) -> Void)?

    private var player: AVPlayer?
    private var itemObservation: NSKeyValueObservation?
    private var timeObserver: Any?

    deinit {
        stop()
    }

    func play(url: URL) {
        stop()
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let player = AVPlayer(playerItem: item)
        self.player = player

        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak player] observedItem, _ in
            DispatchQueue.main.async {
                switch observedItem.status {
                case .readyToPlay:
                    do {
                        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
                        try AVAudioSession.sharedInstance().setActive(true)
                    } catch {
                        self?.onStatusChange?(.failed(error))
                        return
                    }
                    player?.play()
                    self?.onStatusChange?(.playing)
                case .failed:
                    self?.onStatusChange?(.failed(observedItem.error ?? QobuzStreamingError.invalidResponse))
                default:
                    break
                }
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak item] time in
            guard let item = item else { return }
            let elapsed = CMTimeGetSeconds(time)
            let duration = CMTimeGetSeconds(item.duration)
            guard elapsed.isFinite, duration.isFinite, duration > 0 else { return }
            self?.onTimeChange?(elapsed, duration)
        }
    }

    func togglePlayback() {
        guard let player = player else { return }
        if player.rate == 0 {
            player.play()
            onStatusChange?(.playing)
        } else {
            player.pause()
            onStatusChange?(.paused)
        }
    }

    func seek(to ratio: Float) {
        guard let duration = player?.currentItem?.duration else { return }
        let seconds = CMTimeGetSeconds(duration) * Double(min(max(ratio, 0), 1))
        guard seconds.isFinite else { return }
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func stop() {
        itemObservation?.invalidate()
        itemObservation = nil
        if let timeObserver = timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}
