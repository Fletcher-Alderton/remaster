import CommonCrypto
import Foundation
import Security

// Qobuz streaming protocol ported from SofusA/qobine (GPL-3.0).
// Modified for this iOS app on 2026-07-11.
struct QobuzCredentials: Codable {
    let userAuthToken: String
    let userID: Int64
}

enum QobuzStreamQuality: Int, CaseIterable {
    case mp3 = 5
    case cd = 6
    case hiRes96 = 7
    case hiRes192 = 27

    var title: String {
        switch self {
        case .mp3: return "MP3"
        case .cd: return "CD"
        case .hiRes96: return "Hi-Res 96"
        case .hiRes192: return "Hi-Res 192"
        }
    }

    var detail: String {
        switch self {
        case .mp3: return "MP3, up to 320 kbps"
        case .cd: return "Lossless, 16-bit / 44.1 kHz"
        case .hiRes96: return "Hi-Res, up to 24-bit / 96 kHz"
        case .hiRes192: return "Hi-Res, up to 24-bit / 192 kHz"
        }
    }
}

struct QobuzSearchTrack: Codable {
    struct Performer: Codable {
        let id: String?
        let name: String?

        enum CodingKeys: String, CodingKey { case id, name }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let direct = try? container.decode(String.self, forKey: .name) { name = direct }
            else { name = try container.decodeIfPresent(DisplayName.self, forKey: .name)?.display }
            if let value = try? container.decode(String.self, forKey: .id) { id = value }
            else if let value = try? container.decode(Int64.self, forKey: .id) { id = String(value) }
            else { id = nil }
        }
    }

    private struct DisplayName: Decodable { let display: String? }

    struct Image: Codable {
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
        private enum AlternateKeys: String, CodingKey { case extraLarge, extaLarge }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let alternates = try decoder.container(keyedBy: AlternateKeys.self)
            small = try container.decodeIfPresent(String.self, forKey: .small)
            thumbnail = try container.decodeIfPresent(String.self, forKey: .thumbnail)
            large = try container.decodeIfPresent(String.self, forKey: .large)
            medium = try container.decodeIfPresent(String.self, forKey: .medium)
            mega = try container.decodeIfPresent(String.self, forKey: .mega)
            extraLarge = try container.decodeIfPresent(String.self, forKey: .extraLarge)
                ?? alternates.decodeIfPresent(String.self, forKey: .extraLarge)
                ?? alternates.decodeIfPresent(String.self, forKey: .extaLarge)
        }
    }

    struct Album: Codable {
        let id: String?
        let title: String?
        let image: Image?
        let artist: Performer?

        enum CodingKeys: String, CodingKey { case id, title, image, artist }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            image = try container.decodeIfPresent(Image.self, forKey: .image)
            artist = try container.decodeIfPresent(Performer.self, forKey: .artist)
            if let value = try? container.decode(String.self, forKey: .id) { id = value }
            else if let value = try? container.decode(Int64.self, forKey: .id) { id = String(value) }
            else { id = nil }
        }

        var imageURL: URL? {
            [image?.mega, image?.extraLarge, image?.large, image?.medium, image?.thumbnail, image?.small].catalogArtworkURL
        }
    }

    let id: Int64
    let title: String
    let duration: Int?
    let performer: Performer?
    let album: Album?
    let albumID: String?
    let streamable: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, duration, performer, album, streamable
        case albumID = "album_id"
    }
    private enum ModernKeys: String, CodingKey { case artist, rights }
    private struct Rights: Decodable { let streamable: Bool? }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modern = try decoder.container(keyedBy: ModernKeys.self)
        if let numericID = try? container.decode(Int64.self, forKey: .id) { id = numericID }
        else {
            let stringID = try container.decode(String.self, forKey: .id)
            guard let numericID = Int64(stringID) else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Expected a numeric track ID.")
            }
            id = numericID
        }
        title = try container.decode(String.self, forKey: .title)
        duration = try container.decodeIfPresent(Int.self, forKey: .duration)
        performer = try container.decodeIfPresent(Performer.self, forKey: .performer)
            ?? modern.decodeIfPresent(Performer.self, forKey: .artist)
        album = try container.decodeIfPresent(Album.self, forKey: .album)
        if let stringID = try? container.decode(String.self, forKey: .albumID) { albumID = stringID }
        else if let numericID = try? container.decode(Int64.self, forKey: .albumID) { albumID = String(numericID) }
        else { albumID = nil }
        streamable = try container.decodeIfPresent(Bool.self, forKey: .streamable)
            ?? modern.decodeIfPresent(Rights.self, forKey: .rights)?.streamable
    }

    var subtitle: String {
        [performer?.name ?? album?.artist?.name, album?.title].compactMap { $0 }.joined(separator: " • ")
    }
}

struct QobuzTrackSearchResponse: Decodable {
    struct Tracks: Decodable {
        let items: [QobuzSearchTrack]
    }

    let tracks: Tracks
}

struct QobuzTrackURL: Decodable {
    let url: URL
    let formatID: Int
    let mimeType: String
    let samplingRate: Double
    let bitDepth: Int

    enum CodingKeys: String, CodingKey {
        case url
        case formatID = "format_id"
        case mimeType = "mime_type"
        case samplingRate = "sampling_rate"
        case bitDepth = "bit_depth"
    }
}

enum QobuzStreamingError: LocalizedError {
    case invalidResponse
    case notAuthenticated
    case appIDNotFound
    case appIDDiscoveryFailed(stage: String, details: String)
    case secretsNotFound
    case resolutionTimedOut
    case secretProbesFailed(count: Int, lastError: String)
    case unauthorized
    case signingRejected
    case api(String)
    case invalidTrackID
    case invalidQobuzTrackID
    case emptySearchQuery
    case invalidCallback
    case keychain(OSStatus)

