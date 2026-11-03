import AVFoundation
import Foundation

/// A normalised second-order section: y = (b0 x + b1 x' + b2 x'') - a1 y' - a2 y''
struct EQBiquadCoefficients: Equatable {
    var b0: Double = 1
    var b1: Double = 0
    var b2: Double = 0
    var a1: Double = 0
    var a2: Double = 0
}

/// Robert Bristow-Johnson audio EQ cookbook coefficients.
enum EQBiquadMath {
    /// Returns `nil` when the band cannot be realised at this sample rate.
    static func coefficients(for filter: EQFilter, sampleRate: Double) -> EQBiquadCoefficients? {
        guard sampleRate.isFinite, sampleRate > 0 else { return nil }
        let frequency = filter.frequency
        // At or above Nyquist the bilinear transform has no sensible answer.
        guard frequency.isFinite, frequency > 0, frequency < sampleRate * 0.49 else { return nil }

        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let gain = filter.gain.isFinite ? filter.gain : 0
        let A = pow(10, gain / 40)

        let raw: (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double)

        switch filter.kind {
        case .peaking:
            guard filter.q.isFinite, filter.q > 0 else { return nil }
            let alpha = sinw / (2 * filter.q)
            raw = (1 + alpha * A, -2 * cosw, 1 - alpha * A,
                   1 + alpha / A, -2 * cosw, 1 - alpha / A)

        case .lowShelfQ, .highShelfQ:
            guard filter.q.isFinite, filter.q > 0 else { return nil }
            let alpha = sinw / (2 * filter.q)
            raw = shelf(A: A, cosw: cosw, alpha: alpha, isLow: filter.kind == .lowShelfQ)

        case .lowPass, .highPass:
            guard filter.q.isFinite, filter.q > 0 else { return nil }
            let alpha = sinw / (2 * filter.q)
            let numerator: (Double, Double, Double)
            if filter.kind == .lowPass {
                // 1 - cos w0 over 2, doubled in the middle tap.
                numerator = ((1 - cosw) / 2, 1 - cosw, (1 - cosw) / 2)
            } else {
                numerator = ((1 + cosw) / 2, -(1 + cosw), (1 + cosw) / 2)
            }
            raw = (numerator.0, numerator.1, numerator.2,
                   1 + alpha, -2 * cosw, 1 - alpha)

        case .lowShelfS, .highShelfS:
            guard filter.slope.isFinite, filter.slope > 0 else { return nil }
            // Slope form: S = 1 is the steepest shelf without overshoot.
            let alpha = sinw / 2 * sqrt((A + 1 / A) * (1 / filter.slope - 1) + 2)
            guard alpha.isFinite else { return nil }
            raw = shelf(A: A, cosw: cosw, alpha: alpha, isLow: filter.kind == .lowShelfS)
        }

        guard raw.a0 != 0, raw.a0.isFinite else { return nil }
        let coefficients = EQBiquadCoefficients(
            b0: raw.b0 / raw.a0,
            b1: raw.b1 / raw.a0,
            b2: raw.b2 / raw.a0,
            a1: raw.a1 / raw.a0,
            a2: raw.a2 / raw.a0
        )
        guard coefficients.isFinite else { return nil }
        return coefficients
    }

    private static func shelf(A: Double, cosw: Double, alpha: Double, isLow: Bool)
        -> (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
        let sqrtA2Alpha = 2 * sqrt(A) * alpha
        if isLow {
            return (
                b0:    A * ((A + 1) - (A - 1) * cosw + sqrtA2Alpha),
                b1:  2 * A * ((A - 1) - (A + 1) * cosw),
                b2:    A * ((A + 1) - (A - 1) * cosw - sqrtA2Alpha),
                a0:         (A + 1) + (A - 1) * cosw + sqrtA2Alpha,
                a1:   -2 * ((A - 1) + (A + 1) * cosw),
                a2:         (A + 1) + (A - 1) * cosw - sqrtA2Alpha
            )
        }
        return (
            b0:    A * ((A + 1) + (A - 1) * cosw + sqrtA2Alpha),
            b1: -2 * A * ((A - 1) + (A + 1) * cosw),
            b2:    A * ((A + 1) + (A - 1) * cosw - sqrtA2Alpha),
            a0:         (A + 1) - (A - 1) * cosw + sqrtA2Alpha,
            a1:    2 * ((A - 1) - (A + 1) * cosw),
            a2:         (A + 1) - (A - 1) * cosw - sqrtA2Alpha
        )
    }

