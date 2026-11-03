import AVFoundation
import XCTest
@testable import Music

final class AudioPathFormattingTests: XCTestCase {
    private func report(source: StreamFormatSummary? = nil,
                        processing: TapFormatSummary? = nil,
                        activity: EQActivity = .active,
                        session: Double = 48_000,
                        requested: AudioSampleRateOption = .automatic,
                        applied: AudioSampleRateOption = .automatic) -> AudioPathReport {
        AudioPathReport(source: source, processing: processing, activity: activity,
                        sessionSampleRate: session, requestedOption: requested,
                        appliedOption: applied)
    }

    private let hiRes = StreamFormatSummary(sampleRateHz: 96_000, bitDepth: 24, codec: "flac")
    private let float48 = TapFormatSummary(sampleRate: 48_000, channels: 2, bitsPerChannel: 32, isFloat: true)

    func testSourceLineDescribesBitDepthRateAndCodec() {
        XCTAssertEqual(AudioPathFormatting.sourceLine(report(source: hiRes)),
                       "Source: 24-bit / 96.0 kHz · flac")
    }

    func testSourceLineOmitsMissingDepthAndCodec() {
        let bare = StreamFormatSummary(sampleRateHz: 44_100, bitDepth: 0, codec: nil)
        XCTAssertEqual(AudioPathFormatting.sourceLine(report(source: bare)),
                       "Source: 44.1 kHz")
    }

    func testSourceLineWhenNothingHasPlayed() {
        XCTAssertEqual(AudioPathFormatting.sourceLine(report()),
                       "Source: unavailable (nothing has played yet)")
    }

    func testEqualiserLineForActiveFloatTap() {
        XCTAssertEqual(AudioPathFormatting.equaliserLine(report(processing: float48)),
                       "EQ: 32-bit float / 48.0 kHz · 2 ch")
    }

    func testEqualiserLineForIntegerTap() {
        let integer = TapFormatSummary(sampleRate: 44_100, channels: 2, bitsPerChannel: 24, isFloat: false)
        XCTAssertEqual(AudioPathFormatting.equaliserLine(report(processing: integer)),
                       "EQ: 24-bit / 44.1 kHz · 2 ch")
    }

    func testEqualiserLineStates() {
        XCTAssertEqual(AudioPathFormatting.equaliserLine(report(activity: .bypassed)),
                       "EQ: bypassed (no profiles)")
        XCTAssertEqual(AudioPathFormatting.equaliserLine(report(activity: .idle)),
                       "EQ: idle (all profiles off)")
        XCTAssertEqual(AudioPathFormatting.equaliserLine(report(activity: .unavailable)),
                       "EQ: unavailable (the tap could not be created)")
        XCTAssertEqual(AudioPathFormatting.equaliserLine(report(activity: .waiting)),
                       "EQ: ready (engages when audio plays)")
    }

    func testVerdictWhenRatesMatch() {
        let source = StreamFormatSummary(sampleRateHz: 44_100, bitDepth: 16, codec: "flac")
        let processing = TapFormatSummary(sampleRate: 44_100, channels: 2, bitsPerChannel: 32, isFloat: true)
        XCTAssertEqual(AudioPathFormatting.verdictLine(report(source: source, processing: processing)),
                       "EQ runs at the source rate (44.1 kHz).")
    }

    func testVerdictWhenConvertedDown() {
        XCTAssertEqual(AudioPathFormatting.verdictLine(report(source: hiRes, processing: float48)),
                       "Converted 2:1 before the EQ (96.0 kHz → 48.0 kHz).")
    }

    func testVerdictWithFractionalRatio() {
        let source = StreamFormatSummary(sampleRateHz: 88_200, bitDepth: 24, codec: "flac")
        let processing = TapFormatSummary(sampleRate: 48_000, channels: 2, bitsPerChannel: 32, isFloat: true)
        XCTAssertEqual(AudioPathFormatting.verdictLine(report(source: source, processing: processing)),
                       "Converted 1.8:1 before the EQ (88.2 kHz → 48.0 kHz).")
    }

