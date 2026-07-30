import Foundation

enum PlaybackEndReason: String, Codable {
    case completed
    case skipped
    case restarted
    case queueReplaced
    case queueCleared
    case appTerminated
}

struct PlaybackEvent: Codable, Equatable {
    static let currentSchemaVersion = 1

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

    init(
        schemaVersion: Int = PlaybackEvent.currentSchemaVersion,
        id: String = UUID().uuidString,
        trackID: String,
        sourceRelativePath: String,
        title: String,
        artist: String,
        album: String,
        albumArtist: String,
        trackNumber: Int?,
        startedAt: Date,
        endedAt: Date,
        listenedSeconds: TimeInterval,
        trackDuration: TimeInterval,
        completed: Bool,
        endReason: PlaybackEndReason
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.trackID = trackID
        self.sourceRelativePath = sourceRelativePath
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.listenedSeconds = listenedSeconds
        self.trackDuration = trackDuration
        self.completed = completed
        self.endReason = endReason
    }
}

final class PlaybackHistoryStore {
    private struct ActiveSession: Codable {
        var id: String
        var track: Track
        var startedAt: Date
        var segmentStartedAt: Date?
        var listenedSeconds: TimeInterval
        var lastCheckpointAt: Date
    }

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "Music.PlaybackHistoryStore")
    private let checkpointInterval: TimeInterval
    private var activeSession: ActiveSession?

    let historyDirectory: URL
    let eventsURL: URL
    let activeSessionURL: URL

    init(
        fileManager: FileManager = .default,
        documentsDirectory: URL? = nil,
        checkpointInterval: TimeInterval = 5
    ) {
        self.fileManager = fileManager
        self.checkpointInterval = checkpointInterval
        let documents = documentsDirectory
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.historyDirectory = documents.appendingPathComponent("PlaybackHistory", isDirectory: true)
        self.eventsURL = historyDirectory.appendingPathComponent("events.jsonl")
        self.activeSessionURL = historyDirectory.appendingPathComponent("active-session.json")
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601

        try? fileManager.createDirectory(
            at: historyDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        if !fileManager.fileExists(atPath: eventsURL.path) {
            fileManager.createFile(atPath: eventsURL.path, contents: nil, attributes: nil)
        }

        if let data = try? Data(contentsOf: activeSessionURL),
           var recovered = try? decoder.decode(ActiveSession.self, from: data) {
            // Never count time while the process was not running. The
            // checkpointed listening total is still durable and exportable.
            recovered.segmentStartedAt = nil
            activeSession = recovered
            finishLocked(reason: .appTerminated, at: Date())
        }
    }

    deinit {
        queue.sync {
            finishLocked(reason: .appTerminated, at: Date())
        }
    }

    func begin(track: Track, at date: Date = Date()) {
        queue.sync {
            if var active = activeSession, active.track.id == track.id {
                if active.segmentStartedAt == nil {
                    active.segmentStartedAt = date
                    active.lastCheckpointAt = date
                    activeSession = active
                    persistActiveSessionLocked()
                }
                return
            }

            finishLocked(reason: .queueReplaced, at: date)
            activeSession = ActiveSession(
                id: UUID().uuidString,
                track: track,
                startedAt: date,
                segmentStartedAt: date,
                listenedSeconds: 0,
                lastCheckpointAt: date
            )
            persistActiveSessionLocked()
        }
    }

    func pause(at date: Date = Date()) {
        queue.sync {
            accumulateActiveSegmentLocked(until: date)
            guard var active = activeSession else { return }
            active.segmentStartedAt = nil
            active.lastCheckpointAt = date
            activeSession = active
            persistActiveSessionLocked()
        }
    }

    func checkpoint(at date: Date = Date()) {
        queue.sync {
            guard let active = activeSession,
                  date.timeIntervalSince(active.lastCheckpointAt) >= checkpointInterval else { return }
            accumulateActiveSegmentLocked(until: date)
            guard var updated = activeSession else { return }
            if active.segmentStartedAt != nil {
                updated.segmentStartedAt = date
            }
            updated.lastCheckpointAt = date
            activeSession = updated
            persistActiveSessionLocked()
        }
    }

    func finish(reason: PlaybackEndReason, at date: Date = Date()) {
        queue.sync {
            finishLocked(reason: reason, at: date)
        }
    }

    func readAllEvents() -> [PlaybackEvent] {
        return queue.sync {
            guard let data = try? Data(contentsOf: eventsURL),
                  let contents = String(data: data, encoding: .utf8) else { return [] }
            return contents
                .split(separator: "\n")
                .compactMap { line in
                    guard let lineData = String(line).data(using: .utf8) else { return nil }
                    return try? decoder.decode(PlaybackEvent.self, from: lineData)
                }
        }
    }

    private func finishLocked(reason: PlaybackEndReason, at date: Date) {
        accumulateActiveSegmentLocked(until: date)
        guard let active = activeSession else { return }
        let listened = max(0, active.listenedSeconds)
        let duration = max(0, active.track.duration)
        let completed = reason == .completed
            || (duration > 0 && listened >= max(0, duration - 1))
        let event = PlaybackEvent(
            id: active.id,
            trackID: active.track.id,
            sourceRelativePath: active.track.relativePath,
            title: active.track.title,
            artist: active.track.artist,
            album: active.track.albumTitle,
            albumArtist: active.track.albumArtist,
            trackNumber: active.track.trackNumber,
            startedAt: active.startedAt,
            endedAt: max(date, active.startedAt),
            listenedSeconds: listened,
            trackDuration: duration,
            completed: completed,
            endReason: reason
        )
        appendEventLocked(event)
        activeSession = nil
        try? fileManager.removeItem(at: activeSessionURL)
    }

    private func accumulateActiveSegmentLocked(until date: Date) {
        guard var active = activeSession, let segmentStart = active.segmentStartedAt else { return }
        let delta = max(0, date.timeIntervalSince(segmentStart))
        // The engine calls pause before audio stops, so this interval is
        // listening time rather than wall-clock time.
        active.listenedSeconds += delta
        active.segmentStartedAt = date
        activeSession = active
    }

    private func persistActiveSessionLocked() {
        guard let active = activeSession,
              let data = try? encoder.encode(active) else { return }
        try? data.write(to: activeSessionURL, options: .atomic)
    }

    private func appendEventLocked(_ event: PlaybackEvent) {
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        if !fileManager.fileExists(atPath: eventsURL.path) {
            fileManager.createFile(atPath: eventsURL.path, contents: nil, attributes: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: eventsURL) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
}
