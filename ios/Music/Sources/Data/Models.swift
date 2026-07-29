import Foundation

enum LibraryTab: String, Codable, CaseIterable {
    case tracks
    case albums
    case artists
    case playlists
    case genres
    case settings

    var title: String {
        switch self {
        case .tracks: return "Tracks"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .playlists: return "Playlists"
        case .genres: return "Genres"
        case .settings: return "Settings"
        }
    }
}

struct Track: Codable, Equatable, Hashable {
    var id: String
    var sourceFileName: String
    var relativePath: String
    var title: String
    var artist: String
    var albumTitle: String
    var albumArtist: String
    var year: Int?
    var genre: String
    var trackNumber: Int?
    var discNumber: Int?
    var duration: TimeInterval
    var formatDescription: String
    var artworkFileName: String?
    var byteSize: Int64
    var importedAt: Date

    init(id: String = UUID().uuidString,
         sourceFileName: String,
         relativePath: String,
         title: String,
         artist: String = "Unknown Artist",
         albumTitle: String = "Unknown Album",
         albumArtist: String = "Unknown Artist",
         year: Int? = nil,
         genre: String = "Unknown",
         trackNumber: Int? = nil,
         discNumber: Int? = nil,
         duration: TimeInterval = 0,
         formatDescription: String = "Unknown format",
         artworkFileName: String? = nil,
         byteSize: Int64 = 0,
         importedAt: Date = Date()) {
        self.id = id
        self.sourceFileName = sourceFileName
        self.relativePath = relativePath
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        self.year = year
        self.genre = genre
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.duration = duration
        self.formatDescription = formatDescription
        self.artworkFileName = artworkFileName
        self.byteSize = byteSize
        self.importedAt = importedAt
    }
}

struct Album: Codable, Equatable, Hashable {
    var id: String
    var title: String
    var artist: String
    var year: Int?
    var genre: String
    var trackIDs: [String]
    var artworkFileName: String?
    var duration: TimeInterval
}

struct Artist: Codable, Equatable, Hashable {
    var id: String
    var name: String
    var albumIDs: [String]
    var trackIDs: [String]
    var artworkFileName: String?
}

struct Genre: Codable, Equatable, Hashable {
    var id: String
    var name: String
    var albumIDs: [String]
    var trackIDs: [String]
    var artworkFileName: String?
}

struct Playlist: Codable, Equatable, Hashable {
    var id: String
    var name: String
    var trackIDs: [String]
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, trackIDs: [String] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.trackIDs = trackIDs
        self.createdAt = createdAt
    }
}

struct QueueState: Codable, Equatable {
    var trackIDs: [String]
    var currentIndex: Int
    var elapsed: TimeInterval
    var isPlaying: Bool
    var isShuffled: Bool

    init(trackIDs: [String] = [], currentIndex: Int = 0, elapsed: TimeInterval = 0, isPlaying: Bool = false, isShuffled: Bool = false) {
        self.trackIDs = trackIDs
        self.currentIndex = currentIndex
        self.elapsed = elapsed
        self.isPlaying = isPlaying
        self.isShuffled = isShuffled
    }

    var currentTrackID: String? {
        guard currentIndex >= 0 && currentIndex < trackIDs.count else { return nil }
        return trackIDs[currentIndex]
    }
}

struct LibraryIndex: Codable, Equatable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var tracks: [Track]
    var albums: [Album]
    var artists: [Artist]
    var genres: [Genre]
    var playlists: [Playlist]
    var updatedAt: Date

    init(schemaVersion: Int = LibraryIndex.currentSchemaVersion,
         tracks: [Track] = [],
         albums: [Album] = [],
         artists: [Artist] = [],
         genres: [Genre] = [],
         playlists: [Playlist] = [],
         updatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.tracks = tracks
        self.albums = albums
        self.artists = artists
        self.genres = genres
        self.playlists = playlists
        self.updatedAt = updatedAt
    }
}

struct TabConfiguration: Codable, Equatable {
    static let maximumTabs = 6
    static let minimumTabs = 1

    var enabledTabs: [LibraryTab]

    init(enabledTabs: [LibraryTab] = [.tracks, .albums, .artists, .playlists, .genres]) {
        self.enabledTabs = TabConfiguration.normalized(enabledTabs)
    }

    static func normalized(_ tabs: [LibraryTab]) -> [LibraryTab] {
        var unique: [LibraryTab] = []
        for tab in tabs where !unique.contains(tab) && unique.count < maximumTabs {
            unique.append(tab)
        }
        if unique.isEmpty { unique = [.tracks] }
        return unique
    }

    mutating func setEnabled(_ isEnabled: Bool, for tab: LibraryTab) {
        if isEnabled {
            guard !enabledTabs.contains(tab), enabledTabs.count < TabConfiguration.maximumTabs else { return }
            enabledTabs.append(tab)
        } else {
            guard enabledTabs.count > TabConfiguration.minimumTabs else { return }
            enabledTabs.removeAll { $0 == tab }
        }
    }

    mutating func moveTab(from source: Int, to destination: Int) {
        guard source >= 0, source < enabledTabs.count, destination >= 0, destination < enabledTabs.count, source != destination else { return }
        let tab = enabledTabs.remove(at: source)
        enabledTabs.insert(tab, at: destination)
    }
}

enum TrackSort: String, Codable, CaseIterable {
    case titleAscending
    case titleDescending
    case artist
    case newest
}

enum AlbumSort: String, Codable, CaseIterable {
    case titleAscending
    case titleDescending
    case newest
    case oldest
}
