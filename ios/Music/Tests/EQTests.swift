import AVFoundation
import XCTest
@testable import Music

final class EQProfileParserTests: XCTestCase {
    /// The exact profile from the feature request.
    static let suppliedProfile = """
    Preamp: -2.0 dB
    Filter 1: ON LSC Fc 60 Hz Gain -3.7 dB Q 0.70
    Filter 2: ON PK Fc 480 Hz Gain 1.1 dB Q 2.00
    Filter 3: ON PK Fc 1600 Hz Gain -0.5 dB Q 1.50
    Filter 4: ON PK Fc 5178 Hz Gain 2.0 dB Q 1.20
    Filter 5: ON PK Fc 12401 Hz Gain -0.3 dB Q 1.90
    Filter 6: OFF PK Fc 9350 Hz Gain -0.3 dB Q 2.90
    Filter 7: ON PK Fc 8032 Hz Gain -0.7 dB Q 7.00
    Filter 8: ON PK Fc 8950 Hz Gain 1.2 dB Q 6.69
    Filter 9: ON PK Fc 3824 Hz Gain -0.5 dB Q 2.25
    Filter 10: ON PK Fc 14791 Hz Gain -0.3 dB Q 7.00
    Filter 11: ON PK Fc 3049 Hz Gain -2.4 dB Q 3.30
    Filter 12: ON PK Fc 11573 Hz Gain -4.0 dB Q 7.78
    Filter 13: ON PK Fc 8928 Hz Gain -6.1 dB Q 4.62
    """

    func testParsesTheSuppliedProfileExactly() throws {
        let result = try EQProfileParser.parse(Self.suppliedProfile)

        XCTAssertEqual(result.preamp, -2.0, accuracy: 1e-9)
        XCTAssertEqual(result.filters.count, 13)
        XCTAssertTrue(result.skippedLines.isEmpty, "unexpected skipped lines: \(result.skippedLines)")

        let first = try XCTUnwrap(result.filters.first)
        XCTAssertEqual(first.index, 1)
        XCTAssertEqual(first.kind, .lowShelfQ)
        XCTAssertEqual(first.frequency, 60, accuracy: 1e-9)
        XCTAssertEqual(first.gain, -3.7, accuracy: 1e-9)
        XCTAssertEqual(first.q, 0.70, accuracy: 1e-9)
        XCTAssertTrue(first.isEnabled)

        // Filter 6 is OFF and must stay off.
        let sixth = try XCTUnwrap(result.filters.first { $0.index == 6 })
        XCTAssertFalse(sixth.isEnabled)
        XCTAssertEqual(sixth.frequency, 9350, accuracy: 1e-9)

        let last = try XCTUnwrap(result.filters.first { $0.index == 13 })
        XCTAssertEqual(last.gain, -6.1, accuracy: 1e-9)
        XCTAssertEqual(last.q, 4.62, accuracy: 1e-9)
        XCTAssertEqual(result.filters.filter { $0.isEnabled }.count, 12)
    }

    func testIgnoresCommentsBlankLinesAndWindowsLineEndings() throws {
        let text = """
        # AutoEQ correction\r
        \r
        preamp: -6.5 db\r
        filter 38: on pk fc 105 hz gain -2.1 db q 1.41  # bass\r
        \r
        """
        let result = try EQProfileParser.parse(text)
        XCTAssertEqual(result.preamp, -6.5, accuracy: 1e-9)
        XCTAssertEqual(result.filters.count, 1)
        XCTAssertEqual(result.filters[0].frequency, 105, accuracy: 1e-9)
        XCTAssertTrue(result.skippedLines.isEmpty)
    }

    func testAcceptsKeysInAnyOrderAndOptionalUnits() throws {
        let result = try EQProfileParser.parse("Filter 2: ON PK Q 1.20 Gain 2.0 Fc 5178")
        let filter = try XCTUnwrap(result.filters.first)
        XCTAssertEqual(filter.frequency, 5178, accuracy: 1e-9)
        XCTAssertEqual(filter.gain, 2.0, accuracy: 1e-9)
        XCTAssertEqual(filter.q, 1.20, accuracy: 1e-9)
    }

    func testConvertsBandwidthInOctavesToQ() throws {
        let result = try EQProfileParser.parse("Filter 1: ON PK Fc 1000 Hz Gain 3 dB BW Oct 1.0")
        let filter = try XCTUnwrap(result.filters.first)
        XCTAssertEqual(filter.q, 1.4142135, accuracy: 1e-6)
    }

    func testParsesSlopeParameterisedShelves() throws {
        let result = try EQProfileParser.parse("""
        Filter 1: ON LS Fc 100 Hz Gain 4 dB S 1.0
        Filter 2: ON HS Fc 8000 Hz Gain -3 dB S 0.7
        """)
        XCTAssertEqual(result.filters.count, 2)
        XCTAssertEqual(result.filters[0].kind, .lowShelfS)
        XCTAssertEqual(result.filters[0].slope, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result.filters[1].kind, .highShelfS)
        XCTAssertEqual(result.filters[1].slope, 0.7, accuracy: 1e-9)
    }

