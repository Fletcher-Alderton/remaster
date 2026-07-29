import UIKit

final class ScreenMapper {
    private let store: LibraryStore
    private let cacheLock = NSLock()
    private var cachedTracks: [String: ScreenTrack] = [:]
    private var cachedAlbums: [String: ScreenAlbum] = [:]
    private var cachedArtists: [String: ScreenProfile] = [:]
    private var cachedGenres: [String: ScreenProfile] = [:]
    private var cachedTracksByID: [String: Track] = [:]
    private var cachedAlbumsByID: [String: Album] = [:]
    private var cachedLibraryDate: Date?

    init(store: LibraryStore) {
        self.store = store
    }

    func track(_ track: Track) -> ScreenTrack {
        let key = [
            track.id,
            track.title,
            track.artist,
            track.albumTitle,
            track.formatDescription,
            track.artworkFileName ?? "",
            String(track.duration)
        ].joined(separator: "\u{1f}")
        if let cached = withCacheLock({ cachedTracks[key] }) {
            return cached
        }
        let mapped = ScreenTrack(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.albumTitle,
            quality: track.formatDescription,
            // This model is also used by the full-screen player, so keep one
            // shared 320-pixel decode instead of separate row/player variants.
            artwork: store.artworkStore.image(named: track.artworkFileName, maximumPixelSize: 320),
            duration: track.duration
        )
        withCacheLock { cachedTracks[key] = mapped }
        return mapped
    }

    func album(_ album: Album, index: LibraryIndex? = nil) -> ScreenAlbum {
        let library = index ?? store.snapshot()
        prepareCache(for: library)
        if let cached = withCacheLock({ cachedAlbums[album.id] }) {
            return cached
        }
        let tracksByID = withCacheLock { cachedTracksByID }
        return self.album(album, tracksByID: tracksByID)
    }

    private func album(_ album: Album, tracksByID: [String: Track]) -> ScreenAlbum {
        if let cached = withCacheLock({ cachedAlbums[album.id] }) {
            return cached
        }
        let screenTracks = album.trackIDs.compactMap { tracksByID[$0] }.map(track)
        let quality = album.trackIDs
            .compactMap { tracksByID[$0]?.formatDescription }
            .first ?? ""
        let mapped = ScreenAlbum(
            id: album.id,
            title: album.title,
            artist: album.artist,
            year: album.year.map(String.init) ?? "",
            genre: album.genre,
            quality: quality,
            // A two-column card is about 136 points wide. 320 pixels leaves
            // headroom for transitions without retaining oversized bitmaps.
            artwork: store.artworkStore.image(named: album.artworkFileName, maximumPixelSize: 320),
            tracks: screenTracks
        )
        withCacheLock { cachedAlbums[album.id] = mapped }
        return mapped
    }

    func artist(_ artist: Artist, index: LibraryIndex? = nil) -> ScreenProfile {
        let library = index ?? store.snapshot()
        prepareCache(for: library)
        if let cached = withCacheLock({ cachedArtists[artist.id] }) {
            return cached
        }
        let lookups = withCacheLock { (cachedAlbumsByID, cachedTracksByID) }
        let albumsByID = lookups.0
        let tracksByID = lookups.1
        let albums = artist.albumIDs.compactMap { albumsByID[$0] }.map { album($0, tracksByID: tracksByID) }
        let mapped = ScreenProfile(
            id: artist.id,
            name: artist.name,
            subtitle: countLabel(albums: artist.albumIDs.count, tracks: artist.trackIDs.count),
            information: "Music in your local collection by \(artist.name).",
            artwork: store.artworkStore.image(named: artist.artworkFileName, maximumPixelSize: 320),
            albums: albums
        )
        withCacheLock { cachedArtists[artist.id] = mapped }
        return mapped
    }

    func genre(_ genre: Genre, index: LibraryIndex? = nil) -> ScreenProfile {
        let library = index ?? store.snapshot()
        prepareCache(for: library)
        if let cached = withCacheLock({ cachedGenres[genre.id] }) {
            return cached
        }
        let lookups = withCacheLock { (cachedAlbumsByID, cachedTracksByID) }
        let albumsByID = lookups.0
        let tracksByID = lookups.1
        let albums = genre.albumIDs.compactMap { albumsByID[$0] }.map { album($0, tracksByID: tracksByID) }
        let mapped = ScreenProfile(
            id: genre.id,
            name: genre.name,
            subtitle: countLabel(albums: genre.albumIDs.count, tracks: genre.trackIDs.count),
            information: "Albums tagged \(genre.name) in your local collection.",
            artwork: store.artworkStore.image(named: genre.artworkFileName, maximumPixelSize: 320),
            albums: albums
        )
        withCacheLock { cachedGenres[genre.id] = mapped }
        return mapped
    }

    func playlist(_ playlist: Playlist, index: LibraryIndex? = nil) -> ScreenPlaylist {
        let library = index ?? store.snapshot()
        prepareCache(for: library)
        let tracksByID = withCacheLock { cachedTracksByID }
        let artwork = playlist.trackIDs
            .compactMap { tracksByID[$0]?.artworkFileName }
            .compactMap { store.artworkStore.image(named: $0, maximumPixelSize: 240) }
            .first
        return ScreenPlaylist(id: playlist.id, name: playlist.name, trackCount: playlist.trackIDs.count, artwork: artwork)
    }

    private func countLabel(albums: Int, tracks: Int) -> String {
        let albumWord = albums == 1 ? "album" : "albums"
        let trackWord = tracks == 1 ? "track" : "tracks"
        return "\(albums) \(albumWord) · \(tracks) \(trackWord)"
    }

    private func dictionaryKeepingFirst<Key: Hashable, Value>(_ pairs: [(Key, Value)]) -> [Key: Value] {
        return pairs.reduce(into: [:]) { result, pair in
            if result[pair.0] == nil { result[pair.0] = pair.1 }
        }
    }

    private func prepareCache(for library: LibraryIndex) {
        withCacheLock {
            guard cachedLibraryDate != library.updatedAt else { return }
            cachedLibraryDate = library.updatedAt
            cachedTracks.removeAll(keepingCapacity: true)
            cachedAlbums.removeAll(keepingCapacity: true)
            cachedArtists.removeAll(keepingCapacity: true)
            cachedGenres.removeAll(keepingCapacity: true)
            cachedTracksByID = dictionaryKeepingFirst(library.tracks.map { ($0.id, $0) })
            cachedAlbumsByID = dictionaryKeepingFirst(library.albums.map { ($0.id, $0) })
        }
    }

    @discardableResult
    private func withCacheLock<Result>(_ body: () -> Result) -> Result {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return body()
    }
}
