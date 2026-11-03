import Foundation

/// One parametric EQ band, as written in an Equalizer APO / AutoEQ profile line.
enum EQFilterKind: String, Codable {
    case peaking = "PK"
    /// Low shelf shaped by Q (`LSC`).
    case lowShelfQ = "LSC"
    /// High shelf shaped by Q (`HSC`).
    case highShelfQ = "HSC"
    /// Low shelf shaped by slope (`LS`).
    case lowShelfS = "LS"
    /// High shelf shaped by slope (`HS`).
    case highShelfS = "HS"
    /// Second-order low pass (`LP`). Used for diagnostics: it removes everything above Fc.
    case lowPass = "LP"
    /// Second-order high pass (`HP`). Used for diagnostics: it removes everything below Fc.
    case highPass = "HP"

    /// Stable small integer used when the parameters are copied to the render thread.
    var paramCode: Int32 {
        switch self {
        case .peaking: return 0
        case .lowShelfQ: return 1
        case .highShelfQ: return 2
        case .lowShelfS: return 3
        case .highShelfS: return 4
        case .lowPass: return 5
        case .highPass: return 6
        }
    }

    init?(paramCode: Int32) {
        switch paramCode {
        case 0: self = .peaking
        case 1: self = .lowShelfQ
        case 2: self = .highShelfQ
        case 3: self = .lowShelfS
        case 4: self = .highShelfS
        case 5: self = .lowPass
        case 6: self = .highPass
        default: return nil
        }
    }

    init?(token: String) {
        switch token.uppercased() {
        case "PK", "PEAK": self = .peaking
        case "LSC", "LSQ": self = .lowShelfQ
        case "HSC", "HSQ": self = .highShelfQ
        case "LS": self = .lowShelfS
        case "HS": self = .highShelfS
        case "LP", "LPQ": self = .lowPass
        case "HP", "HPQ": self = .highPass
        default: return nil
        }
    }

    /// Whether the band takes a `Gain` value. Filters are cutoffs, not boosts.
    var carriesGain: Bool {
        switch self {
        case .peaking, .lowShelfQ, .highShelfQ, .lowShelfS, .highShelfS: return true
        case .lowPass, .highPass: return false
        }
    }

    var usesSlope: Bool {
        self == .lowShelfS || self == .highShelfS
    }
}

struct EQFilter: Codable, Equatable {
    /// The `N` in `Filter N:`.
    var index: Int
    /// The `ON` / `OFF` token on the line.
    var isEnabled: Bool
    var kind: EQFilterKind
    /// Centre or corner frequency in hertz.
    var frequency: Double
    /// Band gain in decibels. Zero for kinds that do not carry gain.
    var gain: Double
    /// Quality factor. Zero for slope-shaped shelves.
    var q: Double
    /// Slope. Zero for Q-shaped filters.
    var slope: Double

    init(index: Int, isEnabled: Bool = true, kind: EQFilterKind,
         frequency: Double, gain: Double = 0, q: Double = 0, slope: Double = 0) {
        self.index = index
        self.isEnabled = isEnabled
        self.kind = kind
        self.frequency = frequency
        self.gain = gain
        self.q = q
        self.slope = slope
    }

    /// `PK · 480 Hz · +1.1 dB · Q 2.00`, plus `OFF` when the band is disabled.
    var displayDescription: String {
        var parts = [kind.rawValue, "\(Self.hz(frequency)) Hz"]
        if kind.carriesGain { parts.append("\(Self.db(gain)) dB") }
        if kind.usesSlope { parts.append("S \(Self.decimal(slope))") }
        else { parts.append("Q \(Self.decimal(q))") }
        if !isEnabled { parts.append("OFF") }
        return parts.joined(separator: " · ")
    }

    private static func hz(_ value: Double) -> String {
        String(format: value == value.rounded() ? "%.0f" : "%.1f", value)
    }