    static func catalogRequestFailure(path: String, statusCode: Int, responseData: Data) -> Self {
        let response = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        let nestedError = response?["error"] as? [String: Any]
        let rawMessage = (response?["message"] as? String)
            ?? (response?["error"] as? String)
            ?? (nestedError?["message"] as? String)
        let message = rawMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = message.flatMap { $0.isEmpty ? nil : String($0.prefix(240)) }
        let summary = "Qobuz catalog request to \(path) failed (HTTP \(statusCode))"
        return .api(detail.map { "\(summary): \($0)" } ?? "\(summary).")
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Qobuz returned an invalid response."
        case .notAuthenticated: return "Sign in to Qobuz before queueing music."
        case .appIDNotFound: return "Could not find the Qobuz web player app ID."
        case .appIDDiscoveryFailed(let stage, let details):
            return "Could not find the Qobuz web player app ID.\nStage: \(stage)\n\(details)"
        case .secretsNotFound: return "Could not find the active Qobuz signing secret."
        case .resolutionTimedOut: return "Qobuz stream resolution timed out. Check your connection and try again."
        case .secretProbesFailed(let count, let lastError):
            return "None of the \(count) Qobuz signing secrets worked. Last probe error: \(lastError)"
        case .unauthorized: return "Qobuz rejected the sign-in or stream request."
        case .signingRejected: return "Qobuz rejected the stream request signature."
        case .api(let message): return message
        case .invalidTrackID: return "Enter a numeric Qobuz track ID."
        case .invalidQobuzTrackID: return "The selected Qobuz track has an invalid ID."
        case .emptySearchQuery: return "Enter a song title or artist to search Qobuz."
        case .invalidCallback: return "Qobuz sign-in did not return an authorization code."
        case .keychain(let status): return "Could not securely store Qobuz credentials (Keychain error \(status))."
        }
    }
}

/// Stores the OAuth token in the system Keychain rather than app preferences.
final class QobuzCredentialStore {
    static let shared = QobuzCredentialStore()

    private let service = Bundle.main.bundleIdentifier ?? "com.fletcher.MusicPrototype"
    private let account = "qobuz.credentials"
    #if targetEnvironment(simulator)
    private var simulatorSessionCredentials: QobuzCredentials?
    #endif
    private(set) var isSessionOnly = false