    /// |H(e^-jw)| in decibels.
    static func magnitudeDB(_ c: EQBiquadCoefficients, at frequency: Double, sampleRate: Double) -> Double {
        guard sampleRate > 0, frequency.isFinite, frequency > 0 else { return 0 }
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(w), cos2 = cos(2 * w)
        let sin1 = sin(w), sin2 = sin(2 * w)

        let numeratorReal = c.b0 + c.b1 * cos1 + c.b2 * cos2
        let numeratorImaginary = -(c.b1 * sin1 + c.b2 * sin2)
        let denominatorReal = 1 + c.a1 * cos1 + c.a2 * cos2
        let denominatorImaginary = -(c.a1 * sin1 + c.a2 * sin2)

        let numerator = (numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary).squareRoot()
        let denominator = (denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary).squareRoot()
        guard denominator > 0 else { return 0 }
        return 20 * log10(max(numerator / denominator, 1e-12))
    }
}

private extension EQBiquadCoefficients {
    var isFinite: Bool {
        b0.isFinite && b1.isFinite && b2.isFinite && a1.isFinite && a2.isFinite
    }
}

/// Applies the combined profile chain to decoded audio buffers, in place.
///
/// Everything the render callback touches is preallocated: coefficient storage and
/// per-channel filter state are sized to `EQMaximumSections` in `prepare` and never
/// resized, so a profile added later cannot overrun them.
final class EQAudioProcessor {
    private var coefficients: UnsafeMutablePointer<EQBiquadCoefficients>?
    private var state: UnsafeMutablePointer<Double>?
    private var parameters: UnsafeMutablePointer<EQFilterParam>?
    private var parameterSource: EQParameterSource?

    private var capacity = 0
    private var channelCount = 1
    private var sectionCount = 0
    private var sampleRate: Double = 44_100
    private var preampLinear: Double = 1
    private var generation: Int32 = -1
    private var isUsable = false
    private var isInterleaved = false
    private var loggedFirstBuffer = false

    deinit { releaseStorage() }

    // MARK: - Lifecycle (both callbacks run off the render thread)

    func prepare(format: AVAudioFormat, source: EQParameterSource) {
        releaseStorage()
        parameterSource = source
        sampleRate = format.sampleRate > 0 ? format.sampleRate : 44_100
        channelCount = max(Int(format.channelCount), 1)
        isInterleaved = format.isInterleaved
        isUsable = format.commonFormat == .pcmFormatFloat32
        capacity = EQMaximumSections
        coefficients = .allocate(capacity: capacity)
        coefficients?.initialize(repeating: EQBiquadCoefficients(), count: capacity)
        state = .allocate(capacity: capacity * channelCount * 2)
        state?.initialize(repeating: 0, count: capacity * channelCount * 2)
        parameters = .allocate(capacity: capacity)
        parameters?.initialize(repeating: EQFilterParam(), count: capacity)
        generation = -1
        sectionCount = 0
        preampLinear = 1
        loggedFirstBuffer = false
    }

    func unprepare() {
        releaseStorage()
        parameterSource = nil
    }

    // MARK: - Render callback

    func process(buffers: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard isUsable, frameCount > 0, let source = parameterSource else { return }
        syncParameters(from: source)
        guard sectionCount > 0 || preampLinear != 1 else { return }

        // One line per prepared tap, so "is the DSP actually being called?" is answerable
        // from the device log instead of by ear alone.
        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            let trimdB = 20 * log10(max(preampLinear, 1e-6))
            NSLog("EQ: processing audio — %d sections, trim %.2f dB, %d frames",
                  sectionCount, trimdB, frameCount)
        }