    private static func db(_ value: Double) -> String {
        String(format: "%+.1f", value)
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct EQProfile: Codable, Equatable {
    /// Assigned by the editor, never by the parser, so parsing stays deterministic.
    var id: String
    var name: String
    /// Broadband attenuation applied before the filters, in decibels.
    var preamp: Double
    var filters: [EQFilter]
    /// Lines that could not be used, kept verbatim so the user can see them.
    var skippedLines: [String]
    /// The text the profile was created from.
    var sourceText: String
    var isEnabled: Bool

    var enabledFilterCount: Int {
        filters.reduce(0) { $0 + ($1.isEnabled ? 1 : 0) }
    }

    /// `13 filters · Preamp -2.0 dB · 1 off · 2 skipped`
    var summaryText: String {
        var parts = ["\(filters.count) filter\(filters.count == 1 ? "" : "s")",
                     String(format: "Preamp %.1f dB", preamp)]
        let off = filters.count - enabledFilterCount
        if off > 0 { parts.append("\(off) off") }
        if !skippedLines.isEmpty { parts.append("\(skippedLines.count) skipped") }
        return parts.joined(separator: " · ")
    }
}

struct EQParseResult: Equatable {
    var preamp: Double
    var filters: [EQFilter]
    var skippedLines: [String]
}

enum EQParseError: LocalizedError, Equatable {
    case emptyInput
    case noUsableFilters(skipped: [String])
    case unsupportedChannel(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "There is nothing to load. Paste a parametric EQ profile first."
        case .noUsableFilters(let skipped):
            let detail = skipped.first.map { " First unusable line: \($0)" } ?? ""
            return "No usable filters were found. Profiles must use PK, LSC, HSC, LS or HS lines.\(detail)"
        case .unsupportedChannel(let channel):
            return "Per-channel profiles are not supported (Channel: \(channel)). Use a profile with a single set of filters, or Channel: all."
        }
    }
}

/// Reads the Equalizer APO parametric text format.
enum EQProfileParser {
    static func parse(_ text: String) throws -> EQParseResult {
        let lines = text.components(separatedBy: .newlines)
        var preamp = 0.0
        var filters: [EQFilter] = []
        var skipped: [String] = []
        var sawContent = false

        for rawLine in lines {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            sawContent = true
            let lower = line.lowercased()

            if lower.hasPrefix("preamp") {
                if let value = numberAfterColon(line) { preamp = value }
                else { skipped.append(line) }
                continue
            }

            if lower.hasPrefix("channel") {
                let value = line.split(separator: ":", maxSplits: 1)
                    .dropFirst().first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if !value.isEmpty && value.lowercased() != "all" {
                    throw EQParseError.unsupportedChannel(value)
                }
                continue
            }

            if lower.hasPrefix("filter") {
                switch parseFilter(line) {
                case .success(let filter): filters.append(filter)
                case .failure: skipped.append(line)
                }
                continue
            }

            skipped.append(line)
        }

        guard sawContent else { throw EQParseError.emptyInput }
        guard !filters.isEmpty else { throw EQParseError.noUsableFilters(skipped: skipped) }
        return EQParseResult(preamp: preamp, filters: filters, skippedLines: skipped)
    }

    // MARK: - Line parsing

    private static func stripComment(_ line: String) -> String {
        guard let hash = line.firstIndex(of: "#") else { return line }
        return String(line[line.startIndex..<hash])
    }

    private static func number(_ token: String) -> Double? {
        let cleaned = token.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    private static func numberAfterColon(_ line: String) -> Double? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let rest = line[line.index(after: colon)...]
        guard let token = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else { return nil }
        return number(String(token))
    }

