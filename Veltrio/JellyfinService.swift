import Foundation
import Observation

/// Minimal Jellyfin bridge: connect to a server with username + password,
/// pull the user's library, and surface items as playable streams that
/// hit the same player as Stremio sources.
///
/// Scope for this pass:
///   - username + password login (quick-connect comes later)
///   - Latest items for the user (home carousel)
///   - Direct play via `/Videos/{id}/stream?ApiKey=...`
///
/// Jellyfin API: https://api.jellyfin.org/
///
/// Credentials are stored in Keychain; only the server URL lives in
/// UserDefaults (public info, used by the Settings UI).

struct JellyfinItem: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String          // "Movie" / "Episode" / "Series" / …
    let overview: String?
    let primaryImageTag: String?
    let runtimeTicks: Int64?
    let seriesName: String?
    let seasonIndex: Int?
    let episodeIndex: Int?
}

@MainActor
@Observable
final class JellyfinService {
    private(set) var serverUrl: String = ""
    private(set) var accessToken: String?
    private(set) var userId: String?
    private(set) var username: String?
    private(set) var isConnecting = false
    private(set) var connectionError: String?

    private(set) var latestItems: [JellyfinItem] = []

    private let keychainService = "com.veltrio.jellyfin.token"
    private let defaultsKeyUrl   = "veltrio.jellyfin.url"
    private let defaultsKeyUser  = "veltrio.jellyfin.userId"
    private let defaultsKeyName  = "veltrio.jellyfin.userName"