    func testKeepsUnsupportedLinesInsteadOfFailingTheProfile() throws {
        let result = try EQProfileParser.parse("""
        Preamp: -3 dB
        GraphicEQ: 20 -1.5; 21 -1.4
        Filter 1: ON PK Fc 500 Hz Gain 2 dB Q 1.0
        Filter 2: ON XX Fc 900 Hz Gain 2 dB Q 1.0
        Convolution: correction.wav
        """)
        XCTAssertEqual(result.filters.count, 1)
        XCTAssertEqual(result.skippedLines.count, 3)
        XCTAssertTrue(result.skippedLines.contains { $0.hasPrefix("GraphicEQ") })
        XCTAssertTrue(result.skippedLines.contains { $0.hasPrefix("Convolution") })
    }

    func testAcceptsChannelAll() throws {
        let result = try EQProfileParser.parse("""
        Channel: all
        Filter 1: ON PK Fc 500 Hz Gain 2 dB Q 1.0
        """)
        XCTAssertEqual(result.filters.count, 1)
        XCTAssertTrue(result.skippedLines.isEmpty)
    }

    func testRefusesPerChannelProfiles() {
        XCTAssertThrowsError(try EQProfileParser.parse("""
        Channel: L
        Filter 1: ON PK Fc 500 Hz Gain 2 dB Q 1.0
        """)) { error in
            guard case EQParseError.unsupportedChannel(let channel) = error else {
                return XCTFail("expected unsupportedChannel, got \(error)")
            }
            XCTAssertEqual(channel, "L")
        }
    }

    func testThrowsForBlankInput() {
        XCTAssertThrowsError(try EQProfileParser.parse("   \n\n  ")) { error in
            XCTAssertEqual(error as? EQParseError, .emptyInput)
        }
    }

    func testThrowsWhenNoFilterIsUsable() {
        XCTAssertThrowsError(try EQProfileParser.parse("GraphicEQ: 20 -1.5; 21 -1.4")) { error in
            guard case EQParseError.noUsableFilters = error else {
                return XCTFail("expected noUsableFilters, got \(error)")
            }
        }
    }

    func testSummaryTextDescribesEnabledAndSkippedBands() throws {
        let result = try EQProfileParser.parse(Self.suppliedProfile)
        let profile = EQProfile(id: "1", name: "Headphones", preamp: result.preamp,
                                filters: result.filters, skippedLines: ["GraphicEQ: 20 0"],
                                sourceText: Self.suppliedProfile, isEnabled: true)
        XCTAssertEqual(profile.summaryText, "13 filters · Preamp -2.0 dB · 1 off · 1 skipped")
    }
}

final class EQBiquadTests: XCTestCase {
    func testPeakingFilterHasItsGainAtTheCentreFrequency() throws {
        for (frequency, gain, q) in [(480.0, 1.1, 2.0), (8950.0, 1.2, 6.69), (3049.0, -2.4, 3.3)] {
            let filter = EQFilter(index: 1, kind: .peaking, frequency: frequency, gain: gain, q: q)
            let coefficients = try XCTUnwrap(EQBiquadMath.coefficients(for: filter, sampleRate: 44_100))
            let measured = EQBiquadMath.magnitudeDB(coefficients, at: frequency, sampleRate: 44_100)
            XCTAssertEqual(measured, gain, accuracy: 1e-6, "at \(frequency) Hz")
        }
    }

    func testLowShelfApproachesItsGainAtLowFrequency() throws {
        let filter = EQFilter(index: 1, kind: .lowShelfQ, frequency: 60, gain: -3.7, q: 0.7)
        let coefficients = try XCTUnwrap(EQBiquadMath.coefficients(for: filter, sampleRate: 44_100))
        let low = EQBiquadMath.magnitudeDB(coefficients, at: 1, sampleRate: 44_100)
        let high = EQBiquadMath.magnitudeDB(coefficients, at: 18_000, sampleRate: 44_100)
        XCTAssertEqual(low, -3.7, accuracy: 0.15)
        XCTAssertEqual(high, 0, accuracy: 0.2)
    }

    func testHighShelfApproachesItsGainAtHighFrequency() throws {
        let filter = EQFilter(index: 1, kind: .highShelfQ, frequency: 6000, gain: 4, q: 0.707)
        let coefficients = try XCTUnwrap(EQBiquadMath.coefficients(for: filter, sampleRate: 48_000))
        let high = EQBiquadMath.magnitudeDB(coefficients, at: 20_000, sampleRate: 48_000)
        let low = EQBiquadMath.magnitudeDB(coefficients, at: 30, sampleRate: 48_000)
        XCTAssertEqual(high, 4, accuracy: 0.35)
        XCTAssertEqual(low, 0, accuracy: 0.2)
    }

