import AVFoundation
import Foundation

/// The format Qobuz said it delivered, taken from the stream response rather than
/// inferred from the selected quality.
struct StreamFormatSummary: Equatable {
    var sampleRateHz: Double
    var bitDepth: Int
    var codec: String?

    static func from(_ stream: QobuzTrackURL) -> StreamFormatSummary {
        StreamFormatSummary(
            sampleRateHz: stream.samplingRate > 0 ? stream.samplingRate * 1000 : 0,
            bitDepth: max(0, stream.bitDepth),
            codec: shortCodec(for: stream.mimeType)
        )
    }

    /// `audio/flac` and `audio/mpeg` become `flac` and `mpeg`.
    static func shortCodec(for mimeType: String) -> String? {
        let trimmed = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let slash = trimmed.lastIndex(of: "/") {
            let suffix = String(trimmed[trimmed.index(after: slash)...])
            return suffix.isEmpty ? nil : suffix.lowercased()
        }
        return trimmed.lowercased()
    }
}

/// The format the equaliser callback is actually invoked with.
struct TapFormatSummary: Equatable {
    var sampleRate: Double
    var channels: Int
    var bitsPerChannel: Int
    var isFloat: Bool

    static func from(_ description: AudioStreamBasicDescription) -> TapFormatSummary {
        let isFloat = description.mFormatFlags & kAudioFormatFlagIsFloat != 0
        return TapFormatSummary(
            sampleRate: description.mSampleRate,
            channels: max(Int(description.mChannelsPerFrame), 1),
            bitsPerChannel: Int(description.mBitsPerChannel),
            isFloat: isFloat
        )
    }
}

enum EQActivity: Equatable {
    /// No profiles are stored, so no tap is installed.
    case bypassed
    /// Profiles are stored but every filter is switched off, so nothing is filtered.
    case idle
    /// A tap is attached, but no audio has rendered through it yet.
    case waiting
    /// A tap is running with at least one filter.
    case active
    /// Profiles are stored but no tap could be created.
    case unavailable
}

/// Whether the transport managed to install a processing tap on the current item.
enum EQTapAttachment: Equatable {
    /// No attempt yet, or the equaliser is not stored.
    case none
    /// A tap is on the item; it reports its format once audio renders.
    case attached
    /// The item had no audio track, or the tap could not be created.
    case failed
}

struct AudioPathReport: Equatable {
    var source: StreamFormatSummary?
    var processing: TapFormatSummary?
    var activity: EQActivity = .bypassed
    /// `AVAudioSession.sampleRate`; 0 while the session is inactive.
    var sessionSampleRate: Double = 0
    var requestedOption: AudioSampleRateOption = .automatic
    /// The option that was in force at the last session activation.
    var appliedOption: AudioSampleRateOption = .automatic
}

enum AudioPathFormatting {
    /// Rates are compared and displayed with this slack, because a route may report a
    /// nominal rate that differs in the last few digits.
    static let rateTolerance: Double = 1.0

    static let bitDepthCaveat =
        "Output bit depth is chosen by iOS. Audio is float-processed and is not bit-perfect while EQ is active."

    static func sourceLine(_ report: AudioPathReport) -> String {
        guard let source = report.source, source.sampleRateHz > 0 else {
            return "Source: unavailable (nothing has played yet)"
        }
        var text = ""
        if source.bitDepth > 0 { text += "\(source.bitDepth)-bit / " }
        text += kiloHertz(source.sampleRateHz / 1000)
        if let codec = source.codec { text += " · \(codec)" }
        return "Source: " + text
    }

    static func equaliserLine(_ report: AudioPathReport) -> String {
        switch report.activity {
        case .bypassed:
            return "EQ: bypassed (no profiles)"
        case .idle:
            return "EQ: idle (all profiles off)"
        case .unavailable:
            return "EQ: unavailable (the tap could not be created)"
        case .waiting:
            return "EQ: ready (engages when audio plays)"
        case .active:
            guard let processing = report.processing else { return "EQ: starting…" }
            let depth = processing.isFloat
                ? "\(processing.bitsPerChannel)-bit float"
                : "\(processing.bitsPerChannel)-bit"
            return "EQ: \(depth) / \(kiloHertz(processing.sampleRate / 1000)) · \(processing.channels) ch"
        }
    }

