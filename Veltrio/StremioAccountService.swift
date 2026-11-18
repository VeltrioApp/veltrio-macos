import Foundation
import Observation

/// A Stremio account: sign in with email and password, then import its
/// library (saved titles, watched flags, film progress) and its addons.
///
/// Import is one-way: Veltrio reads the account and merges it into its
/// own library, it doesn't write back.
@MainActor
@Observable
final class StremioAccountService {
    private(set) var email: String?
    private(set) var isWorking = false
    private(set) var error: String?
    private(set) var lastSync: Date?
    /// "12 titles imported", shown under the card after a sync.
    private(set) var lastResult: String?

    private var authKey: String?
    private let keychainService = "com.veltrio.stremio.authkey"
    private let defaultsEmail = "veltrio.stremio.email"
    private let api = URL(string: "https://api.strem.io/api")!

    var isConnected: Bool { authKey != nil }

    init() {
        authKey = Keychain.get(service: keychainService)
        email = UserDefaults.standard.string(forKey: defaultsEmail)
    }

    func signIn(email: String, password: String) async {
        error = nil
        isWorking = true
        defer { isWorking = false }
        struct Login: Decodable {
            let authKey: String
            let user: User?
            struct User: Decodable { let email: String? }
        }
        do {
            let login: Login = try await call("login", body: [
                "type": "Login", "email": email, "password": password, "facebook": false,
            ])
            authKey = login.authKey
            self.email = login.user?.email ?? email
            Keychain.set(login.authKey, service: keychainService)
            UserDefaults.standard.set(self.email, forKey: defaultsEmail)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut() {
        if let key = authKey {
            Task { _ = try? await call("logout", body: ["type": "Logout", "authKey": key]) as Empty }
        }
        Keychain.delete(service: keychainService)
        UserDefaults.standard.removeObject(forKey: defaultsEmail)
        authKey = nil
        email = nil
        lastResult = nil
        lastSync = nil
    }

    /// Saved and watched titles, and film progress, into `watch`.
    func importLibrary(into watch: WatchStore) async {
        guard let key = authKey else { return }
        error = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let items: [LibraryItem] = try await call("datastoreGet", body: [
                "authKey": key, "collection": "libraryItem", "ids": [String](), "all": true,
            ])
            let imported = items.compactMap(Self.imported)
            let changed = watch.merge(imported)
            lastSync = Date()
            lastResult = String(localized: "\(imported.count) titles read, \(changed) updated")
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Transport URLs of the account's addons that aren't installed yet.
    func addonURLs(excluding installed: Set<String>) async -> [String] {
        guard let key = authKey else { return [] }
        struct Collection: Decodable {
            let addons: [Addon]
            struct Addon: Decodable { let transportUrl: String }
        }
        do {
            let collection: Collection = try await call("addonCollectionGet", body: [
                "type": "AddonCollectionGet", "authKey": key, "update": true,
            ])
            return collection.addons.map(\.transportUrl).filter { !installed.contains($0) }
        } catch {
            self.error = error.localizedDescription
            return []
        }
    }

    // MARK: - wire

    struct LibraryItem: Decodable {
        let _id: String
        let name: String?
        let type: String?
        let poster: String?
        let removed: Bool?
        let temp: Bool?
        let state: State?

        struct State: Decodable {
            let timeOffset: Double?   // ms
            let duration: Double?     // ms
            let lastWatched: String?
            let timesWatched: Int?
            let flaggedWatched: Int?
        }
    }

    nonisolated static func imported(_ item: LibraryItem) -> ImportedWatchItem? {
        guard item._id.hasPrefix("tt"), let type = item.type, type == "movie" || type == "series" else { return nil }
        let state = item.state
        let isFilm = type == "movie"
        return ImportedWatchItem(
            type: type, id: item._id, name: item.name ?? item._id, poster: item.poster,
            // "temp" items are ones Stremio tracks only because they were opened.
            inLibrary: item.removed != true && item.temp != true,
            watched: isFilm && ((state?.flaggedWatched ?? 0) > 0 || (state?.timesWatched ?? 0) > 0),
            position: isFilm ? state?.timeOffset.map { $0 / 1000 } : nil,
            duration: isFilm ? state?.duration.map { $0 / 1000 } : nil,
            lastWatched: state?.lastWatched.flatMap(parseDate)
        )
    }

    nonisolated static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private struct Empty: Decodable {}

    private struct Envelope<T: Decodable>: Decodable {
        let result: T?
        let error: APIError?
        struct APIError: Decodable { let message: String? }
    }

    private func call<T: Decodable>(_ method: String, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: api.appendingPathComponent(method))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let env = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if let result = env.result { return result }
        throw DebridAPIError.rejected(env.error?.message ?? String(localized: "Stremio refused the request."))
    }
}
