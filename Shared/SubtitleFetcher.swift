import Foundation

/// One subtitle entry from an addon's `subtitles` resource. Used by the
/// player's Subtitles menu to let the user pick a language without
/// knowing which addon it came from.
struct AddonSubtitle: Hashable, Identifiable {
    let id: String
    let url: String
    let lang: String?
    let addonName: String

    var displayLanguage: String {
        if let l = lang, !l.isEmpty { return MediaTrack.languageName(for: l) }
        return "Unknown"
    }
}

/// Fetches subtitles from every installed addon that declares the
/// `subtitles` resource. Stremio spec: GET `{transportUrl}/subtitles/{type}/{id}.json`
/// returns `{ "subtitles": [{ id, url, lang }, ...] }`.
struct SubtitleFetcher {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 10
            cfg.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Fan out across the given addons in parallel. Returns an empty list
    /// if nothing came back in time — the player keeps embedded tracks.
    func fetchAll(
        addons: [InstalledAddon], type: String, id: String, videoId: String? = nil
    ) async -> [AddonSubtitle] {
        let eligible = addons.filter {
            $0.manifest.resources.contains("subtitles") &&
            ($0.manifest.types.contains(type) || $0.manifest.types.isEmpty)
        }
        guard !eligible.isEmpty else { return [] }

        let queryId: String = {
            // For series Stremio uses the episode id (type|series|imdb:season:episode).
            // Caller passes it via `videoId`; fall back to the content id.
            if let vid = videoId, !vid.isEmpty { return vid }
            return id
        }()

        return await withTaskGroup(of: [AddonSubtitle].self) { group in
            for addon in eligible {
                group.addTask {
                    await fetchOne(addon: addon, type: type, id: queryId)
                }
            }
            var merged: [AddonSubtitle] = []
            for await chunk in group { merged.append(contentsOf: chunk) }
            // Sort English first, then everything else alphabetically — the
            // default preference in the player can be overridden per-user.
            merged.sort { a, b in
                let la = a.lang?.lowercased() ?? ""
                let lb = b.lang?.lowercased() ?? ""
                let aIsEn = ["en", "eng"].contains(la)
                let bIsEn = ["en", "eng"].contains(lb)
                if aIsEn && !bIsEn { return true }
                if !aIsEn && bIsEn { return false }
                return a.displayLanguage < b.displayLanguage
            }
            return merged
        }
    }

    /// Direct manual search against OpenSubtitles v3 (works even if no subtitle
    /// addon is installed).
    func searchOpenSubtitles(type: String, id: String, videoId: String? = nil) async -> [AddonSubtitle] {
        let queryId = (videoId?.isEmpty == false) ? videoId! : id
        guard queryId.hasPrefix("tt") else { return [] }
        let encodedId = queryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? queryId
        guard let url = URL(string: "https://opensubtitles-v3.strem.io/subtitles/\(type)/\(encodedId).json") else {
            return []
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return [] }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.subtitles.compactMap {
                guard let u = $0.url, !u.isEmpty else { return nil }
                return AddonSubtitle(id: $0.id ?? u, url: u, lang: $0.lang, addonName: "OpenSubtitles")
            }
        } catch {
            return []
        }
    }

    private func fetchOne(addon: InstalledAddon, type: String, id: String) async -> [AddonSubtitle] {
        var base = addon.manifest.transportUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        // Addons publish their transport URL with or without a trailing
        // `/manifest.json`. Strip it so we can build sibling endpoints.
        if base.hasSuffix("/manifest.json") {
            base = String(base.dropLast("/manifest.json".count))
        }
        while base.hasSuffix("/") { base.removeLast() }

        let safeType = id.contains(":") ? type : type
        let encodedId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = URL(string: "\(base)/subtitles/\(safeType)/\(encodedId).json") else {
            return []
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return [] }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            return decoded.subtitles.compactMap {
                guard let url = $0.url, !url.isEmpty else { return nil }
                return AddonSubtitle(
                    id: $0.id ?? url,
                    url: url,
                    lang: $0.lang,
                    addonName: addon.manifest.name
                )
            }
        } catch {
            return []
        }
    }

    // MARK: - wire types

    private struct Response: Decodable {
        let subtitles: [Entry]
    }
    private struct Entry: Decodable {
        let id: String?
        let url: String?
        let lang: String?
    }
}
