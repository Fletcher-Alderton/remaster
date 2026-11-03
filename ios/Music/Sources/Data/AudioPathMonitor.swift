import AVFoundation
import Foundation
import os

/// Collects the three formats that matter — the delivered stream, the equaliser's actual
/// processing format, and the audio session's rate — and publishes them as one report.
///
/// Writers are split across threads: the resolved stream and the session arrive on the
/// main queue, while the processing format arrives from the tap's `prepare`/`unprepare`.
/// A single lock guards the stored values; readers copy a value type out and never see a
/// half-updated report.
final class AudioPathMonitor {
    static let shared = AudioPathMonitor()
    static let didChange = Notification.Name("MusicAudioPathDidChange")

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var source: StreamFormatSummary?
    private var processing: TapFormatSummary?
    private var sessionSampleRate: Double = 0
    private var requestedOption: AudioSampleRateOption = .automatic
    private var appliedOption: AudioSampleRateOption = .automatic
    private var installed = false
    private var filterCount = 0
    private var attachment: EQTapAttachment = .none
    private var observers: [NSObjectProtocol] = []

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        requestedOption = AudioPathPreferences.shared.option
        appliedOption = .automatic

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshSession() })
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshSession() })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshSession()
            self?.updateProcessing(nil)
        })
        observers.append(center.addObserver(
            forName: EQChainRuntime.installStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            // The tap is released with the player item, so its reported format is stale.
            if !EQChainRuntime.shared.isInstalled { self?.updateProcessing(nil) }
            self?.refreshEqualiserState()
        })
        refreshEqualiserState()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - Reading

    func snapshot() -> AudioPathReport {
        os_unfair_lock_lock(lock)
        let state = AudioReportState(source: source,
                                     processing: processing,
                                     sessionSampleRate: sessionSampleRate,
                                     requestedOption: requestedOption,
                                     appliedOption: appliedOption,
                                     installed: installed,
                                     filterCount: filterCount,
                                     attachment: attachment)
        os_unfair_lock_unlock(lock)

        let activity: EQActivity
        if !state.installed {
            activity = .bypassed
        } else if state.filterCount == 0 {
            activity = .idle
        } else if state.attachment == .failed {
            activity = .unavailable
        } else if let processing = state.processing, processing.sampleRate > 0 {
            activity = .active
        } else {
            activity = .waiting
        }

        return AudioPathReport(source: state.source,
                               processing: state.processing,
                               activity: activity,
                               sessionSampleRate: state.sessionSampleRate,
                               requestedOption: state.requestedOption,
                               appliedOption: state.appliedOption)
    }

    // MARK: - Writing

    func updateSource(_ summary: StreamFormatSummary?) {
        mutate { $0.source = summary }
    }

    func updateProcessing(_ summary: TapFormatSummary?) {
        mutate { $0.processing = summary }
    }

    func refreshSession(_ session: AVAudioSession = .sharedInstance()) {
        mutate { state in
            state.sessionSampleRate = session.sampleRate
            state.requestedOption = AudioPathPreferences.shared.option
        }
    }

    /// Records the option that was in force when the session last activated.
    func noteAppliedOption(_ option: AudioSampleRateOption) {
        mutate { state in
            state.appliedOption = option
            state.requestedOption = AudioPathPreferences.shared.option
        }
    }

    func updateEqualiserState(installed: Bool, filterCount: Int) {
        mutate {
            $0.installed = installed
            $0.filterCount = filterCount
        }
    }

    /// Records whether the transport managed to put a processing tap on an item. Without
    /// this a failed tap and a late one look identical.
    func noteEQAttachment(_ attachment: EQTapAttachment) {
        mutate { $0.attachment = attachment }
    }

    /// Re-reads the profile state the equaliser already owns.
    /// Re-reads the profile state the equaliser already owns.
    ///
    /// The UI calls this with `publish: false` before reading a snapshot: publishing from a
    /// refresh that a `didChange` observer triggered would re-enter that observer.
    func refreshEqualiserState(publish: Bool = true) {
        let runtime = EQChainRuntime.shared
        mutate(publish: publish) {
            $0.installed = runtime.isInstalled
            $0.filterCount = runtime.installedFilterCount
        }
    }

    // MARK: - Private

    private struct AudioReportState {
        var source: StreamFormatSummary?
        var processing: TapFormatSummary?
        var sessionSampleRate: Double
        var requestedOption: AudioSampleRateOption
        var appliedOption: AudioSampleRateOption
        var installed: Bool
        var filterCount: Int
        var attachment: EQTapAttachment
    }

    private func mutate(publish shouldPublish: Bool = true, _ change: (inout AudioReportState) -> Void) {
        os_unfair_lock_lock(lock)
        var state = AudioReportState(source: source,
                                     processing: processing,
                                     sessionSampleRate: sessionSampleRate,
                                     requestedOption: requestedOption,
                                     appliedOption: appliedOption,
                                     installed: installed,
                                     filterCount: filterCount,
                                     attachment: attachment)
        os_unfair_lock_unlock(lock)

        change(&state)

        os_unfair_lock_lock(lock)
        source = state.source
        processing = state.processing
        sessionSampleRate = state.sessionSampleRate
        requestedOption = state.requestedOption
        appliedOption = state.appliedOption
        installed = state.installed
        filterCount = state.filterCount
        attachment = state.attachment
        os_unfair_lock_unlock(lock)

        if shouldPublish { publish() }
    }

    /// Posts on the main queue. The tap's `prepare` can call in from a non-main thread, so
    /// the notification is never delivered synchronously from there.
    private func publish() {
        // Always asynchronous: a synchronous post would re-enter any observer that reads a
        // snapshot, and the tap's prepare may call in from a non-main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }
}