    func testSlopeShelfIsStableAndReachesItsGain() throws {
        let filter = EQFilter(index: 1, kind: .lowShelfS, frequency: 120, gain: 5, slope: 1.0)
        let coefficients = try XCTUnwrap(EQBiquadMath.coefficients(for: filter, sampleRate: 44_100))
        XCTAssertEqual(EQBiquadMath.magnitudeDB(coefficients, at: 5, sampleRate: 44_100), 5, accuracy: 0.3)
        XCTAssertTrue(isStable(coefficients))
    }

    func testSuppliedProfileFiltersAreStableAtAllCommonRates() throws {
        let parsed = try EQProfileParser.parse(EQProfileParserTests.suppliedProfile)
        for sampleRate in [44_100.0, 48_000, 96_000, 192_000] {
            for filter in parsed.filters {
                guard let coefficients = EQBiquadMath.coefficients(for: filter, sampleRate: sampleRate) else {
                    XCTFail("filter \(filter.index) failed at \(sampleRate)")
                    continue
                }
                XCTAssertTrue(isStable(coefficients), "filter \(filter.index) unstable at \(sampleRate)")
                for frequency in [20.0, 100, 1_000, 10_000, 19_000] where frequency < sampleRate * 0.49 {
                    let value = EQBiquadMath.magnitudeDB(coefficients, at: frequency, sampleRate: sampleRate)
                    XCTAssertTrue(value.isFinite, "non-finite response at \(frequency) Hz, rate \(sampleRate)")
                }
            }
        }
    }

    func testBandAtOrAboveNyquistIsUnusable() {
        let filter = EQFilter(index: 1, kind: .peaking, frequency: 24_000, gain: 3, q: 1)
        XCTAssertNil(EQBiquadMath.coefficients(for: filter, sampleRate: 44_100))
        let zero = EQFilter(index: 1, kind: .peaking, frequency: 0, gain: 3, q: 1)
        XCTAssertNil(EQBiquadMath.coefficients(for: zero, sampleRate: 44_100))
    }

    /// Jury stability test for a second-order section.
    private func isStable(_ c: EQBiquadCoefficients) -> Bool {
        abs(c.a2) < 1 && abs(c.a1) < 1 + c.a2
    }
}

final class EQChainRuntimeTests: XCTestCase {
    func testEnabledProfilesSumTheirPreamps() {
        let runtime = EQChainRuntime()
        runtime.update(profiles: [
            EQProfile(id: "a", name: "A", preamp: -2, filters: [], skippedLines: [], sourceText: "", isEnabled: true),
            EQProfile(id: "b", name: "B", preamp: -3, filters: [], skippedLines: [], sourceText: "", isEnabled: true)
        ])
        XCTAssertEqual(publishedTrim(runtime), -5, accuracy: 1e-9)
        XCTAssertTrue(runtime.isInstalled)
    }

    func testDisabledProfileContributesNothing() {
        let runtime = EQChainRuntime()
        runtime.update(profiles: [
            EQProfile(id: "a", name: "A", preamp: -2, filters: [], skippedLines: [], sourceText: "", isEnabled: true),
            EQProfile(id: "b", name: "B", preamp: -30, filters: [], skippedLines: [], sourceText: "", isEnabled: false)
        ])
        XCTAssertEqual(publishedTrim(runtime), -2, accuracy: 1e-9)
    }

    func testEveryFilterOffLeavesAnEmptyChain() {
        let runtime = EQChainRuntime()
        let parsed = try! EQProfileParser.parse(EQProfileParserTests.suppliedProfile)
        let disabled = parsed.filters.map { filter -> EQFilter in
            var copy = filter
            copy.isEnabled = false
            return copy
        }
        runtime.update(profiles: [EQProfile(id: "a", name: "A", preamp: 0, filters: disabled,
                                            skippedLines: [], sourceText: "", isEnabled: true)])
        XCTAssertEqual(runtime.installedFilterCount, 0)
        XCTAssertEqual(publishedTrim(runtime), 0, accuracy: 1e-9)
    }

    func testSuppliedProfileNeedsAlmostNoSafetyTrim() {
        let runtime = EQChainRuntime()
        let parsed = try! EQProfileParser.parse(EQProfileParserTests.suppliedProfile)
        runtime.update(profiles: [EQProfile(id: "a", name: "A", preamp: parsed.preamp,
                                            filters: parsed.filters, skippedLines: [],
                                            sourceText: "", isEnabled: true)])
        let trim = publishedTrim(runtime)
        XCTAssertLessThanOrEqual(trim, 0.0001)
        XCTAssertGreaterThan(trim, -4, "the authored preamp should already cover the peak")
        XCTAssertEqual(runtime.installedFilterCount, 12)
    }