    func testVerdictWhenUpsampled() {
        let source = StreamFormatSummary(sampleRateHz: 44_100, bitDepth: 16, codec: "flac")
        let processing = TapFormatSummary(sampleRate: 48_000, channels: 2, bitsPerChannel: 32, isFloat: true)
        XCTAssertEqual(AudioPathFormatting.verdictLine(report(source: source, processing: processing)),
                       "EQ runs above the source rate (44.1 kHz → 48.0 kHz).")
    }

    func testVerdictIsEmptyWhenEqualiserIsNotActive() {
        XCTAssertEqual(AudioPathFormatting.verdictLine(report(source: hiRes, processing: float48, activity: .idle)), "")
        XCTAssertEqual(AudioPathFormatting.verdictLine(report(source: hiRes, processing: float48, activity: .bypassed)), "")
    }

    func testVerdictWhenSourceIsUnknown() {
        XCTAssertEqual(AudioPathFormatting.verdictLine(report(processing: float48)),
                       "EQ rate cannot be compared yet.")
    }

    func testSampleRateLineAutomatic() {
        XCTAssertEqual(AudioPathFormatting.sampleRateLine(report()),
                       "Sample rate: automatic (session 48.0 kHz).")
    }

    func testSampleRateLineInactive() {
        XCTAssertEqual(AudioPathFormatting.sampleRateLine(report(session: 0)), "Session inactive.")
    }

    func testSampleRateLineRequestedAndInUse() {
        XCTAssertEqual(AudioPathFormatting.sampleRateLine(
            report(requested: .hz48000, applied: .hz48000)),
            "Sample rate: 48.0 kHz requested and in use.")
    }

    func testSampleRateLinePendingUntilNextActivation() {
        XCTAssertEqual(AudioPathFormatting.sampleRateLine(
            report(requested: .hz96000, applied: .hz44100)),
            "Sample rate: 96.0 kHz requested. Applies from the next playback start.")
    }

    func testSampleRateLineRefused() {
        XCTAssertEqual(AudioPathFormatting.sampleRateLine(
            report(session: 44_100, requested: .hz192000, applied: .hz192000)),
            "Sample rate: 192.0 kHz requested; session is 44.1 kHz.")
    }

    func testCaveatNeverClaimsBitPerfect() {
        XCTAssertTrue(AudioPathFormatting.bitDepthCaveat.contains("chosen by iOS"))
        XCTAssertTrue(AudioPathFormatting.bitDepthCaveat.contains("not bit-perfect"))
        XCTAssertTrue(AudioPathFormatting.bitDepthCaveat.contains("while EQ is active"))
    }
}

final class AudioFormatSummaryTests: XCTestCase {
    func testStreamSummaryConvertsKilohartzToHertz() {
        let stream = QobuzTrackURL(url: URL(string: "https://example.com/a.flac")!,
                                   formatID: 27, mimeType: "audio/flac",
                                   samplingRate: 96, bitDepth: 24)
        let summary = StreamFormatSummary.from(stream)
        XCTAssertEqual(summary.sampleRateHz, 96_000)
        XCTAssertEqual(summary.bitDepth, 24)
        XCTAssertEqual(summary.codec, "flac")
    }

    func testStreamSummaryHandlesMissingValues() {
        let stream = QobuzTrackURL(url: URL(string: "https://example.com/a.mp3")!,
                                   formatID: 5, mimeType: "", samplingRate: 0, bitDepth: 0)
        let summary = StreamFormatSummary.from(stream)
        XCTAssertEqual(summary.sampleRateHz, 0)
        XCTAssertEqual(summary.bitDepth, 0)
        XCTAssertNil(summary.codec)
    }

