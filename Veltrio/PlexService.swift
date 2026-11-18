import Foundation
import Observation

/// Plex bridge using the PIN flow. Plex's OAuth has you:
///   1. POST /api/v2/pins → {id, code}
///   2. Direct user to https://plex.tv/link with the `code`
///   3. Poll /api/v2/pins/{id} → eventually has `authToken`
///
/// Streaming goes against the user's home server (resource discovery
/// via /api/resources endpoint). For this pass we land PIN auth + user
/// info; library + playback fetchers can hook in later.

struct PlexPin: Equatable {
    let id: Int
    let code: String
    let expiresAt: Date
}

struct PlexUser: Equatable {
    let username: String
    let email: String?
}

@MainActor
@Observable
final class PlexService {
    /// Stable per install: plex.tv lists each client id as a device, and
    /// the auth token is issued to it.
    private let clientId: String = {
        let key = "veltrio.plex.clientId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = "veltrio-\(UUID().uuidString.prefix(12).lowercased())"
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()
    private let product  = "Veltrio"
    private let device   = "Mac"

    private(set) var token: String?
    private(set) var user: PlexUser?
    private(set) var pendingPin: PlexPin?
    private(set) var isConnecting = false
    private(set) var connectionError: String?

    private var pollTask: Task<Void, Never>?
    private let session: URLSession
    private let keychainService = "com.veltrio.plex.token"

    var isConnected: Bool { token != nil }

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
        self.token = Keychain.get(service: keychainService)
        if let t = token {
            Task { [weak self] in
                let u = try? await self?.fetchUser(token: t)
                await MainActor.run { self?.user = u }
            }
        }
    }

