import UIKit

// These lightweight display models deliberately keep screen code independent from the
// importer and persistence layers.  LibraryStore/AppState can map their Codable models
// into these values on the main queue.

enum AlbumQueueAction {
    case playNext
    case enqueue
}

enum LibraryScreenKind: String, CaseIterable {
    case tracks, albums, artists, playlists, genres

    var searchPlaceholder: String { return "Search " + rawValue }
}

struct ScreenTrack {
    let id: String
    let title: String
    let artist: String
    let album: String
    let quality: String
    let artwork: UIImage?
    let duration: TimeInterval

    init(id: String, title: String, artist: String, album: String, quality: String = "", artwork: UIImage? = nil, duration: TimeInterval = 0) {
        self.id = id; self.title = title; self.artist = artist; self.album = album
        self.quality = quality; self.artwork = artwork; self.duration = duration
    }
}

struct ScreenAlbum {
    let id: String
    let title: String
    let artist: String
    let year: String
    let genre: String
    let quality: String
    let artwork: UIImage?
    let tracks: [ScreenTrack]

    init(id: String, title: String, artist: String, year: String, genre: String = "", quality: String = "", artwork: UIImage? = nil, tracks: [ScreenTrack] = []) {
        self.id = id; self.title = title; self.artist = artist; self.year = year; self.genre = genre
        self.quality = quality; self.artwork = artwork; self.tracks = tracks
    }
}

struct ScreenProfile {
    let id: String
    let name: String
    let subtitle: String
    let information: String
    let artwork: UIImage?
    let albums: [ScreenAlbum]

    init(id: String, name: String, subtitle: String, information: String, artwork: UIImage? = nil, albums: [ScreenAlbum] = []) {
        self.id = id; self.name = name; self.subtitle = subtitle; self.information = information
        self.artwork = artwork; self.albums = albums
    }
}

struct ScreenPlaylist {
    let id: String
    let name: String
    let trackCount: Int
    let artwork: UIImage?
}

struct SettingsTabItem: Equatable {
    let id: String
    let title: String
    var isEnabled: Bool
    let note: String?

    init(id: String, title: String, isEnabled: Bool, note: String? = nil) {
        self.id = id; self.title = title; self.isEnabled = isEnabled; self.note = note
    }
}

struct PlayerScreenState {
    let track: ScreenTrack
    var isPlaying: Bool
    var isLiked: Bool
    var elapsed: TimeInterval
    var duration: TimeInterval
    var queueCount: Int

    init(track: ScreenTrack, isPlaying: Bool = false, isLiked: Bool = false, elapsed: TimeInterval = 0, duration: TimeInterval? = nil, queueCount: Int = 0) {
        self.track = track; self.isPlaying = isPlaying; self.isLiked = isLiked; self.elapsed = elapsed
        self.duration = duration ?? track.duration; self.queueCount = queueCount
    }
}

enum ScreenPalette {
    static var accent: UIColor { return DesignSystem.accent }
    static var primary: UIColor { return DesignSystem.primaryText }
    static var secondary: UIColor { return DesignSystem.secondaryText }
    static var separator: UIColor { return DesignSystem.separator }
    static var softFill: UIColor { return DesignSystem.controlFill }

    static func label(_ text: String = "", font: UIFont, color: UIColor = primary, lines: Int = 1) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = lines
        return label
    }
}

extension TimeInterval {
    var screenTime: String {
        guard isFinite, self >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(self) / 60, Int(self) % 60)
    }
}