        let list = UnsafeMutableAudioBufferListPointer(buffers)
        if isInterleaved {
            guard let buffer = list.first, let data = buffer.mData else { return }
            // Never trust the buffer to name more channels than were prepared: the state
            // buffer is sized from the format, not from the render buffer list.
            let channels = min(max(Int(buffer.mNumberChannels), 1), channelCount)
            processInterleaved(data.assumingMemoryBound(to: Float.self),
                               frames: frameCount, channels: channels)
        } else {
            for (index, buffer) in list.enumerated() {
                guard let data = buffer.mData else { continue }
                processPlanar(data.assumingMemoryBound(to: Float.self),
                              frames: frameCount, channel: index)
            }
        }
    }

    // MARK: - Private

    private func releaseStorage() {
        coefficients?.deinitialize(count: capacity)
        coefficients?.deallocate()
        coefficients = nil
        state?.deinitialize(count: capacity * channelCount * 2)
        state?.deallocate()
        state = nil
        parameters?.deinitialize(count: capacity)
        parameters?.deallocate()
        parameters = nil
        capacity = 0
        sectionCount = 0
    }

    /// Copies the published parameters and, only when they changed, rebuilds
    /// coefficients. Bounded and allocation free: reads, `sin`/`cos`/`sqrt`, writes.
    private func syncParameters(from source: EQParameterSource) {
        guard let parameters = parameters,
              let coefficients = coefficients,
              capacity > 0 else { return }

        var count = 0
        var preampDB = 0.0
        let newGeneration = source.copyParameters(into: parameters, count: &count, preampDB: &preampDB)
        guard newGeneration != generation else { return }
        generation = newGeneration

        var usable = 0
        for index in 0..<min(count, capacity) {
            let parameter = parameters[index]
            guard let kind = EQFilterKind(paramCode: parameter.code) else { continue }
            let filter = EQFilter(index: index + 1, kind: kind,
                                  frequency: parameter.frequency,
                                  gain: parameter.gain,
                                  q: parameter.q,
                                  slope: parameter.slope)
            guard let section = EQBiquadMath.coefficients(for: filter, sampleRate: sampleRate) else { continue }
            coefficients[usable] = section
            usable += 1
        }

        sectionCount = usable
        preampLinear = pow(10, preampDB / 20)
        resetState()
    }

    private func resetState() {
        guard let state = state, capacity > 0 else { return }
        state.update(repeating: 0, count: capacity * channelCount * 2)
    }

    /// Transposed direct form II. Two history values per section per channel, which
    /// gives the same transfer function with lower round-off than direct form I.
    private func processPlanar(_ data: UnsafeMutablePointer<Float>, frames: Int, channel: Int) {
        guard let coefficients = coefficients, let state = state else { return }
        let base = min(channel, channelCount - 1) * capacity * 2
        let sections = sectionCount
        let preamp = preampLinear

        for frame in 0..<frames {
            var sample = Double(data[frame]) * preamp
            for section in 0..<sections {
                let c = coefficients[section]
                let slot = base + section * 2
                let output = c.b0 * sample + state[slot]
                var z1 = c.b1 * sample - c.a1 * output + state[slot + 1]
                var z2 = c.b2 * sample - c.a2 * output
                // Double denormals start near 1e-308; this only clears fully decayed state.
                if abs(z1) < 1e-30 { z1 = 0 }
                if abs(z2) < 1e-30 { z2 = 0 }
                state[slot] = z1
                state[slot + 1] = z2
                sample = output
            }
            data[frame] = Float(sample)
        }
    }

    private func processInterleaved(_ data: UnsafeMutablePointer<Float>,
                                    frames: Int, channels: Int) {
        guard let coefficients = coefficients, let state = state else { return }
        let sections = sectionCount
        let preamp = preampLinear

        for channel in 0..<channels {
            let base = channel * capacity * 2
            for frame in 0..<frames {
                let position = frame * channels + channel
                var sample = Double(data[position]) * preamp
                for section in 0..<sections {
                    let c = coefficients[section]
                    let slot = base + section * 2
                    let output = c.b0 * sample + state[slot]
                    var z1 = c.b1 * sample - c.a1 * output + state[slot + 1]
                    var z2 = c.b2 * sample - c.a2 * output
                    if abs(z1) < 1e-30 { z1 = 0 }
                    if abs(z2) < 1e-30 { z2 = 0 }
                    state[slot] = z1
                    state[slot + 1] = z2
                    sample = output
                }
                data[position] = Float(sample)
            }
        }
    }
}