    func testSafetyTrimProtectsAProfileWithoutPreamp() {
        let runtime = EQChainRuntime()
        let filter = EQFilter(index: 1, kind: .peaking, frequency: 1_000, gain: 9, q: 1)
        runtime.update(profiles: [EQProfile(id: "a", name: "A", preamp: 0, filters: [filter],
                                            skippedLines: [], sourceText: "", isEnabled: true)])
        XCTAssertEqual(publishedTrim(runtime), -9, accuracy: 0.5)
    }

    func testChainIsCappedAtTheMaximumSectionCount() {
        let runtime = EQChainRuntime()
        let filters = (1...80).map { EQFilter(index: $0, kind: .peaking, frequency: 500, gain: 0.5, q: 1) }
        runtime.update(profiles: [EQProfile(id: "a", name: "A", preamp: 0, filters: filters,
                                            skippedLines: [], sourceText: "", isEnabled: true)])
        XCTAssertEqual(runtime.installedFilterCount, EQMaximumSections)
    }

    func testInstallStateIsReportedEvenWhenEverythingIsSwitchedOff() {
        let runtime = EQChainRuntime()
        let expectation = XCTNSNotificationExpectation(name: EQChainRuntime.installStateDidChange)
        runtime.update(profiles: [EQProfile(id: "a", name: "A", preamp: 0, filters: [],
                                            skippedLines: [], sourceText: "", isEnabled: false)])
        wait(for: [expectation], timeout: 1)
        XCTAssertTrue(runtime.isInstalled)
        XCTAssertEqual(runtime.installedFilterCount, 0)
    }

    private func publishedTrim(_ runtime: EQChainRuntime) -> Double {
        let buffer = UnsafeMutablePointer<EQFilterParam>.allocate(capacity: EQMaximumSections)
        defer { buffer.deallocate() }
        var count = 0
        var preamp = 0.0
        _ = runtime.copyParameters(into: buffer, count: &count, preampDB: &preamp)
        return preamp
    }
}

final class EQAudioProcessorTests: XCTestCase {
    private let sampleRate = 44_100.0

    func testPeakingCutLowersASineByItsGain() throws {
        // A cut needs no headroom trim, so the measured change is the filter's own gain.
        let filter = EQFilter(index: 1, kind: .peaking, frequency: 1_000, gain: -6, q: 1.0)
        let runtime = EQChainRuntime()
        runtime.update(profiles: [EQProfile(id: "a", name: "A", preamp: 0, filters: [filter],
                                            skippedLines: [], sourceText: "", isEnabled: true)])

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = 44_100
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<frames {
            data[frame] = Float(sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate)) * 0.25
        }
        let before = rms(data, from: frames / 2, to: frames)

        let processor = EQAudioProcessor()
        processor.prepare(format: format, source: runtime)
        processor.process(buffers: buffer.mutableAudioBufferList, frameCount: frames)