    func testTapSummaryReadsIntegerFormat() {
        var description = AudioStreamBasicDescription()
        description.mSampleRate = 96_000
        description.mChannelsPerFrame = 2
        description.mBitsPerChannel = 24
        description.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        let summary = TapFormatSummary.from(description)
        XCTAssertEqual(summary.sampleRate, 96_000)
        XCTAssertEqual(summary.channels, 2)
        XCTAssertEqual(summary.bitsPerChannel, 24)
        XCTAssertFalse(summary.isFloat)
    }

    func testTapSummaryReadsFloatFormat() {
        var description = AudioStreamBasicDescription()
        description.mSampleRate = 44_100
        description.mChannelsPerFrame = 2
        description.mBitsPerChannel = 32
        description.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        let summary = TapFormatSummary.from(description)
        XCTAssertTrue(summary.isFloat)
        XCTAssertEqual(summary.bitsPerChannel, 32)
    }

    func testTapSummaryKeepsUnknownDepthAtZero() {
        var description = AudioStreamBasicDescription()
        description.mSampleRate = 48_000
        description.mChannelsPerFrame = 2
        description.mBitsPerChannel = 0
        XCTAssertEqual(TapFormatSummary.from(description).bitsPerChannel, 0)
    }
}

final class AudioPathPreferencesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AudioPathTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testEveryOptionRoundTrips() {
        let preferences = AudioPathPreferences(defaults: defaults, key: "k")
        for option in AudioSampleRateOption.allCases {
            preferences.option = option
            XCTAssertEqual(preferences.option, option)
            let reopened = AudioPathPreferences(defaults: defaults, key: "k")
            XCTAssertEqual(reopened.option, option)
        }
    }

    func testUnknownStoredValueReadsAsAutomatic() {
        defaults.set(12_345, forKey: "k")
        XCTAssertEqual(AudioPathPreferences(defaults: defaults, key: "k").option, .automatic)
    }

    func testAutomaticRequestsNothing() {
        let preferences = AudioPathPreferences(defaults: defaults, key: "k")
        preferences.option = .automatic
        XCTAssertFalse(preferences.apply(to: AVAudioSession.sharedInstance()))
    }

    func testOptionTitlesAndRates() {
        XCTAssertNil(AudioSampleRateOption.automatic.hertz)
        XCTAssertEqual(AudioSampleRateOption.hz44100.hertz, 44_100)
        XCTAssertEqual(AudioSampleRateOption.hz192000.hertz, 192_000)
        XCTAssertEqual(AudioSampleRateOption.hz88200.title, "88.2")
    }
}

final class AudioPathMonitorTests: XCTestCase {
    func testSourceAndProcessingAreReported() {
        let monitor = AudioPathMonitor()
        monitor.updateEqualiserState(installed: true, filterCount: 3)
        monitor.noteEQAttachment(.attached)
        monitor.updateSource(StreamFormatSummary(sampleRateHz: 96_000, bitDepth: 24, codec: "flac"))
        monitor.updateProcessing(TapFormatSummary(sampleRate: 48_000, channels: 2,
                                                  bitsPerChannel: 32, isFloat: true))

        let report = monitor.snapshot()
        XCTAssertEqual(report.source?.sampleRateHz, 96_000)
        XCTAssertEqual(report.processing?.sampleRate, 48_000)
        XCTAssertEqual(report.activity, .active)
        XCTAssertEqual(AudioPathFormatting.verdictLine(report),
                       "Converted 2:1 before the EQ (96.0 kHz → 48.0 kHz).")
    }

    func testClearingProcessingReturnsToStarting() {
        let monitor = AudioPathMonitor()
        monitor.updateEqualiserState(installed: true, filterCount: 2)
        monitor.noteEQAttachment(.attached)
        monitor.updateProcessing(TapFormatSummary(sampleRate: 48_000, channels: 2,
                                                  bitsPerChannel: 32, isFloat: true))
        monitor.updateProcessing(nil)
        XCTAssertEqual(monitor.snapshot().activity, .waiting)
    }