    private static func parseFilter(_ line: String) -> Result<EQFilter, EQParseError> {
        guard let colon = line.firstIndex(of: ":") else { return .failure(.emptyInput) }
        // `Filter 1:` -> `1`
        let prefix = line[line.index(line.startIndex, offsetBy: min(6, line.count))..<colon]
            .trimmingCharacters(in: .whitespaces)
        guard let index = Int(prefix) else { return .failure(.emptyInput) }

        let rest = line[line.index(after: colon)...]
        let tokens = rest.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard tokens.count >= 2 else { return .failure(.emptyInput) }
        guard let kind = EQFilterKind(token: tokens[1]) else { return .failure(.emptyInput) }
        let isEnabled = tokens[0].uppercased() != "OFF"

        var frequency: Double?
        var gain: Double?
        var q: Double?
        var slope: Double?

        var position = 2
        while position < tokens.count {
            let key = tokens[position].lowercased()
            switch key {
            case "fc", "f":
                if position + 1 < tokens.count, let value = number(tokens[position + 1]) {
                    frequency = value
                    position += 2
                    continue
                }
            case "gain", "g":
                if position + 1 < tokens.count, let value = number(tokens[position + 1]) {
                    gain = value
                    position += 2
                    continue
                }
            case "q":
                if position + 1 < tokens.count, let value = number(tokens[position + 1]) {
                    q = value
                    position += 2
                    continue
                }
            case "s":
                if position + 1 < tokens.count, let value = number(tokens[position + 1]) {
                    slope = value
                    position += 2
                    continue
                }
            case "bw":
                // `BW Oct 1.0` and `BW 1.0` are both valid.
                var cursor = position + 1
                if cursor < tokens.count,
                   ["oct", "octaves"].contains(tokens[cursor].lowercased()) {
                    cursor += 1
                }
                if cursor < tokens.count, let octaves = number(tokens[cursor]) {
                    // Equalizer APO: Q = sqrt(2^BW) / (2^BW - 1)
                    let bandwidth = pow(2, octaves)
                    if bandwidth > 1 { q = sqrt(bandwidth) / (bandwidth - 1) }
                    position = cursor + 1
                    continue
                }
            default:
                break
            }
            // Units (`Hz`, `dB`, `Oct`) and stray tokens are ignored.
            position += 1
        }

        guard let fc = frequency, fc > 0 else { return .failure(.emptyInput) }

        if kind.carriesGain && gain == nil { return .failure(.emptyInput) }

        if kind.usesSlope {
            let resolvedSlope = slope ?? 1.0
            guard resolvedSlope > 0 else { return .failure(.emptyInput) }
            return .success(EQFilter(index: index, isEnabled: isEnabled, kind: kind,
                                     frequency: fc, gain: gain ?? 0, slope: resolvedSlope))
        }

        let resolvedQ = q ?? 0.707
        guard resolvedQ > 0 else { return .failure(.emptyInput) }
        return .success(EQFilter(index: index, isEnabled: isEnabled, kind: kind,
                                 frequency: fc, gain: gain ?? 0, q: resolvedQ))
    }
}

/// Persists loaded profiles and publishes them to the audio chain.
final class EQProfileStore {
    static let shared = EQProfileStore()

    private let defaults: UserDefaults
    private let key: String
    private let runtime: EQChainRuntime
    private(set) var profiles: [EQProfile] = []

    var hasProfiles: Bool { !profiles.isEmpty }

    init(defaults: UserDefaults = .standard,
         key: String = "Music.EQ.profiles.v1",
         runtime: EQChainRuntime = .shared) {
        self.defaults = defaults
        self.key = key
        self.runtime = runtime
        load()
        // Publishes on launch so the transport knows a tap is needed before the
        // first track resolves, without any AppDelegate priming.
        runtime.update(profiles: profiles)
    }

    func add(_ profile: EQProfile) {
        profiles.append(profile)
        persist()
    }

    func remove(id: String) {
        profiles.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ enabled: Bool, id: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].isEnabled = enabled
        persist()
    }

    // MARK: - Bundled profiles

