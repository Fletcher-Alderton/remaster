import CommonCrypto
import Foundation
import Security

// Qobuz streaming protocol ported from SofusA/qobine (GPL-3.0).
// Modified for this iOS app on 2026-07-11. See THIRD_PARTY_NOTICES.md.
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
        let name: String?
    }

    struct Album: Codable {
        let title: String?
    }

    let id: Int64
    let title: String
    let duration: Int?
    let performer: Performer?
    let album: Album?

    var subtitle: String {
        [performer?.name, album?.title].compactMap { $0 }.joined(separator: " • ")
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
    case appIDNotFound
    case secretsNotFound
    case resolutionTimedOut
    case secretProbesFailed(count: Int, lastError: String)
    case unauthorized
    case api(String)
    case invalidTrackID
    case emptySearchQuery
    case invalidCallback
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Qobuz returned an invalid response."
        case .appIDNotFound: return "Could not find the Qobuz web player app ID."
        case .secretsNotFound: return "Could not find the active Qobuz signing secret."
        case .resolutionTimedOut: return "Qobuz stream resolution timed out. Check your connection and try again."
        case .secretProbesFailed(let count, let lastError):
            return "None of the \(count) Qobuz signing secrets worked. Last probe error: \(lastError)"
        case .unauthorized: return "Qobuz rejected the sign-in or stream request."
        case .api(let message): return message
        case .invalidTrackID: return "Enter a numeric Qobuz track ID."
        case .emptySearchQuery: return "Enter a song title or artist to search Qobuz."
        case .invalidCallback: return "Qobuz sign-in did not return an authorization code."
        case .keychain(let status): return "Could not securely store Qobuz credentials (Keychain error \(status))."
        }
    }
}

/// Stores the OAuth token in the system Keychain rather than app preferences.
final class QobuzCredentialStore {
    private let service = Bundle.main.bundleIdentifier ?? "com.fletcher.MusicPrototype"
    private let account = "qobuz.credentials"
    #if targetEnvironment(simulator)
    private var simulatorSessionCredentials: QobuzCredentials?
    #endif
    private(set) var isSessionOnly = false

    func load() -> QobuzCredentials? {
        let service = Bundle.main.bundleIdentifier ?? "com.fletcher.MusicPrototype"
        let account = "qobuz.credentials"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.fletcher.MusicPrototype",
            kSecAttrAccount as String: "qobuz.credentials",
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
        let service = Bundle.main.bundleIdentifier ?? "com.fletcher.MusicPrototype"
        let account = "qobuz.credentials"
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
    private static let keyPrefix = "qobuz.search.v1."
    private static let expirationInterval: TimeInterval = 15 * 60

    private static func cacheKey(query: String) -> String {
        let bytes = Array(query.lowercased().utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = CC_MD5(bytes, CC_LONG(bytes.count), &digest)
        return keyPrefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func load(query: String) -> [QobuzSearchTrack]? {
        let key = cacheKey(query: query)
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(QobuzCachedSearch.self, from: data),
              Date().timeIntervalSince(cached.cachedAt) < expirationInterval else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return cached.tracks
    }

    static func save(_ tracks: [QobuzSearchTrack], query: String) {
        let key = cacheKey(query: query)
        guard let data = try? JSONEncoder().encode(QobuzCachedSearch(tracks: tracks, cachedAt: Date())) else { return }
        UserDefaults.standard.set(data, forKey: key)
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
final class QobuzStreamingClient {
    private static let apiBase = URL(string: "https://www.qobuz.com/api.json/0.2/")!
    private static let playBase = URL(string: "https://play.qobuz.com")!
    private static let oauthPrivateKey = "6lz8C03UDIC7"
    private static let secretProbeTrackID: Int64 = 64_868_955
    private static let requestTimeout: TimeInterval = 12

    private let credentials: QobuzCredentials
    private let session: URLSession
    private let resolutionTimeout: TimeInterval

    init(credentials: QobuzCredentials, session: URLSession = .shared, resolutionTimeout: TimeInterval = 45) {
        self.credentials = credentials
        self.session = session
        self.resolutionTimeout = resolutionTimeout
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
        if let cachedTracks = QobuzSearchCache.load(query: trimmedQuery) {
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
                        QobuzSearchCache.save(search.tracks.items, query: trimmedQuery)
                        completion(.success(search.tracks.items))
                    } catch {
                        completion(.failure(error))
                    }
                }.resume()
            }
        }
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
                            guard case .failure = result,
                                  playerInfo.activeSecret == secret else {
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
        var request = URLRequest(url: Self.playBase.appendingPathComponent("login"))
        request.timeoutInterval = Self.requestTimeout
        session.dataTask(with: request) { [weak self] data, _, error in
            guard let self = self else { return }
            if let error = error { completion(.failure(error)); return }
            guard let data = data, let html = String(data: data, encoding: .utf8),
                  let bundlePath = Self.firstCapture(
                    pattern: #"<script src="(/resources/\d+\.\d+\.\d+-[a-z0-9]\d{3}/bundle\.js)"></script>"#,
                    in: html
                  ) else {
                completion(.failure(QobuzStreamingError.appIDNotFound))
                return
            }
            let bundleURL = Self.playBase.appendingPathComponent(String(bundlePath.dropFirst()))
            var bundleRequest = URLRequest(url: bundleURL)
            bundleRequest.timeoutInterval = Self.requestTimeout
            self.session.dataTask(with: bundleRequest) { bundleData, _, bundleError in
                if let bundleError = bundleError { completion(.failure(bundleError)); return }
                guard let bundleData = bundleData, let script = String(data: bundleData, encoding: .utf8),
                      let appID = Self.firstCapture(
                        pattern: #"production:\{api:\{appId:"(\d{9})",appSecret:"\w{32}""#,
                        in: script
                      ) else {
                    completion(.failure(QobuzStreamingError.appIDNotFound))
                    return
                }
                let secrets = Self.extractTimezoneSecrets(from: script)
                QobuzWebPlayerCache.save(appID: appID, secrets: secrets)
                completion(.success(WebPlayerInfo(appID: appID, secrets: secrets, activeSecret: nil)))
            }.resume()
        }.resume()
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
                completion(.failure(QobuzStreamingError.api("Qobuz stream request failed (HTTP \(http.statusCode)).")))
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