    func testAllFiltersOffIsIdle() {
        let monitor = AudioPathMonitor()
        monitor.updateEqualiserState(installed: true, filterCount: 0)
        XCTAssertEqual(monitor.snapshot().activity, .idle)
    }

    func testNoProfilesIsBypassed() {
        let monitor = AudioPathMonitor()
        monitor.updateEqualiserState(installed: false, filterCount: 0)
        XCTAssertEqual(monitor.snapshot().activity, .bypassed)
    }

    func testAttachedButUnpreparedTapIsWaiting() {
        let monitor = AudioPathMonitor()
        monitor.updateEqualiserState(installed: true, filterCount: 2)
        monitor.noteEQAttachment(.attached)
        XCTAssertEqual(monitor.snapshot().activity, .waiting)
        XCTAssertEqual(AudioPathFormatting.equaliserLine(monitor.snapshot()),
                       "EQ: ready (engages when audio plays)")
    }

    func testMissingTapIsUnavailable() {
        let monitor = AudioPathMonitor()
        monitor.updateEqualiserState(installed: true, filterCount: 2)
        monitor.noteEQAttachment(.failed)
        XCTAssertEqual(monitor.snapshot().activity, .unavailable)
    }

    func testMutationsPostAChangeNotification() {
        let monitor = AudioPathMonitor()
        let expectation = XCTNSNotificationExpectation(name: AudioPathMonitor.didChange, object: monitor)
        monitor.updateSource(StreamFormatSummary(sampleRateHz: 44_100, bitDepth: 16, codec: "flac"))
        wait(for: [expectation], timeout: 1)
    }

    func testAppliedOptionIsRecorded() {
        let monitor = AudioPathMonitor()
        monitor.noteAppliedOption(.hz48000)
        XCTAssertEqual(monitor.snapshot().appliedOption, .hz48000)
    }
}

@MainActor
final class AudioPathSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AudioPathSettings." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    func testSectionShowsMeasuredLinesAndControl() throws {
        let store = EQProfileStore(defaults: defaults, key: "profiles", runtime: EQChainRuntime())
        let controller = SettingsViewController(items: [], lastFMUsername: nil,
                                                appearanceMode: AppearanceMode.allCases[0],
                                                eqStore: store)
        controller.loadViewIfNeeded()
        let views = descendants(controller.view)

        let control = try XCTUnwrap(views.compactMap { $0 as? UISegmentedControl }
            .first { $0.accessibilityIdentifier == "settings.audioPath.sampleRate" })
        XCTAssertEqual(control.numberOfSegments, AudioSampleRateOption.allCases.count)

        let source = try XCTUnwrap(views.compactMap { $0 as? UILabel }
            .first { $0.accessibilityIdentifier == "settings.audioPath.source" })
        XCTAssertFalse((source.text ?? "").isEmpty)

        let caveat = try XCTUnwrap(views.compactMap { $0 as? UILabel }
            .first { $0.accessibilityIdentifier == "settings.audioPath.caveat" })
        XCTAssertTrue((caveat.text ?? "").contains("not bit-perfect"))
    }

    func testSelectingARatePersistsIt() throws {
        let store = EQProfileStore(defaults: defaults, key: "profiles", runtime: EQChainRuntime())
        let controller = SettingsViewController(items: [], lastFMUsername: nil,
                                                appearanceMode: AppearanceMode.allCases[0],
                                                eqStore: store)
        controller.loadViewIfNeeded()
        let control = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UISegmentedControl }
            .first { $0.accessibilityIdentifier == "settings.audioPath.sampleRate" })

        let index = try XCTUnwrap(AudioSampleRateOption.allCases.firstIndex(of: .hz48000))
        control.selectedSegmentIndex = index
        control.sendActions(for: .valueChanged)

        XCTAssertEqual(AudioPathPreferences.shared.option, .hz48000)
        AudioPathPreferences.shared.option = .automatic
    }
}

