import Foundation

enum PlaybackEndReason: String, Codable {
    case completed
    case skipped
    case restarted
    case queueReplaced
    case queueCleared
    case appTerminated
}

struct PlaybackEvent: Codable, Equatable, Identifiable {
    var schemaVersion: Int
    var id: String
    var trackID: String
    var sourceRelativePath: String
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var trackNumber: Int?
    var startedAt: Date
    var endedAt: Date
    var listenedSeconds: TimeInterval
    var trackDuration: TimeInterval
    var completed: Bool
    var endReason: PlaybackEndReason

    var isLastFMEligible: Bool {
        guard trackDuration > 30 else { return false }
        return listenedSeconds >= min(trackDuration / 2, 240)
    }
}

enum ScrobbleState: String, Codable {
    case pending
    case scrobbled
    case ineligible
    case failed
}

struct ImportedPlaybackEvent: Codable, Identifiable {
    var event: PlaybackEvent
    var state: ScrobbleState
    var stateMessage: String?
    var importedAt: Date
    var scrobbledAt: Date?

    var id: String { event.id }
}

struct FileFingerprint: Codable, Equatable {
    var byteSize: Int64
    var modificationTime: TimeInterval
}

struct SyncManifest: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion = currentSchemaVersion
    var files: [String: FileFingerprint] = [:]
    var updatedAt = Date()
}

struct SourceFile {
    var localURL: URL
    var relativePath: String
    var fingerprint: FileFingerprint
}

struct LastFMSession: Codable {
    var name: String
    var key: String
}

enum LastFMScrobbleResult {
    case accepted
    case ignored(String)
}
