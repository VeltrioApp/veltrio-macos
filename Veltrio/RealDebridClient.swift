import Foundation

/// Native Swift Real-Debrid client. Lives outside the Rust core because
/// the whole thing is HTTP + JSON and Swift gets the job done without a
/// bindgen round-trip. API docs: https://api.real-debrid.com/
///
/// Flows:
/// - OAuth 2 device code: no API-key paste. User visits a URL, enters the
///   code, we poll for a token.
/// - Resolve: `instantAvailability` → `addMagnet` → `selectFiles` →
///   `/torrents/info` → `unrestrict/link`.

struct RdDeviceCode: Equatable {
    let deviceCode: String
    let userCode: String
    let verificationUrl: String
    let interval: Int
    let expiresInSeconds: Int
}

struct RdUser: Equatable {
    let username: String
    let email: String
    let type: String      // "premium" | "free"
    var isPremium: Bool { type == "premium" }
}

enum RdError: Error {
    case network(String)
    case decode(String)
    case authPending
    case authSlowDown
    case tokenRejected(String)
    case notReady
    case apiError(code: Int, message: String)
}

/// Public anonymous Stremio-compatible Real-Debrid OAuth client id. This
/// is the same id many third-party Stremio clients use — no secret,
/// public-flow friendly.
private let kRdOpenClientId = "X245A4XAIBGVM"

@MainActor
final class RealDebridClient {
    private let base  = URL(string: "https://api.real-debrid.com/rest/1.0")!
    private let oauth = URL(string: "https://api.real-debrid.com/oauth/v2")!
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Device code flow

    func startDeviceAuth() async throws -> RdDeviceCode {
        var req = URLRequest(url: oauth.appendingPathComponent("device/code"))
        req.httpMethod = "GET"
        req.url = req.url?.appending(queryItems: [
            .init(name: "client_id",   value: kRdOpenClientId),
            .init(name: "new_credentials", value: "yes")
        ])
        let (data, _) = try await session.data(for: req)
        struct R: Decodable {
            let device_code: String
            let user_code: String
            let interval: Int
            let expires_in: Int
            let verification_url: String
        }
        guard let d = try? JSONDecoder().decode(R.self, from: data) else {
            throw RdError.decode("device/code response malformed")
        }
        return RdDeviceCode(
            deviceCode: d.device_code,
            userCode: d.user_code,
            verificationUrl: d.verification_url,
            interval: max(5, d.interval),
            expiresInSeconds: d.expires_in
        )
    }

    /// Poll for app credentials, then exchange for an access token. Returns
    /// the long-lived token on success, throws `.authPending` to signal
    /// the caller to keep polling, or `.tokenRejected` on hard failure.
    func pollDeviceAuth(deviceCode: String) async throws -> String {
        // Phase 1: credentials
        var req = URLRequest(url: oauth.appendingPathComponent("device/credentials"))
        req.url = req.url?.appending(queryItems: [
            .init(name: "client_id", value: kRdOpenClientId),
            .init(name: "code",      value: deviceCode)
        ])
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 403 {
            // Not yet entered — keep polling.
            throw RdError.authPending
        }
        struct Creds: Decodable { let client_id: String; let client_secret: String }
        guard let c = try? JSONDecoder().decode(Creds.self, from: data) else {
            throw RdError.authPending
        }

        // Phase 2: exchange for access token.
        var tokenReq = URLRequest(url: oauth.appendingPathComponent("token"))
        tokenReq.httpMethod = "POST"
        let body = [
            "client_id": c.client_id,
            "client_secret": c.client_secret,
            "code": deviceCode,
            "grant_type": "http://oauth.net/grant_type/device/1.0"
        ]
        tokenReq.httpBody = Self.formEncode(body)
        tokenReq.setValue("application/x-www-form-urlencoded",
                          forHTTPHeaderField: "Content-Type")
        let (tdata, _) = try await session.data(for: tokenReq)
        struct Tok: Decodable { let access_token: String? ; let error: String? }
        if let t = try? JSONDecoder().decode(Tok.self, from: tdata),
           let token = t.access_token {
            return token
        }
        throw RdError.tokenRejected(String(data: tdata, encoding: .utf8) ?? "unknown")
    }

    // MARK: - User info

    func userInfo(token: String) async throws -> RdUser {
        let data = try await authedGet(path: "user", token: token)
        struct R: Decodable {
            let username: String
            let email: String
            let type: String
        }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else {
            throw RdError.decode("user")
        }
        return RdUser(username: r.username, email: r.email, type: r.type)
    }

    // MARK: - Availability