        let after = rms(data, from: frames / 2, to: frames)
        let changeDB = 20 * log10(after / before)
        XCTAssertEqual(changeDB, -6, accuracy: 0.5)
        processor.unprepare()
    }

    func testBoostIsOffsetByTheHeadroomTrim() throws {
        // A bare +6 dB boost would clip, so the published preamp cancels it: the peak
        // response ends up at unity instead of +6 dB.
        let filter = EQFilter(index: 1, kind: .peaking, frequency: 1_000, gain: 6, q: 1.0)
        let runtime = EQChainRuntime()
        runtime.update(profiles: [EQProfile(id: "a", name: "A", preamp: 0, filters: [filter],
                                            skippedLines: [], sourceText: "", isEnabled: true)])

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = 44_100
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<frames {
            data[frame] = Float(sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate)) * 0.25
        }
        let before = rms(data, from: frames / 2, to: frames)

        let processor = EQAudioProcessor()
        processor.prepare(format: format, source: runtime)
        processor.process(buffers: buffer.mutableAudioBufferList, frameCount: frames)

        let after = rms(data, from: frames / 2, to: frames)
        let changeDB = 20 * log10(after / before)
        XCTAssertEqual(changeDB, 0, accuracy: 0.5)
        XCTAssertLessThanOrEqual(after, before + 1e-6, "output must not exceed the input level")
        processor.unprepare()
    }

    func testBypassedChainLeavesSamplesUntouched() throws {
        let runtime = EQChainRuntime()
        runtime.update(profiles: [EQProfile(id: "a", name: "A", preamp: 0, filters: [],
                                            skippedLines: [], sourceText: "", isEnabled: true)])

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = 512
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<frames { data[frame] = Float(sin(Double(frame) * 0.1)) }

        var reference = [Float](repeating: 0, count: frames)
        for frame in 0..<frames { reference[frame] = data[frame] }

        let processor = EQAudioProcessor()
        processor.prepare(format: format, source: runtime)
        processor.process(buffers: buffer.mutableAudioBufferList, frameCount: frames)

        for frame in 0..<frames { XCTAssertEqual(data[frame], reference[frame]) }
        processor.unprepare()
    }

    func testParameterChangeBetweenBuffersIsAppliedWithoutCorruption() throws {
        let runtime = EQChainRuntime()
        runtime.update(profiles: [EQProfile(id: "a", name: "A", preamp: 0, filters: [], skippedLines: [],
                                            sourceText: "", isEnabled: true)])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = 1_024
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData?[0])

        let processor = EQAudioProcessor()
        processor.prepare(format: format, source: runtime)

        for frame in 0..<frames { data[frame] = 0.5 }
        processor.process(buffers: buffer.mutableAudioBufferList, frameCount: frames)
        XCTAssertEqual(data[frames - 1], 0.5, accuracy: 1e-6)

        // Enable a heavy boost mid-stream, then push another buffer through.
        let filter = EQFilter(index: 1, kind: .peaking, frequency: 1_000, gain: 12, q: 4)
        runtime.update(profiles: [EQProfile(id: "a", name: "A", preamp: 0, filters: [filter],
                                            skippedLines: [], sourceText: "", isEnabled: true)])
        for frame in 0..<frames { data[frame] = Float(sin(Double(frame) * 0.3)) * 0.1 }
        processor.process(buffers: buffer.mutableAudioBufferList, frameCount: frames)

        for frame in 0..<frames {
            XCTAssertTrue(data[frame].isFinite, "sample \(frame) is not finite")
            XCTAssertLessThan(abs(data[frame]), 10, "sample \(frame) exploded")
        }
        processor.unprepare()
    }

    func testStereoPlanarInputIsProcessedPerChannel() throws {
        let filter = EQFilter(index: 1, kind: .peaking, frequency: 2_000, gain: -6, q: 2)
        let runtime = EQChainRuntime()
        runtime.update(profiles: [EQProfile(id: "a", name: "A", preamp: 0, filters: [filter],
                                            skippedLines: [], sourceText: "", isEnabled: true)])
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let frames = 8_192
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = try XCTUnwrap(buffer.floatChannelData?[0])
        let right = try XCTUnwrap(buffer.floatChannelData?[1])
        for frame in 0..<frames {
            left[frame] = Float(sin(2 * Double.pi * 2_000 * Double(frame) / sampleRate)) * 0.25
            right[frame] = 0
        }

        let processor = EQAudioProcessor()
        processor.prepare(format: format, source: runtime)
        processor.process(buffers: buffer.mutableAudioBufferList, frameCount: frames)

        let leftRMS = rms(left, from: frames / 2, to: frames)
        XCTAssertLessThan(leftRMS, 0.14, "left channel should be attenuated")
        XCTAssertGreaterThan(leftRMS, 0.05, "left channel should still carry the signal")
        for frame in 0..<frames { XCTAssertEqual(right[frame], 0, accuracy: 1e-6) }
        processor.unprepare()
    }

    private func rms(_ data: UnsafePointer<Float>, from: Int, to: Int) -> Double {
        var sum = 0.0
        for index in from..<to {
            let value = Double(data[index])
            sum += value * value
        }
        return (sum / Double(to - from)).squareRoot()
    }
}

final class EQProfileStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "EQTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func profile(id: String = "a", enabled: Bool = true) -> EQProfile {
        EQProfile(id: id, name: "Headphones", preamp: -2, filters: [], skippedLines: [],
                  sourceText: "", isEnabled: enabled)
    }

    func testProfilesSurviveAReload() {
        let store = EQProfileStore(defaults: defaults, key: "k", runtime: EQChainRuntime())
        store.add(profile())

        let reopened = EQProfileStore(defaults: defaults, key: "k", runtime: EQChainRuntime())
        XCTAssertEqual(reopened.profiles, [profile()])
    }

    func testEnabledStatePersists() {
        let store = EQProfileStore(defaults: defaults, key: "k", runtime: EQChainRuntime())
        store.add(profile())
        store.setEnabled(false, id: "a")

        let reopened = EQProfileStore(defaults: defaults, key: "k", runtime: EQChainRuntime())
        XCTAssertEqual(reopened.profiles.first?.isEnabled, false)
    }

    func testRemovalPersists() {
        let store = EQProfileStore(defaults: defaults, key: "k", runtime: EQChainRuntime())
        store.add(profile())
        store.remove(id: "a")

        let reopened = EQProfileStore(defaults: defaults, key: "k", runtime: EQChainRuntime())
        XCTAssertTrue(reopened.profiles.isEmpty)
        XCTAssertFalse(reopened.hasProfiles)
    }

    func testCorruptPayloadYieldsAnEmptyLibrary() {
        defaults.set(Data("not json".utf8), forKey: "k")
        let store = EQProfileStore(defaults: defaults, key: "k", runtime: EQChainRuntime())
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testAddingPublishesToTheChain() {
        let runtime = EQChainRuntime()
        XCTAssertFalse(runtime.isInstalled)
        let store = EQProfileStore(defaults: defaults, key: "k", runtime: runtime)
        store.add(profile())
        XCTAssertTrue(runtime.isInstalled)
    }
}

