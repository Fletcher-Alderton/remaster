import AppKit
import CryptoKit
import Foundation

enum LastFMError: LocalizedError {
    case invalidResponse
    case api(code: Int, message: String)
    case missingCredentials

    var isAuthorizationPending: Bool {
        if case .api(let code, _) = self { return code == 14 }
        return false
    }

    var isInvalidSignature: Bool {
        if case .api(let code, _) = self { return code == 13 }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Last.fm returned an unreadable response."
        case .api(let code, let message): return "Last.fm error \(code): \(message)"
        case .missingCredentials: return "Enter your Last.fm API key and shared secret first."
        }
    }
}

struct LastFMClient {
    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    func requestToken(apiKey: String, sharedSecret: String) async throws -> String {
        let json = try await request(
            method: "auth.getToken",
            parameters: ["api_key": apiKey],
            apiKey: apiKey,
            sharedSecret: sharedSecret,
            sessionKey: nil
        )
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw LastFMError.invalidResponse
        }
        return token
    }

    func requestSession(
        token: String,
        apiKey: String,
        sharedSecret: String
    ) async throws -> LastFMSession {
        let json = try await request(
            method: "auth.getSession",
            parameters: ["api_key": apiKey, "token": token],
            apiKey: apiKey,
            sharedSecret: sharedSecret,
            sessionKey: nil
        )
        guard let session = json["session"] as? [String: Any],
              let name = session["name"] as? String,
              let key = session["key"] as? String else {
            throw LastFMError.invalidResponse
        }
        return LastFMSession(name: name, key: key)
    }

    func authorizationURL(apiKey: String, token: String) -> URL? {
        var components = URLComponents(string: "https://www.last.fm/api/auth/")
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token)
        ]
        return components?.url
    }

    func scrobble(
        events: [PlaybackEvent],
        apiKey: String,
        sharedSecret: String,
        sessionKey: String
    ) async throws -> [String: LastFMScrobbleResult] {
        var results: [String: LastFMScrobbleResult] = [:]
        for batch in events.chunked(into: 50) {
            var parameters: [String: String] = [
                "api_key": apiKey,
                "sk": sessionKey
            ]
            for (index, event) in batch.enumerated() {
                parameters["artist[\(index)]"] = event.artist
                parameters["track[\(index)]"] = event.title
                parameters["timestamp[\(index)]"] = String(Int(event.startedAt.timeIntervalSince1970))
                parameters["duration[\(index)]"] = String(Int(event.trackDuration.rounded()))
                parameters["chosenByUser[\(index)]"] = "1"
                if !event.album.isEmpty {
                    parameters["album[\(index)]"] = event.album
                }
                if !event.albumArtist.isEmpty {
                    parameters["albumArtist[\(index)]"] = event.albumArtist
                }
                if let trackNumber = event.trackNumber {
                    parameters["trackNumber[\(index)]"] = String(trackNumber)
                }
            }
            let json = try await request(
                method: "track.scrobble",
                parameters: parameters,
                apiKey: apiKey,
                sharedSecret: sharedSecret,
                sessionKey: sessionKey,
                usePOST: true
            )
            let responses = Self.scrobbleObjects(from: json)
            guard responses.count == batch.count else {
                throw LastFMError.invalidResponse
            }
            for (index, event) in batch.enumerated() {
                let ignored = (responses[index]["ignoredMessage"] as? [String: Any])
                    ?? (responses[index]["ignoredmessage"] as? [String: Any])
                let code = (ignored?["code"] as? String) ?? String(ignored?["code"] as? Int ?? 0)
                let text = (ignored?["#text"] as? String) ?? ""
                results[event.id] = code == "0" ? .accepted : .ignored(text.isEmpty ? "Last.fm ignored this play." : text)
            }
        }
        return results
    }

    private func request(
        method: String,
        parameters: [String: String],
        apiKey: String,
        sharedSecret: String,
        sessionKey: String?,
        usePOST: Bool = false
    ) async throws -> [String: Any] {
        guard !apiKey.isEmpty, !sharedSecret.isEmpty else {
            throw LastFMError.missingCredentials
        }
        var signedParameters = parameters
        signedParameters["method"] = method
        if let sessionKey {
            signedParameters["sk"] = sessionKey
        }
        signedParameters["api_sig"] = Self.signature(
            parameters: signedParameters,
            sharedSecret: sharedSecret
        )
        signedParameters["format"] = "json"

        let request: URLRequest
        if usePOST {
            var mutable = URLRequest(url: endpoint)
            mutable.httpMethod = "POST"
            mutable.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            mutable.httpBody = Self.formEncoded(signedParameters).data(using: .utf8)
            request = mutable
        } else {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = signedParameters
                .sorted(by: { $0.key < $1.key })
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            request = URLRequest(url: components.url!)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LastFMError.invalidResponse
        }
        return try Self.decodeResponse(data: data, httpStatus: http.statusCode)
    }

    static func decodeResponse(data: Data, httpStatus: Int) throws -> [String: Any] {
        // Last.fm explicitly requires clients to inspect the response body
        // even when the HTTP status is not 200. Authentication errors such as
        // an unapproved token commonly arrive as HTTP 403 with valid JSON.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LastFMError.invalidResponse
        }
        if let errorNumber = json["error"] as? NSNumber,
           let message = json["message"] as? String {
            throw LastFMError.api(code: errorNumber.intValue, message: message)
        }
        if let errorText = json["error"] as? String,
           let errorCode = Int(errorText),
           let message = json["message"] as? String {
            throw LastFMError.api(code: errorCode, message: message)
        }
        guard (200..<300).contains(httpStatus) else {
            throw LastFMError.invalidResponse
        }
        return json
    }

    static func signature(parameters: [String: String], sharedSecret: String) -> String {
        let payload = parameters
            .filter { $0.key != "format" && $0.key != "callback" }
            .sorted(by: { $0.key < $1.key })
            .map { $0.key + $0.value }
            .joined() + sharedSecret
        let digest = Insecure.MD5.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func formEncoded(_ parameters: [String: String]) -> String {
        parameters
            .sorted(by: { $0.key < $1.key })
            .map { percentEncode($0.key) + "=" + percentEncode($0.value) }
            .joined(separator: "&")
    }

    private static func percentEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func scrobbleObjects(from json: [String: Any]) -> [[String: Any]] {
        guard let scrobbles = json["scrobbles"] as? [String: Any] else { return [] }
        if let array = scrobbles["scrobble"] as? [[String: Any]] { return array }
        if let single = scrobbles["scrobble"] as? [String: Any] { return [single] }
        return []
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
