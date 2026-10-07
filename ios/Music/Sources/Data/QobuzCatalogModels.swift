import Foundation

/// Tolerant models for Qobuz's undocumented `/api.json/0.2` catalog responses.
/// IDs vary between numeric and string values across endpoints.
struct QobuzCatalogArtist: Decodable {
    let id: String
    let name: String
    let albumsCount: Int?
    let picture: String?
    let image: QobuzCatalogImage?
    let information: String?
    let biography: QobuzCatalogBiography?
    let albums: QobuzCatalogPage<QobuzCatalogAlbum>?
    let topTracks: [QobuzSearchTrack]
    /// Non-nil when some release categories/pages could not be loaded.
    let releasesError: String?

    enum CodingKeys: String, CodingKey {
        case id, name, picture, image, information, biography, albums
        case albumsCount = "albums_count"
        case topTracks = "top_tracks"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleID(forKey: .id)
        name = try container.decodeCatalogName(forKey: .name)
        albumsCount = try container.decodeIfPresent(Int.self, forKey: .albumsCount)
        picture = try container.decodeIfPresent(String.self, forKey: .picture)
        image = try container.decodeIfPresent(QobuzCatalogImage.self, forKey: .image)
        information = try container.decodeIfPresent(String.self, forKey: .information)
        biography = try container.decodeIfPresent(QobuzCatalogBiography.self, forKey: .biography)
        albums = try container.decodeIfPresent(QobuzCatalogPage<QobuzCatalogAlbum>.self, forKey: .albums)
        topTracks = try container.decodeIfPresent([QobuzSearchTrack].self, forKey: .topTracks) ?? []
        releasesError = nil
    }

    init(
        id: String,
        name: String,
        albumsCount: Int? = nil,
        picture: String? = nil,
        image: QobuzCatalogImage? = nil,
        information: String? = nil,
        biography: QobuzCatalogBiography? = nil,
        albums: QobuzCatalogPage<QobuzCatalogAlbum>? = nil,
        topTracks: [QobuzSearchTrack] = [],
        releasesError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.albumsCount = albumsCount
        self.picture = picture
        self.image = image
        self.information = information
        self.biography = biography
        self.albums = albums
        self.topTracks = topTracks
        self.releasesError = releasesError
    }

    var artworkURL: URL? {
        [image?.mega, image?.extraLarge, image?.large, image?.medium, image?.small, picture]
            .catalogArtworkURL
    }
}

struct QobuzCatalogBiography: Decodable {
    let summary: String?
    let content: String?
}

struct QobuzCatalogArtistPage: Decodable {
    let id: String
    let name: String
    let biography: QobuzCatalogBiography?
    let portrait: QobuzCatalogArtistPortrait?
    let topTracks: [QobuzSearchTrack]
    let image: QobuzCatalogImage?
    let picture: String?

    enum CodingKeys: String, CodingKey {
        case id, name, biography, images, image, picture
        case topTracks = "top_tracks"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleID(forKey: .id)
        name = try container.decodeCatalogName(forKey: .name)
        biography = try container.decodeIfPresent(QobuzCatalogBiography.self, forKey: .biography)
        let images = try container.decodeIfPresent(QobuzCatalogArtistPageImages.self, forKey: .images)
        portrait = images?.portrait
        topTracks = try container.decodeIfPresent([QobuzSearchTrack].self, forKey: .topTracks) ?? []
        image = try container.decodeIfPresent(QobuzCatalogImage.self, forKey: .image)
        picture = try container.decodeIfPresent(String.self, forKey: .picture)
    }

    var portraitURL: URL? {
        let directURL = [portrait?.url, portrait?.large, image?.mega, image?.extraLarge,
                         image?.large, image?.medium, image?.small, picture].catalogArtworkURL
        if let directURL = directURL { return directURL }
        guard let hash = portrait?.hash?.trimmingCharacters(in: .whitespacesAndNewlines),
              let format = portrait?.format?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hash.isEmpty, !format.isEmpty,
              hash.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
              format.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://static.qobuz.com/images/artists/covers/large/\(hash).\(format.lowercased())")
    }
}

private struct QobuzCatalogArtistPageName: Decodable {
    let display: String?
}

private struct QobuzCatalogArtistPageImages: Decodable {
    let portrait: QobuzCatalogArtistPortrait?
}