final class EQAudioMixFactoryTests: XCTestCase {
    func testTapIsAttachedToAPlayableTrack() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eq-tap-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410))
        buffer.frameLength = 4_410
        try file.write(from: buffer)

        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let mix = EQAudioMixFactory.makeAudioMix(for: track, source: EQChainRuntime())
        let unwrapped = try XCTUnwrap(mix, "no audio mix was produced")
        XCTAssertEqual(unwrapped.inputParameters.count, 1)
        XCTAssertNotNil(unwrapped.inputParameters.first?.audioTapProcessor)
    }
}

@MainActor
final class EQSettingsUITests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "EQSettings." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSectionShowsStoredProfilesAndAddButton() throws {
        let store = EQProfileStore(defaults: defaults, key: "k", runtime: EQChainRuntime())
        let parsed = try EQProfileParser.parse(EQProfileParserTests.suppliedProfile)
        store.add(EQProfile(id: "a", name: "Headphones", preamp: parsed.preamp,
                            filters: parsed.filters, skippedLines: [], sourceText: "",
                            isEnabled: true))

        let controller = SettingsViewController(items: [], lastFMUsername: nil,
                                                appearanceMode: AppearanceMode.allCases[0],
                                                eqStore: store)
        controller.loadViewIfNeeded()

        let add = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "settings.eq.add" })
        XCTAssertTrue(add.isEnabled)

        let table = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UITableView }
            .first { $0.accessibilityIdentifier == "settings.eq.table" })
        XCTAssertEqual(table.numberOfRows(inSection: 0), 1)

        let cell = try XCTUnwrap(table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0)) as? EQProfileCell)
        XCTAssertFalse(cell.enabledSwitch.isHidden)
        XCTAssertTrue(cell.enabledSwitch.isOn)
    }

    func testTogglingAProfileSwitchPersists() throws {
        let store = EQProfileStore(defaults: defaults, key: "k", runtime: EQChainRuntime())
        store.add(EQProfile(id: "a", name: "Headphones", preamp: -2, filters: [], skippedLines: [],
                            sourceText: "", isEnabled: true))

        let controller = SettingsViewController(items: [], lastFMUsername: nil,
                                                appearanceMode: AppearanceMode.allCases[0],
                                                eqStore: store)
        controller.loadViewIfNeeded()
        let table = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UITableView }
            .first { $0.accessibilityIdentifier == "settings.eq.table" })
        let cell = try XCTUnwrap(table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0)) as? EQProfileCell)

        cell.enabledSwitch.isOn = false
        cell.enabledSwitch.sendActions(for: .valueChanged)

        XCTAssertEqual(store.profiles.first?.isEnabled, false)
        let reopened = EQProfileStore(defaults: defaults, key: "k", runtime: EQChainRuntime())
        XCTAssertEqual(reopened.profiles.first?.isEnabled, false)
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}


