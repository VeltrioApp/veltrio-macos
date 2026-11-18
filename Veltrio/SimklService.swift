import Foundation
import Observation

/// SIMKL: PIN sign-in, scrobbling, and importing the account's lists.
///
/// SIMKL requires an app-specific client id (registered at
/// simkl.com/settings/developer). It's read from the `SimklClientId`
/// Info.plist entry, filled at build time from `VELTRIO_SIMKL_CLIENT_ID`;
/// without it the service stays unavailable.
@MainActor
@Observable
final class SimklService {
    struct Pin: Equatable {
        let userCode: String
        let verificationURL: URL
        let expiresIn: Int
        let interval: Int
    }

    private(set) var accessToken: String?
    private(set) var pendingPin: Pin?
    private(set) var isConnecting = false
    private(set) var isImporting = false
    private(set) var error: String?
    private(set) var lastImport: String?

    let clientId: String?
    private let keychainService = "com.veltrio.simkl.token"
    private let api = "https://api.simkl.com"
    private var pollTask: Task<Void, Never>?

    var isAvailable: Bool { clientId != nil }
    var isConnected: Bool { accessToken != nil }

    init() {
        let id = (Bundle.main.infoDictionary?["SimklClientId"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        clientId = (id?.isEmpty ?? true) ? nil : id
        accessToken = Keychain.get(service: keychainService)
    }

    // MARK: - PIN flow

    func startPinFlow() async {
        guard let clientId else { return }
        error = nil
        pollTask?.cancel()
        isConnecting = true
        defer { isConnecting = false }
        struct Answer: Decodable {
            let user_code: String
            let verification_url: String
            let expires_in: Int?
            let interval: Int?
        }
        do {
            let a: Answer = try await get("/oauth/pin", query: ["client_id": clientId], auth: false)
            let pin = Pin(userCode: a.user_code,
                          verificationURL: URL(string: a.verification_url) ?? URL(string: "https://simkl.com/pin")!,
                          expiresIn: a.expires_in ?? 900, interval: a.interval ?? 5)
            pendingPin = pin
            pollTask = Task { [weak self] in await self?.poll(pin) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancelPinFlow() {
        pollTask?.cancel()
        pendingPin = nil
    }

    private func poll(_ pin: Pin) async {
        guard let clientId else { return }
        struct Answer: Decodable { let result: String?; let access_token: String? }
        let deadline = Date().addingTimeInterval(TimeInterval(pin.expiresIn))
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(pin.interval) * 1_000_000_000)
            if Task.isCancelled { return }
            guard let a: Answer = try? await get("/oauth/pin/\(pin.userCode)", query: ["client_id": clientId], auth: false)
            else { continue }
            if let token = a.access_token {
                guard pendingPin == pin else { return }
                Keychain.set(token, service: keychainService)
                accessToken = token
                pendingPin = nil
                return
            }
        }
        guard pendingPin == pin else { return }
        pendingPin = nil
        error = String(localized: "The SIMKL code expired. Try again.")
    }

    func disconnect() {
        pollTask?.cancel()
        Keychain.delete(service: keychainService)
        accessToken = nil
        pendingPin = nil
        lastImport = nil
    }

    // MARK: - import

    /// Plan-to-watch (saved) and completed (watched) lists into `watch`.
    func importLibrary(into watch: WatchStore) async {
        guard isConnected else { return }
        isImporting = true
        defer { isImporting = false }
        struct IDs: Decodable { let imdb: String? }
        struct Title: Decodable { let title: String?; let ids: IDs }
        struct Row: Decodable {
            let status: String?
            let last_watched_at: String?
            let added_to_watchlist_at: String?
            let movie: Title?
            let show: Title?
        }
        struct Answer: Decodable { let movies: [Row]?; let shows: [Row]?; let anime: [Row]? }
        guard let a: Answer = try? await get("/sync/all-items/", query: [:], auth: true) else {
            error = String(localized: "Couldn't read the SIMKL lists.")
            return
        }
        var items: [ImportedWatchItem] = []
        for (rows, isFilm) in [(a.movies ?? [], true), ((a.shows ?? []) + (a.anime ?? []), false)] {
            for row in rows {
                guard let t = row.movie ?? row.show, let imdb = t.ids.imdb, imdb.hasPrefix("tt") else { continue }
                items.append(ImportedWatchItem(
                    type: isFilm ? "movie" : "series", id: imdb, name: t.title ?? imdb,
                    inLibrary: row.status == "plantowatch" || row.status == "watching",
                    watched: isFilm && row.status == "completed",
                    lastWatched: (row.last_watched_at ?? row.added_to_watchlist_at).flatMap(StremioAccountService.parseDate)
                ))
            }
        }
        let changed = watch.merge(items)
        lastImport = String(localized: "\(items.count) titles read, \(changed) updated")
    }

    // MARK: - scrobble

    enum ScrobbleAction: String { case start, pause, stop }

    /// SIMKL marks a title watched when `stop` comes with 80 % or more.
    func scrobble(_ action: ScrobbleAction, imdbId: String, season: Int32?, episode: Int32?, progress: Double) async {
        guard isConnected, imdbId.hasPrefix("tt") else { return }
        var body: [String: Any] = ["progress": max(0, min(100, progress))]
        if let season, let episode {
            body["show"] = ["ids": ["imdb": imdbId]]
            body["episode"] = ["season": season, "number": episode]
        } else {
            body["movie"] = ["ids": ["imdb": imdbId]]
        }
        guard var req = request("/scrobble/\(action.rawValue)", query: [:], auth: true) else { return }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - wire

    private func request(_ path: String, query: [String: String], auth: Bool) -> URLRequest? {
        guard let clientId, var comps = URLComponents(string: api + path) else { return nil }
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(clientId, forHTTPHeaderField: "simkl-api-key")
        if auth, let token = accessToken { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func get<T: Decodable>(_ path: String, query: [String: String], auth: Bool) async throws -> T {
        guard let req = request(path, query: query, auth: auth) else { throw URLError(.badURL) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DebridAPIError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