struct QobuzCatalogArtistPortrait: Decodable {
    let hash: String?
    let format: String?
    let url: String?
    let large: String?
}

struct QobuzCatalogImage: Decodable {
    let small: String?
    let thumbnail: String?
    let large: String?
    let medium: String?
    let extraLarge: String?
    let mega: String?

    enum CodingKeys: String, CodingKey {
        case small, thumbnail, large, medium, mega
        case extraLarge = "extralarge"
    }
}

struct QobuzCatalogGenre: Decodable {
    let id: String?
    let name: String?
    let slug: String?
    let color: String?

    enum CodingKeys: String, CodingKey {
        case id, name, slug, color
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeFlexibleID(forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        color = try container.decodeIfPresent(String.self, forKey: .color)
    }
}

struct QobuzCatalogAlbum: Decodable {
    let id: String
    let title: String
    let artist: QobuzCatalogArtist?
    let image: QobuzCatalogImage?
    let genre: QobuzCatalogGenre?
    let releaseDate: String?
    let releasedAt: TimeInterval?
    let duration: Int?
    let maximumBitDepth: Int?
    let maximumSamplingRate: Double?
    let tracks: QobuzCatalogTrackPage?

    enum CodingKeys: String, CodingKey {
        case id, title, artist, image, genre, duration, tracks
        case releaseDate = "release_date_original"
        case releasedAt = "released_at"
        case maximumBitDepth = "maximum_bit_depth"
        case maximumSamplingRate = "maximum_sampling_rate"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleID(forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decodeIfPresent(QobuzCatalogArtist.self, forKey: .artist)
        image = try container.decodeIfPresent(QobuzCatalogImage.self, forKey: .image)
        genre = try container.decodeIfPresent(QobuzCatalogGenre.self, forKey: .genre)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        releasedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .releasedAt)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        maximumBitDepth = try container.decodeIfPresent(Int.self, forKey: .maximumBitDepth)
        maximumSamplingRate = try container.decodeIfPresent(Double.self, forKey: .maximumSamplingRate)
        tracks = try container.decodeIfPresent(QobuzCatalogTrackPage.self, forKey: .tracks)
    }

    init(
        id: String,
        title: String,
        artist: QobuzCatalogArtist?,
        image: QobuzCatalogImage? = nil,
        genre: QobuzCatalogGenre? = nil,
        releaseDate: String? = nil,
        releasedAt: TimeInterval? = nil,
        duration: Int? = nil,
        maximumBitDepth: Int? = nil,
        maximumSamplingRate: Double? = nil,
        tracks: QobuzCatalogTrackPage? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.image = image
        self.genre = genre
        self.releaseDate = releaseDate
        self.releasedAt = releasedAt
        self.duration = duration
        self.maximumBitDepth = maximumBitDepth
        self.maximumSamplingRate = maximumSamplingRate
        self.tracks = tracks
    }

    var artworkURL: URL? {
        [image?.mega, image?.extraLarge, image?.large, image?.medium, image?.thumbnail, image?.small]
            .catalogArtworkURL
    }

    var year: String {
        if let releaseDate = releaseDate, releaseDate.count >= 4 { return String(releaseDate.prefix(4)) }
        guard let releasedAt = releasedAt, releasedAt > 0 else { return "" }
        return String(Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: releasedAt)))
    }

    var quality: String {
        guard let depth = maximumBitDepth else { return "" }
        let rate = maximumSamplingRate.map { " / \(Int($0 * 1000)) Hz" } ?? ""
        return "\(depth)-bit\(rate)"
    }
}

/// Favorites, releases and editorial pages have different pagination metadata.
/// Decode item failures rather than turning a malformed response into an empty library.
struct QobuzCatalogTrackPage: Decodable {
    let items: [QobuzSearchTrack]
    let total: Int?
    let offset: Int?
    let limit: Int?
    let hasMore: Bool?

    init(items: [QobuzSearchTrack], total: Int? = nil, offset: Int? = nil, limit: Int? = nil, hasMore: Bool? = nil) {
        self.items = items; self.total = total; self.offset = offset; self.limit = limit; self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let page = try QobuzCatalogPage<QobuzSearchTrack>(from: decoder)
        items = page.items; total = page.total; offset = page.offset; limit = page.limit; hasMore = page.hasMore
    }
}

struct QobuzCatalogPage<Item: Decodable>: Decodable {
    let items: [Item]
    let total: Int?
    let offset: Int?
    let limit: Int?
    let hasMore: Bool?