final class BundledEQProfileTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BundledEQ." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store() -> EQProfileStore {
        EQProfileStore(defaults: defaults, key: "k", runtime: EQChainRuntime())
    }

    private static let bundledText = """
    Preamp: -2.0 dB
    Filter 1: ON LSC Fc 60 Hz Gain -3.7 dB Q 0.70
    Filter 2: ON PK Fc 480 Hz Gain 1.1 dB Q 2.00
    Filter 3: ON PK Fc 1600 Hz Gain -0.5 dB Q 1.50
    Filter 4: ON PK Fc 5178 Hz Gain 2.0 dB Q 1.20
    Filter 5: ON PK Fc 12401 Hz Gain -0.3 dB Q 1.90
    Filter 6: ON PK Fc 8032 Hz Gain -0.7 dB Q 7.00
    Filter 7: ON PK Fc 8950 Hz Gain 1.2 dB Q 6.69
    Filter 8: ON PK Fc 3824 Hz Gain -0.5 dB Q 2.25
    Filter 9: ON PK Fc 14791 Hz Gain -0.3 dB Q 7.00
    Filter 10: ON PK Fc 3049 Hz Gain -2.4 dB Q 3.30
    Filter 11: ON PK Fc 11573 Hz Gain -4.0 dB Q 7.78
    Filter 12: ON PK Fc 8928 Hz Gain -6.1 dB Q 4.62
    """

    /// The shipped file must be inside the app bundle, in the EQ directory, and parse.
    func testBundledProfileShipsWithTheApp() throws {
        let items = BundledEQProfiles.load()
        let headphones = try XCTUnwrap(items.first { $0.name == "Headphones" },
                                       "EQ/Headphones.txt is missing from the app bundle")
        let parsed = try EQProfileParser.parse(headphones.text)
        XCTAssertEqual(parsed.preamp, -2.0, accuracy: 1e-9)
        XCTAssertEqual(parsed.filters.count, 12)
        XCTAssertTrue(parsed.filters.allSatisfy { $0.isEnabled })
        XCTAssertTrue(parsed.skippedLines.isEmpty)
    }

    func testImportsOnceAndEnablesTheProfile() throws {
        let store = self.store()
        let item = BundledEQProfiles.Item(name: "Headphones", text: Self.bundledText)

        XCTAssertEqual(store.importBundledProfiles([item]), 1)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].name, "Headphones")
        XCTAssertTrue(store.profiles[0].isEnabled)
        XCTAssertEqual(store.profiles[0].filters.count, 12)

        // A second launch must not duplicate it.
        XCTAssertEqual(store.importBundledProfiles([item]), 0)
        XCTAssertEqual(store.profiles.count, 1)

        let reopened = self.store()
        XCTAssertEqual(reopened.importBundledProfiles([item]), 0)
        XCTAssertEqual(reopened.profiles.count, 1)
    }

    func testDeletedBundledProfileIsNotResurrected() {
        let store = self.store()
        let item = BundledEQProfiles.Item(name: "Headphones", text: Self.bundledText)
        store.importBundledProfiles([item])
        store.remove(id: store.profiles[0].id)

        XCTAssertEqual(store.importBundledProfiles([item]), 0)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testHandAddedProfileWithSameNameIsAdoptedNotDuplicated() {
        let store = self.store()
        store.add(EQProfile(id: "manual", name: "Headphones", preamp: -1, filters: [],
                            skippedLines: [], sourceText: "", isEnabled: false))
        let item = BundledEQProfiles.Item(name: "Headphones", text: Self.bundledText)

        XCTAssertEqual(store.importBundledProfiles([item]), 0)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].id, "manual")
        XCTAssertFalse(store.profiles[0].isEnabled, "the user's switch must not be overridden")
    }

    func testChangedTextUpdatesInPlaceKeepingIdentityAndSwitch() throws {
        let store = self.store()
        let original = BundledEQProfiles.Item(name: "Headphones", text: Self.bundledText)
        store.importBundledProfiles([original])
        let id = store.profiles[0].id
        store.setEnabled(false, id: id)

        let revised = BundledEQProfiles.Item(name: "Headphones", text: """
        Preamp: -3.0 dB
        Filter 1: ON PK Fc 1000 Hz Gain -2.0 dB Q 1.00
        """)
        XCTAssertEqual(store.importBundledProfiles([revised]), 1)

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles[0].id, id)
        XCTAssertFalse(store.profiles[0].isEnabled)
        XCTAssertEqual(store.profiles[0].preamp, -3.0, accuracy: 1e-9)
        XCTAssertEqual(store.profiles[0].filters.count, 1)
    }

    func testFingerprintIsStableAndDistinct() {
        XCTAssertEqual(EQProfileStore.fingerprint("abc"), EQProfileStore.fingerprint("abc"))
        XCTAssertNotEqual(EQProfileStore.fingerprint("abc"), EQProfileStore.fingerprint("abd"))
        XCTAssertEqual(EQProfileStore.fingerprint("abc"), "e71fa2190541574b")
    }

    func testUnparseableBundledTextIsSkipped() {
        let store = self.store()
        let item = BundledEQProfiles.Item(name: "Broken", text: "GraphicEQ: 20 0; 21 0")
        XCTAssertEqual(store.importBundledProfiles([item]), 0)
        XCTAssertTrue(store.profiles.isEmpty)
    }
}

final class BundledEQProfileDedupeTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "BundledEQDedupe." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func store() -> EQProfileStore {
        EQProfileStore(defaults: defaults, key: "k", runtime: EQChainRuntime())
    }

    /// A profile pasted in by hand, with a different name but the same curve, must not be
    /// duplicated: two enabled profiles would apply the correction twice.
    func testSameCurveUnderAnotherNameIsNotAdded() throws {
        let store = self.store()
        let headphones = try XCTUnwrap(BundledEQProfiles.load().first { $0.name == "Headphones" })
        let parsed = try EQProfileParser.parse(headphones.text)

        store.add(EQProfile(id: "manual", name: "My correction", preamp: parsed.preamp,
                            filters: parsed.filters, skippedLines: parsed.skippedLines,
                            sourceText: headphones.text, isEnabled: true))

        // Only the one bundled profile, so the assertion is about this curve alone.
        XCTAssertEqual(store.importBundledProfiles([headphones]), 0)
        XCTAssertEqual(store.profiles.count, 1)
    }
}

final class EQHighPassTests: XCTestCase {
    private let sampleRate = 44_100.0

    func testParsesHighPassAndLowPass() throws {
        let result = try EQProfileParser.parse("""
        Filter 1: ON HP Fc 1000 Hz Q 0.707
        Filter 2: ON LP Fc 8000 Hz Q 0.707
        """)
        XCTAssertEqual(result.filters.count, 2)
        XCTAssertEqual(result.filters[0].kind, .highPass)
        XCTAssertEqual(result.filters[0].gain, 0, "a filter carries no gain")
        XCTAssertEqual(result.filters[0].q, 0.707, accuracy: 1e-9)
        XCTAssertEqual(result.filters[1].kind, .lowPass)
        XCTAssertTrue(result.skippedLines.isEmpty)
    }