    func startPinFlow() async {
        connectionError = nil
        pollTask?.cancel()
        isConnecting = true
        defer { isConnecting = false }
        do {
            let pin = try await createPin()
            pendingPin = pin
            pollTask = Task { [weak self] in await self?.pollPin(pin: pin) }
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func cancelPinFlow() {
        pollTask?.cancel()
        pollTask = nil
        pendingPin = nil
    }

    func disconnect() {
        Keychain.delete(service: keychainService)
        token = nil
        user = nil
    }

    /// Open https://plex.tv/link in the user's browser with the code
    /// pre-populated. Caller passes the current pin.
    func verificationURL(for pin: PlexPin) -> URL? {
        URL(string: "https://plex.tv/link?code=\(pin.code)")
    }

    // MARK: - API

    private func createPin() async throws -> PlexPin {
        var req = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins")!)
        req.httpMethod = "POST"
        for (k, v) in commonHeaders() {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = Self.formEncode(["strong": "true"])
        req.setValue("application/x-www-form-urlencoded",
                     forHTTPHeaderField: "Content-Type")
        let (data, _) = try await session.data(for: req)
        struct R: Decodable {
            let id: Int
            let code: String
            let expiresIn: Int
        }
        let r = try JSONDecoder().decode(R.self, from: data)
        return PlexPin(
            id: r.id, code: r.code,
            expiresAt: Date().addingTimeInterval(TimeInterval(r.expiresIn))
        )
    }

    private func pollPin(pin: PlexPin) async {
        while Date() < pin.expiresAt {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled { return }
            do {
                if let tok = try await checkPin(id: pin.id) {
                    let u = try? await fetchUser(token: tok)
                    guard self.pendingPin?.id == pin.id else { return }
                    Keychain.set(tok, service: keychainService)
                    self.token = tok
                    self.user = u
                    self.pendingPin = nil
                    return
                }
            } catch {
                continue
            }
        }
        guard self.pendingPin?.id == pin.id else { return }
        self.pendingPin = nil
        self.connectionError = "Plex code expired. Try again."
    }

    private func checkPin(id: Int) async throws -> String? {
        var req = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins/\(id)")!)
        for (k, v) in commonHeaders() {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: req)
        struct R: Decodable { let authToken: String? }
        return try? JSONDecoder().decode(R.self, from: data).authToken
    }

    private func fetchUser(token: String) async throws -> PlexUser {
        var req = URLRequest(url: URL(string: "https://plex.tv/api/v2/user")!)
        for (k, v) in commonHeaders() {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: req)
        struct R: Decodable { let username: String; let email: String? }
        let r = try JSONDecoder().decode(R.self, from: data)
        return PlexUser(username: r.username, email: r.email)
    }

    // MARK: - Library search

    /// One item from a Plex library.
    struct PlexItem: Identifiable, Hashable, Decodable {
        let id: String
        let title: String
        let type: String          // "movie" | "show" | "episode"
        let summary: String?
        let year: Int?
        let rating: String?
        let posterPath: String?
        /// The rating key, used to build the stream URL.
        let ratingKey: String

        private enum CodingKeys: String, CodingKey {
            case id = "ratingKey"
            case title
            case type
            case summary
            case year
            case rating
            case posterPath = "thumb"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ratingKey = String(try c.decode(String.self, forKey: .id))
            id = ratingKey
            title = try c.decode(String.self, forKey: .title)
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? "movie"
            summary = try c.decodeIfPresent(String.self, forKey: .summary)
            year = try c.decodeIfPresent(Int.self, forKey: .year)
            rating = try c.decodeIfPresent(String.self, forKey: .rating)
            posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath)
        }
    }

    /// The user's Plex Media Server, as discovered from plex.tv.
    private struct PlexServer: Decodable {
        let name: String
        let accessToken: String?
        let connections: [Connection]

        struct Connection: Decodable {
            let uri: String
            let local: Bool
        }

        /// The best connection to use: prefer a local one, else the first.
        var bestConnection: Connection? {
            connections.first { $0.local } ?? connections.first
        }
    }

    /// Search the Plex library for a title.
    ///
    /// Plex has no single "search everything" endpoint. The path is:
    ///   1. ask plex.tv which servers this account can reach
    ///   2. ask the server for its library sections
    ///   3. query each movie / show / episode section
    ///
    /// Every step is best-effort: a Plex account with no server, or a
    /// server that's asleep, simply yields no results rather than an
    /// error the user has to read.
    func search(query: String, limit: Int = 40) async -> [PlexItem] {
        guard let token, !query.isEmpty else { return [] }
        guard let server = await discoverServer(token: token) else { return [] }
        guard let base = server.bestConnection?.uri else { return [] }
        cachedServerUri = base

        let sections = await fetchSections(base: base, token: token)
        let searchable = sections.filter { $0.type == "movie" || $0.type == "show" || $0.type == "episode" }
        guard !searchable.isEmpty else { return [] }

        var results: [PlexItem] = []
        for section in searchable {
            let items = await fetchSearchResults(
                base: base, token: token, sectionKey: section.key,
                type: section.type, query: query, limit: limit
            )
            results.append(contentsOf: items)
            if results.count >= limit { break }
        }
        return Array(results.prefix(limit))
    }

    /// Find the user's Plex Media Server.
    private func discoverServer(token: String) async -> PlexServer? {
        guard let data = await get(url: URL(string: "https://plex.tv/api/resources?includeHttps=1")!, token: token) else {
            return nil
        }
        let servers = try? JSONDecoder().decode([PlexServer].self, from: data)
        return servers?.first { $0.connections.isEmpty == false }
    }

    private struct PlexSection: Decodable {
        let key: String
        let title: String
        let type: String
    }

    private func fetchSections(base: String, token: String) async -> [PlexSection] {
        guard let data = await get(url: URL(string: base + "/library/sections")!, token: token),
              let parsed = try? JSONDecoder().decode(SectionsEnvelope.self, from: data) else { return [] }
        return parsed.MediaContainer.Directory ?? []
    }

    private struct SectionsEnvelope: Decodable {
        let MediaContainer: Container
        struct Container: Decodable {
            let Directory: [PlexSection]?
        }
    }

    /// The `type` filter Plex expects per section kind.
    private func plexSearchType(for sectionType: String) -> String {
        switch sectionType {
        case "movie": return "1"
        case "show": return "2"
        case "episode": return "4"
        default: return "1"
        }
    }

    private func fetchSearchResults(base: String, token: String, sectionKey: String,
                                    type: String, query: String, limit: Int) async -> [PlexItem] {
        var components = URLComponents(string: base + "/library/sections/\(sectionKey)/all")!
        components.queryItems = [
            URLQueryItem(name: "type", value: plexSearchType(for: type)),
            URLQueryItem(name: "title", value: query),
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: String(limit))
        ]
        guard let url = components.url,
              let data = await get(url: url, token: token),
              let parsed = try? JSONDecoder().decode(SearchEnvelope.self, from: data) else { return [] }
        return parsed.MediaContainer.Metadata ?? []
    }

    private struct SearchEnvelope: Decodable {
        let MediaContainer: Container
        struct Container: Decodable {
            let Metadata: [PlexItem]?
        }
    }

    /// The direct-play URL for a library item.
    ///
    /// Plex streams a file at `/library/metadata/{ratingKey}` with the
    /// `X-Plex-Container-Start` header set to the media part. Asking for
    /// `MPEG4` in the Accept header gets us an MP4 rendition that mpv can
    /// play directly.
    func streamUrl(for ratingKey: String, serverUri: String? = nil) -> URL? {
        guard let token else { return nil }
        guard let base = serverUri ?? cachedServerUri else { return nil }
        var components = URLComponents(string: base + "/library/metadata/\(ratingKey)")!
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: token),
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "1")
        ]
        return components.url
    }

    // MARK: - Matching an IMDB title

    /// The library's copies of one film. Plex keeps the IMDB id among an
    /// item's `Guid`s (`imdb://tt…`) when asked with `includeGuids`;
    /// title and year are the fallback.
    func findMovie(imdbId: String, title: String, year: Int?) async -> [MediaServerMatch] {
        guard let (base, token) = await serverAccess() else { return [] }
        var out: [MediaServerMatch] = []
        for section in await fetchSections(base: base, token: token) where section.type == "movie" {
            let items = await metadata(base: base, token: token,
                                       path: "/library/sections/\(section.key)/all",
                                       query: ["type": "1", "title": title, "includeGuids": "1"])
            for item in items where Self.isSame(item, imdbId: imdbId, title: title, year: year) {
                if let m = await match(item, base: base, token: token) { out.append(m) }
            }
        }
        return out
    }

    /// The library's copies of one episode: the show is matched like a
    /// film, then its episodes are listed and the right one picked.
    func findEpisode(seriesImdbId: String, title: String, year: Int?,
                     season: Int, episode: Int) async -> [MediaServerMatch] {
        guard let (base, token) = await serverAccess() else { return [] }
        var out: [MediaServerMatch] = []
        for section in await fetchSections(base: base, token: token) where section.type == "show" {
            let shows = await metadata(base: base, token: token,
                                       path: "/library/sections/\(section.key)/all",
                                       query: ["type": "2", "title": title, "includeGuids": "1"])
            for show in shows where Self.isSame(show, imdbId: seriesImdbId, title: title, year: year) {
                let episodes = await metadata(base: base, token: token,
                                              path: "/library/metadata/\(show.ratingKey)/allLeaves", query: [:])
                for ep in episodes where ep.parentIndex == season && ep.index == episode {
                    if let m = await match(ep, base: base, token: token, seriesName: show.title) { out.append(m) }
                }
            }
        }
        return out
    }

    /// The server's address and the token to use with it. A server shared
    /// by someone else only accepts its own access token.
    private func serverAccess() async -> (String, String)? {
        guard let token, let server = await discoverServer(token: token),
              let base = server.bestConnection?.uri else { return nil }
        cachedServerUri = base
        return (base, server.accessToken ?? token)
    }

    private struct Meta: Decodable {
        let ratingKey: String
        let title: String
        let type: String?
        let year: Int?
        let parentIndex: Int?
        let index: Int?
        let Guid: [GuidEntry]?
        let Media: [MediaEntry]?

        struct GuidEntry: Decodable { let id: String }
        struct MediaEntry: Decodable {
            let videoResolution: String?
            let videoCodec: String?
            let Part: [PartEntry]?
        }
        struct PartEntry: Decodable {
            let key: String?
            let Stream: [StreamEntry]?
        }
        struct StreamEntry: Decodable {
            let streamType: Int?
            let languageCode: String?
        }
    }

    private struct MetaEnvelope: Decodable {
        let MediaContainer: Container
        struct Container: Decodable { let Metadata: [Meta]? }
    }

    private func metadata(base: String, token: String, path: String, query: [String: String]) async -> [Meta] {
        guard var comps = URLComponents(string: base + path) else { return [] }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url, let data = await get(url: url, token: token) else { return [] }
        return (try? JSONDecoder().decode(MetaEnvelope.self, from: data))?.MediaContainer.Metadata ?? []
    }

    private static func isSame(_ item: Meta, imdbId: String, title: String, year: Int?) -> Bool {
        let imdb = item.Guid?.first(where: { $0.id.hasPrefix("imdb://") })?.id.dropFirst("imdb://".count)
        if let imdb { return imdb.lowercased() == imdbId.lowercased() }
        return MediaServerTitles.same(item.title, title, theirYear: item.year, year: year)
    }

    /// Turns a matched item into a stream entry. The listing omits audio
    /// streams, so the item's own metadata is fetched for its languages;
    /// the playable file is the media part.
    private func match(_ item: Meta, base: String, token: String, seriesName: String? = nil) async -> MediaServerMatch? {
        let full = await metadata(base: base, token: token, path: "/library/metadata/\(item.ratingKey)", query: [:]).first ?? item
        guard let media = full.Media?.first, let part = media.Part?.first, let key = part.key,
              var comps = URLComponents(string: base + key) else { return nil }
        comps.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
        var languages: [String] = []
        for stream in part.Stream ?? [] where stream.streamType == 2 {
            if let l = stream.languageCode, !languages.contains(l) { languages.append(l) }
        }
        let video = [media.videoResolution.map { $0.lowercased() == "4k" ? "4K" : "\($0)p" },
                     media.videoCodec?.uppercased()].compactMap { $0 }.joined(separator: " ")
        return MediaServerMatch(
            itemId: item.ratingKey, name: item.title, type: item.type ?? "movie",
            seriesName: seriesName, video: video.isEmpty ? nil : video,
            audioLanguages: languages, streamURL: comps.url
        )
    }

    /// The server URI discovered during the last search, so a result can
    /// be turned into a playable URL without a second round-trip.
    private(set) var cachedServerUri: String?

    /// GET with the Plex auth headers, returning the body or nil.
    private func get(url: URL, token: String) async -> Data? {
        var req = URLRequest(url: url)
        for (k, v) in commonHeaders() {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        return data
    }

    private func commonHeaders() -> [String: String] {
        [
            "X-Plex-Client-Identifier": clientId,
            "X-Plex-Product": product,
            "X-Plex-Device": device,
            "X-Plex-Version": "0.1.0",
            "X-Plex-Platform": "macOS"
        ]
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