    /// Imports the profiles shipped in the bundle's `EQ/` directory.
    ///
    /// Each name is imported once. A profile the user has since deleted is not brought
    /// back, and one the user added by hand under the same name is adopted rather than
    /// duplicated. If the shipped text changes, the stored profile's bands and preamp are
    /// updated in place so its identifier and on/off switch survive.
    @discardableResult
    func importBundledProfilesIfNeeded() -> Int {
        importBundledProfiles(BundledEQProfiles.load())
    }

    @discardableResult
    func importBundledProfiles(_ items: [BundledEQProfiles.Item]) -> Int {
        guard !items.isEmpty else { return 0 }
        var fingerprints = defaults.dictionary(forKey: bundledFingerprintsKey) as? [String: String] ?? [:]
        var changed = 0

        for item in items {
            guard let parsed = try? EQProfileParser.parse(item.text) else {
                NSLog("EQProfileStore: bundled profile %@ did not parse; skipping.", item.name)
                continue
            }
            let fingerprint = Self.fingerprint(item.text)

            // Same curve already present under another name (for example one pasted in by
            // hand before this profile shipped). Enabling both would stack the correction
            // twice, so treat it as imported instead of adding a second copy.
            if profiles.contains(where: { $0.preamp == parsed.preamp && $0.filters == parsed.filters }) {
                fingerprints[item.name] = fingerprint
                continue
            }

            if let existing = profiles.first(where: { $0.name == item.name }) {
                // Already present, either from an earlier import or added by hand.
                let previous = fingerprints[item.name]
                if previous == nil {
                    // Adopt the hand-added profile instead of adding a second copy.
                    fingerprints[item.name] = fingerprint
                } else if previous != fingerprint {
                    var updated = existing
                    updated.preamp = parsed.preamp
                    updated.filters = parsed.filters
                    updated.skippedLines = parsed.skippedLines
                    updated.sourceText = item.text
                    if let index = profiles.firstIndex(where: { $0.id == existing.id }) {
                        profiles[index] = updated
                        changed += 1
                    }
                    fingerprints[item.name] = fingerprint
                }
                continue
            }

            // Not present. Only add it if this name has never been imported; otherwise the
            // user deleted it deliberately.
            guard fingerprints[item.name] == nil else { continue }
            profiles.append(EQProfile(id: UUID().uuidString,
                                      name: item.name,
                                      preamp: parsed.preamp,
                                      filters: parsed.filters,
                                      skippedLines: parsed.skippedLines,
                                      sourceText: item.text,
                                      isEnabled: !Self.prefersDisabled(item.text)))
            fingerprints[item.name] = fingerprint
            changed += 1
        }

        defaults.set(fingerprints, forKey: bundledFingerprintsKey)
        if changed > 0 { persist() }
        return changed
    }

    /// A profile can opt out of being switched on at import with a `# Default: off`
    /// comment. Diagnostic curves use this so they never stack with a real correction.
    static func prefersDisabled(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { line in
            let squashed = line.lowercased().filter { !$0.isWhitespace }
            return squashed.hasPrefix("#default:off")
        }
    }

    /// FNV-1a over the UTF-8 bytes. Swift's `hashValue` is seeded per process and cannot be
    /// persisted; this is stable across launches.
    static func fingerprint(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private var bundledFingerprintsKey: String { key + ".bundledFingerprints" }

    // MARK: - Private

    private func load() {
        guard let data = defaults.data(forKey: key) else { return }
        do {
            profiles = try JSONDecoder().decode([EQProfile].self, from: data)
        } catch {
            // A corrupt or older payload is an empty library, never a crash.
            NSLog("EQProfileStore: could not decode stored profiles: \(error.localizedDescription)")
            profiles = []
        }
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: key)
        } catch {
            NSLog("EQProfileStore: could not encode profiles: \(error.localizedDescription)")
        }
        runtime.update(profiles: profiles)
    }
}
