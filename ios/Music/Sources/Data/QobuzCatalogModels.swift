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

    enum CodingKeys: String, CodingKey {
        case id, name, picture, image, information, biography, albums
        case albumsCount = "albums_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeFlexibleID(forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        albumsCount = try container.decodeIfPresent(Int.self, forKey: .albumsCount)
        picture = try container.decodeIfPresent(String.self, forKey: .picture)
        image = try container.decodeIfPresent(QobuzCatalogImage.self, forKey: .image)
        information = try container.decodeIfPresent(String.self, forKey: .information)
        biography = try container.decodeIfPresent(QobuzCatalogBiography.self, forKey: .biography)
        albums = try container.decodeIfPresent(QobuzCatalogPage<QobuzCatalogAlbum>.self, forKey: .albums)
    }

    var artworkURL: URL? {
        [image?.mega, image?.extraLarge, image?.large, image?.medium, image?.small, picture]
            .compactMap { $0 }
            .compactMap(URL.init(string:))
            .first { $0.scheme?.lowercased() == "https" }
    }
}

struct QobuzCatalogBiography: Decodable {
    let summary: String?
    let content: String?
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
    let name: String?
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

    var artworkURL: URL? {
        [image?.mega, image?.extraLarge, image?.large, image?.thumbnail, image?.small]
            .compactMap { $0 }
            .compactMap(URL.init(string:))
            .first { $0.scheme?.lowercased() == "https" }
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

struct QobuzCatalogTrackPage: Decodable {
    let items: [QobuzSearchTrack]
}

struct QobuzCatalogPage<Item: Decodable>: Decodable {
    let items: [Item]
    let total: Int?
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

private extension KeyedDecodingContainer {
    func decodeFlexibleID(forKey key: Key) throws -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int64.self, forKey: key) { return String(value) }
        throw DecodingError.typeMismatch(String.self, .init(codingPath: codingPath + [key], debugDescription: "Expected a string or numeric catalog ID."))
    }
}