    /// Batched instant-availability check. Returns a dict of lowercased
    /// infohash → is-cached. Real-Debrid's response groups variants per
    /// hash; any non-empty variant list = cached.
    func checkAvailability(hashes: [String], token: String) async throws -> [String: Bool] {
        guard !hashes.isEmpty else { return [:] }
        let joined = hashes.joined(separator: "/")
        let data = try await authedGet(
            path: "torrents/instantAvailability/\(joined)",
            token: token
        )
        var out: [String: Bool] = [:]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return out
        }
        for (hash, value) in root {
            let lower = hash.lowercased()
            if let dict = value as? [String: Any] {
                // Any non-empty host dict = cached.
                let cached = dict.values.contains { entry in
                    if let arr = entry as? [[String: Any]] { return !arr.isEmpty }
                    return false
                }
                out[lower] = cached
            } else {
                out[lower] = false
            }
        }
        return out
    }

    // MARK: - Resolve

    /// Full magnet → playable HTTPS URL pipeline. For a given infohash +
    /// optional season/episode (so we pick the right file in a pack), we:
    /// 1. addMagnet → torrent id
    /// 2. select best file (episode-aware match if S/E given, else biggest)
    /// 3. GET /torrents/info/<id> → wait for `links` list
    /// 4. unrestrict/link → direct HTTPS URL
    func resolveStream(
        infoHash: String,
        season: Int32?,
        episode: Int32?,
        token: String
    ) async throws -> String {
        let magnet = "magnet:?xt=urn:btih:\(infoHash)"
        let added = try await addMagnet(magnet: magnet, token: token)
        let torrentId = added.id

        // Wait for file list.
        var info = try await torrentInfo(id: torrentId, token: token)
        var waited = 0
        while info.files.isEmpty, waited < 10 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            info = try await torrentInfo(id: torrentId, token: token)
            waited += 1
        }

        let pick = pickFile(from: info.files, season: season, episode: episode)
        guard let pick else { throw RdError.notReady }

        _ = try await selectFiles(id: torrentId, fileIds: [pick.id], token: token)

        // Wait for downloaded links.
        info = try await torrentInfo(id: torrentId, token: token)
        waited = 0
        while info.links.isEmpty, waited < 10 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            info = try await torrentInfo(id: torrentId, token: token)
            waited += 1
        }
        guard let firstLink = info.links.first else { throw RdError.notReady }

        return try await unrestrict(link: firstLink, token: token)
    }

    private struct AddResp: Decodable { let id: String; let uri: String }
    private struct TorrentFile: Decodable {
        let id: Int
        let path: String
        let bytes: Int
        let selected: Int
    }
    private struct TorrentInfo: Decodable {
        let id: String
        let filename: String
        let status: String
        let links: [String]
        let files: [TorrentFile]
    }

    private func addMagnet(magnet: String, token: String) async throws -> AddResp {
        var req = URLRequest(url: base.appendingPathComponent("torrents/addMagnet"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(["magnet": magnet])
        let (data, _) = try await session.data(for: req)
        guard let r = try? JSONDecoder().decode(AddResp.self, from: data) else {
            throw RdError.decode("addMagnet")
        }
        return r
    }

    private func torrentInfo(id: String, token: String) async throws -> TorrentInfo {
        let data = try await authedGet(path: "torrents/info/\(id)", token: token)
        guard let r = try? JSONDecoder().decode(TorrentInfo.self, from: data) else {
            throw RdError.decode("torrents/info")
        }
        return r
    }

    private func selectFiles(id: String, fileIds: [Int], token: String) async throws -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("torrents/selectFiles/\(id)"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        let body = ["files": fileIds.map(String.init).joined(separator: ",")]
        req.httpBody = Self.formEncode(body)
        let (_, resp) = try await session.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode == 204
    }

    private func unrestrict(link: String, token: String) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("unrestrict/link"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(["link": link])
        let (data, _) = try await session.data(for: req)
        struct R: Decodable { let download: String }
        guard let r = try? JSONDecoder().decode(R.self, from: data) else {
            throw RdError.decode("unrestrict")
        }
        return r.download
    }

    private func pickFile(
        from files: [TorrentFile], season: Int32?, episode: Int32?
    ) -> TorrentFile? {
        DebridFilePicker.pick(files, path: \.path, size: { Int64($0.bytes) }, season: season, episode: episode)
    }

    // MARK: - Helpers

    private func authedGet(path: String, token: String) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RdError.apiError(code: http.statusCode, message: body)
        }
        return data
    }

    private static func formEncode(_ pairs: [String: String]) -> Data {
        pairs.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(ek)=\(ev)"
        }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
    }
}