    init(items: [Item], total: Int?, offset: Int? = nil, limit: Int? = nil, hasMore: Bool? = nil) {
        self.items = items; self.total = total; self.offset = offset; self.limit = limit; self.hasMore = hasMore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([Item].self, forKey: .items)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        offset = try container.decodeIfPresent(Int.self, forKey: .offset)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore)
    }

    private enum CodingKeys: String, CodingKey {
        case items, total, offset, limit
        case hasMore = "has_more"
    }
}

struct QobuzCatalogLibraryResponse: Decodable {
    let albums: QobuzCatalogPage<QobuzCatalogAlbum>?
    let artists: QobuzCatalogPage<QobuzCatalogArtist>?
    let tracks: QobuzCatalogTrackPage?
}

struct QobuzCatalogDiscoveryResponse: Decodable {
    let containers: QobuzCatalogDiscoveryContainers?
}

struct QobuzCatalogDiscoveryContainers: Decodable {
    let newReleases: QobuzCatalogDiscoverySection<QobuzCatalogDiscoveryAlbum>?
    let qobuzissims: QobuzCatalogDiscoverySection<QobuzCatalogDiscoveryAlbum>?
    let idealDiscography: QobuzCatalogDiscoverySection<QobuzCatalogDiscoveryAlbum>?
    let albumOfTheWeek: QobuzCatalogDiscoverySection<QobuzCatalogDiscoveryAlbum>?
    let mostStreamed: QobuzCatalogDiscoverySection<QobuzCatalogDiscoveryAlbum>?
    let pressAwards: QobuzCatalogDiscoverySection<QobuzCatalogDiscoveryAlbum>?
    let playlists: QobuzCatalogDiscoverySection<QobuzCatalogPlaylist>?
    let playlistsTags: QobuzCatalogDiscoverySection<QobuzCatalogPlaylistTag>?

    enum CodingKeys: String, CodingKey {
        case newReleases = "new_releases"
        case qobuzissims
        case idealDiscography = "ideal_discography"
        case albumOfTheWeek = "album_of_the_week"
        case mostStreamed = "most_streamed"
        case pressAwards = "press_awards"
        case playlists
        case playlistsTags = "playlists_tags"
    }
}

struct QobuzCatalogDiscoverySection<Item: Decodable>: Decodable {
    let data: QobuzCatalogPage<Item>?
}

struct QobuzCatalogDiscoveryAlbum: Decodable {
    let id: String
    let title: String
    let artists: [QobuzCatalogDiscoveryArtist]?
    let artist: QobuzCatalogDiscoveryArtist?
    let image: QobuzCatalogImage?
    let duration: Int?
    let dates: QobuzCatalogDiscoveryDates?
    let releaseDate: String?

    enum CodingKeys: String, CodingKey {
        case id, title, artists, artist, image, duration, dates
        case releaseDate = "release_date_original"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleID(forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artists = try container.decodeIfPresent([QobuzCatalogDiscoveryArtist].self, forKey: .artists)
        artist = try container.decodeIfPresent(QobuzCatalogDiscoveryArtist.self, forKey: .artist)
        image = try container.decodeIfPresent(QobuzCatalogImage.self, forKey: .image)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        dates = try container.decodeIfPresent(QobuzCatalogDiscoveryDates.self, forKey: .dates)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
    }

    var primaryArtist: QobuzCatalogDiscoveryArtist? {
        artists?.first ?? artist
    }

    var artworkURL: URL? {
        [image?.mega, image?.extraLarge, image?.large, image?.medium, image?.thumbnail, image?.small]
            .catalogArtworkURL
    }

    var year: String {
        let value = dates?.original ?? releaseDate ?? ""
        return value.count >= 4 ? String(value.prefix(4)) : ""
    }
}

struct QobuzCatalogDiscoveryArtist: Decodable {
    let id: String?
    let name: String?
    let image: QobuzCatalogImage?

    enum CodingKeys: String, CodingKey {
        case id, name, image
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeFlexibleID(forKey: .id)
        if container.contains(.name), try !container.decodeNil(forKey: .name) {
            name = try container.decodeCatalogName(forKey: .name)
        } else { name = nil }
        image = try container.decodeIfPresent(QobuzCatalogImage.self, forKey: .image)
    }

