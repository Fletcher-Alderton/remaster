import Foundation
import Network

/// Connection state for the "downloaded music only" offline view.
/// While offline, screens show and play only downloaded tracks. That restriction ends
/// automatically when the connection returns, or manually via `showAllContent()`
/// (a second pull-down in a library tab), which lasts until the next reconnect.
final class OfflineMode {
    static let shared = OfflineMode(startMonitoring: true)
    /// Posted on the main thread whenever `isOnline` or `restrictsToDownloads` changes.
    static let didChange = Notification.Name("OfflineMode.didChange")

    private(set) var isOnline = true
    private var showsAllContent = false
    private var monitor: NWPathMonitor?

    var restrictsToDownloads: Bool { !isOnline && !showsAllContent }

    init(startMonitoring: Bool) {
        guard startMonitoring else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async { self?.setOnline(online) }
        }
        monitor.start(queue: DispatchQueue(label: "Music.OfflineMode"))
        self.monitor = monitor
    }

    deinit { monitor?.cancel() }

    func setOnline(_ online: Bool) {
        let before = (isOnline, restrictsToDownloads)
        isOnline = online
        if online { showsAllContent = false }
        guard before != (isOnline, restrictsToDownloads) else { return }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// Manual override while offline: show every screen's normal content (cached where possible).
    func showAllContent() {
        guard restrictsToDownloads else { return }
        showsAllContent = true
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// The downloaded subset of a queue, starting at the first downloaded track at or after `index`.
    static func downloadedQueue(_ tracks: [ScreenTrack], startingAt index: Int,
                                isDownloaded: (ScreenTrack) -> Bool) -> (tracks: [ScreenTrack], start: Int) {
        let kept = tracks.enumerated().filter { isDownloaded($0.element) }
        guard !kept.isEmpty else { return ([], 0) }
        let start = kept.firstIndex { $0.offset >= index } ?? 0
        return (kept.map(\.element), start)
    }
}

/// Albums, artists and tracks rebuilt from download records alone, so the library can be
/// browsed and played with no connection (and without any cached catalog responses).
struct OfflineLibrary {
    /// Newest download first.
    let records: [QobuzDownloadRecord]

    init(records: [QobuzDownloadRecord]) {
        self.records = records.sorted { $0.completedAt > $1.completedAt }
    }

    static let empty = OfflineLibrary(records: [])

    var tracks: [ScreenTrack] { records.map(Self.track) }

    /// Albums ordered by their most recent download; tracks within an album in download order
    /// (album downloads are queued in album order).
    var albums: [ScreenAlbum] {
        var order: [String] = []
        var grouped: [String: [QobuzDownloadRecord]] = [:]
        for record in records {
            let key = Self.albumKey(record)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(record)
        }
        return order.compactMap { key in grouped[key].map { Self.album(id: key, records: $0) } }
    }

    var artists: [ScreenProfile] {
        var seen = Set<String>()
        return records.compactMap { record -> ScreenProfile? in
            let name = record.artist ?? "Unknown Artist"
            guard seen.insert(name.lowercased()).inserted else { return nil }
            return ScreenProfile(id: record.artistID ?? "", name: name, subtitle: "Downloaded", information: "",
                                 artworkURL: record.artworkURL)
        }
    }

    func album(id: String) -> ScreenAlbum? {
        let matching = records.filter { Self.albumKey($0) == id }
        return matching.isEmpty ? nil : Self.album(id: id, records: matching)
    }

    /// An artist page built from downloads, matched by Qobuz artist ID or, failing that, by name.
    func profile(artistID: String, name: String) -> ScreenProfile {
        let matching = records.filter { record in
            if !artistID.isEmpty, let id = record.artistID { return id == artistID }
            return (record.artist ?? "").caseInsensitiveCompare(name) == .orderedSame
        }
        let library = OfflineLibrary(records: matching)
        let albums = library.albums
        return ScreenProfile(id: artistID, name: name,
                             subtitle: matching.isEmpty ? "No downloads by this artist" : "Downloaded",
                             information: "", artworkURL: matching.first?.artworkURL,
                             albums: albums, tracks: albums.flatMap(\.tracks))
    }

    /// Minimal Qobuz track values so album pages can show per-track download state offline.
    func searchTracks(albumID: String) -> [QobuzSearchTrack] {
        records.filter { Self.albumKey($0) == albumID }.sorted { $0.completedAt < $1.completedAt }.compactMap { record in
            var object: [String: Any] = ["id": record.trackID, "title": record.title, "album_id": albumID]
            if let duration = record.duration { object["duration"] = duration }
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(QobuzSearchTrack.self, from: data)
        }
    }

    private static func albumKey(_ record: QobuzDownloadRecord) -> String {
        record.albumID ?? "offline-album:\(record.albumTitle ?? "Unknown Album")"
    }

    private static func track(_ record: QobuzDownloadRecord) -> ScreenTrack {
        ScreenTrack(id: String(record.trackID), title: record.title, artist: record.artist ?? "Unknown Artist",
                    album: record.albumTitle ?? "Unknown Album",
                    quality: "Downloaded · \(record.bitDepth)-bit / \(Int(record.samplingRate * 1000)) Hz",
                    artworkURL: record.artworkURL, catalogAlbumID: record.albumID, catalogArtistID: record.artistID,
                    duration: TimeInterval(record.duration ?? 0))
    }

    private static func album(id: String, records: [QobuzDownloadRecord]) -> ScreenAlbum {
        let ordered = records.sorted { $0.completedAt < $1.completedAt }
        let first = ordered[0]
        return ScreenAlbum(id: id, title: first.albumTitle ?? "Unknown Album", artist: first.artist ?? "Unknown Artist",
                           year: "", artworkURL: ordered.compactMap(\.artworkURL).first, tracks: ordered.map(track))
    }
}
