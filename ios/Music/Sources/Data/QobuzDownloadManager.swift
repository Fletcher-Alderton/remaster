import Foundation

/// A download is usable only after both its media file and atomic manifest commit succeed.
enum QobuzDownloadState: Equatable {
    case notDownloaded, queued, resolving, downloading(Double), downloaded, cancelled, failed(String)
}

/// Deliberately contains no credentials, artwork URLs, or expiring stream URLs.
struct QobuzDownloadRecord: Codable, Equatable {
    let accountID: Int64
    let trackID: Int64
    let requestedQuality: Int
    let actualFormatID: Int
    let title: String
    let artist: String?
    let albumID: String?
    let albumTitle: String?
    let duration: Int?
    let mimeType: String
    let samplingRate: Double
    let bitDepth: Int
    let byteCount: Int64
    let filename: String
    let completedAt: Date
    /// Added later; older manifests decode these as nil.
    var artworkURL: URL? = nil
    var artistID: String? = nil
}

enum QobuzDownloadError: LocalizedError {
    case notAuthenticated, invalidTrack, invalidMedia, invalidManifest
    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Sign in to Qobuz before downloading music."
        case .invalidTrack: return "This track cannot be downloaded."
        case .invalidMedia: return "The download did not contain a complete supported audio file."
        case .invalidManifest: return "The download library could not be read."
        }
    }
}

/// Own one instance per library directory. Calls and network completions are serialized by a lock;
/// `didChange` notifications are delivered on main. Use state/record/fileURL to read the latest snapshot.
/// Downloads are foreground URLSession tasks: interrupted work is not restored or auto-restarted.
final class QobuzDownloadManager {
    static let didChange = Notification.Name("QobuzDownloadManager.didChange")

    private struct Key: Hashable {
        let account: Int64
        let track: Int64
        let quality: Int
    }
    private final class Job {
        let id = UUID()
        let key: Key
        let track: QobuzSearchTrack
        let quality: QobuzStreamQuality
        var state: QobuzDownloadState = .queued
        var task: URLSessionDownloadTask?
        var observation: NSKeyValueObservation?
        init(key: Key, track: QobuzSearchTrack, quality: QobuzStreamQuality) {
            self.key = key; self.track = track; self.quality = quality
        }
    }

    private let lock = NSRecursiveLock()
    private let directory: URL
    private let session: URLSession
    private let maximumConcurrentDownloads: Int
    private var accountID: Int64?
    private var resolver: QobuzStreamResolving?
    private var records: [Key: QobuzDownloadRecord] = [:]
    private var jobs: [Key: Job] = [:]
    private var pending: [Key] = []
    private var active = Set<Key>()
    private var terminalStates: [Key: QobuzDownloadState] = [:]
    private var manifestURL: URL { directory.appendingPathComponent("downloads.json") }

