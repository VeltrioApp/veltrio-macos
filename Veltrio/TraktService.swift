import Foundation
import Observation

/// Lightweight Trakt.tv integration. Uses the public OAuth2 device code
/// flow (no secret needed from the user) and exposes a scrobbler so the
/// player can post `start`, `pause`, `stop` when watching movies or
/// episodes identified by their IMDb id.
///
/// Docs: https://trakt.docs.apiary.io/#reference/authentication-oauth
///
/// This is a *best-effort* integration: every network error is swallowed
/// rather than surfaced — Trakt is a convenience, not a gate for watching.

struct TraktDeviceCode: Equatable {
    let deviceCode: String
    let userCode: String
    let verificationUrl: String
    let interval: Int
    let expiresInSeconds: Int
}

struct TraktUser: Equatable {
    let username: String
    let name: String?
    let isVip: Bool
}

@MainActor
@Observable
final class TraktService {
    /// Public Trakt API client id (same id used by stremio-trakt-scrobbler,
    /// trakt-cli, etc.). Allows the device flow without shipping a secret.
    private let clientId = "4087ac4d3cfa5c0c9d5fe31056cb19e4e1b30a73b04bed79e51d1c6b0ebc7c8e"

    private(set) var accessToken: String?
    private(set) var user: TraktUser?
    private(set) var pendingDevice: TraktDeviceCode?
    private(set) var isConnecting = false
    private(set) var connectionError: String?

    private var pollTask: Task<Void, Never>?
    private let session: URLSession

    var isConnected: Bool { accessToken != nil }

    private let keychainService = "com.veltrio.trakt.token"

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
        self.accessToken = Keychain.get(service: keychainService)
        if let tok = accessToken {
            Task { [weak self] in
                let u = try? await self?.fetchUser(token: tok)
                await MainActor.run { self?.user = u }
            }
        }
    }

    // MARK: - Device code flow

    func startDeviceAuth() async {
        connectionError = nil
        pollTask?.cancel()
        isConnecting = true
        defer { isConnecting = false }
        do {
            let code = try await requestDeviceCode()
            pendingDevice = code
            pollTask = Task { [weak self] in await self?.pollToken(code: code) }
        } catch {
            connectionError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    func cancelDeviceAuth() {
        pollTask?.cancel()
        pollTask = nil
        pendingDevice = nil
    }

    func disconnect() {
        Keychain.delete(service: keychainService)
        accessToken = nil
        user = nil
    }

    private func requestDeviceCode() async throws -> TraktDeviceCode {
        var req = URLRequest(url: URL(string: "https://api.trakt.tv/oauth/device/code")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["client_id": clientId]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await session.data(for: req)
        struct R: Decodable {
            let device_code: String
            let user_code: String
            let verification_url: String
            let expires_in: Int
            let interval: Int
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        return TraktDeviceCode(
            deviceCode: r.device_code,
            userCode: r.user_code,
            verificationUrl: r.verification_url,
            interval: max(5, r.interval),
            expiresInSeconds: r.expires_in
        )
    }

    private func pollToken(code: TraktDeviceCode) async {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresInSeconds))
        let interval = UInt64(code.interval) * 1_000_000_000
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: interval)
            if Task.isCancelled { return }
            do {
                if let token = try await exchangeToken(deviceCode: code.deviceCode) {
                    let u = try? await fetchUser(token: token)
                    guard self.pendingDevice?.deviceCode == code.deviceCode else { return }
                    Keychain.set(token, service: keychainService)
                    self.accessToken = token
                    self.user = u
                    self.pendingDevice = nil
                    return
                }
            } catch { continue }
        }
        guard self.pendingDevice?.deviceCode == code.deviceCode else { return }
        self.pendingDevice = nil
        self.connectionError = String(localized: "Trakt code expired. Try again.")
    }

    private func exchangeToken(deviceCode: String) async throws -> String? {
        var req = URLRequest(url: URL(string: "https://api.trakt.tv/oauth/device/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "code": deviceCode,
            "client_id": clientId,
            "client_secret": ""     // device flow with blank secret works on Trakt
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 404 {
            // 400 = pending; 404 = not yet authorized. Keep polling.
            return nil
        }
        struct R: Decodable { let access_token: String? }
        return try JSONDecoder().decode(R.self, from: data).access_token
    }

    private func fetchUser(token: String) async throws -> TraktUser {
        let data = try await authedGet(path: "users/me?extended=full", token: token)
        struct R: Decodable {
            let username: String
            let name: String?
            let vip: Bool?
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        return TraktUser(username: r.username, name: r.name, isVip: r.vip ?? false)
    }

    // MARK: - Scrobbler

    enum ScrobbleAction: String {
        case start, pause, stop
        var path: String { "scrobble/\(rawValue)" }
    }

    /// Fire a scrobble event. `imdbId` is the title's IMDb id (tt1234567),
    /// `season`/`episode` only for series. `progress` is a 0–100 float.
    /// Silent on every error: Trakt failing shouldn't ever bubble a toast.
    func scrobble(
        action: ScrobbleAction,
        imdbId: String,
        season: Int32?,
        episode: Int32?,
        progress: Double
    ) async {
        guard let token = accessToken else { return }
        var body: [String: Any] = ["progress": max(0, min(100, progress))]
        if let s = season, let e = episode {
            body["episode"] = [
                "season": Int(s),
                "number": Int(e)
            ]
            body["show"] = ["ids": ["imdb": imdbId.split(separator: ":").first.map(String.init) ?? imdbId]]
        } else {
            body["movie"] = ["ids": ["imdb": imdbId]]
        }
        do {
            var req = URLRequest(url: URL(string: "https://api.trakt.tv/\(action.path)")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)",         forHTTPHeaderField: "Authorization")
            req.setValue("application/json",        forHTTPHeaderField: "Content-Type")
            req.setValue("2",                       forHTTPHeaderField: "trakt-api-version")
            req.setValue(clientId,                  forHTTPHeaderField: "trakt-api-key")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            _ = try await session.data(for: req)
        } catch {
            // Silent on purpose.
        }
    }

    // MARK: - Helpers

    private func authedGet(path: String, token: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://api.trakt.tv/\(path)")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2",               forHTTPHeaderField: "trakt-api-version")
        req.setValue(clientId,          forHTTPHeaderField: "trakt-api-key")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw NSError(domain: "trakt", code: http.statusCode)
        }
        return data
    }
}
