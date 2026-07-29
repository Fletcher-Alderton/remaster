import AVFoundation
import Foundation
import ImageIO
import UIKit

final class ArtworkStore {
    private let cache = NSCache<NSString, UIImage>()
    private let artworkDirectory: URL
    private var memoryWarningObserver: NSObjectProtocol?

    init(artworkDirectory: URL) {
        self.artworkDirectory = artworkDirectory
        cache.countLimit = 80
        cache.totalCostLimit = 32 * 1_024 * 1_024
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.cache.removeAllObjects()
        }
    }

    deinit {
        if let memoryWarningObserver = memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    func image(named fileName: String?, maximumPixelSize: CGFloat = 400) -> UIImage? {
        guard let fileName = fileName else { return nil }
        let pixelSize = max(1, maximumPixelSize)
        let cacheKey = "\(fileName)-\(Int(pixelSize))" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let url = artworkDirectory.appendingPathComponent(fileName)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let result = UIImage(cgImage: image)
        cache.setObject(result, forKey: cacheKey, cost: image.bytesPerRow * image.height)
        return result
    }
}

struct LibraryImportResult {
    var importedTracks: [Track]
    var skippedURLs: [URL]
    var errors: [Error]
}

final class LibraryStore {
    private enum ArtworkLookup {
        case found(String)
        case missing
    }

    private struct ParsedAudioTags {
        var values: [String: String] = [:]
        var artworkData: Data?

        func value(_ keys: String...) -> String? {
            for key in keys {
                if let value = values[key.uppercased()]?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }
    }

    private struct FolderTags {
        var artist: String?
        var album: String?
        var year: Int?
    }

    static let fixtureFileName = "FixtureLibrary"
    static let supportedFileExtensions = [
        "flac", "alac", "m4a", "aac", "mp3", "wav", "aif", "aiff", "caf", "ogg", "opus"
    ]

    private let fileManager: FileManager
    private let operationQueue: OperationQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let stateQueue = DispatchQueue(label: "Music.LibraryStore.state")
    // Indexing is serialized, so this cache needs no additional locking. It
    // prevents reading and hashing the same album cover once per track.
    private var artworkByFolder: [String: ArtworkLookup] = [:]

    private(set) var index: LibraryIndex
    let applicationSupportDirectory: URL
    let importedMusicDirectory: URL
    let artworkDirectory: URL
    let persistenceURL: URL
    let artworkStore: ArtworkStore

    init(fileManager: FileManager = .default, applicationSupportDirectory: URL? = nil) {
        self.fileManager = fileManager
        let resolvedSupportDirectory = applicationSupportDirectory ?? LibraryStore.defaultApplicationSupportDirectory(fileManager: fileManager)
        let documentsDirectory: URL
        if applicationSupportDirectory != nil {
            // Keep tests and previews isolated inside their supplied root.
            documentsDirectory = resolvedSupportDirectory.appendingPathComponent("Documents", isDirectory: true)
        } else {
            documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? resolvedSupportDirectory.appendingPathComponent("Documents", isDirectory: true)
        }
        self.applicationSupportDirectory = resolvedSupportDirectory
        // Finder file sharing drops albums directly into Documents. Treat that
        // entire directory as the local library so a user does not need to
        // discover or preserve an extra nesting level.
        self.importedMusicDirectory = documentsDirectory
        self.artworkDirectory = resolvedSupportDirectory.appendingPathComponent("Artwork", isDirectory: true)
        self.persistenceURL = resolvedSupportDirectory.appendingPathComponent("LibraryIndex.json")
        self.artworkStore = ArtworkStore(artworkDirectory: artworkDirectory)
        self.operationQueue = OperationQueue()
        self.operationQueue.name = "Music.LibraryStore.indexing"
        self.operationQueue.maxConcurrentOperationCount = 1
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.index = LibraryIndex()
        prepareDirectories()
        migrateLegacyImportedMusicIfNeeded(
            from: resolvedSupportDirectory.appendingPathComponent("ImportedMusic", isDirectory: true)
        )
        migrateLegacyImportedMusicIfNeeded(
            from: documentsDirectory.appendingPathComponent("Music", isDirectory: true)
        )
        self.index = loadPersistedIndex() ?? LibraryIndex()
    }