    init(directory: URL? = nil, session: URLSession = .shared, maximumConcurrentDownloads: Int = 2) throws {
        self.directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("QobuzDownloads", isDirectory: true)
        self.session = session
        self.maximumConcurrentDownloads = min(4, max(1, maximumConcurrentDownloads))
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var excludedDirectory = self.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(values)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let saved = try JSONDecoder().decode([QobuzDownloadRecord].self, from: Data(contentsOf: manifestURL))
            for record in saved {
                guard Self.validFilename(record.filename), record.trackID > 0,
                      QobuzStreamQuality(rawValue: record.requestedQuality) != nil else {
                    throw QobuzDownloadError.invalidManifest
                }
                let key = Key(account: record.accountID, track: record.trackID, quality: record.requestedQuality)
                if validFile(record) { records[key] = record }
            }
            // Repair missing/truncated files before exposing the recovered library.
            if records.count != saved.count { try persist(records) }
        }
        // A crash after moving media but before committing the manifest leaves an orphan, never a download.
        let referenced = Set(records.values.map(\.filename))
        for file in try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
        where Self.validFilename(file.lastPathComponent) && !referenced.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }

    deinit {
        for job in jobs.values { job.observation?.invalidate(); job.task?.cancel() }
    }

    /// Call on every sign-in, sign-out, or credential/account replacement. Existing completed files
    /// remain on disk, but only this account's files are visible. All in-flight generations are invalidated.
    func setAccount(id: Int64?, resolver: QobuzStreamResolving?) {
        locked {
            let obsolete = Array(jobs.values)
            jobs.removeAll(); pending.removeAll(); active.removeAll(); terminalStates.removeAll()
            self.accountID = id
            self.resolver = resolver
            for job in obsolete { job.observation?.invalidate(); job.task?.cancel() }
            changed()
        }
    }

    /// Repeating this call deduplicates completed/queued/active work. After failure or cancellation,
    /// the same call retries with a freshly resolved signed URL (never a persisted URL).
    func download(track: QobuzSearchTrack, quality: QobuzStreamQuality) throws {
        try downloadAlbum(tracks: [track], quality: quality)
    }

    /// Pass the complete album track list. Duplicate track IDs are downloaded only once per quality/account.
    /// Authentication and track eligibility are validated before enqueueing any work.
    func downloadAlbum(tracks: [QobuzSearchTrack], quality: QobuzStreamQuality) throws {
        try locked {
            guard let account = accountID, resolver != nil else { throw QobuzDownloadError.notAuthenticated }
            guard tracks.allSatisfy({ $0.id > 0 && $0.streamable != false }) else { throw QobuzDownloadError.invalidTrack }
            for track in tracks {
                let key = Key(account: account, track: track.id, quality: quality.rawValue)
                guard jobs[key] == nil, usableRecord(key) == nil else { continue }
                terminalStates.removeValue(forKey: key)
                jobs[key] = Job(key: key, track: track, quality: quality)
                pending.append(key)
            }
            changed()
            pump()
        }
    }

    func state(trackID: Int64, quality: QobuzStreamQuality) -> QobuzDownloadState {
        locked {
            guard let key = key(trackID, quality) else { return .notDownloaded }
            if usableRecord(key) != nil { return .downloaded }
            return jobs[key]?.state ?? terminalStates[key] ?? .notDownloaded
        }
    }

    func record(trackID: Int64, quality: QobuzStreamQuality) -> QobuzDownloadRecord? {
        locked { key(trackID, quality).flatMap(usableRecord) }
    }

    /// Every playable download for the signed-in account at exactly this quality.
    func records(quality: QobuzStreamQuality) -> [QobuzDownloadRecord] {
        locked {
            guard let account = accountID else { return [] }
            return records.keys.filter { $0.account == account && $0.quality == quality.rawValue }.compactMap(usableRecord)
        }
    }

    /// Exact requested-quality match only; no implicit lower-quality fallback across settings/accounts.
    func fileURL(trackID: Int64, quality: QobuzStreamQuality) -> URL? {
        locked { record(trackID: trackID, quality: quality).map { directory.appendingPathComponent($0.filename) } }
    }

    func cancel(trackID: Int64, quality: QobuzStreamQuality) {
        locked {
            guard let key = key(trackID, quality) else { return }
            cancel(key)
            pump()
        }
    }

    /// Cancels work and removes this account/quality only. Disk errors are thrown to the caller.
    func delete(trackID: Int64, quality: QobuzStreamQuality) throws {
        try locked {
            guard let key = key(trackID, quality) else { return }
            cancel(key)
            defer { pump(); changed() }
            if let record = records[key] {
                var updated = records
                updated.removeValue(forKey: key)
                // Commit absence first, so a failed physical deletion cannot publish a deleted file.
                try persist(updated)
                records = updated
                let file = directory.appendingPathComponent(record.filename)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            terminalStates.removeValue(forKey: key)
        }
    }

    private func key(_ track: Int64, _ quality: QobuzStreamQuality) -> Key? {
        accountID.map { Key(account: $0, track: track, quality: quality.rawValue) }
    }

    private func cancel(_ key: Key) {
        guard let job = jobs.removeValue(forKey: key) else { return }
        pending.removeAll { $0 == key }
        active.remove(key)
        terminalStates[key] = .cancelled
        job.observation?.invalidate()
        job.task?.cancel()
        changed()
    }

    private func pump() {
        while active.count < maximumConcurrentDownloads, !pending.isEmpty, let resolver = resolver {
            let key = pending.removeFirst()
            guard let job = jobs[key] else { continue }
            active.insert(key)
            job.state = .resolving
            changed()
            resolver.requestStreamURL(trackID: job.track.id, quality: job.quality, progress: { _ in }) { [weak self, weak job] result in
                guard let self = self, let job = job else { return }
                self.locked {
                    guard self.isCurrent(job), job.task == nil else { return }
                    switch result {
                    case .failure:
                        self.finish(job, state: .failed("Could not resolve download. Try again."))
                    case .success(let stream):
                        guard stream.url.scheme?.lowercased() == "https" || stream.url.scheme?.lowercased() == "http",
                              QobuzStreamQuality(rawValue: stream.formatID) != nil else {
                            self.finish(job, state: .failed("Unsupported download response.")); return
                        }
                        let task = self.session.downloadTask(with: stream.url) { [weak self, weak job] location, response, error in
                            guard let self = self, let job = job else { return }
                            // URLSession's temporary file is valid only during this callback: commit synchronously.
                            self.locked {
                                guard self.isCurrent(job) else { return }
                                guard error == nil, let location = location else {
                                    self.finish(job, state: .failed("Download interrupted. Try again.")); return
                                }
                                do {
                                    try self.commit(job, stream: stream, location: location, response: response)
                                    self.finish(job, state: .downloaded)
                                } catch {
                                    // Never expose network errors (which may include signed URLs/tokens) to metadata/UI.
                                    self.finish(job, state: .failed("Could not save a complete audio download. Check storage and retry."))
                                }
                            }
                        }
                        job.task = task
                        job.state = .downloading(0)
                        job.observation = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self, weak job] progress, _ in
                            guard let self = self, let job = job else { return }
                            self.locked {
                                guard self.isCurrent(job) else { return }
                                job.state = .downloading(min(1, max(0, progress.fractionCompleted)))
                                self.changed()
                            }
                        }
                        self.changed()
                        task.resume()
                    }
                }
            }
        }
    }

    private func isCurrent(_ job: Job) -> Bool { jobs[job.key]?.id == job.id && accountID == job.key.account }

    private func finish(_ job: Job, state: QobuzDownloadState) {
        guard isCurrent(job) else { return }
        jobs.removeValue(forKey: job.key)
        active.remove(job.key)
        job.observation?.invalidate()
        // Downloaded state is derived exclusively from a currently valid file/record, never cached.
        if state == .downloaded { terminalStates.removeValue(forKey: job.key) }
        else { terminalStates[job.key] = state }
        changed()
        pump()
    }

    private func commit(_ job: Job, stream: QobuzTrackURL, location: URL, response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              !http.allHeaderFields.keys.contains(where: { String(describing: $0).caseInsensitiveCompare("Content-Range") == .orderedSame }) else { throw QobuzDownloadError.invalidMedia }
        let mime = (http.mimeType ?? "").lowercased()
        guard ["audio/flac", "audio/x-flac", "audio/mpeg", "audio/mp3", "application/octet-stream"].contains(mime) else {
            throw QobuzDownloadError.invalidMedia
        }
        let size = try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, http.expectedContentLength < 0 || Int64(size) == http.expectedContentLength else {
            throw QobuzDownloadError.invalidMedia
        }
        let handle = try FileHandle(forReadingFrom: location)
        let header = handle.readData(ofLength: 12)
        handle.closeFile()
        let bytes = Array(header)
        let flac = bytes.starts(with: [0x66, 0x4c, 0x61, 0x43])
        let mp3 = bytes.starts(with: [0x49, 0x44, 0x33]) || (bytes.count >= 2 && bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0)
        guard (stream.formatID == QobuzStreamQuality.mp3.rawValue ? mp3 : flac), size > 12 else {
            throw QobuzDownloadError.invalidMedia
        }
        let filename = UUID().uuidString + (flac ? ".flac" : ".mp3")
        let destination = directory.appendingPathComponent(filename)
        // moveItem may cross volumes; manifest is committed only after the full move/copy succeeds.
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            var updated = records
            updated[job.key] = QobuzDownloadRecord(accountID: job.key.account, trackID: job.track.id,
                requestedQuality: job.quality.rawValue, actualFormatID: stream.formatID,
                title: job.track.title, artist: job.track.performer?.name ?? job.track.album?.artist?.name,
                albumID: job.track.albumID ?? job.track.album?.id, albumTitle: job.track.album?.title,
                duration: job.track.duration, mimeType: flac ? "audio/flac" : "audio/mpeg",
                samplingRate: stream.samplingRate, bitDepth: stream.bitDepth, byteCount: Int64(size),
                filename: filename, completedAt: Date(), artworkURL: job.track.album?.imageURL,
                artistID: job.track.performer?.id ?? job.track.album?.artist?.id)
            try persist(updated)
            records = updated
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func validFilename(_ name: String) -> Bool {
        let url = URL(fileURLWithPath: name)
        return url.lastPathComponent == name && ["flac", "mp3"].contains(url.pathExtension)
            && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
    }

    private func validFile(_ record: QobuzDownloadRecord) -> Bool {
        guard record.byteCount > 0, Self.validFilename(record.filename),
              let values = try? directory.appendingPathComponent(record.filename).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        return values.fileSize.map { Int64($0) == record.byteCount } ?? false
    }

    private func usableRecord(_ key: Key) -> QobuzDownloadRecord? {
        guard let record = records[key], validFile(record) else { return nil }
        return record
    }

    private func persist(_ records: [Key: QobuzDownloadRecord]) throws {
        try JSONEncoder().encode(Array(records.values)).write(to: manifestURL, options: .atomic)
    }

    private func changed() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    @discardableResult private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}
