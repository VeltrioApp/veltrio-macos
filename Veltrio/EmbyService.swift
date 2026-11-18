import Foundation
import Observation

/// Emby bridge. Emby's HTTP API is a superset of Jellyfin's (both fork
/// from the same ancestor), so we lean on the same AuthenticateByName +
/// `/Videos/{id}/stream` endpoints. Headers tweak the authorisation
/// token name (`X-Emby-Token` for streaming, like Emby's docs show).

struct EmbyItem: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let overview: String?
    let primaryImageTag: String?
    let runtimeTicks: Int64?
    let seriesName: String?
}

@MainActor
@Observable
final class EmbyService {
    private(set) var serverUrl: String = ""
    private(set) var accessToken: String?
    private(set) var userId: String?
    private(set) var username: String?
    private(set) var isConnecting = false
    private(set) var connectionError: String?
    private(set) var latestItems: [EmbyItem] = []

    private let keychainService = "com.veltrio.emby.token"
    private let defaultsKeyUrl   = "veltrio.emby.url"
    private let defaultsKeyUser  = "veltrio.emby.userId"
    private let defaultsKeyName  = "veltrio.emby.userName"

    private let session: URLSession
    private let appName = "Veltrio"
    /// Stable per install: Emby ties tokens and its device list to it.
    private let deviceId: String = {
        let key = "veltrio.emby.deviceId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "veltrio-emby-\(UUID().uuidString.prefix(12).lowercased())"
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    var isConnected: Bool { accessToken != nil && userId != nil }

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)

