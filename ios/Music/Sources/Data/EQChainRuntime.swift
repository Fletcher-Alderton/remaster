import Foundation
import os

/// A filter as it is handed to the render thread. Only `Int32` and `Double`, so
/// copying it does no reference counting.
struct EQFilterParam {
    var code: Int32 = 0
    var frequency: Double = 0
    var gain: Double = 0
    var q: Double = 0
    var slope: Double = 0

    init(code: Int32 = 0, frequency: Double = 0, gain: Double = 0, q: Double = 0, slope: Double = 0) {
        self.code = code
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.slope = slope
    }
}

/// Upper bound on the filters one chain can carry, and therefore on the storage the
/// audio processor preallocates.
let EQMaximumSections = 64

protocol EQParameterSource: AnyObject {
    /// Copies the published parameters into `buffer`. Must not allocate.
    func copyParameters(into buffer: UnsafeMutablePointer<EQFilterParam>,
                        count: inout Int,
                        preampDB: inout Double) -> Int32
}

/// Owns the combined parameter set and publishes it to every installed tap.
///
/// Writers run on the main thread. Readers run on the audio render thread and only
/// ever copy plain values out of a fixed-capacity buffer.
final class EQChainRuntime: EQParameterSource {
    static let shared = EQChainRuntime()
    /// Posted when the stored-profile count crosses zero, so live players can attach
    /// or detach their audio mixes.
    static let installStateDidChange = Notification.Name("MusicEQInstallStateDidChange")
    /// Posted on every store mutation, including plain enable/disable toggles, so a player
    /// holding an item that never got a mix can attach one.
    static let chainDidChange = Notification.Name("MusicEQChainDidChange")

    /// Reference rate for the headroom estimate. The peak of a headphone correction
    /// between 20 Hz and 20 kHz barely moves between 44.1 and 96 kHz, and the runtime
    /// has no access to the format the tap will deliver.
    private static let referenceSampleRate = 48_000.0

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var parameters: [EQFilterParam] = []
    private var appliedTrimDB: Double = 0
    private var generation: Int32 = 0

    private(set) var isInstalled = false
    private(set) var installedFilterCount = 0

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - Publishing

    func update(profiles: [EQProfile]) {
        let collapsed = Self.collapse(profiles)
        var rawTrim = 0.0
        for profile in profiles where profile.isEnabled { rawTrim += profile.preamp }

        let peak = Self.peakGainDB(sections: collapsed, sampleRate: Self.referenceSampleRate)
        // Only ever attenuate. A well-formed AutoEQ profile already sizes its preamp so
        // this is zero and the profile is reproduced exactly as authored.
        let safetyTrim = min(0, -(rawTrim + peak))
        let trim = rawTrim + safetyTrim

        let hadProfiles = isInstalled
        let willInstall = !profiles.isEmpty

        os_unfair_lock_lock(lock)
        parameters = collapsed.map {
            EQFilterParam(code: $0.kind.paramCode, frequency: $0.frequency,
                          gain: $0.gain, q: $0.q, slope: $0.slope)
        }
        appliedTrimDB = trim
        generation = generation &+ 1
        os_unfair_lock_unlock(lock)

        isInstalled = willInstall
        installedFilterCount = min(collapsed.count, EQMaximumSections)

        if hadProfiles != willInstall {
            NotificationCenter.default.post(name: Self.installStateDidChange, object: self)
        }
        NotificationCenter.default.post(name: Self.chainDidChange, object: self)
    }

    // MARK: - EQParameterSource

    func copyParameters(into buffer: UnsafeMutablePointer<EQFilterParam>,
                        count: inout Int,
                        preampDB: inout Double) -> Int32 {
        os_unfair_lock_lock(lock)
        let available = min(parameters.count, EQMaximumSections)
        for index in 0..<available { buffer[index] = parameters[index] }
        count = available
        preampDB = appliedTrimDB
        let published = generation
        os_unfair_lock_unlock(lock)
        return published
    }

    // MARK: - Headroom estimate

    /// Peak of the combined magnitude response between 20 Hz and 20 kHz.
    func peakGainDB(profiles: [EQProfile], sampleRate: Double) -> Double {
        Self.peakGainDB(sections: Self.collapse(profiles), sampleRate: sampleRate)
    }

    private static func peakGainDB(sections: [EQFilter], sampleRate: Double) -> Double {
        let usable = sections.compactMap { EQBiquadMath.coefficients(for: $0, sampleRate: sampleRate) }
        guard !usable.isEmpty else { return 0 }

        let low = 20.0
        let high = min(20_000.0, sampleRate * 0.49)
        guard high > low else { return 0 }

        var peak = -Double.infinity
        let steps = 256
        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            let frequency = low * pow(high / low, fraction)
            var total = 0.0
            for section in usable {
                total += EQBiquadMath.magnitudeDB(section, at: frequency, sampleRate: sampleRate)
            }
            if total > peak { peak = total }
        }
        return peak.isFinite ? peak : 0
    }

    /// Enabled filters of enabled profiles, in store order then band order, capped at
    /// `EQMaximumSections`.
    private static func collapse(_ profiles: [EQProfile]) -> [EQFilter] {
        var result: [EQFilter] = []
        result.reserveCapacity(EQMaximumSections)
        for profile in profiles where profile.isEnabled {
            for filter in profile.filters where filter.isEnabled {
                guard result.count < EQMaximumSections else { return result }
                result.append(filter)
            }
        }
        return result
    }
}
