import Foundation
import Observation

/// Optional TMDB integration for localized movie & series titles and synopses
/// on top of Cinemeta / Stremio metadata. Accepts either a TMDB v3 API key or
/// a v4 Read Access Token. Stored in `Keychain` under `com.veltrio.tmdb.*` and
/// transferred automatically during LAN TV pairing.
@MainActor
@Observable
final class TmdbService {
    static let shared = TmdbService()

    static let keyService = "com.veltrio.tmdb.key"
    static let langService = "com.veltrio.tmdb.lang"
    private static let base = "https://api.themoviedb.org/3"

    static let languages: [(code: String, label: String)] = [
        ("fr-FR", "Français"),
        ("en-US", "English"),
        ("es-ES", "Español"),
        ("de-DE", "Deutsch"),
        ("it-IT", "Italiano"),
        ("pt-BR", "Português"),
        ("ja-JP", "日本語"),
        ("", "Disabled (addon language)"),
    ]

    struct LocalizedMeta: Sendable {
        let title: String?
        let overview: String?
    }

    private(set) var isConnected = false
    private(set) var language = "fr-FR"
    private(set) var isBusy = false
    private(set) var error: String?

    private var cache: [String: LocalizedMeta] = [:]

    private init() {
        reload()
    }

    func reload() {
        let key = Keychain.get(service: Self.keyService)?.trimmingCharacters(in: .whitespacesAndNewlines)
        isConnected = key != nil && !(key?.isEmpty ?? true)
        language = Keychain.get(service: Self.langService) ?? "fr-FR"
        error = nil
    }

    func setLanguage(_ lang: String) {
        Keychain.set(lang, service: Self.langService)
        language = lang
    }

    @discardableResult
    func connect(rawKey: String) async -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            error = String(localized: "Enter a TMDB API key or Read Access Token.")
            return false
        }
        isBusy = true
        error = nil
        defer { isBusy = false }
        guard let req = buildRequest(path: "/configuration", key: key) else {
            error = String(localized: "Invalid TMDB request.")
            return false
        }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else {
                error = String(localized: "Invalid TMDB key (HTTP \(code)).")
                return false
            }
            Keychain.set(key, service: Self.keyService)
            if Keychain.get(service: Self.langService) == nil {
                Keychain.set("fr-FR", service: Self.langService)
            }
            cache.removeAll()
            isConnected = true
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func disconnect() {
        Keychain.delete(service: Self.keyService)
        cache.removeAll()
        isConnected = false
        error = nil
    }

    func localize(imdbId: String, type: String) async -> LocalizedMeta? {
        guard let key = Keychain.get(service: Self.keyService)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty,
              !language.isEmpty,
              imdbId.hasPrefix("tt") else { return nil }
        let cacheKey = "\(imdbId)|\(type)|\(language)"
        if let hit = cache[cacheKey] { return hit }
        guard let req = buildRequest(path: "/find/\(imdbId)?external_source=imdb_id&language=\(language)", key: key) else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
            struct Item: Decodable {
                let title: String?
                let name: String?
                let overview: String?
            }
            struct FindResponse: Decodable {
                let movie_results: [Item]?
                let tv_results: [Item]?
            }
            let decoded = try JSONDecoder().decode(FindResponse.self, from: data)
            let isSeries = type.lowercased() == "series"
            let primary = (isSeries ? decoded.tv_results?.first : decoded.movie_results?.first)
                ?? (isSeries ? decoded.movie_results?.first : decoded.tv_results?.first)
            guard let primary else { return nil }
            let title = (primary.title ?? primary.name)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let overview = primary.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = LocalizedMeta(
                title: (title?.isEmpty == false) ? title : nil,
                overview: (overview?.isEmpty == false) ? overview : nil
            )
            cache[cacheKey] = result
            return result
        } catch {
            return nil
        }
    }

    private func buildRequest(path: String, key: String) -> URLRequest? {
        let isBearer = key.count > 40 || key.contains(".")
        let sep = path.contains("?") ? "&" : "?"
        let urlStr = isBearer ? "\(Self.base)\(path)" : "\(Self.base)\(path)\(sep)api_key=\(key)"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if isBearer { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return req
    }
}