        let d = UserDefaults.standard
        self.serverUrl   = d.string(forKey: defaultsKeyUrl)  ?? ""
        self.userId      = d.string(forKey: defaultsKeyUser)
        self.username    = d.string(forKey: defaultsKeyName)
        self.accessToken = Keychain.get(service: keychainService)
    }

    func connect(host: String, user: String, password: String) async {
        connectionError = nil
        isConnecting = true
        defer { isConnecting = false }
        let normalized = normalizeHost(host)
        guard let probeUrl = URL(string: "\(normalized)/System/Info/Public"),
              let url = URL(string: "\(normalized)/Users/AuthenticateByName") else {
            connectionError = String(localized: "Invalid server URL")
            return
        }

        // Check an Emby server answers here before sending credentials, so
        // a wrong address isn't reported as a wrong password.
        do {
            let (data, resp) = try await session.data(from: probeUrl)
            struct Info: Decodable { let ProductName: String?; let Version: String? }
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let info = try? JSONDecoder().decode(Info.self, from: data),
                  info.Version != nil else {
                connectionError = String(localized: "No Emby server answered at \(normalized). Check the address and port (8096 by default).")
                return
            }
            if info.ProductName?.localizedCaseInsensitiveContains("jellyfin") == true {
                connectionError = String(localized: "This is a Jellyfin server. Connect it with the Jellyfin card instead.")
                return
            }
        } catch {
            connectionError = String(localized: "Couldn't reach \(normalized): \(error.localizedDescription)")
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        setAuthHeaders(on: &req, token: nil)
        let body = ["Username": user, "Pw": password]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                connectionError = String(localized: "Unexpected response from the server")
                return
            }
            guard (200...299).contains(http.statusCode) else {
                switch http.statusCode {
                case 401:
                    connectionError = String(localized: "Wrong username or password")
                case 403:
                    connectionError = String(localized: "This account isn't allowed to sign in")
                default:
                    let detail = String(data: data.prefix(200), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    connectionError = String(localized: "Emby refused the sign-in (HTTP \(http.statusCode))")
                        + (detail.isEmpty ? "" : ": \(detail)")
                }
                return
            }
            struct R: Decodable {
                let AccessToken: String
                let User: RUser
                struct RUser: Decodable { let Id: String; let Name: String }
            }
            let r = try JSONDecoder().decode(R.self, from: data)
            serverUrl = normalized
            accessToken = r.AccessToken
            userId = r.User.Id
            username = r.User.Name
            Keychain.set(r.AccessToken, service: keychainService)
            let d = UserDefaults.standard
            d.set(normalized, forKey: defaultsKeyUrl)
            d.set(r.User.Id, forKey: defaultsKeyUser)
            d.set(r.User.Name, forKey: defaultsKeyName)
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func disconnect() {
        Keychain.delete(service: keychainService)
        accessToken = nil
        userId = nil
        username = nil
        latestItems = []
        let d = UserDefaults.standard
        d.removeObject(forKey: defaultsKeyUser)
        d.removeObject(forKey: defaultsKeyName)
    }

    func streamUrl(for itemId: String) -> URL? {
        guard let token = accessToken else { return nil }
        return URL(string: "\(serverUrl)/Videos/\(itemId)/stream?X-Emby-Token=\(token)&Static=true")
    }

    /// Search the user's library by title.
    ///
    /// Emby shares Jellyfin's API shape, so this mirrors
    /// `JellyfinService.search` — same `/Items` endpoint, same
    /// `SearchTerm` parameter.
    func search(query: String, limit: Int = 40) async -> [EmbyItem] {
        guard let token = accessToken, let uid = userId else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var comps = URLComponents(string: "\(serverUrl)/Users/\(uid)/Items")
        comps?.queryItems = [
            URLQueryItem(name: "SearchTerm", value: trimmed),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode"),
            URLQueryItem(name: "Fields", value: "Overview"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Recursive", value: "true"),
        ]
        guard let url = comps?.url else { return [] }

        var req = URLRequest(url: url)
        setAuthHeaders(on: &req, token: token)
        do {
            let (data, _) = try await session.data(for: req)
            return try Self.decodeItems(data)
        } catch {
            return []
        }
    }

    /// Decode the `{Items: [...]}` envelope Emby's `/Items` returns.
    private static func decodeItems(_ data: Data) throws -> [EmbyItem] {
        struct Raw: Decodable {
            let id: String
            let name: String
            let itemType: String
            let overview: String?
            let imageTags: [String: String]?
            let runtimeTicks: Int64?
            let seriesName: String?
            let parentIndex: Int?
            let episodeIndex: Int?
            enum CodingKeys: String, CodingKey {
                case id = "Id"
                case name = "Name"
                case itemType = "Type"
                case overview = "Overview"
                case imageTags = "ImageTags"
                case runtimeTicks = "RunTimeTicks"
                case seriesName = "SeriesName"
                case parentIndex = "ParentIndexNumber"
                case episodeIndex = "IndexNumber"
            }
        }
        struct Envelope: Decodable {
            let items: [Raw]
            enum CodingKeys: String, CodingKey { case items = "Items" }
        }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.items.map { r in
            EmbyItem(
                id: r.id,
                name: r.name,
                type: r.itemType,
                overview: r.overview,
                primaryImageTag: r.imageTags?["Primary"],
                runtimeTicks: r.runtimeTicks,
                seriesName: r.seriesName
            )
        }
    }

    /// Poster image URL for a given item.
    func posterUrl(for item: EmbyItem, maxWidth: Int = 300) -> URL? {
        guard let tag = item.primaryImageTag else { return nil }
        return URL(string: "\(serverUrl)/Items/\(item.id)/Images/Primary?maxWidth=\(maxWidth)&tag=\(tag)&quality=90")
    }

    private func normalizeHost(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while h.hasSuffix("/") { h.removeLast() }
        if h.isEmpty { return h }
        if !h.contains("://") { h = "http://\(h)" }
        return h
    }

    private func setAuthHeaders(on req: inout URLRequest, token: String?) {
        var value = "MediaBrowser Client=\"\(appName)\", Device=\"Mac\", DeviceId=\"\(deviceId)\", Version=\"0.1.0\""
        if let token {
            value += ", Token=\"\(token)\""
            req.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        req.setValue(value, forHTTPHeaderField: "X-Emby-Authorization")
    }

    // MARK: - Matching an IMDB title

    func findMovie(imdbId: String, title: String, year: Int?) async -> [MediaServerMatch] {
        await matcher?.findMovie(imdbId: imdbId, title: title, year: year) ?? []
    }

    func findEpisode(seriesImdbId: String, title: String, year: Int?,
                     season: Int, episode: Int) async -> [MediaServerMatch] {
        await matcher?.findEpisode(seriesImdbId: seriesImdbId, title: title, year: year,
                                   season: season, episode: episode) ?? []
    }

    private var matcher: MediaBrowserMatcher? {
        guard let token = accessToken, let uid = userId else { return nil }
        var req = URLRequest(url: URL(string: "about:blank")!)
        setAuthHeaders(on: &req, token: token)
        return MediaBrowserMatcher(serverUrl: serverUrl, userId: uid, session: session,
                                   headers: req.allHTTPHeaderFields ?? [:])
    }
}