    var artworkURL: URL? {
        [image?.mega, image?.extraLarge, image?.large, image?.medium, image?.small]
            .catalogArtworkURL
    }
}

struct QobuzCatalogDiscoveryDates: Decodable {
    let original: String?
}

struct QobuzCatalogGenreListResponse: Decodable {
    let genres: QobuzCatalogPage<QobuzCatalogGenre>?
}

struct QobuzCatalogPlaylistTag: Decodable {
    let slug: String
    let name: String
}

struct QobuzCatalogPlaylistOwner: Decodable {
    let id: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case id, name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decodeFlexibleID(forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
    }
}

struct QobuzCatalogPlaylistImage: Decodable {
    let rectangle: String?
    let covers: [String]?
}

struct QobuzCatalogPlaylist: Decodable {
    let id: String
    let name: String
    let description: String?
    let owner: QobuzCatalogPlaylistOwner?
    let image: QobuzCatalogPlaylistImage?
    let tracksCount: Int?
    let duration: Int?
    let rectangleImages: [String]?
    let images300: [String]?
    let tracks: QobuzCatalogTrackPage?

    enum CodingKeys: String, CodingKey {
        case id, name, title, description, owner, image, duration, tracks
        case tracksCount = "tracks_count"
        case rectangleImages = "image_rectangle"
        case images300 = "images300"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleID(forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        owner = try container.decodeIfPresent(QobuzCatalogPlaylistOwner.self, forKey: .owner)
        image = try container.decodeIfPresent(QobuzCatalogPlaylistImage.self, forKey: .image)
        tracksCount = try container.decodeIfPresent(Int.self, forKey: .tracksCount)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        rectangleImages = (try? container.decode([String].self, forKey: .rectangleImages))
            ?? (try? container.decode(String.self, forKey: .rectangleImages)).map { [$0] }
        images300 = try container.decodeIfPresent([String].self, forKey: .images300)
        tracks = try container.decodeIfPresent(QobuzCatalogTrackPage.self, forKey: .tracks)
    }

    var artworkURL: URL? {
        [image?.rectangle, image?.covers?.first, rectangleImages?.first, images300?.first]
            .catalogArtworkURL
    }
}

struct QobuzCatalogPlaylistsResponse: Decodable {
    let items: [QobuzCatalogPlaylist]
    let total: Int?
    let offset: Int?
    let limit: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? container.decode([QobuzCatalogPlaylist].self, forKey: .items)) ?? []
        total = try? container.decode(Int.self, forKey: .total)
        offset = try? container.decode(Int.self, forKey: .offset)
        limit = try? container.decode(Int.self, forKey: .limit)
    }

    private enum CodingKeys: String, CodingKey {
        case items, total, offset, limit
    }
}

struct QobuzCatalogFeaturedResponse: Decodable {
    let albums: QobuzCatalogPage<QobuzCatalogAlbum>?
    let artists: QobuzCatalogPage<QobuzCatalogArtist>?
}

struct QobuzCatalogSearchResponse: Decodable {
    let albums: QobuzCatalogPage<QobuzCatalogAlbum>?
    let artists: QobuzCatalogPage<QobuzCatalogArtist>?
    let tracks: QobuzCatalogPage<QobuzSearchTrack>?
}

/// Qobuz sometimes supplies protocol-relative or legacy HTTP static artwork URLs.
/// Prefer an existing HTTPS candidate, then safely upgrade HTTP (never accept other schemes).
extension Array where Element == String? {
    var catalogArtworkURL: URL? {
        let urls = compactMap { value -> URL? in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return URL(string: value.hasPrefix("//") ? "https:" + value : value)
        }.filter { $0.host?.isEmpty == false && ["https", "http"].contains($0.scheme?.lowercased() ?? "") }
        if let secure = urls.first(where: { $0.scheme?.lowercased() == "https" }) { return secure }
        guard let legacy = urls.first, var components = URLComponents(url: legacy, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        return components.url
    }
}

private extension KeyedDecodingContainer {
    func decodeCatalogName(forKey key: Key) throws -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        return try decode(QobuzCatalogArtistPageName.self, forKey: key).display ?? ""
    }

    func decodeFlexibleID(forKey key: Key) throws -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        throw DecodingError.typeMismatch(String.self, .init(codingPath: codingPath + [key], debugDescription: "Expected a string or numeric catalog ID."))
    }
}