    private let session: URLSession
    private let appName = "Veltrio"
    /// Stable per install. Jellyfin ties access tokens and the device list
    /// to this id, so a fresh one on every launch would register a new
    /// device each time the app starts.
    private let deviceId: String = {
        let key = "veltrio.jellyfin.deviceId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "veltrio-\(UUID().uuidString.prefix(12).lowercased())"
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()
    private let clientVersion = "0.1.0"

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

    // MARK: - Auth

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

        // Check there is a Jellyfin server at this address before sending
        // credentials. Without it, a wrong URL or port comes back as a 404
        // on the login call, which reads as "wrong password".
        do {
            let (data, resp) = try await session.data(from: probeUrl)
            struct Info: Decodable { let ProductName: String?; let Version: String? }
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let info = try? JSONDecoder().decode(Info.self, from: data),
                  info.Version != nil else {
                connectionError = String(localized: "No Jellyfin server answered at \(normalized). Check the address and port (8096 by default), and add the base path if your server uses one, e.g. /jellyfin.")
                return
            }
            if info.ProductName?.localizedCaseInsensitiveContains("emby") == true {
                connectionError = String(localized: "This is an Emby server. Connect it with the Emby card instead.")
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
        let body: [String: String] = ["Username": user, "Pw": password]
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
                    connectionError = String(localized: "This account isn't allowed to sign in (disabled, or remote access is off for it)")
                default:
                    let detail = String(data: data.prefix(200), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    connectionError = String(localized: "Jellyfin refused the sign-in (HTTP \(http.statusCode))")
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
            self.serverUrl = normalized
            self.accessToken = r.AccessToken
            self.userId = r.User.Id
            self.username = r.User.Name
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

    // MARK: - Library

    func refreshLatest(limit: Int = 24) async {
        guard let token = accessToken, let uid = userId else { return }
        guard let url = URL(string: "\(serverUrl)/Users/\(uid)/Items/Latest?Limit=\(limit)&IncludeItemTypes=Movie,Episode&Fields=Overview")
        else { return }
        var req = URLRequest(url: url)
        setAuthHeaders(on: &req, token: token)
        do {
            let (data, _) = try await session.data(for: req)
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
            let items = try JSONDecoder().decode([Raw].self, from: data)
            self.latestItems = items.map { r in
                JellyfinItem(
                    id: r.id,
                    name: r.name,
                    type: r.itemType,
                    overview: r.overview,
                    primaryImageTag: r.imageTags?["Primary"],
                    runtimeTicks: r.runtimeTicks,
                    seriesName: r.seriesName,
                    seasonIndex: r.parentIndex,
                    episodeIndex: r.episodeIndex
                )
            }
        } catch {
            // Silent — leave latestItems as they were.
        }
    }

    /// Search the user's library by title.
    ///
    /// Jellyfin's `/Items` endpoint takes a `SearchTerm` and filters by
    /// `IncludeItemTypes`. We ask for Movies, Series and Episodes so a
    /// search for "Dune" surfaces the film, the series and its episodes
    /// in one pass.
    func search(query: String, limit: Int = 40) async -> [JellyfinItem] {
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

    // MARK: - Matching an IMDB title

    func findMovie(imdbId: String, title: String, year: Int?) async -> [MediaServerMatch] {
        await browser?.findMovie(imdbId: imdbId, title: title, year: year) ?? []
    }

    func findEpisode(seriesImdbId: String, title: String, year: Int?,
                     season: Int, episode: Int) async -> [MediaServerMatch] {
        await browser?.findEpisode(seriesImdbId: seriesImdbId, title: title, year: year,
                                   season: season, episode: episode) ?? []
    }

    /// Library calls (IMDB matching, Collection browsing), nil until signed in.
    var browser: MediaBrowserMatcher? {
        guard let token = accessToken, let uid = userId else { return nil }
        var req = URLRequest(url: URL(string: "about:blank")!)
        setAuthHeaders(on: &req, token: token)
        return MediaBrowserMatcher(serverUrl: serverUrl, userId: uid, session: session,
                                   headers: req.allHTTPHeaderFields ?? [:])
    }

    /// Decode the `{Items: [...]}` envelope that both `/Items` and
    /// `/Items/Latest` return.
    private static func decodeItems(_ data: Data) throws -> [JellyfinItem] {
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
            JellyfinItem(
                id: r.id,
                name: r.name,
                type: r.itemType,
                overview: r.overview,
                primaryImageTag: r.imageTags?["Primary"],
                runtimeTicks: r.runtimeTicks,
                seriesName: r.seriesName,
                seasonIndex: r.parentIndex,
                episodeIndex: r.episodeIndex
            )
        }
    }

    /// Build a direct-stream URL for mpv. This uses the raw "stream" endpoint
    /// which lets the server pick the right container. Transcoding kicks in
    /// server-side when the codec isn't natively supported.
    func streamUrl(for itemId: String) -> URL? {
        guard let token = accessToken else { return nil }
        // `ApiKey` is the current name; `api_key` is the legacy one that
        // servers before 10.10 still expect.
        return URL(string: "\(serverUrl)/Videos/\(itemId)/stream?ApiKey=\(token)&api_key=\(token)&Static=true")
    }

    /// Poster image URL for a given item.
    func posterUrl(for item: JellyfinItem, maxWidth: Int = 300) -> URL? {
        guard let tag = item.primaryImageTag else { return nil }
        return URL(string: "\(serverUrl)/Items/\(item.id)/Images/Primary?maxWidth=\(maxWidth)&tag=\(tag)&quality=90")
    }

    /// Backdrop image URL, used as the detail-page atmosphere.
    func backdropUrl(for item: JellyfinItem, maxWidth: Int = 1280) -> URL? {
        guard let tag = item.primaryImageTag else { return nil }
        return URL(string: "\(serverUrl)/Items/\(item.id)/Images/Backdrop?maxWidth=\(maxWidth)&tag=\(tag)&quality=90")
    }

    // MARK: - Helpers

    private func normalizeHost(_ raw: String) -> String {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while h.hasSuffix("/") { h.removeLast() }
        if h.isEmpty { return h }
        if !h.contains("://") { h = "http://\(h)" }
        return h
    }

    /// Jellyfin reads the client description from `Authorization`; the
    /// legacy `X-Emby-Authorization` header is off by default on recent
    /// servers but still the only one older ones accept, so send both.
    private func setAuthHeaders(on req: inout URLRequest, token: String?) {
        var value = "MediaBrowser Client=\"\(appName)\", Device=\"Mac\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
        if let token { value += ", Token=\"\(token)\"" }
        req.setValue(value, forHTTPHeaderField: "Authorization")
        req.setValue(value, forHTTPHeaderField: "X-Emby-Authorization")
    }
}
