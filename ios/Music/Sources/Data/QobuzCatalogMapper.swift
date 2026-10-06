import Foundation

enum QobuzCatalogMapper {
    static func track(_ track: QobuzSearchTrack) -> ScreenTrack {
        ScreenTrack(id: String(track.id), title: track.title, artist: track.performer?.name ?? "Unknown Artist", album: track.album?.title ?? "Unknown Album", quality: "Qobuz", artworkURL: track.album?.imageURL, catalogAlbumID: track.album?.id, catalogArtistID: track.performer?.id, duration: TimeInterval(track.duration ?? 0))
    }

    static func album(_ album: QobuzCatalogAlbum) -> ScreenAlbum {
        let tracks = album.tracks?.items.map { track in
            ScreenTrack(id: String(track.id), title: track.title, artist: track.performer?.name ?? album.artist?.name ?? "Unknown Artist", album: album.title, quality: album.quality, artworkURL: album.artworkURL, catalogAlbumID: album.id, catalogArtistID: album.artist?.id, duration: TimeInterval(track.duration ?? 0))
        } ?? []
        return ScreenAlbum(id: album.id, title: album.title, artist: album.artist?.name ?? "Unknown Artist", year: album.year, genre: album.genre?.name ?? "", quality: album.quality, artworkURL: album.artworkURL, tracks: tracks)
    }

    static func profile(_ artist: QobuzCatalogArtist) -> ScreenProfile {
        let albums = (artist.albums?.items ?? []).map(album)
        let biography = artist.biography?.content ?? artist.biography?.summary ?? artist.information ?? "Artist on Qobuz."
        return ScreenProfile(id: artist.id, name: artist.name, subtitle: "\(artist.albumsCount ?? albums.count) albums", information: biography, artworkURL: artist.artworkURL, albums: albums)
    }
}