    func bootstrapIfNeeded(bundle: Bundle = .main) {
        stateQueue.sync {
            if !index.tracks.isEmpty {
                repairFixtureArtwork(bundle: bundle)
                return
            }
            let fixture: LibraryIndex
            if let url = bundle.url(forResource: LibraryStore.fixtureFileName, withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let decoded = try? decoder.decode(LibraryIndex.self, from: data) {
                fixture = decoded
            } else {
                fixture = bundledFixtureIndex(bundle: bundle)
            }
            index = rebuildDerivedCollections(in: fixture)
            repairFixtureArtwork(bundle: bundle)
            saveIndexLocked()
        }
    }

    func snapshot() -> LibraryIndex {
        return stateQueue.sync { index }
    }

    func track(id: String) -> Track? {
        return stateQueue.sync { index.tracks.first { $0.id == id } }
    }

    func audioFileURL(for trackID: String) -> URL? {
        guard let relativePath = stateQueue.sync(execute: {
            index.tracks.first { $0.id == trackID }?.relativePath
        }), !relativePath.isEmpty else { return nil }
        let root = importedMusicDirectory.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/"),
              fileManager.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }

    func tracks(matching query: String = "", sort: TrackSort = .titleAscending, likedIDs: Set<String> = [], likedOnly: Bool = false) -> [Track] {
        return stateQueue.sync {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var result = index.tracks.filter { track in
                let matchesSearch = needle.isEmpty || [track.title, track.artist, track.albumTitle, track.genre].contains { $0.lowercased().contains(needle) }
                return matchesSearch && (!likedOnly || likedIDs.contains(track.id))
            }
            switch sort {
            case .titleAscending: result.sort { ordered($0.title, before: $1.title, lhsTieBreaker: $0.id, rhsTieBreaker: $1.id, ascending: true) }
            case .titleDescending: result.sort { ordered($0.title, before: $1.title, lhsTieBreaker: $0.id, rhsTieBreaker: $1.id, ascending: false) }
            case .artist: result.sort {
                let artistComparison = $0.artist.localizedCaseInsensitiveCompare($1.artist)
                if artistComparison != .orderedSame { return artistComparison == .orderedAscending }
                return ordered($0.title, before: $1.title, lhsTieBreaker: $0.id, rhsTieBreaker: $1.id, ascending: true)
            }
            case .newest: result.sort {
                $0.importedAt == $1.importedAt ? $0.id < $1.id : $0.importedAt > $1.importedAt
            }
            }
            return result
        }
    }

    func albums(matching query: String = "", sort: AlbumSort = .titleAscending) -> [Album] {
        return stateQueue.sync {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var result = index.albums.filter { needle.isEmpty || $0.title.lowercased().contains(needle) || $0.artist.lowercased().contains(needle) }
            switch sort {
            case .titleAscending: result.sort { ordered($0.title, before: $1.title, lhsTieBreaker: $0.id, rhsTieBreaker: $1.id, ascending: true) }
            case .titleDescending: result.sort { ordered($0.title, before: $1.title, lhsTieBreaker: $0.id, rhsTieBreaker: $1.id, ascending: false) }
            case .newest: result.sort {
                let lhsYear = $0.year ?? 0
                let rhsYear = $1.year ?? 0
                return lhsYear == rhsYear
                    ? ordered($0.title, before: $1.title, lhsTieBreaker: $0.id, rhsTieBreaker: $1.id, ascending: true)
                    : lhsYear > rhsYear
            }
            case .oldest: result.sort {
                let lhsYear = $0.year ?? Int.max
                let rhsYear = $1.year ?? Int.max
                return lhsYear == rhsYear
                    ? ordered($0.title, before: $1.title, lhsTieBreaker: $0.id, rhsTieBreaker: $1.id, ascending: true)
                    : lhsYear < rhsYear
            }
            }
            return result
        }
    }

    func artists(matching query: String = "") -> [Artist] {
        return stateQueue.sync {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return index.artists.filter { needle.isEmpty || $0.name.lowercased().contains(needle) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func genres(matching query: String = "") -> [Genre] {
        return stateQueue.sync {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return index.genres.filter { needle.isEmpty || $0.name.lowercased().contains(needle) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func importTracks(from urls: [URL], completion: @escaping (LibraryImportResult) -> Void) {
        operationQueue.addOperation { [weak self] in
            guard let self = self else { return }
            var imported: [Track] = []
            var skipped: [URL] = []
            var errors: [Error] = []
            for url in urls {
                do {
                    if let track = try self.importTrackSynchronously(from: url) {
                        imported.append(track)
                    } else {
                        skipped.append(url)
                    }
                } catch {
                    errors.append(error)
                }
            }
            let result = LibraryImportResult(importedTracks: imported, skippedURLs: skipped, errors: errors)
            OperationQueue.main.addOperation { completion(result) }
        }
    }

    /// Indexes audio already copied into the Finder-visible Documents/Music
    /// folder, including files transferred directly from a Mac.
    func indexExistingImportedMusic(completion: @escaping (Int) -> Void) {
        operationQueue.addOperation { [weak self] in
            guard let self = self else { return }
            let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            let enumerator = self.fileManager.enumerator(
                at: self.importedMusicDirectory,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles]
            )
            var removedCount = 0
            let existingPaths = self.stateQueue.sync { () -> Set<String> in
                // Drop stale paths left by interrupted transfers or older
                // path-normalization code so the files can be rediscovered.
                let previousCount = self.index.tracks.count
                self.index.tracks.removeAll { track in
                    guard !track.relativePath.isEmpty else { return false }
                    return !self.fileManager.fileExists(
                        atPath: self.importedMusicDirectory
                            .appendingPathComponent(track.relativePath).path
                    )
                }
                removedCount = previousCount - self.index.tracks.count
                return Set(self.index.tracks.map { $0.relativePath }.filter { !$0.isEmpty })
            }
            var discovered: [Track] = []

            while let url = enumerator?.nextObject() as? URL {
                guard self.supportsImport(url: url) else { continue }
                let components = url.standardizedFileURL.pathComponents
                guard let importFolderIndex = components.lastIndex(of: self.importedMusicDirectory.lastPathComponent),
                      importFolderIndex + 1 < components.count else { continue }
                let relativePath = components.dropFirst(importFolderIndex + 1).joined(separator: "/")
                guard !relativePath.isEmpty, !existingPaths.contains(relativePath) else { continue }
                do {
                    let values = try url.resourceValues(forKeys: Set(resourceKeys))
                    let duration = self.durationForURL(url)
                    var track = try self.buildTrack(
                        url: url,
                        sourceFileName: url.lastPathComponent,
                        byteSize: Int64(values.fileSize ?? 0),
                        duration: duration
                    )
                    track.relativePath = relativePath
                    discovered.append(track)
                } catch {
                    NSLog("Music could not index %@: %@", url.lastPathComponent, error.localizedDescription)
                }
            }

            self.stateQueue.sync {
                if !discovered.isEmpty || removedCount > 0 {
                    // The bundled entries are visual fixtures, not playable
                    // songs. Remove them as soon as a real local library exists.
                    if !discovered.isEmpty {
                        self.index.tracks.removeAll { $0.relativePath.isEmpty }
                    }
                    self.index.tracks.append(contentsOf: discovered)
                    self.index = self.rebuildDerivedCollections(in: self.index)
                    self.pruneUnusedArtworkLocked()
                    self.saveIndexLocked()
                }
            }
            OperationQueue.main.addOperation { completion(discovered.count + removedCount) }
        }
    }

    func supportsImport(url: URL) -> Bool {
        return LibraryStore.supportedFileExtensions.contains(url.pathExtension.lowercased())
    }

    @discardableResult
    func importTrackSynchronously(from sourceURL: URL) throws -> Track? {
        let wasSecurityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if wasSecurityScoped { sourceURL.stopAccessingSecurityScopedResource() } }
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        let byteSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let duration = durationForURL(sourceURL)
        let sourceFileName = sourceURL.lastPathComponent
        let duplicate = stateQueue.sync {
            index.tracks.contains { $0.sourceFileName == sourceFileName && $0.byteSize == byteSize && abs($0.duration - duration) < 0.1 }
        }
        guard !duplicate else { return nil }

        let targetName = uniqueImportedFileName(for: sourceURL)
        let targetURL = importedMusicDirectory.appendingPathComponent(targetName)
        try fileManager.copyItem(at: sourceURL, to: targetURL)
        do {
            let track = try buildTrack(url: targetURL, sourceFileName: sourceFileName, byteSize: byteSize, duration: duration)
            stateQueue.sync {
                index.tracks.removeAll { $0.relativePath.isEmpty }
                index.tracks.append(track)
                index = rebuildDerivedCollections(in: index)
                pruneUnusedArtworkLocked()
                saveIndexLocked()
            }
            return track
        } catch {
            try? fileManager.removeItem(at: targetURL)
            throw error
        }
    }

    func replacePlaylists(_ playlists: [Playlist]) {
        stateQueue.sync {
            index.playlists = playlists
            index.updatedAt = Date()
            saveIndexLocked()
        }
    }

    func deleteAllImportedMusic() {
        stateQueue.sync {
            try? fileManager.removeItem(at: importedMusicDirectory)
            try? fileManager.removeItem(at: artworkDirectory)
            prepareDirectories()
            index = LibraryIndex(playlists: index.playlists)
            saveIndexLocked()
        }
    }

    private static func defaultApplicationSupportDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("Music", isDirectory: true)
    }

    private func prepareDirectories() {
        try? fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: importedMusicDirectory, withIntermediateDirectories: true, attributes: nil)
        try? fileManager.createDirectory(at: artworkDirectory, withIntermediateDirectories: true, attributes: nil)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedDirectory = applicationSupportDirectory
        try? protectedDirectory.setResourceValues(values)
        var localMusicDirectory = importedMusicDirectory
        try? localMusicDirectory.setResourceValues(values)
    }

    private func migrateLegacyImportedMusicIfNeeded(from legacyDirectory: URL) {
        guard legacyDirectory.standardizedFileURL != importedMusicDirectory.standardizedFileURL,
              fileManager.fileExists(atPath: legacyDirectory.path),
              let items = try? fileManager.contentsOfDirectory(
                at: legacyDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return }

        for sourceURL in items {
            var destinationURL = importedMusicDirectory.appendingPathComponent(sourceURL.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                destinationURL = importedMusicDirectory.appendingPathComponent(
                    "\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
                )
            }
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                NSLog("Music could not migrate %@ into Documents: %@", sourceURL.lastPathComponent, error.localizedDescription)
            }
        }
        if (try? fileManager.contentsOfDirectory(atPath: legacyDirectory.path).isEmpty) == true {
            try? fileManager.removeItem(at: legacyDirectory)
        }
    }

    private func loadPersistedIndex() -> LibraryIndex? {
        guard let data = try? Data(contentsOf: persistenceURL), let persisted = try? decoder.decode(LibraryIndex.self, from: data), persisted.schemaVersion == LibraryIndex.currentSchemaVersion else { return nil }
        return rebuildDerivedCollections(in: persisted)
    }

    private func saveIndexLocked() {
        index.updatedAt = Date()
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: persistenceURL, options: .atomic)
    }

    private func pruneUnusedArtworkLocked() {
        let referenced = Set(index.tracks.compactMap { $0.artworkFileName })
        guard let files = try? fileManager.contentsOfDirectory(
            at: artworkDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    private func uniqueImportedFileName(for sourceURL: URL) -> String {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var candidate = "\(UUID().uuidString)-\(baseName)"
        if !ext.isEmpty { candidate += ".\(ext)" }
        return candidate
    }

    private func durationForURL(_ url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        var duration: CMTime = .zero
        asset.loadValuesAsynchronously(forKeys: ["duration"]) {
            duration = asset.duration
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 15)
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    private func buildTrack(url: URL, sourceFileName: String, byteSize: Int64, duration: TimeInterval) throws -> Track {
        let asset = AVURLAsset(url: url)
        let metadata = asset.commonMetadata
        let flacTags = parseFLACTags(at: url)
        let folderTags = parseFolderTags(url.deletingLastPathComponent().lastPathComponent)
        let title = textValue(for: .commonKeyTitle, in: metadata)
            ?? flacTags.value("TITLE")
            ?? titleFromFileName(url.deletingPathExtension().lastPathComponent)
        let artist = textValue(for: .commonKeyArtist, in: metadata)
            ?? flacTags.value("ARTIST")
            ?? folderTags.artist
            ?? "Unknown Artist"
        let albumTitle = textValue(for: .commonKeyAlbumName, in: metadata)
            ?? flacTags.value("ALBUM")
            ?? folderTags.album
            ?? "Unknown Album"
        let albumArtist = textValue(identifierSuffix: "albumArtist", in: asset.metadata)
            ?? flacTags.value("ALBUMARTIST", "ALBUM ARTIST")
            ?? folderTags.artist
            ?? artist
        let genre = textValue(identifierSuffix: "genre", in: asset.metadata)
            ?? textValue(for: .commonKeyType, in: metadata)
            ?? flacTags.value("GENRE")
            ?? "Unknown"
        let year = yearValue(in: metadata)
            ?? flacTags.value("DATE", "YEAR").flatMap { Int(String($0.prefix(4))) }
            ?? folderTags.year
        let artworkFileName = artworkFileName(
            for: url,
            albumKey: "\(albumArtist.lowercased())\u{1f}\(albumTitle.lowercased())",
            metadata: metadata,
            embeddedFLACArtwork: flacTags.artworkData
        )
        let trackNumber = numberValue(identifierSuffix: "trackNumber", in: asset.metadata)
            ?? tagNumber(flacTags.value("TRACKNUMBER"))
            ?? leadingTrackNumber(in: url.deletingPathExtension().lastPathComponent)
        let discNumber = numberValue(identifierSuffix: "discNumber", in: asset.metadata)
            ?? tagNumber(flacTags.value("DISCNUMBER"))
        return Track(sourceFileName: sourceFileName,
                     relativePath: url.lastPathComponent,
                     title: title,
                     artist: artist,
                     albumTitle: albumTitle,
                     albumArtist: albumArtist,
                     year: year,
                     genre: genre,
                     trackNumber: trackNumber,
                     discNumber: discNumber,
                     duration: duration,
                     formatDescription: formatDescription(for: url),
                     artworkFileName: artworkFileName,
                     byteSize: byteSize)
    }

    private func textValue(for key: AVMetadataKey, in metadata: [AVMetadataItem]) -> String? {
        return metadata.first { $0.commonKey == key }?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func textValue(identifierSuffix: String, in metadata: [AVMetadataItem]) -> String? {
        return metadata.first { $0.identifier?.rawValue.lowercased().hasSuffix(identifierSuffix.lowercased()) == true }?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    private func yearValue(in metadata: [AVMetadataItem]) -> Int? {
        guard let date = metadata.first(where: { $0.commonKey == .commonKeyCreationDate })?.stringValue else { return nil }
        let digits = String(date.prefix(4))
        return Int(digits)
    }

    private func numberValue(identifierSuffix: String, in metadata: [AVMetadataItem]) -> Int? {
        guard let item = metadata.first(where: {
            $0.identifier?.rawValue.lowercased().hasSuffix(identifierSuffix.lowercased()) == true
        }) else { return nil }
        if let number = item.numberValue { return number.intValue }
        guard let value = item.stringValue else { return nil }
        return Int(value.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? value)
    }

    private func persistArtwork(from metadata: [AVMetadataItem]) -> String? {
        guard let item = metadata.first(where: { $0.commonKey == .commonKeyArtwork }), let data = item.dataValue else { return nil }
        return persistArtworkData(data)
    }

    private func artworkFileName(for audioURL: URL,
                                 albumKey: String,
                                 metadata: [AVMetadataItem],
                                 embeddedFLACArtwork: Data?) -> String? {
        if let cached = artworkByFolder[albumKey] {
            switch cached {
            case .found(let fileName): return fileName
            case .missing: return nil
            }
        }

        let fileName = persistArtwork(from: metadata)
            ?? embeddedFLACArtwork.flatMap { persistArtworkData($0) }
            ?? persistAdjacentArtwork(for: audioURL)
        artworkByFolder[albumKey] = fileName.map(ArtworkLookup.found) ?? .missing
        return fileName
    }

    private func persistAdjacentArtwork(for audioURL: URL) -> String? {
        let directory = audioURL.deletingLastPathComponent()
        let preferredNames = ["cover.jpg", "cover.jpeg", "cover.png", "folder.jpg", "folder.png", "front.jpg", "front.png"]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let fileByName = Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent.lowercased(), $0) })
        for name in preferredNames {
            if let url = fileByName[name], let data = try? Data(contentsOf: url) {
                return persistArtworkData(data)
            }
        }
        return nil
    }

    private func persistArtworkData(_ data: Data) -> String? {
        let name = String(format: "artwork-%016llx.jpg", stableArtworkHash(data))
        let url = artworkDirectory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: url.path) {
            return name
        }
        let encodedData: Data
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600
                ] as CFDictionary
           ),
           let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.82) {
            encodedData = jpeg
        } else {
            encodedData = data
        }
        do {
            try encodedData.write(to: url, options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    private func stableArtworkHash(_ data: Data) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private func parseFLACTags(at url: URL) -> ParsedAudioTags {
        guard url.pathExtension.lowercased() == "flac",
              let handle = try? FileHandle(forReadingFrom: url) else { return ParsedAudioTags() }
        defer { handle.closeFile() }
        guard handle.readData(ofLength: 4) == Data([0x66, 0x4C, 0x61, 0x43]) else {
            return ParsedAudioTags()
        }

        var result = ParsedAudioTags()
        var isLastBlock = false
        while !isLastBlock {
            let header = [UInt8](handle.readData(ofLength: 4))
            guard header.count == 4 else { break }
            isLastBlock = (header[0] & 0x80) != 0
            let blockType = header[0] & 0x7F
            let length = (Int(header[1]) << 16) | (Int(header[2]) << 8) | Int(header[3])
            guard length >= 0, length <= 32 * 1_024 * 1_024 else { break }

            if blockType == 4 || blockType == 6 {
                let payload = handle.readData(ofLength: length)
                guard payload.count == length else { break }
                if blockType == 4 {
                    result.values.merge(parseVorbisComments(payload)) { current, _ in current }
                } else if result.artworkData == nil {
                    result.artworkData = parseFLACPicture(payload)
                }
            } else {
                handle.seek(toFileOffset: handle.offsetInFile + UInt64(length))
            }
        }
        return result
    }

    private func parseVorbisComments(_ data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var offset = 0
        guard let vendorLength = readUInt32LE(bytes, offset: &offset),
              vendorLength <= UInt32(bytes.count),
              offset + Int(vendorLength) <= bytes.count else { return [:] }
        offset += Int(vendorLength)
        guard let commentCount = readUInt32LE(bytes, offset: &offset), commentCount < 100_000 else { return [:] }

        var result: [String: String] = [:]
        for _ in 0..<Int(commentCount) {
            guard let length = readUInt32LE(bytes, offset: &offset),
                  length <= UInt32(bytes.count),
                  offset + Int(length) <= bytes.count else { break }
            let comment = String(bytes: bytes[offset..<(offset + Int(length))], encoding: .utf8)
            offset += Int(length)
            guard let value = comment, let separator = value.firstIndex(of: "=") else { continue }
            let key = String(value[..<separator]).uppercased()
            let content = String(value[value.index(after: separator)...])
            if result[key] == nil { result[key] = content }
        }
        return result
    }

    private func parseFLACPicture(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var offset = 0
        guard readUInt32BE(bytes, offset: &offset) != nil,
              let mimeLength = readUInt32BE(bytes, offset: &offset),
              offset + Int(mimeLength) <= bytes.count else { return nil }
        offset += Int(mimeLength)
        guard let descriptionLength = readUInt32BE(bytes, offset: &offset),
              offset + Int(descriptionLength) <= bytes.count else { return nil }
        offset += Int(descriptionLength)
        for _ in 0..<4 {
            guard readUInt32BE(bytes, offset: &offset) != nil else { return nil }
        }
        guard let imageLength = readUInt32BE(bytes, offset: &offset),
              offset + Int(imageLength) <= bytes.count else { return nil }
        return Data(bytes[offset..<(offset + Int(imageLength))])
    }

    private func readUInt32LE(_ bytes: [UInt8], offset: inout Int) -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        let value = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        offset += 4
        return value
    }

    private func readUInt32BE(_ bytes: [UInt8], offset: inout Int) -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        let value = (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        offset += 4
        return value
    }

    private func parseFolderTags(_ folderName: String) -> FolderTags {
        var value = folderName.replacingOccurrences(
            of: "\\s*\\[[^\\]]+\\]\\s*$",
            with: "",
            options: .regularExpression
        )
        var year: Int?
        if let match = value.range(of: "\\((\\d{4})\\)\\s*$", options: .regularExpression) {
            let yearText = String(value[match]).filter { $0.isNumber }
            year = Int(yearText)
            value.removeSubrange(match)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let separator = value.range(of: " - ") else {
            return FolderTags(artist: nil, album: value.nonEmpty, year: year)
        }
        return FolderTags(
            artist: String(value[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            album: String(value[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            year: year
        )
    }

    private func titleFromFileName(_ fileName: String) -> String {
        return fileName.replacingOccurrences(
            of: "^\\s*\\d+(?:[-.]\\d+)?\\s*[.\\-_ ]+\\s*",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func leadingTrackNumber(in fileName: String) -> Int? {
        guard let match = fileName.range(of: "^\\s*\\d+", options: .regularExpression) else { return nil }
        return Int(fileName[match].trimmingCharacters(in: .whitespaces))
    }

    private func tagNumber(_ value: String?) -> Int? {
        guard let value = value else { return nil }
        return Int(value.components(separatedBy: "/").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? value)
    }

    private func formatDescription(for url: URL) -> String {
        let ext = url.pathExtension.isEmpty ? "Unknown" : url.pathExtension.uppercased()
        return ext
    }

    private func rebuildDerivedCollections(in source: LibraryIndex) -> LibraryIndex {
        var rebuilt = source
        let tracks = source.tracks
        let albumGroups = Dictionary(grouping: tracks) { "\($0.albumTitle.lowercased())|\($0.albumArtist.lowercased())" }
        rebuilt.albums = albumGroups.values.map { group in
            let first = group[0]
            let orderedTracks = group.sorted {
                let lhs = ($0.discNumber ?? Int.max, $0.trackNumber ?? Int.max)
                let rhs = ($1.discNumber ?? Int.max, $1.trackNumber ?? Int.max)
                if lhs != rhs { return lhs < rhs }
                return ordered($0.title, before: $1.title, lhsTieBreaker: $0.id, rhsTieBreaker: $1.id, ascending: true)
            }
            return Album(id: stableIdentifier(prefix: "album", value: "\(first.albumTitle)|\(first.albumArtist)"),
                         title: first.albumTitle,
                         artist: first.albumArtist,
                         year: group.compactMap { $0.year }.min(),
                         genre: first.genre,
                         trackIDs: orderedTracks.map { $0.id },
                         artworkFileName: group.compactMap { $0.artworkFileName }.first,
                         duration: group.reduce(0) { $0 + $1.duration })
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let albumByKey = Dictionary(uniqueKeysWithValues: rebuilt.albums.map { ("\($0.title.lowercased())|\($0.artist.lowercased())", $0.id) })
        let artistGroups = Dictionary(grouping: tracks) { $0.albumArtist.lowercased() }
        rebuilt.artists = artistGroups.values.map { group in
            let first = group[0]
            let albumIDs = Array(Set(group.compactMap { albumByKey["\($0.albumTitle.lowercased())|\($0.albumArtist.lowercased())"] })).sorted()
            return Artist(id: stableIdentifier(prefix: "artist", value: first.albumArtist), name: first.albumArtist, albumIDs: albumIDs, trackIDs: group.map { $0.id }, artworkFileName: group.compactMap { $0.artworkFileName }.first)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let genreGroups = Dictionary(grouping: tracks) { $0.genre.lowercased() }
        rebuilt.genres = genreGroups.values.map { group in
            let first = group[0]
            let albumIDs = Array(Set(group.compactMap { albumByKey["\($0.albumTitle.lowercased())|\($0.albumArtist.lowercased())"] })).sorted()
            return Genre(id: stableIdentifier(prefix: "genre", value: first.genre), name: first.genre, albumIDs: albumIDs, trackIDs: group.map { $0.id }, artworkFileName: group.compactMap { $0.artworkFileName }.first)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return rebuilt
    }

    private func bundledFixtureIndex(bundle: Bundle) -> LibraryIndex {
        let fixtureTracks: [(String, String, String, Int, String, Double, String)] = [
            ("all 2s", "2hollis", "2", 2023, "Electronic", 165, "album1.jpg"),
            ("poster boy", "2hollis", "2", 2023, "Electronic", 172, "album1.jpg"),
            ("GOD", "2hollis", "2", 2023, "Electronic", 187, "album1.jpg"),
            ("boy", "2hollis", "boy", 2024, "Electronic", 190, "album2.jpg"),
            ("gold", "2hollis", "gold", 2024, "Electronic", 178, "album3.jpg"),
            ("Hurt", "2hollis", "Hurt", 2026, "Electronic", 202, "album4.jpg")
        ]
        let tracks = fixtureTracks.enumerated().map { offset, item -> Track in
            let artworkFileName = copyFixtureArtwork(named: item.6, bundle: bundle)
            return Track(id: "fixture-track-\(offset + 1)",
                         sourceFileName: "fixture-\(offset + 1).flac",
                         relativePath: "",
                         title: item.0,
                         artist: item.1,
                         albumTitle: item.2,
                         albumArtist: item.1,
                         year: item.3,
                         genre: item.4,
                         trackNumber: offset + 1,
                         duration: item.5,
                         formatDescription: "FLAC 16-bit / 44.1 kHz",
                         artworkFileName: artworkFileName)
        }
        return LibraryIndex(tracks: tracks)
    }

    private func copyFixtureArtwork(named name: String, bundle: Bundle) -> String? {
        let sourceURL = bundle.url(forResource: name, withExtension: nil, subdirectory: "FixtureArtwork")
            ?? bundle.url(forResource: name, withExtension: nil)
        guard let source = sourceURL else { return name }
        let destination = artworkDirectory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        try? fileManager.copyItem(at: source, to: destination)
        return name
    }

    private func repairFixtureArtwork(bundle: Bundle) {
        let fixtureNames = Set(index.tracks.compactMap { track -> String? in
            guard track.id.hasPrefix("fixture-track-") else { return nil }
            return track.artworkFileName
        })
        fixtureNames.forEach { _ = copyFixtureArtwork(named: $0, bundle: bundle) }
    }

    private func stableIdentifier(prefix: String, value: String) -> String {
        let allowed = value.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-" }
        let normalized = String(allowed).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let readable = normalized.isEmpty ? "unknown" : normalized
        return "\(prefix)-\(readable)-\(stableHash(value.lowercased()))"
    }

    private func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func ordered(_ lhs: String,
                         before rhs: String,
                         lhsTieBreaker: String,
                         rhsTieBreaker: String,
                         ascending: Bool) -> Bool {
        let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
        if comparison == .orderedSame { return lhsTieBreaker < rhsTieBreaker }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