    func testHighPassIsMinusThreeDBAtTheCutoff() throws {
        let filter = EQFilter(index: 1, kind: .highPass, frequency: 1_000, q: 0.707)
        let coefficients = try XCTUnwrap(EQBiquadMath.coefficients(for: filter, sampleRate: sampleRate))
        let atCutoff = EQBiquadMath.magnitudeDB(coefficients, at: 1_000, sampleRate: sampleRate)
        XCTAssertEqual(atCutoff, -3.0, accuracy: 0.2, "Butterworth response is -3 dB at Fc")
        let low = EQBiquadMath.magnitudeDB(coefficients, at: 100, sampleRate: sampleRate)
        XCTAssertLessThan(low, -35, "two octaves below the cutoff is heavily attenuated")
        let high = EQBiquadMath.magnitudeDB(coefficients, at: 15_000, sampleRate: sampleRate)
        XCTAssertEqual(high, 0, accuracy: 0.2)
    }

    func testLowPassIsMinusThreeDBAtTheCutoff() throws {
        let filter = EQFilter(index: 1, kind: .lowPass, frequency: 1_000, q: 0.707)
        let coefficients = try XCTUnwrap(EQBiquadMath.coefficients(for: filter, sampleRate: sampleRate))
        XCTAssertEqual(EQBiquadMath.magnitudeDB(coefficients, at: 1_000, sampleRate: sampleRate),
                       -3.0, accuracy: 0.2)
        XCTAssertEqual(EQBiquadMath.magnitudeDB(coefficients, at: 50, sampleRate: sampleRate),
                       0, accuracy: 0.2)
    }

    /// The audible claim behind the diagnostic profile: bass and mids lose most of their
    /// level while treble passes through.
    func testBassSineIsLargelyRemovedAndTreblePasses() throws {
        func level(of sine: Double, through filter: EQFilter) throws -> Double {
            let runtime = EQChainRuntime()
            runtime.update(profiles: [EQProfile(id: "hp", name: "HP", preamp: 0, filters: [filter],
                                                skippedLines: [], sourceText: "", isEnabled: true)])
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
            let frames = 22_050
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try XCTUnwrap(buffer.floatChannelData?[0])
            for frame in 0..<frames {
                data[frame] = Float(sin(2 * Double.pi * sine * Double(frame) / sampleRate)) * 0.25
            }
            let processor = EQAudioProcessor()
            processor.prepare(format: format, source: runtime)
            processor.process(buffers: buffer.mutableAudioBufferList, frameCount: frames)
            var sum = 0.0
            for frame in frames / 2..<frames { let v = Double(data[frame]); sum += v * v }
            processor.unprepare()
            return (sum / Double(frames - frames / 2)).squareRoot()
        }

        let filter = EQFilter(index: 1, kind: .highPass, frequency: 1_000, q: 0.707)
        let bass = try level(of: 100, through: filter)
        let treble = try level(of: 8_000, through: filter)
        XCTAssertLessThan(bass, 0.01, "100 Hz should be almost gone")
        XCTAssertEqual(treble, 0.25 / 2.0.squareRoot(), accuracy: 0.01, "8 kHz should pass at full level")
    }

    func testBundledHighPassProfileImportsSwitchedOff() throws {
        let suite = "HPBundled." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = EQProfileStore(defaults: defaults, key: "k", runtime: EQChainRuntime())

        let items = BundledEQProfiles.load()
        let test = try XCTUnwrap(items.first { $0.name == "High-Pass Test" },
                                "EQ/High-Pass Test.txt is missing from the bundle")
        store.importBundledProfiles(items)

        let profile = try XCTUnwrap(store.profiles.first { $0.name == "High-Pass Test" })
        XCTAssertFalse(profile.isEnabled, "a diagnostic curve must not stack with the real one")
        XCTAssertEqual(profile.filters.count, 1)
        XCTAssertEqual(profile.filters[0].kind, .highPass)
        XCTAssertEqual(profile.filters[0].frequency, 1_000, accuracy: 1e-9)
    }

    func testPrefersDisabledReadsTheDirective() {
        XCTAssertTrue(EQProfileStore.prefersDisabled("# Default: off\nFilter 1: ON HP Fc 900 Hz Q 0.7"))
        XCTAssertTrue(EQProfileStore.prefersDisabled("#DEFAULT:OFF"))
        XCTAssertFalse(EQProfileStore.prefersDisabled("Filter 1: ON HP Fc 900 Hz Q 0.7"))
        XCTAssertFalse(EQProfileStore.prefersDisabled("# Default: on\nFilter 1: ON PK Fc 900 Hz Gain 1 dB Q 0.7"))
    }
}