    static func verdictLine(_ report: AudioPathReport) -> String {
        guard report.activity == .active else { return "" }
        guard let source = report.source, let processing = report.processing,
              source.sampleRateHz > 0, processing.sampleRate > 0 else {
            return "EQ rate cannot be compared yet."
        }
        let sourceKHz = source.sampleRateHz / 1000
        let processingKHz = processing.sampleRate / 1000
        let difference = processing.sampleRate - source.sampleRateHz
        if abs(difference) <= rateTolerance {
            return "EQ runs at the source rate (\(kiloHertz(processingKHz)))."
        }
        if difference < 0 {
            let ratio = source.sampleRateHz / processing.sampleRate
            return "Converted \(ratioText(ratio)):1 before the EQ (\(kiloHertz(sourceKHz)) → \(kiloHertz(processingKHz)))."
        }
        return "EQ runs above the source rate (\(kiloHertz(sourceKHz)) → \(kiloHertz(processingKHz)))."
    }

    static func sampleRateLine(_ report: AudioPathReport) -> String {
        guard report.sessionSampleRate > 0 else { return "Session inactive." }
        let sessionKHz = kiloHertz(report.sessionSampleRate / 1000)
        guard let requested = report.requestedOption.hertz else {
            return "Sample rate: automatic (session \(sessionKHz))."
        }
        let requestedText = kiloHertz(requested / 1000)
        if report.requestedOption != report.appliedOption {
            return "Sample rate: \(requestedText) requested. Applies from the next playback start."
        }
        if abs(report.sessionSampleRate - requested) <= rateTolerance {
            return "Sample rate: \(requestedText) requested and in use."
        }
        return "Sample rate: \(requestedText) requested; session is \(sessionKHz)."
    }

    // MARK: - Private

    /// `44.1 kHz`, `48.0 kHz`, `96.0 kHz`.
    private static func kiloHertz(_ kHz: Double) -> String {
        String(format: "%.1f kHz", kHz)
    }

    /// `2:1` when the ratio is whole, `1.5:1` otherwise.
    private static func ratioText(_ ratio: Double) -> String {
        guard ratio.isFinite, ratio > 0 else { return "?" }
        let rounded = ratio.rounded()
        if abs(ratio - rounded) < 0.05 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.1f", ratio)
    }
}

// MARK: - Sample rate request

enum AudioSampleRateOption: Int, CaseIterable {
    case automatic = 0
    case hz44100 = 44100
    case hz48000 = 48000
    case hz88200 = 88200
    case hz96000 = 96000
    case hz192000 = 192000

    /// nil for `.automatic`, which requests nothing.
    var hertz: Double? {
        self == .automatic ? nil : Double(rawValue)
    }

    var title: String {
        switch self {
        case .automatic: return "Auto"
        case .hz44100: return "44.1"
        case .hz48000: return "48"
        case .hz88200: return "88.2"
        case .hz96000: return "96"
        case .hz192000: return "192"
        }
    }

    var detail: String {
        switch self {
        case .automatic: return "Automatic"
        default: return String(format: "%.1f kHz", Double(rawValue) / 1000)
        }
    }
}

/// The stored sample-rate request. It is a request, never a guarantee: iOS decides what
/// the route actually runs at.
final class AudioPathPreferences {
    static let shared = AudioPathPreferences()

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "Music.audio.sampleRateOption") {
        self.defaults = defaults
        self.key = key
    }

    var option: AudioSampleRateOption {
        get { AudioSampleRateOption(rawValue: defaults.integer(forKey: key)) ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }

    /// Asks the session for the stored rate. Returns false when nothing was requested or
    /// the call threw; it never implies the route accepted the request.
    @discardableResult
    func apply(to session: AVAudioSession = .sharedInstance()) -> Bool {
        guard let hertz = option.hertz else { return false }
        do {
            try session.setPreferredSampleRate(hertz)
            return true
        } catch {
            NSLog("AudioPathPreferences: could not request %.0f Hz: %@",
                  hertz, error.localizedDescription)
            return false
        }
    }
}