    func load() -> QobuzCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data {
            return try? JSONDecoder().decode(QobuzCredentials.self, from: data)
        }
        #if targetEnvironment(simulator)
        return simulatorSessionCredentials
        #else
        return nil
        #endif
    }

    func save(_ credentials: QobuzCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            let addStatus = SecItemAdd(insertion as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                #if targetEnvironment(simulator)
                if addStatus == errSecMissingEntitlement {
                    simulatorSessionCredentials = credentials
                    isSessionOnly = true
                    return
                }
                #endif
                throw QobuzStreamingError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            #if targetEnvironment(simulator)
            if status == errSecMissingEntitlement {
                simulatorSessionCredentials = credentials
                isSessionOnly = true
                return
            }
            #endif
            throw QobuzStreamingError.keychain(status)
        }
        isSessionOnly = false
    }

    func delete() {
        #if targetEnvironment(simulator)
        simulatorSessionCredentials = nil
        #endif
        isSessionOnly = false
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private struct QobuzWebPlayerConfiguration: Codable {
    let appID: String
    let secrets: [String]
    var activeSecret: String?
    let cachedAt: Date
}

private struct QobuzCachedSearch: Codable {
    let tracks: [QobuzSearchTrack]
    let cachedAt: Date
}

private enum QobuzSearchCache {
    private static let keyPrefix = "qobuz.search.v2."
    private static let legacyKeyPrefix = "qobuz.search.v1."
    private static let expirationInterval: TimeInterval = 15 * 60
    private static let maximumEntries = 100

    private static func cacheKey(query: String, accountID: Int64) -> String {
        let bytes = Array(query.lowercased().utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = CC_MD5(bytes, CC_LONG(bytes.count), &digest)
        let queryHash = digest.map { String(format: "%02x", $0) }.joined()
        return keyPrefix + String(accountID) + "." + queryHash
    }

    private static func removeLegacyEntries() {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(legacyKeyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func pruneEntries(excluding keyToKeep: String? = nil) {
        let defaults = UserDefaults.standard
        let entries = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(keyPrefix) }.compactMap { key -> (String, Date)? in
            guard let data = defaults.data(forKey: key),
                  let cached = try? JSONDecoder().decode(QobuzCachedSearch.self, from: data) else {
                defaults.removeObject(forKey: key)
                return nil
            }
            let age = Date().timeIntervalSince(cached.cachedAt)
            guard age >= 0, age < expirationInterval else {
                defaults.removeObject(forKey: key)
                return nil
            }
            return (key, cached.cachedAt)
        }
        let candidates = entries.filter { $0.0 != keyToKeep }.sorted { $0.1 < $1.1 }
        let excess = max(0, entries.count - maximumEntries)
        for (key, _) in candidates.prefix(excess) {
            defaults.removeObject(forKey: key)
        }
    }

    static func load(query: String, accountID: Int64) -> [QobuzSearchTrack]? {
        removeLegacyEntries()
        let key = cacheKey(query: query, accountID: accountID)
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(QobuzCachedSearch.self, from: data),
              Date().timeIntervalSince(cached.cachedAt) >= 0,
              Date().timeIntervalSince(cached.cachedAt) < expirationInterval else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return cached.tracks
    }

    static func save(_ tracks: [QobuzSearchTrack], query: String, accountID: Int64) {
        removeLegacyEntries()
        let key = cacheKey(query: query, accountID: accountID)
        guard let data = try? JSONEncoder().encode(QobuzCachedSearch(tracks: tracks, cachedAt: Date())) else { return }
        UserDefaults.standard.set(data, forKey: key)
        pruneEntries(excluding: key)
    }
}

private enum QobuzWebPlayerCache {
    private static let key = "qobuz.webPlayerConfiguration.v1"
    private static let expirationInterval: TimeInterval = 8 * 60 * 60
    private static let lock = NSLock()

    static func load() -> QobuzWebPlayerConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: key),
              let configuration = try? JSONDecoder().decode(QobuzWebPlayerConfiguration.self, from: data),
              Date().timeIntervalSince(configuration.cachedAt) < expirationInterval else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return configuration
    }

    static func save(appID: String, secrets: [String]) {
        store(QobuzWebPlayerConfiguration(appID: appID, secrets: secrets, activeSecret: nil, cachedAt: Date()))
    }

    static func saveActiveSecret(_ secret: String, appID: String) {
        guard var configuration = load(), configuration.appID == appID else { return }
        configuration.activeSecret = secret
        store(configuration)
    }

    static func clearActiveSecret(appID: String) {
        guard var configuration = load(), configuration.appID == appID else { return }
        configuration.activeSecret = nil
        store(configuration)
    }

    private static func store(_ configuration: QobuzWebPlayerConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

private final class QobuzResolution {
    private let lock = NSLock()
    private let progressHandler: (String) -> Void
    private let completion: (Result<QobuzTrackURL, Error>) -> Void
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    init(
        timeout: TimeInterval,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<QobuzTrackURL, Error>) -> Void
    ) {
        self.progressHandler = progress
        self.completion = completion
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(.failure(QobuzStreamingError.resolutionTimedOut))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)
    }

    func report(_ message: String) {
        lock.lock()
        let shouldReport = !finished
        lock.unlock()
        if shouldReport { progressHandler(message) }
    }

    func finish(_ result: Result<QobuzTrackURL, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        completion(result)
    }
}

/// Minimal Swift port of Qobine's web-player secret discovery and signed file-URL flow.
protocol QobuzStreamResolving {
    func requestStreamURL(
        trackID: Int64,
        quality: QobuzStreamQuality,
        progress: @escaping (String) -> Void,
        completion: @escaping (Result<QobuzTrackURL, Error>) -> Void
    )
}

final class QobuzStreamingClient: QobuzStreamResolving {
    private static let apiBase = URL(string: "https://www.qobuz.com/api.json/0.2/")!
    private static let playBase = URL(string: "https://play.qobuz.com")!
    private static let oauthPrivateKey = "6lz8C03UDIC7"
    private static let secretProbeTrackID: Int64 = 64_868_955
    private static let requestTimeout: TimeInterval = 12

    private let credentials: QobuzCredentials
    private let session: URLSession
    private let resolutionTimeout: TimeInterval
    private let catalogAppID: String?

    /// Supplying a catalog app ID allows isolated URLProtocol tests without changing the player cache.
    /// Normal app callers leave it nil and discover the current web-player configuration.
    init(credentials: QobuzCredentials, session: URLSession = .shared, resolutionTimeout: TimeInterval = 45, catalogAppID: String? = nil) {
        self.credentials = credentials
        self.session = session
        self.resolutionTimeout = resolutionTimeout
        self.catalogAppID = catalogAppID
    }

    static func authorizationURL(appID: String) -> URL? {
        var components = URLComponents(string: "https://www.qobuz.com/signin/oauth")
        components?.queryItems = [
            URLQueryItem(name: "ext_app_id", value: appID),
            URLQueryItem(name: "redirect_url", value: "qobuz-music://oauth")
        ]
        return components?.url
    }

    static func exchangeAuthorizationCode(
        _ code: String,
        appID: String,
        session: URLSession = .shared,
        completion: @escaping (Result<QobuzCredentials, Error>) -> Void
    ) {
        var components = URLComponents(url: apiBase.appendingPathComponent("oauth/callback"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "private_key", value: oauthPrivateKey)
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(appID, forHTTPHeaderField: "X-App-Id")
        session.dataTask(with: request) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data, let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                completion(.failure(QobuzStreamingError.unauthorized))
                return
            }
            do {
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let token = (object["token"] as? String) ?? (object["user_auth_token"] as? String),
                      let rawID = object["user_id"],
                      let userID = (rawID as? NSNumber)?.int64Value ?? (rawID as? String).flatMap(Int64.init) else {
                    throw QobuzStreamingError.invalidResponse
                }
                completion(.success(QobuzCredentials(userAuthToken: token, userID: userID)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    func searchTracks(query: String, completion: @escaping (Result<[QobuzSearchTrack], Error>) -> Void) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            completion(.failure(QobuzStreamingError.emptySearchQuery))
            return
        }
        if let cachedTracks = QobuzSearchCache.load(query: trimmedQuery, accountID: credentials.userID) {
            completion(.success(cachedTracks))
            return
        }
        discoverWebPlayer { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let playerInfo):
                var components = URLComponents(url: Self.apiBase.appendingPathComponent("track/search"), resolvingAgainstBaseURL: false)!
                components.queryItems = [
                    URLQueryItem(name: "query", value: trimmedQuery),
                    URLQueryItem(name: "limit", value: "10")
                ]
                var request = URLRequest(url: components.url!)
                request.timeoutInterval = Self.requestTimeout
                request.setValue(playerInfo.appID, forHTTPHeaderField: "X-App-Id")
                request.setValue(self.credentials.userAuthToken, forHTTPHeaderField: "X-User-Auth-Token")
                self.session.dataTask(with: request) { data, response, error in
                    if let error = error { completion(.failure(error)); return }
                    guard let data = data, let http = response as? HTTPURLResponse else {
                        completion(.failure(QobuzStreamingError.invalidResponse))
                        return
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        completion(.failure(QobuzStreamingError.api("Qobuz song search failed (HTTP \(http.statusCode)).")))
                        return
                    }
                    do {
                        let search = try JSONDecoder().decode(QobuzTrackSearchResponse.self, from: data)
                        QobuzSearchCache.save(search.tracks.items, query: trimmedQuery, accountID: self.credentials.userID)
                        completion(.success(search.tracks.items))
                    } catch {
                        completion(.failure(error))
                    }
                }.resume()
            }
        }
    }

    func searchCatalog(query: String, completion: @escaping (Result<QobuzCatalogSearchResponse, Error>) -> Void) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            completion(.failure(QobuzStreamingError.emptySearchQuery))
            return
        }
        discoverWebPlayer { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let playerInfo):
                let group = DispatchGroup()
                let lock = NSLock()
                var albums: QobuzCatalogPage<QobuzCatalogAlbum>?
                var artists: QobuzCatalogPage<QobuzCatalogArtist>?
                var tracks: QobuzTrackSearchResponse.Tracks?
                var firstError: Error?
                let requests: [(String, (Data) throws -> Void)] = [
                    ("album/search", { data in albums = try JSONDecoder().decode(QobuzCatalogSearchResponse.self, from: data).albums }),
                    ("artist/search", { data in artists = try JSONDecoder().decode(QobuzCatalogSearchResponse.self, from: data).artists }),
                    ("track/search", { data in tracks = try JSONDecoder().decode(QobuzTrackSearchResponse.self, from: data).tracks })
                ]
                for (path, decode) in requests {
                    group.enter()
                    self.performCatalogRequest(path: path, queryItems: [
                        URLQueryItem(name: "query", value: query),
                        URLQueryItem(name: "limit", value: "25")
                    ], appID: playerInfo.appID) { result in
                        lock.lock()
                        defer { lock.unlock() }
                        switch result {
                        case .success(let data):
                            do { try decode(data) } catch { if firstError == nil { firstError = error } }
                        case .failure(let error): if firstError == nil { firstError = error }
                        }
                        group.leave()
                    }
                }
                group.notify(queue: .global()) {
                    lock.lock()
                    let response = QobuzCatalogSearchResponse(albums: albums, artists: artists, tracks: tracks.map { QobuzCatalogPage(items: $0.items, total: nil) })
                    let succeeded = [albums != nil, artists != nil, tracks != nil].contains(true)
                    let error = succeeded ? nil : firstError
                    lock.unlock()
                    if let error = error { completion(.failure(error)) }
                    else { completion(.success(response)) }
                }
            }
        }
    }

    func catalogGenres(completion: @escaping (Result<[QobuzCatalogGenre], Error>) -> Void) {
        discoverWebPlayer { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let playerInfo):
                self.performCatalogRequest(path: "genre/list", queryItems: [], appID: playerInfo.appID) { result in
                    completion(result.flatMap { data in
                        Result {
                            try JSONDecoder().decode(QobuzCatalogGenreListResponse.self, from: data).genres?.items ?? []
                        }
                    })
                }
            }
        }
    }

    func discoveryIndex(genreID: String?, completion: @escaping (Result<QobuzCatalogDiscoveryResponse, Error>) -> Void) {
        discoverWebPlayer { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let playerInfo):
                self.performCatalogRequest(path: "discover/index", queryItems: [
                    URLQueryItem(name: "genre_ids", value: genreID ?? "")
                ], appID: playerInfo.appID) { result in
                    completion(result.flatMap { data in
                        Result { try JSONDecoder().decode(QobuzCatalogDiscoveryResponse.self, from: data) }
                    })
                }
            }
        }
    }

    func discoverPlaylists(
        genreID: String?,
        tag: String?,
        offset: Int,
        limit: Int = 20,
        completion: @escaping (Result<QobuzCatalogPlaylistsResponse, Error>) -> Void
    ) {
        discoverWebPlayer { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let playerInfo):
                self.performCatalogRequest(path: "discover/playlists", queryItems: [
                    URLQueryItem(name: "genre_ids", value: genreID ?? ""),
                    URLQueryItem(name: "tags", value: tag ?? ""),
                    URLQueryItem(name: "offset", value: String(max(0, offset))),
                    URLQueryItem(name: "limit", value: String(min(max(1, limit), 100)))
                ], appID: playerInfo.appID) { result in
                    completion(result.flatMap { data in
                        Result { try JSONDecoder().decode(QobuzCatalogPlaylistsResponse.self, from: data) }
                    })
                }
            }
        }
    }

    func playlist(id: String, completion: @escaping (Result<QobuzCatalogPlaylist, Error>) -> Void) {
        discoverWebPlayer { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let playerInfo):
                self.performCatalogRequest(path: "playlist/get", queryItems: [
                    URLQueryItem(name: "limit", value: "500"),
                    URLQueryItem(name: "extra", value: "tracks"),
                    URLQueryItem(name: "playlist_id", value: id),
                    URLQueryItem(name: "offset", value: "0")
                ], appID: playerInfo.appID) { result in
                    completion(result.flatMap { data in
                        Result { try JSONDecoder().decode(QobuzCatalogPlaylist.self, from: data) }
                    })
                }
            }
        }
    }

    func featuredCatalog(completion: @escaping (Result<QobuzCatalogFeaturedResponse, Error>) -> Void) {
        discoveryIndex(genreID: nil) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let response):
                let section = response.containers?.newReleases?.data
                let albumPage = section.map { page in
                    QobuzCatalogPage(
                        items: page.items.map(QobuzCatalogMapper.catalogAlbum),
                        total: page.total
                    )
                }
                let artistPage = QobuzCatalogMapper.featuredArtists(from: albumPage)
                completion(.success(QobuzCatalogFeaturedResponse(albums: albumPage, artists: artistPage)))
            }
        }
    }

    /// One authenticated favorites endpoint supplies all three saved-library groups.
    /// Qobine requests limit=1000; each group also reports its own offset/limit/total.
    func library(completion: @escaping (Result<QobuzCatalogLibraryResponse, Error>) -> Void) {
        guard !credentials.userAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(.failure(QobuzStreamingError.notAuthenticated))
            return
        }
        discoverCatalogAppID { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let appID):
                var albums = QobuzCatalogAccumulator<QobuzCatalogAlbum>()
                var artists = QobuzCatalogAccumulator<QobuzCatalogArtist>()
                var tracks = QobuzCatalogAccumulator<QobuzSearchTrack>()
                func load(offset: Int) {
                    self.performCatalogRequest(path: "favorite/getUserFavorites", queryItems: [
                        URLQueryItem(name: "limit", value: "1000"),
                        URLQueryItem(name: "offset", value: String(offset))
                    ], appID: appID) { result in
                        do {
                            let response = try JSONDecoder().decode(QobuzCatalogLibraryResponse.self, from: result.get())
                            guard response.albums != nil || response.artists != nil || response.tracks != nil else {
                                throw QobuzStreamingError.invalidResponse
                            }
                            // Missing groups on the first page are legitimately empty. A missing
                            // unfinished group on a later page is not a complete saved library.
                            try albums.append(response.albums, requestedOffset: offset, requestedLimit: 1000, id: { $0.id })
                            try artists.append(response.artists, requestedOffset: offset, requestedLimit: 1000, id: { $0.id })
                            let trackPage = response.tracks.map {
                                QobuzCatalogPage(items: $0.items, total: $0.total, offset: $0.offset, limit: $0.limit, hasMore: $0.hasMore)
                            }
                            try tracks.append(trackPage, requestedOffset: offset, requestedLimit: 1000, id: { String($0.id) })
                            let pending = [albums.pendingOffset, artists.pendingOffset, tracks.pendingOffset].compactMap { $0 }
                            if let nextOffset = pending.min() {
                                guard nextOffset > offset else { throw QobuzStreamingError.api("Qobuz favorites pagination did not advance.") }
                                load(offset: nextOffset)
                            } else {
                                completion(.success(QobuzCatalogLibraryResponse(
                                    albums: QobuzCatalogPage(items: albums.items, total: albums.items.count),
                                    artists: QobuzCatalogPage(items: artists.items, total: artists.items.count),
                                    tracks: QobuzCatalogTrackPage(items: tracks.items, total: tracks.items.count)
                                )))
                            }
                        } catch { completion(.failure(error)) }
                    }
                }
                load(offset: 0)
            }
        }
    }

    func album(id: String, completion: @escaping (Result<QobuzCatalogAlbum, Error>) -> Void) {
        discoverWebPlayer { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let playerInfo):
                self.performCatalogRequest(path: "album/get", queryItems: [
                    URLQueryItem(name: "album_id", value: id),
                    URLQueryItem(name: "limit", value: "500")
                ], appID: playerInfo.appID) { result in
                    completion(result.flatMap { data in Result { try JSONDecoder().decode(QobuzCatalogAlbum.self, from: data) } })
                }
            }
        }
    }

    func artist(id: String, completion: @escaping (Result<QobuzCatalogArtist, Error>) -> Void) {
        discoverCatalogAppID { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let appID):
                self.performCatalogRequest(path: "artist/page", queryItems: [
                    URLQueryItem(name: "artist_id", value: id),
                    URLQueryItem(name: "app_id", value: appID),
                    URLQueryItem(name: "sort", value: "relevant")
                ], appID: appID) { pageResult in
                    switch pageResult {
                    case .failure(let error): completion(.failure(error))
                    case .success(let pageData):
                        do {
                            let page = try JSONDecoder().decode(QobuzCatalogArtistPage.self, from: pageData)
                            self.loadArtistReleases(id: id, appID: appID) { releases, warning in
                                completion(.success(QobuzCatalogMapper.artistPage(page, releases: releases, releasesError: warning)))
                            }
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
            }
        }
    }

    private func discoverCatalogAppID(completion: @escaping (Result<String, Error>) -> Void) {
        if let appID = catalogAppID { completion(.success(appID)); return }
        discoverWebPlayer { result in completion(result.map { $0.appID }) }
    }

    private func loadArtistReleases(
        id: String,
        appID: String,
        completion: @escaping (QobuzCatalogPage<QobuzCatalogDiscoveryAlbum>?, String?) -> Void
    ) {
        let categories = ["album", "epSingle", "live", "compilation"]
        var releases: [QobuzCatalogDiscoveryAlbum] = []
        var seen = Set<String>()
        var failedCategories: [String] = []
        func loadCategory(_ index: Int) {
            guard index < categories.count else {
                let warning = failedCategories.isEmpty ? nil
                    : "Some artist releases could not be loaded (\(failedCategories.joined(separator: ", ")))."
                completion(QobuzCatalogPage(items: releases, total: warning == nil ? releases.count : nil), warning)
                return
            }
            let category = categories[index]
            var accumulator = QobuzCatalogAccumulator<QobuzCatalogDiscoveryAlbum>()
            func finishCategory(failed: Bool) {
                releases += accumulator.items.filter { seen.insert($0.id).inserted }
                if failed { failedCategories.append(category) }
                loadCategory(index + 1)
            }
            func loadPage(offset: Int) {
                self.performCatalogRequest(path: "artist/getReleasesList", queryItems: [
                    URLQueryItem(name: "artist_id", value: id),
                    URLQueryItem(name: "limit", value: "100"),
                    URLQueryItem(name: "release_type", value: category),
                    URLQueryItem(name: "sort", value: "release_date"),
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "track_size", value: "1")
                ], appID: appID) { result in
                    do {
                        // Actual Qobine ReleaseQuery is {has_more, items}, not {albums: ...}.
                        let page = try JSONDecoder().decode(QobuzCatalogPage<QobuzCatalogDiscoveryAlbum>.self, from: result.get())
                        try accumulator.append(page, requestedOffset: offset, requestedLimit: 100, id: { $0.id })
                        if let nextOffset = accumulator.pendingOffset {
                            loadPage(offset: nextOffset)
                        } else { finishCategory(failed: false) }
                    } catch { finishCategory(failed: true) }
                }
            }
            loadPage(offset: 0)
        }
        loadCategory(0)
    }

    private func performCatalogRequest(
        path: String,
        queryItems: [URLQueryItem],
        appID: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        var components = URLComponents(url: Self.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = Self.requestTimeout
        request.setValue(appID, forHTTPHeaderField: "X-App-Id")
        if credentials.userAuthToken.filter({ $0 == "." }).count == 3 {
            request.setValue("Bearer " + credentials.userAuthToken, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(credentials.userAuthToken, forHTTPHeaderField: "X-User-Auth-Token")
        }
        session.dataTask(with: request) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data, let http = response as? HTTPURLResponse else {
                completion(.failure(QobuzStreamingError.invalidResponse))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(QobuzStreamingError.catalogRequestFailure(
                    path: path,
                    statusCode: http.statusCode,
                    responseData: data
                )))
                return
            }
            completion(.success(data))
        }.resume()
    }

    func requestStreamURL(
        trackID: Int64,
        quality: QobuzStreamQuality = .mp3,
        progress: @escaping (String) -> Void = { _ in },
        completion: @escaping (Result<QobuzTrackURL, Error>) -> Void
    ) {
        guard trackID > 0 else {
            completion(.failure(QobuzStreamingError.invalidTrackID))
            return
        }
        let resolution = QobuzResolution(timeout: resolutionTimeout, progress: progress, completion: completion)
        resolution.report("Loading Qobuz player configuration…")
        discoverWebPlayer { result in
            guard !resolution.isFinished else { return }
            switch result {
            case .failure(let error): resolution.finish(.failure(error))
            case .success(let playerInfo):
                resolution.report("Found \(playerInfo.secrets.count) signing secrets. Checking the first one…")
                self.findActiveSecret(
                    playerInfo.secrets,
                    appID: playerInfo.appID,
                    cachedSecret: playerInfo.activeSecret,
                    resolution: resolution
                ) { result in
                    guard !resolution.isFinished else { return }
                    switch result {
                    case .failure(let error): resolution.finish(.failure(error))
                    case .success(let secret):
                        resolution.report("Signing verified. Resolving track \(trackID)…")
                        self.requestTrackURL(trackID: trackID, appID: playerInfo.appID, secret: secret, quality: quality) { result in
                            guard !resolution.isFinished else { return }
                            guard case .failure(let error) = result,
                                  playerInfo.activeSecret == secret,
                                  Self.isSigningRejection(error) else {
                                resolution.finish(result)
                                return
                            }
                            QobuzWebPlayerCache.clearActiveSecret(appID: playerInfo.appID)
                            resolution.report("Cached signing key was rejected. Refreshing Qobuz signing configuration…")
                            self.findActiveSecret(
                                playerInfo.secrets.filter { $0 != secret },
                                appID: playerInfo.appID,
                                cachedSecret: nil,
                                resolution: resolution
                            ) { refreshResult in
                                guard !resolution.isFinished else { return }
                                switch refreshResult {
                                case .failure(let error): resolution.finish(.failure(error))
                                case .success(let refreshedSecret):
                                    resolution.report("Signing refreshed. Retrying track \(trackID)…")
                                    self.requestTrackURL(
                                        trackID: trackID,
                                        appID: playerInfo.appID,
                                        secret: refreshedSecret,
                                        quality: quality
                                    ) { retryResult in
                                        resolution.finish(retryResult)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private struct WebPlayerInfo {
        let appID: String
        let secrets: [String]
        let activeSecret: String?
    }

    private func discoverWebPlayer(completion: @escaping (Result<WebPlayerInfo, Error>) -> Void) {
        if let cached = QobuzWebPlayerCache.load() {
            completion(.success(WebPlayerInfo(appID: cached.appID, secrets: cached.secrets, activeSecret: cached.activeSecret)))
            return
        }
        Self.discoverWebPlayerConfiguration(session: session) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let configuration):
                QobuzWebPlayerCache.save(appID: configuration.appID, secrets: configuration.secrets)
                completion(.success(WebPlayerInfo(
                    appID: configuration.appID,
                    secrets: configuration.secrets,
                    activeSecret: nil
                )))
            }
        }
    }

    static func discoverWebPlayerConfiguration(
        session: URLSession = .shared,
        completion: @escaping (Result<(appID: String, secrets: [String]), Error>) -> Void
    ) {
        var request = URLRequest(url: Self.playBase.appendingPathComponent("login"))
        request.timeoutInterval = Self.requestTimeout
        session.dataTask(with: request) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                completion(.failure(Self.appIDDiscoveryError(
                    stage: "Qobuz login page HTTP response",
                    response: response,
                    data: data,
                    isBundle: false
                )))
                return
            }
            guard let data = data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(Self.appIDDiscoveryError(
                    stage: "reading Qobuz login page",
                    response: response,
                    data: data,
                    isBundle: false
                )))
                return
            }
            guard let bundlePath = Self.firstCapture(
                pattern: #"<script src="(/resources/\d+\.\d+\.\d+-[a-z0-9]\d{3}/bundle\.js)"></script>"#,
                in: html
            ) else {
                completion(.failure(Self.appIDDiscoveryError(
                    stage: "finding the player bundle in Qobuz login HTML",
                    response: response,
                    data: data,
                    isBundle: false
                )))
                return
            }
            let bundleURL = Self.playBase.appendingPathComponent(String(bundlePath.dropFirst()))
            var bundleRequest = URLRequest(url: bundleURL)
            bundleRequest.timeoutInterval = Self.requestTimeout
            session.dataTask(with: bundleRequest) { bundleData, bundleResponse, bundleError in
                if let bundleError = bundleError { completion(.failure(bundleError)); return }
                guard let http = bundleResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    completion(.failure(Self.appIDDiscoveryError(
                        stage: "Qobuz player bundle HTTP response",
                        response: bundleResponse,
                        data: bundleData,
                        isBundle: true
                    )))
                    return
                }
                guard let bundleData = bundleData, let script = String(data: bundleData, encoding: .utf8) else {
                    completion(.failure(Self.appIDDiscoveryError(
                        stage: "reading Qobuz player JavaScript bundle",
                        response: bundleResponse,
                        data: bundleData,
                        isBundle: true
                    )))
                    return
                }
                guard let appID = Self.firstCapture(
                    pattern: #"production:\{api:\{appId:"(\d{9})",appSecret:"\w{32}""#,
                    in: script
                ) else {
                    completion(.failure(Self.appIDDiscoveryError(
                        stage: "finding the app ID in Qobuz player JavaScript",
                        response: bundleResponse,
                        data: bundleData,
                        isBundle: true
                    )))
                    return
                }
                let secrets = Self.extractTimezoneSecrets(from: script)
                completion(.success((appID: appID, secrets: secrets)))
            }.resume()
        }.resume()
    }

    private static func appIDDiscoveryError(
        stage: String,
        response: URLResponse?,
        data: Data?,
        isBundle: Bool
    ) -> QobuzStreamingError {
        let httpStatus = (response as? HTTPURLResponse).map { String($0.statusCode) } ?? "unavailable"
        let responseURL = response?.url.map { "\($0.host ?? "unknown host")\($0.path)" } ?? "unavailable"
        let contentType = response?.mimeType ?? "unknown"
        let byteCount = data?.count ?? 0
        let preview = responsePreview(data, contentType: contentType, isBundle: isBundle)
        let details = [
            "HTTP status: \(httpStatus)",
            "URL: \(responseURL)",
            "Content type: \(contentType)",
            "Response size: \(byteCount) bytes",
            "Response details: \(preview)"
        ].joined(separator: "\n")
        return .appIDDiscoveryFailed(stage: stage, details: details)
    }

    private static func responsePreview(_ data: Data?, contentType: String, isBundle: Bool) -> String {
        guard let data = data else { return "No response body." }
        guard let body = String(data: data, encoding: .utf8) else { return "Response body is not UTF-8 text." }
        let looksLikeHTML = contentType.localizedCaseInsensitiveContains("html")
            || body.range(of: #"(?is)<(?:!doctype\s+html|html\b|title\b|body\b)"#, options: .regularExpression) != nil

        if isBundle && !looksLikeHTML {
            let hasAppIDMarker = body.range(of: "appId", options: .caseInsensitive) != nil
            let hasProductionMarker = body.range(of: "production", options: .caseInsensitive) != nil
            let hasAppSecretMarker = body.range(of: "appSecret", options: .caseInsensitive) != nil
            return "JavaScript markers — appId: \(hasAppIDMarker ? "present" : "absent"), production: \(hasProductionMarker ? "present" : "absent"), appSecret: \(hasAppSecretMarker ? "present" : "absent"). Script content omitted to protect signing secrets."
        }

        let title = firstCapture(pattern: #"(?is)<title\b[^>]*>(.*?)</title\s*>"#, in: body)
        var visibleText = body
        for pattern in [#"(?is)<script\b[^>]*>.*?</script\s*>"#, #"(?is)<style\b[^>]*>.*?</style\s*>"#, #"(?is)<input\b[^>]*>"#] {
            visibleText = visibleText.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        visibleText = visibleText.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        visibleText = redactSensitiveValues(in: visibleText)
        let textPreview = String(visibleText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ").prefix(280))
        let safeTitle = title.map { String(redactSensitiveValues(in: $0).prefix(100)) }
        let bundleReference = firstCapture(
            pattern: #"(?is)<script\b[^>]*\bsrc\s*=\s*["']([^"']*bundle\.js[^"']*)["'][^>]*>"#,
            in: body
        )?.components(separatedBy: "?").first.map { "player bundle reference: \($0)" }
        let details = [
            safeTitle.map { "title: \($0)" },
            bundleReference,
            textPreview.isEmpty ? nil : "page text: \(textPreview)"
        ]
        .compactMap { $0 }
        .joined(separator: "; ")
        return details.isEmpty ? "No visible page text." : details
    }

    private static func redactSensitiveValues(in text: String) -> String {
        let pattern = #"(?i)\b(appsecret|access[-_]?token|user[-_]?auth[-_]?token|token|secret|password|authorization|cookie|csrf)\b["']?\s*[:=]\s*["']?[^"'\s<>,;&}]+["']?"#
        return text.replacingOccurrences(of: pattern, with: "$1=[redacted]", options: .regularExpression)
    }

    private func findActiveSecret(
        _ secrets: [String],
        appID: String,
        cachedSecret: String?,
        resolution: QobuzResolution,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        if let cachedSecret = cachedSecret {
            resolution.report("Using cached Qobuz signing configuration…")
            completion(.success(cachedSecret))
            return
        }
        var lastError: Error?
        func probe(_ index: Int) {
            guard !resolution.isFinished else { return }
            guard index < secrets.count else {
                if let lastError = lastError {
                    completion(.failure(QobuzStreamingError.secretProbesFailed(
                        count: secrets.count,
                        lastError: lastError.localizedDescription
                    )))
                } else {
                    completion(.failure(QobuzStreamingError.secretsNotFound))
                }
                return
            }
            resolution.report("Checking signing secret \(index + 1) of \(secrets.count)…")
            requestTrackURL(trackID: Self.secretProbeTrackID, appID: appID, secret: secrets[index], quality: .mp3) { result in
                guard !resolution.isFinished else { return }
                switch result {
                case .success:
                    QobuzWebPlayerCache.saveActiveSecret(secrets[index], appID: appID)
                    completion(.success(secrets[index]))
                case .failure(let error):
                    guard Self.isSigningRejection(error) else {
                        completion(.failure(error))
                        return
                    }
                    lastError = error
                    resolution.report("Secret \(index + 1) failed: \(error.localizedDescription)")
                    probe(index + 1)
                }
            }
        }
        probe(0)
    }

    private func requestTrackURL(
        trackID: Int64,
        appID: String,
        secret: String,
        quality: QobuzStreamQuality,
        completion: @escaping (Result<QobuzTrackURL, Error>) -> Void
    ) {
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let signature = Self.requestSignature(trackID: trackID, timestamp: timestamp, secret: secret, quality: quality)
        var components = URLComponents(url: Self.apiBase.appendingPathComponent("track/getFileUrl"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "request_ts", value: timestamp),
            URLQueryItem(name: "request_sig", value: signature),
            URLQueryItem(name: "track_id", value: String(trackID)),
            URLQueryItem(name: "format_id", value: String(quality.rawValue)),
            URLQueryItem(name: "intent", value: "stream")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = Self.requestTimeout
        request.setValue(appID, forHTTPHeaderField: "X-App-Id")
        request.setValue(credentials.userAuthToken, forHTTPHeaderField: "X-User-Auth-Token")
        request.setValue("x-app-id,x-user-auth-token", forHTTPHeaderField: "Access-Control-Request-Headers")
        request.setValue("en,en-US;q=0.8,ko;q=0.6,zh;q=0.4,zh-CN;q=0.2", forHTTPHeaderField: "Accept-Language")
        session.dataTask(with: request) { data, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data, let http = response as? HTTPURLResponse else {
                completion(.failure(QobuzStreamingError.invalidResponse))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                if Self.isSigningRejectionResponse(data) {
                    completion(.failure(QobuzStreamingError.signingRejected))
                } else {
                    completion(.failure(QobuzStreamingError.api("Qobuz stream request failed (HTTP \(http.statusCode)).")))
                }
                return
            }
            do {
                let stream = try JSONDecoder().decode(QobuzTrackURL.self, from: data)
                guard stream.url.scheme?.lowercased() == "https" else { throw QobuzStreamingError.invalidResponse }
                completion(.success(stream))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func isSigningRejection(_ error: Error) -> Bool {
        guard let error = error as? QobuzStreamingError else { return false }
        if case .signingRejected = error { return true }
        return false
    }

    private static func isSigningRejectionResponse(_ data: Data) -> Bool {
        guard let body = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        let explicitMessages = [
            "invalid signature", "signature is invalid", "signature mismatch",
            "signature does not match", "incorrect signature", "signature rejected",
            "invalid request signature"
        ]
        if explicitMessages.contains(where: body.contains) { return true }

        guard let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        let signingErrorCodes: Set<String> = ["invalid_signature", "signature_invalid", "invalid_sig", "invalid_request_sig"]
        func containsSigningCode(_ value: Any) -> Bool {
            if let string = value as? String, signingErrorCodes.contains(string.lowercased()) { return true }
            if let values = value as? [Any] { return values.contains(where: containsSigningCode) }
            if let dictionary = value as? [String: Any] { return dictionary.values.contains(where: containsSigningCode) }
            return false
        }
        return containsSigningCode(object)
    }

    private static func extractTimezoneSecrets(from script: String) -> [String] {
        let seedPattern = #"[a-z]\.initialSeed\("([\w=]+)",window\.utimezone\.([a-z]+)\)"#
        guard let seedRegex = try? NSRegularExpression(pattern: seedPattern) else { return [] }
        let source = script as NSString
        let fullRange = NSRange(location: 0, length: source.length)
        var secrets: [String] = []

        for seedMatch in seedRegex.matches(in: script, range: fullRange) where seedMatch.numberOfRanges >= 3 {
            let seed = source.substring(with: seedMatch.range(at: 1))
            let zoneName = source.substring(with: seedMatch.range(at: 2))
            let capitalizedZone = zoneName.prefix(1).uppercased() + zoneName.dropFirst()
            let detailPattern = #"name:"\w+/"# + NSRegularExpression.escapedPattern(for: capitalizedZone) + #"[a-z]?",info:"([\w=]+)",extras:"([\w=]+)""#
            guard let detailRegex = try? NSRegularExpression(pattern: detailPattern) else { continue }

            for match in detailRegex.matches(in: script, range: fullRange) where match.numberOfRanges >= 3 {
                let encoded = seed + source.substring(with: match.range(at: 1)) + source.substring(with: match.range(at: 2))
                guard encoded.utf8.count > 44 else { continue }
                var base64 = String(encoded.dropLast(44)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                while base64.count % 4 != 0 { base64.append("=") }
                guard let bytes = Data(base64Encoded: base64), let secret = String(data: bytes, encoding: .utf8),
                      !secrets.contains(secret) else { continue }
                secrets.append(secret)
            }
        }
        return secrets
    }

    static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func requestSignature(trackID: Int64, timestamp: String, secret: String, quality: QobuzStreamQuality = .mp3) -> String {
        let signedText = "trackgetFileUrlformat_id\(quality.rawValue)intentstreamtrack_id\(trackID)\(timestamp)\(secret)"
        let bytes = Array(signedText.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = CC_MD5(bytes, CC_LONG(bytes.count), &digest)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Tracks progress by actual returned item count, not the requested limit (the API may cap it).
/// Refuse a stuck/truncated server page instead of returning an apparently complete library.
private struct QobuzCatalogAccumulator<Item: Decodable> {
    private(set) var items: [Item] = []
    private var seen = Set<String>()
    private var done = false
    private var nextOffset = 0
    var pendingOffset: Int? { done ? nil : nextOffset }

    mutating func append(
        _ page: QobuzCatalogPage<Item>?,
        requestedOffset: Int,
        requestedLimit: Int,
        id: (Item) -> String
    ) throws {
        guard !done else { return }
        guard let page = page else {
            guard requestedOffset == 0 else { throw QobuzStreamingError.api("Qobuz omitted an unfinished catalog page.") }
            done = true
            return
        }
        if let returnedOffset = page.offset, returnedOffset != requestedOffset {
            throw QobuzStreamingError.api("Qobuz did not honor the catalog pagination offset.")
        }
        let newItems = page.items.filter { seen.insert(id($0)).inserted }
        let endOffset = requestedOffset + page.items.count
        let more: Bool
        if let hasMore = page.hasMore { more = hasMore }
        else if let total = page.total { more = endOffset < total }
        else { more = page.items.count >= max(1, page.limit ?? requestedLimit) }
        guard !more || (!newItems.isEmpty && endOffset > nextOffset) else {
            throw QobuzStreamingError.api("Qobuz catalog pagination stopped before all items were returned.")
        }
        // Even a terminal repeated page must not silently claim the library is complete.
        guard requestedOffset == 0 || page.items.isEmpty || !newItems.isEmpty else {
            throw QobuzStreamingError.api("Qobuz returned a repeated catalog page.")
        }
        items += newItems
        nextOffset = endOffset
        done = !more
    }
}
