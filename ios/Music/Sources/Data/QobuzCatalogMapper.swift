import Foundation

enum QobuzCatalogMapper {
    static func track(_ track: QobuzSearchTrack) -> ScreenTrack {
        ScreenTrack(id: String(track.id), title: track.title, artist: track.performer?.name ?? track.album?.artist?.name ?? "Unknown Artist", album: track.album?.title ?? "Unknown Album", quality: "Qobuz", artworkURL: track.album?.imageURL, catalogAlbumID: track.album?.id ?? track.albumID, catalogArtistID: track.performer?.id ?? track.album?.artist?.id, duration: TimeInterval(track.duration ?? 0))
    }

    static func album(_ album: QobuzCatalogAlbum) -> ScreenAlbum {
        let tracks = album.tracks?.items.map { track in
            ScreenTrack(id: String(track.id), title: track.title, artist: track.performer?.name ?? album.artist?.name ?? "Unknown Artist", album: album.title, quality: album.quality, artworkURL: album.artworkURL, catalogAlbumID: album.id, catalogArtistID: track.performer?.id ?? album.artist?.id, duration: TimeInterval(track.duration ?? 0))
        } ?? []
        return ScreenAlbum(id: album.id, title: album.title, artist: album.artist?.name ?? "Unknown Artist", year: album.year, genre: album.genre?.name ?? "", quality: album.quality, artworkURL: album.artworkURL, tracks: tracks)
    }

    static func catalogAlbum(_ source: QobuzCatalogDiscoveryAlbum) -> QobuzCatalogAlbum {
        let artist: QobuzCatalogArtist?
        if let id = source.primaryArtist?.id, let name = source.primaryArtist?.name {
            artist = QobuzCatalogArtist(id: id, name: name)
        } else {
            artist = nil
        }
        return QobuzCatalogAlbum(
            id: source.id,
            title: source.title,
            artist: artist,
            image: source.image,
            releaseDate: source.dates?.original ?? source.releaseDate,
            duration: source.duration
        )
    }

    static func featuredArtists(from albums: QobuzCatalogPage<QobuzCatalogAlbum>?) -> QobuzCatalogPage<QobuzCatalogArtist>? {
        guard let albums = albums else { return nil }
        var seenIDs = Set<String>()
        let artists = albums.items.compactMap(\.artist).filter { seenIDs.insert($0.id).inserted }
        return QobuzCatalogPage(items: artists, total: artists.count)
    }

    static func artistPage(
        _ page: QobuzCatalogArtistPage,
        releases: QobuzCatalogPage<QobuzCatalogDiscoveryAlbum>?,
        releasesError: String? = nil
    ) -> QobuzCatalogArtist {
        let albums = (releases?.items ?? []).map { release in
            let releaseArtist = release.primaryArtist
            let albumArtist = QobuzCatalogArtist(
                id: releaseArtist?.id ?? page.id,
                name: releaseArtist?.name ?? page.name
            )
            return QobuzCatalogAlbum(
                id: release.id,
                title: release.title,
                artist: albumArtist,
                image: release.image,
                releaseDate: release.dates?.original ?? release.releaseDate,
                duration: release.duration
            )
        }
        return QobuzCatalogArtist(
            id: page.id,
            name: page.name,
            albumsCount: releasesError == nil ? releases?.total : nil,
            picture: page.portraitURL?.absoluteString,
            biography: page.biography,
            albums: releases.map { QobuzCatalogPage(items: albums, total: $0.total) },
            topTracks: page.topTracks,
            releasesError: releasesError
        )
    }

    static func profile(_ artist: QobuzCatalogArtist) -> ScreenProfile {
        let albums = (artist.albums?.items ?? []).map(album)
        let biography = artist.biography?.content ?? artist.biography?.summary ?? artist.information ?? "Artist on Qobuz."
        let knownCount = artist.albumsCount ?? artist.albums?.total
        var subtitle = knownCount.map { "\($0) albums" } ?? "Artist on Qobuz"
        if artist.releasesError != nil { subtitle += " • Releases incomplete" }
        // The UI cannot represent unavailable tracks yet; do not offer them as playable.
        let tracks = artist.topTracks.filter { $0.streamable != false }.map(track)
        return ScreenProfile(id: artist.id, name: artist.name, subtitle: subtitle, information: biography, artworkURL: artist.artworkURL, albums: albums, tracks: tracks)
    }
}
