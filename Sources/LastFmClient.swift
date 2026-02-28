import Foundation
import CryptoKit

struct LastFmError: Error {
    let code: Int?
    let message: String
}

final class LastFmClient {
    let apiKey: String
    let apiSecret: String
    nonisolated(unsafe) var sessionKey: String?

    private static let baseURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private static let retryableErrorCodes: Set<Int> = [11, 16]
    private static let maxRetries = 3
    private static let retryDelay: UInt64 = 2_000_000_000

    init() {
        guard let key = ProcessInfo.processInfo.environment["LASTFM_API_KEY"], !key.isEmpty else {
            fatalError("LASTFM_API_KEY environment variable not set")
        }
        guard let secret = ProcessInfo.processInfo.environment["LASTFM_API_SECRET"], !secret.isEmpty else {
            fatalError("LASTFM_API_SECRET environment variable not set")
        }
        self.apiKey = key
        self.apiSecret = secret
    }

    // MARK: - Public API

    func authenticate(username: String, password: String) async throws -> Session {
        var params: [String: String] = [
            "method": "auth.getMobileSession",
            "username": username,
            "password": password,
            "api_key": apiKey,
        ]
        params["api_sig"] = generateSignature(params)

        let json = try await post(params: params)

        guard let sessionObj = json["session"] as? [String: Any],
              let key = sessionObj["key"] as? String,
              let name = sessionObj["name"] as? String else {
            throw LastFmError(code: nil, message: "Invalid session response from Last.fm")
        }

        let session = Session(sessionKey: key, username: name)
        self.sessionKey = key
        return session
    }

    func updateNowPlaying(artist: String, track: String, album: String? = nil, duration: Int? = nil) async throws {
        guard let sk = sessionKey else {
            throw LastFmError(code: nil, message: "Not authenticated — no session key")
        }

        var params: [String: String] = [
            "method": "track.updateNowPlaying",
            "artist": artist,
            "track": track,
            "api_key": apiKey,
            "sk": sk,
        ]
        if let album { params["album"] = album }
        if let duration { params["duration"] = String(duration) }
        params["api_sig"] = generateSignature(params)

        _ = try await post(params: params)
    }

    func scrobble(artist: String, track: String, album: String? = nil, duration: Int? = nil, timestamp: Int) async throws {
        guard let sk = sessionKey else {
            throw LastFmError(code: nil, message: "Not authenticated — no session key")
        }

        var params: [String: String] = [
            "method": "track.scrobble",
            "artist[0]": artist,
            "track[0]": track,
            "timestamp[0]": String(timestamp),
            "chosenByUser": "0",
            "api_key": apiKey,
            "sk": sk,
        ]
        if let album { params["album[0]"] = album }
        if let duration { params["duration[0]"] = String(duration) }
        params["api_sig"] = generateSignature(params)

        var lastError: Error?
        for attempt in 0..<Self.maxRetries {
            do {
                _ = try await post(params: params)
                return
            } catch let error as LastFmError where error.code != nil && Self.retryableErrorCodes.contains(error.code!) {
                lastError = error
                if attempt < Self.maxRetries - 1 {
                    try await Task.sleep(nanoseconds: Self.retryDelay)
                }
            } catch let error as LastFmError where error.code == nil && error.message.hasPrefix("HTTP") {
                lastError = error
                if attempt < Self.maxRetries - 1 {
                    try await Task.sleep(nanoseconds: Self.retryDelay)
                }
            } catch {
                throw error
            }
        }

        if let lastError { throw lastError }
    }

    // MARK: - Internal

    private func generateSignature(_ params: [String: String]) -> String {
        let filtered = params.filter { $0.key != "format" && $0.key != "callback" }
        let sorted = filtered.sorted { $0.key < $1.key }
        var sigString = sorted.reduce("") { $0 + $1.key + $1.value }
        sigString += apiSecret
        let digest = Insecure.MD5.hash(data: Data(sigString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private func post(params: [String: String]) async throws -> [String: Any] {
        var bodyParams = params
        bodyParams["format"] = "json"

        let bodyString = bodyParams
            .map { key, value in
                let encodedKey = urlEncode(key)
                let encodedValue = urlEncode(value)
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")

        var request = URLRequest(url: Self.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(bodyString.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 500 {
            throw LastFmError(code: nil, message: "HTTP \(httpResponse.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LastFmError(code: nil, message: "Invalid JSON response")
        }

        if let errorCode = json["error"] as? Int, let message = json["message"] as? String {
            throw LastFmError(code: errorCode, message: message)
        }

        return json
    }

    private func urlEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
