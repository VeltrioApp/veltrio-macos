import Foundation

/// Xtream Codes credentials. Password is NOT serialised — it's loaded
/// from the Keychain by playlist UUID at use time (see `IptvPersistence`).
struct XtreamCredentials: Codable, Hashable {
    var host: String       // e.g. "http://provider.com:8080"
    var username: String
    var password: String
    var output: String     // "ts" | "m3u8" | "rtmp"

    /// Normalised host: `http://` prepended if missing, trailing `/` stripped.
    var normalizedHost: String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while h.hasSuffix("/") { h.removeLast() }
        if h.isEmpty { return "" }
        if !h.contains("://") { h = "http://\(h)" }
        return h
    }

    // Encode skips `password`: that's a user secret we won't let land in
    // ~/Library/Application Support in cleartext. It round-trips through
    // the Keychain instead.
    enum CodingKeys: String, CodingKey { case host, username, output }
    init(host: String, username: String, password: String, output: String) {
        self.host = host; self.username = username
        self.password = password; self.output = output
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        username = try c.decode(String.self, forKey: .username)
        output = try c.decode(String.self, forKey: .output)
        password = ""  // filled in by IptvPersistence.load from Keychain
    }
}

enum XtreamKeychain {
    static let service = "com.veltrio.iptv.xtream"
    static func save(_ password: String, for playlistId: UUID) {
        Keychain.set(password, service: service, account: playlistId.uuidString)
    }
    static func load(for playlistId: UUID) -> String? {
        Keychain.get(service: service, account: playlistId.uuidString)
    }
    static func delete(for playlistId: UUID) {
        Keychain.delete(service: service, account: playlistId.uuidString)
    }
}

/// A saved reference to an IPTV playlist. We persist a source descriptor
/// (either Xtream creds or a plain M3U URL) + a user-chosen name; the
/// actual channel list is re-fetched on demand because:
///   - playlists update server-side (channels added/removed, URLs rotated)
///   - some are huge (10k+ channels) and don't belong in UserDefaults-sized
///     storage
struct IptvPlaylistRef: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    /// M3U URL for `.m3u` / `.m3u8` sources. Empty when `xtream` is set.
    var url: String
    /// When set, the playlist is loaded via the Xtream Codes JSON API.
    /// Absent in older saved state — the Codable default keeps backwards
    /// compatibility with on-disk JSON that pre-dates Xtream support.
    var xtream: XtreamCredentials?
    var addedAt: Date

    var isXtream: Bool { xtream != nil }
}

struct IptvPersistence {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL { self.fileURL = fileURL; return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Veltrio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("iptv.json")
    }

    func load() -> [IptvPlaylistRef] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            var refs = try decoder.decode([IptvPlaylistRef].self, from: data)
            // Hydrate passwords from the Keychain — they're not in the JSON.
            for i in refs.indices {
                if let creds = refs[i].xtream, creds.password.isEmpty,
                   let pass = XtreamKeychain.load(for: refs[i].id) {
                    refs[i].xtream?.password = pass
                }
            }
            return refs
        } catch {
            // Don't silently return [] — that would make the next save wipe
            // the file. Back the corrupted file aside so the user still has
            // their data, log loudly, and start fresh.
            let backup = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            NSLog("IptvPersistence: failed to decode playlists (%@); moved to %@",
                  "\(error)", backup.path)
            return []
        }
    }

    func save(_ refs: [IptvPlaylistRef]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(refs) else { return }

        // Write with file-owner-only perms so other local users can't read
        // what landed in the JSON (even though passwords live in Keychain,
        // host/user/url is still fingerprintable).
        do {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
            )
        } catch {
            NSLog("IptvPersistence: save failed: %@", "\(error)")
        }

        // Keep the Keychain in sync with the current ref set — write any
        // new passwords, remove entries for playlists that were deleted.
        for ref in refs {
            if let creds = ref.xtream, !creds.password.isEmpty {
                XtreamKeychain.save(creds.password, for: ref.id)
            }
        }
    }
}

// MARK: - Xtream Codes API client

/// Talks to a provider's `player_api.php` endpoint and maps the JSON into
/// the same `IptvChannel` shape as the M3U parser — so the rest of the app
/// doesn't need a second channel model.
///
/// What this gives us over parsing the M3U dump:
///   - typed category list (proper names, not "group-title" guesses)
///   - stream ids, which lets us construct direct `/live/{user}/{pass}/{id}.ext`
///     URLs in whatever container format the user picked (ts / m3u8 / rtmp)
///   - clean EPG channel ids (`epg_channel_id`) for later XMLTV wiring
///   - stream logos (`stream_icon`)
struct XtreamClient {
    enum APIError: LocalizedError {
        case http(Int)
        case decoding(String)
        case authFailed
        case invalidServer
        var errorDescription: String? {
            switch self {
            // Too many requests or connections (511 is what some panels
            // answer then, though it's meant for captive portals).
            case .http(let c) where c == 429 || c == 511:
                return String(localized: "Your IPTV provider is limiting connections. Try again in a few minutes.")
            case .http(let c):     return String(localized: "Xtream server returned HTTP \(c).")
            case .decoding(let m): return String(localized: "Could not parse Xtream response: \(m)")
            case .authFailed:      return String(localized: "Xtream authentication failed — check username and password.")
            case .invalidServer:   return String(localized: "Xtream server URL is invalid.")
            }
        }
    }

    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            // Ephemeral so credentials-carrying URLs don't end up in the
            // shared URL cache. Short timeouts so a hanging provider can't
            // sit on a spinner for the default 60s+.
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 20
            cfg.timeoutIntervalForResource = 60
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    /// Hit `action=` on `player_api.php` and decode the array response.
    /// Live TV only for now; VOD / series use the same endpoint with
    /// different actions and can be added when those tabs land.
    func fetchLiveChannels(_ credentials: XtreamCredentials) async throws -> [IptvChannel] {
        async let cats:    [Category]   = fetch(action: "get_live_categories", credentials: credentials)
        async let streams: [LiveStream] = fetch(action: "get_live_streams",    credentials: credentials)

        let (categoriesList, streamsList) = try await (cats, streams)

        // Build id → name map, skipping entries where either side is null —
        // some panels seed a "default" row with every field blank.
        var catName: [String: String] = [:]
        for c in categoriesList {
            guard let id = c.categoryId?.value, let name = c.categoryName?.nonEmpty else { continue }
            catName[id] = name
        }

        let host = credentials.normalizedHost
        let user = credentials.username
        let pass = credentials.password
        let ext  = credentials.output.isEmpty ? "ts" : credentials.output

        return streamsList.compactMap { s -> IptvChannel? in
            // Without a stream id there's no URL to build, so drop the row.
            guard let streamIdValue = s.streamId?.value, !streamIdValue.isEmpty else { return nil }
            let displayName = s.name?.nonEmpty ?? "Channel \(streamIdValue)"
            let group = s.categoryId.flatMap { catName[$0.value] }
                ?? s.categoryName?.nonEmpty
                ?? "Ungrouped"
            let streamUrl = "\(host)/live/\(escape(user))/\(escape(pass))/\(streamIdValue).\(ext)"
            return IptvChannel(
                id: "xtream-\(streamIdValue)",
                name: displayName,
                streamUrl: streamUrl,
                logoUrl: s.streamIcon?.nonEmpty,
                group: group,
                tvgId: s.epgChannelId?.nonEmpty,
                tvgName: displayName,
                tvgCountry: nil,
                tvgLanguage: nil
            )
        }
    }

    /// Fetch VOD (movies). Streams play from `{host}/movie/{u}/{p}/{id}.{ext}`,
    /// which mpv handles natively. We reuse `IptvChannel` as the carrier
    /// because the IPTV grid already renders it nicely — the "live" badge
    /// still fits a movie thumbnail in a browse context, though a future
    /// refactor could split live vs. VOD into their own types.
    func fetchVOD(_ credentials: XtreamCredentials) async throws -> [IptvChannel] {
        async let cats:    [Category]  = fetch(action: "get_vod_categories", credentials: credentials)
        async let streams: [VodStream] = fetch(action: "get_vod_streams",    credentials: credentials)
        let (categoriesList, streamsList) = try await (cats, streams)
        var catName: [String: String] = [:]
        for c in categoriesList {
            guard let id = c.categoryId?.value, let n = c.categoryName?.nonEmpty else { continue }
            catName[id] = n
        }
        let host = credentials.normalizedHost
        let user = credentials.username, pass = credentials.password

        return streamsList.compactMap { s in
            guard let sid = s.streamId?.value, !sid.isEmpty else { return nil }
            let name = s.name?.nonEmpty ?? "Movie \(sid)"
            let ext = s.containerExtension?.nonEmpty ?? "mp4"
            let group = s.categoryId.flatMap { catName[$0.value] } ?? "Movies"
            let url = "\(host)/movie/\(escape(user))/\(escape(pass))/\(sid).\(ext)"
            return IptvChannel(
                id: "xvod-\(sid)", name: name, streamUrl: url,
                logoUrl: s.streamIcon?.nonEmpty, group: group,
                tvgId: nil, tvgName: name, tvgCountry: nil, tvgLanguage: nil
            )
        }
    }

    /// Fetch Series. Returns the top-level series list; the detail view
    /// uses `get_series_info` to drill down into seasons+episodes.
    func fetchSeries(_ credentials: XtreamCredentials) async throws -> [IptvChannel] {
        async let cats:    [Category]    = fetch(action: "get_series_categories", credentials: credentials)
        async let series:  [SeriesEntry] = fetch(action: "get_series",            credentials: credentials)
        let (categoriesList, list) = try await (cats, series)
        var catName: [String: String] = [:]
        for c in categoriesList {
            guard let id = c.categoryId?.value, let n = c.categoryName?.nonEmpty else { continue }
            catName[id] = n
        }
        return list.compactMap { s in
            guard let sid = s.seriesId?.value, !sid.isEmpty else { return nil }
            let name = s.name?.nonEmpty ?? "Series \(sid)"
            let group = s.categoryId.flatMap { catName[$0.value] } ?? "Series"
            // Series don't have a direct URL. We stash the series id in the
            // streamUrl field, prefixed, so the UI opens `IptvSeriesView`
            // (which fetches episodes) instead of the player.
            return IptvChannel(
                id: "xseries-\(sid)", name: name,
                streamUrl: "xtream-series://\(sid)",
                logoUrl: s.cover?.nonEmpty, group: group,
                tvgId: nil, tvgName: name, tvgCountry: nil, tvgLanguage: nil
            )
        }
    }

    // MARK: - Search

    /// Search the provider's VOD and series catalogues for a title.
    ///
    /// Xtream panels accept a `search=` parameter on the same endpoints
    /// that list everything, so this is a server-side filter rather than
    /// a download-then-filter. That matters: a large provider lists tens
    /// of thousands of films, and pulling all of them to find one title
    /// would take minutes and hundreds of megabytes.
    ///
    /// Many providers ignore `search=` and answer with the full catalogue,
    /// so every row is also matched against the query here; the server
    /// filter is only a saving when the panel honours it.
    func search(credentials: XtreamCredentials, query: String, limit: Int = 40) async -> [IptvChannel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        async let vod = searchVOD(credentials: credentials, query: trimmed, limit: limit)
        async let series = searchSeries(credentials: credentials, query: trimmed, limit: limit)
        // Films first: when someone searches for a title they usually mean
        // the film, and the series entry for the same name is usually the
        // show of the same name, which is not what they typed. Concatenating
        // keeps that order; `group` holds the provider's category name, so
        // it can't be used to tell films from series.
        let results = await vod + series
        return Array(results.prefix(limit))
    }

    private func searchVOD(credentials: XtreamCredentials, query: String, limit: Int,
                           matching: ((String) -> Bool)? = nil) async -> [IptvChannel] {
        let matches = matching ?? { Self.title($0, matches: query) }
        let rows: [VodStream] = (await searchRows(action: "get_vod_streams", credentials: credentials,
                                                  query: query))
            .filter { matches($0.name ?? "") }
        guard !rows.isEmpty else { return [] }

        // Category names make the result read like a catalogue entry
        // ("Movies · Action") instead of a bare title.
        var catName: [String: String] = [:]
        if let cats = try? await cachedCatalogue(action: "get_vod_categories", credentials: credentials) as [Category] {
            for c in cats {
                guard let id = c.categoryId?.value, let n = c.categoryName?.nonEmpty else { continue }
                catName[id] = n
            }
        }

        let host = credentials.normalizedHost
        let user = credentials.username, pass = credentials.password

        return rows.prefix(limit).compactMap { s -> IptvChannel? in
            guard let sid = s.streamId?.value, !sid.isEmpty else { return nil }
            let name = s.name?.nonEmpty ?? "Movie \(sid)"
            let ext = s.containerExtension?.nonEmpty ?? "mp4"
            let group = s.categoryId.flatMap { catName[$0.value] } ?? "Movies"
            let url = "\(host)/movie/\(escape(user))/\(escape(pass))/\(sid).\(ext)"
            return IptvChannel(
                id: "xvod-\(sid)", name: name, streamUrl: url,
                logoUrl: s.streamIcon?.nonEmpty, group: group,
                tvgId: nil, tvgName: name, tvgCountry: nil, tvgLanguage: nil
            )
        }
    }

    private func searchSeries(credentials: XtreamCredentials, query: String, limit: Int,
                              matching: ((String) -> Bool)? = nil) async -> [IptvChannel] {
        let matches = matching ?? { Self.title($0, matches: query) }
        let rows: [SeriesEntry] = (await searchRows(action: "get_series", credentials: credentials,
                                                    query: query))
            .filter { matches($0.name ?? "") }
        guard !rows.isEmpty else { return [] }

        var catName: [String: String] = [:]
        if let cats = try? await cachedCatalogue(action: "get_series_categories", credentials: credentials) as [Category] {
            for c in cats {
                guard let id = c.categoryId?.value, let n = c.categoryName?.nonEmpty else { continue }
                catName[id] = n
            }
        }

        return rows.prefix(limit).compactMap { s -> IptvChannel? in
            guard let sid = s.seriesId?.value, !sid.isEmpty else { return nil }
            let name = s.name?.nonEmpty ?? "Series \(sid)"
            let group = s.categoryId.flatMap { catName[$0.value] } ?? "Series"
            return IptvChannel(
                id: "xseries-\(sid)", name: name,
                streamUrl: "xtream-series://\(sid)",
                logoUrl: s.cover?.nonEmpty, group: group,
                tvgId: nil, tvgName: name, tvgCountry: nil, tvgLanguage: nil
            )
        }
    }

    /// Rows for a `search=` query, from the cached full catalogue when the
    /// provider is known to ignore the parameter.
    ///
    /// A provider that ignores `search=` answers with everything — tens of
    /// thousands of rows. When an answer is that large it is kept as the
    /// full catalogue, and later searches filter it locally instead of
    /// downloading it again.
    private func searchRows<T: Decodable>(action: String, credentials: XtreamCredentials,
                                          query: String) async -> [T] {
        let key = XtreamCatalogCache.key(credentials, action)
        if let full: [T] = XtreamCatalogCache.shared.get(key) { return full }
        let rows: [T] = (try? await fetch(action: action, credentials: credentials, search: query)) ?? []
        if rows.count >= 500 { XtreamCatalogCache.shared.set(key, rows) }
        return rows
    }

    private func cachedCatalogue<T: Decodable>(action: String, credentials: XtreamCredentials) async throws -> [T] {
        let key = XtreamCatalogCache.key(credentials, action)
        if let rows: [T] = XtreamCatalogCache.shared.get(key) { return rows }
        let rows: [T] = try await fetch(action: action, credentials: credentials)
        XtreamCatalogCache.shared.set(key, rows)
        return rows
    }

    // MARK: - Matching an IMDB title

    /// The provider's copies of one film, matched by title and year.
    func findMovie(_ credentials: XtreamCredentials, title: String, year: Int?) async -> [IptvChannel] {
        await searchVOD(credentials: credentials, query: title, limit: 50) {
            Self.isSameTitle($0, title, year: year)
        }
    }

    /// The provider's copies of one episode: the series is matched by
    /// title and year, then its episode list is fetched.
    func findEpisode(_ credentials: XtreamCredentials, title: String, year: Int?,
                     season: Int, episode: Int) async -> [(series: IptvChannel, episode: XtreamEpisode)] {
        let series = await searchSeries(credentials: credentials, query: title, limit: 50) {
            Self.isSameTitle($0, title, year: year)
        }
        var found: [(IptvChannel, XtreamEpisode)] = []
        // A title rarely has more than a couple of copies (one per
        // language); cap the info calls so a loose match can't fan out.
        for s in series.prefix(4) {
            guard let sid = s.xtreamSeriesId,
                  let info = try? await fetchSeriesInfo(credentials, seriesId: sid),
                  let ep = info.seasons.first(where: { $0.number == season })?
                    .episodes.first(where: { $0.number == episode })
            else { continue }
            found.append((s, ep))
        }
        return found
    }

    /// Provider names dress titles up: "NF - The Irishman (2019)",
    /// "FR | Dune [MULTI]". Strip that down to the bare title and compare;
    /// when both sides carry a year they must agree to within one (release
    /// dates differ between countries).
    static func isSameTitle(_ providerName: String, _ title: String, year: Int?) -> Bool {
        // A trailing number may be part of the title ("Blade Runner 2049")
        // or a year the provider appended ("Dune 2021"). Equal with it
        // kept: only a bracketed year can disagree. Equal only once it is
        // dropped: it was a year, and it has to agree.
        let theirs: Int?
        if normalizedTitle(providerName, keepTrailingYear: true)
            == normalizedTitle(title, keepTrailingYear: true) {
            theirs = self.year(in: providerName, trailing: false)
        } else if normalizedTitle(providerName) == normalizedTitle(title) {
            theirs = self.year(in: providerName, trailing: true)
        } else {
            return false
        }
        if let year, let theirs { return abs(theirs - year) <= 1 }
        return true
    }

    static func normalizedTitle(_ raw: String, keepTrailingYear: Bool = false) -> String {
        var s = raw
        // Leading tags: "NF - ", "FR | ", "[4K] ", "VOSTFR: "… A tag is
        // upper-case and set off by a pipe or a spaced dash, so
        // "Spider-Man" and "ALIEN: Romulus" keep their first word.
        while let r = s.range(of: #"^\s*(\[[^\]]*\]|\([^)]*\)|[A-Z0-9+]{1,8}\s*(\||\s-\s))\s*"#,
                              options: .regularExpression) {
            s.removeSubrange(r)
        }
        // Anything in brackets or parentheses: years, "(Multi-Audio)"…
        s = s.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
        // A trailing bare year: "Dune 2021".
        if !keepTrailingYear {
            s = s.replacingOccurrences(of: #"\s(19|20)\d{2}\s*$"#, with: " ", options: .regularExpression)
        }
        s = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        let words = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.joined(separator: " ")
    }

    /// A bracketed year — "(2019)" — and, when `trailing`, a bare one at
    /// the end of the name.
    static func year(in name: String, trailing: Bool = true) -> Int? {
        var patterns = [#"[\(\[]\s*((?:19|20)\d{2})\s*[\)\]]"#]
        if trailing { patterns.append(#"\s((?:19|20)\d{2})\s*$"#) }
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let all = re.matches(in: name, range: NSRange(name.startIndex..., in: name))
            if let last = all.last, let r = Range(last.range(at: 1), in: name) {
                return Int(name[r])
            }
        }
        return nil
    }

    /// Language of a provider entry, read from its category ("FR | Films",
    /// "VOSTFR - Séries") and failing that from its name's leading tag.
    static func language(category: String?, name: String?) -> String? {
        for text in [category, name.map(leadingTag)] {
            guard let text else { continue }
            let tokens = text.uppercased().split(whereSeparator: { !$0.isLetter })
            if let lang = tokens.lazy.compactMap({ languageCodes[String($0)] }).first { return lang }
        }
        return nil
    }

    /// Only the tag before the title — "FR" in "FR - Dune". Scanning the
    /// whole name would read "It" or "Us" as a language.
    private static func leadingTag(_ name: String) -> String {
        guard let r = name.range(of: #"^\s*(\[[^\]]*\]|[A-Z]{2,8}(?=\s*(\||\s-\s|:\s)))"#, options: .regularExpression)
        else { return "" }
        return String(name[r])
    }

    private static let languageCodes: [String: String] = [
        "FR": "FR", "FRA": "FR", "FRE": "FR", "FRENCH": "FR", "FRANCE": "FR", "VF": "VF", "VFF": "VF",
        "VFQ": "VFQ", "TRUEFRENCH": "VF", "VOSTFR": "VOSTFR", "VOST": "VOSTFR",
        "EN": "EN", "ENG": "EN", "ENGLISH": "EN", "UK": "EN", "US": "EN", "USA": "EN",
        "AR": "AR", "ARA": "AR", "ARABIC": "AR", "DE": "DE", "GER": "DE", "GERMAN": "DE", "DEUTSCH": "DE",
        "ES": "ES", "ESP": "ES", "SPA": "ES", "SPANISH": "ES", "IT": "IT", "ITA": "IT", "ITALIAN": "IT",
        "NL": "NL", "DUTCH": "NL", "TR": "TR", "TURK": "TR", "TURKISH": "TR",
        "PT": "PT", "POR": "PT", "BR": "PT-BR", "PORTUGUESE": "PT",
        "MULTI": "MULTI", "MULTISUB": "MULTI"
    ]

    /// Every word of the query appears in the title, ignoring case and
    /// accents. Provider prefixes like "NF - " or "FR | " don't get in the
    /// way because only the query's words have to be found.
    static func title(_ name: String?, matches query: String) -> Bool {
        guard let name else { return false }
        let fold: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let haystack = fold(name)
        let words = fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return !words.isEmpty && words.allSatisfy { haystack.contains($0) }
    }

    // MARK: - Series detail

    /// Seasons and episodes for one series, via `get_series_info`.
    ///
    /// Episodes play from `{host}/series/{u}/{p}/{episode_id}.{ext}`. Each
    /// one is handed back as an `IptvChannel` (id `xep-<id>`) so it rides
    /// the same player path as films.
    func fetchSeriesInfo(_ credentials: XtreamCredentials, seriesId: String) async throws -> XtreamSeries {
        let url = try endpoint(credentials: credentials, action: "get_series_info",
                               extra: [URLQueryItem(name: "series_id", value: seriesId)])
        let (data, response) = try await session.data(from: url)
        try assertOK(response)

        // Panels answer bad credentials with a bare user_info envelope and
        // an unknown series id with `[]`, both over HTTP 200. The lenient
        // decoder below would read either as a series with no episodes.
        if let info = try? JSONDecoder().decode(UserInfoResponse.self, from: data),
           info.userInfo?.auth == 0 {
            throw APIError.authFailed
        }
        if (try? JSONSerialization.jsonObject(with: data)) is [Any] {
            return XtreamSeries(id: seriesId, name: "Series \(seriesId)", plot: nil, cover: nil,
                                backdrop: nil, genre: nil, releaseDate: nil, rating: nil, seasons: [])
        }
        let wire: SeriesInfoResponse
        do {
            wire = try JSONDecoder().decode(SeriesInfoResponse.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }

        let meta = wire.info
        let seriesName = meta?.name?.nonEmpty ?? "Series \(seriesId)"
        let cover = meta?.cover?.nonEmpty
        let host = credentials.normalizedHost
        let user = credentials.username, pass = credentials.password

        // Group by the episode's own season field when it has one; the
        // dictionary key is only a fallback because some panels key the
        // map by position rather than by season number.
        var bySeason: [Int: [XtreamEpisode]] = [:]
        for (key, rows) in wire.episodes {
            for (index, e) in rows.enumerated() {
                guard let eid = e.id?.value, !eid.isEmpty else { continue }
                let season = e.season.flatMap { Int($0.value) } ?? Int(key) ?? 1
                let number = e.episodeNum.flatMap { Int($0.value) } ?? index + 1
                let title = e.title?.nonEmpty ?? "Episode \(number)"
                let ext = e.containerExtension?.nonEmpty ?? "mp4"
                let image = e.info?.movieImage?.nonEmpty
                let channel = IptvChannel(
                    id: "xep-\(eid)", name: title,
                    streamUrl: "\(host)/series/\(escape(user))/\(escape(pass))/\(eid).\(ext)",
                    logoUrl: image ?? cover,
                    group: "\(seriesName) · Season \(season) · Episode \(number)",
                    tvgId: nil, tvgName: title, tvgCountry: nil, tvgLanguage: nil
                )
                bySeason[season, default: []].append(XtreamEpisode(
                    id: eid, season: season, number: number, title: title,
                    plot: e.info?.plot?.nonEmpty, image: image,
                    duration: e.info?.duration?.nonEmpty, channel: channel
                ))
            }
        }

        let seasons = bySeason.keys.sorted().map { n in
            XtreamSeason(number: n, episodes: bySeason[n]!.sorted { $0.number < $1.number })
        }
        return XtreamSeries(
            id: seriesId, name: seriesName,
            plot: meta?.plot?.nonEmpty, cover: cover,
            backdrop: meta?.backdropPath?.first?.nonEmpty,
            genre: meta?.genre?.nonEmpty,
            releaseDate: meta?.releaseDate?.nonEmpty,
            rating: meta?.rating?.value.nonEmpty,
            seasons: seasons
        )
    }

    /// Catchup EPG = last 24-48h of programmes on a channel. Same wire
    /// format as the short EPG but a different action.
    func fetchCatchupEPG(        _ credentials: XtreamCredentials, streamId: String, limit: Int = 48
    ) async -> [ShortEPGEntry] {
        do {
            let host = credentials.normalizedHost
            guard var comps = URLComponents(string: "\(host)/player_api.php") else { return [] }
            comps.queryItems = [
                URLQueryItem(name: "username",  value: credentials.username),
                URLQueryItem(name: "password",  value: credentials.password),
                URLQueryItem(name: "action",    value: "get_simple_data_table"),
                URLQueryItem(name: "stream_id", value: streamId),
                URLQueryItem(name: "limit",     value: String(limit))
            ]
            guard let url = comps.url else { return [] }
            let (data, response) = try await session.data(from: url)
            try assertOK(response)
            let wrap = try JSONDecoder().decode(ShortEPGWrap.self, from: data)
            // Filter to past + current slots so the UI shows "replayable".
            let now = Date()
            return wrap.epgListings.filter {
                guard let start = $0.start, let d = parseEpg(start) else { return false }
                return d <= now.addingTimeInterval(60)
            }
        } catch {
            return []
        }
    }

    /// Build a timeshift URL for a given start time on a stream. Xtream
    /// panels accept the `/timeshift/` endpoint with a UTC start and
    /// a duration in minutes:
    ///   `{host}/timeshift/{user}/{pass}/{duration}/{YYYY-MM-DD:HH-mm}/{stream_id}.{ext}`
    func timeshiftURL(
        _ credentials: XtreamCredentials,
        streamId: String,
        start: Date,
        durationMinutes: Int
    ) -> URL? {
        let host = credentials.normalizedHost
        let u = escape(credentials.username)
        let p = escape(credentials.password)
        let ext = credentials.output.isEmpty ? "ts" : credentials.output
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd:HH-mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        let stamp = f.string(from: start)
        return URL(string: "\(host)/timeshift/\(u)/\(p)/\(durationMinutes)/\(stamp)/\(streamId).\(ext)")
    }

    private func parseEpg(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }

    /// Short EPG for a given live stream (next few programs). Returns
    /// base64-decoded titles so the UI can render "now · next" labels.
    func fetchShortEPG(_ credentials: XtreamCredentials, streamId: String) async -> [ShortEPGEntry] {
        do {
            let host = credentials.normalizedHost
            guard var comps = URLComponents(string: "\(host)/player_api.php") else { return [] }
            comps.queryItems = [
                URLQueryItem(name: "username", value: credentials.username),
                URLQueryItem(name: "password", value: credentials.password),
                URLQueryItem(name: "action", value: "get_short_epg"),
                URLQueryItem(name: "stream_id", value: streamId),
            ]
            guard let url = comps.url else { return [] }
            let (data, response) = try await session.data(from: url)
            try assertOK(response)
            let wrap = try JSONDecoder().decode(ShortEPGWrap.self, from: data)
            return wrap.epgListings
        } catch {
            return []
        }
    }

    /// Lightweight auth probe used by the add-sheet "Test" affordance.
    /// Returns the raw user info so we can surface expiry, concurrent-
    /// connection limits etc. later on.
    @discardableResult
    func verify(_ credentials: XtreamCredentials) async throws -> UserInfoResponse {
        let url = try endpoint(credentials: credentials, action: nil)
        let (data, response) = try await session.data(from: url)
        try assertOK(response)
        do {
            let info = try JSONDecoder().decode(UserInfoResponse.self, from: data)
            // An empty / absent user_info means the server answered but
            // didn't recognise us — treat as auth failure, not as success.
            guard let user = info.userInfo else {
                throw APIError.authFailed
            }
            if let auth = user.auth, auth == 0 { throw APIError.authFailed }
            if let status = user.status?.lowercased(),
               status != "active" && status != "trial" {
                throw APIError.authFailed
            }
            return info
        } catch let dec as DecodingError {
            throw APIError.decoding(String(describing: dec))
        }
    }

    // ---- internals ----

    private func fetch<T: Decodable>(action: String, credentials: XtreamCredentials,
                                     search: String? = nil) async throws -> [T] {
        let url = try endpoint(credentials: credentials, action: action, search: search)
        let (data, response) = try await session.data(from: url)
        try assertOK(response)

        // Skip over whitespace / BOM before checking the shape.
        var start = 0
        while start < data.count {
            let b = data[start]
            if b == 0xEF || b == 0xBB || b == 0xBF || b == 0x20 || b == 0x09
                || b == 0x0A || b == 0x0D { start += 1 } else { break }
        }
        let first: UInt8? = start < data.count ? data[start] : nil

        if first == UInt8(ascii: "{") {
            // A `{` body usually means an error or an empty-result envelope.
            // Try to pull a user_info out of it — if auth==0, surface it.
            if let info = try? JSONDecoder().decode(UserInfoResponse.self, from: data),
               info.userInfo?.auth == 0 {
                throw APIError.authFailed
            }
            return []
        }

        // Decode row-by-row so one malformed entry doesn't nuke the entire
        // list. Xtream panels regularly emit e.g. an int where a string is
        // expected on a single stream — we'd rather lose that row than the
        // other 5000.
        guard first == UInt8(ascii: "[") else {
            throw APIError.decoding("Expected JSON array, got unexpected content")
        }
        let decoder = JSONDecoder()
        do {
            // Fast path: full decode.
            return try decoder.decode([T].self, from: data)
        } catch {
            // Slow path: iterate raw elements and keep what parses.
            guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw APIError.decoding(String(describing: error))
            }
            var out: [T] = []
            out.reserveCapacity(jsonArray.count)
            for raw in jsonArray {
                guard let rawData = try? JSONSerialization.data(withJSONObject: raw) else { continue }
                if let decoded = try? decoder.decode(T.self, from: rawData) {
                    out.append(decoded)
                }
            }
            return out
        }
    }

    private func endpoint(credentials: XtreamCredentials, action: String?, search: String? = nil,
                          extra: [URLQueryItem] = []) throws -> URL {
        let host = credentials.normalizedHost
        guard !host.isEmpty, var comps = URLComponents(string: "\(host)/player_api.php") else {
            throw APIError.invalidServer
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password),
        ]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        if let search, !search.isEmpty { items.append(URLQueryItem(name: "search", value: search)) }
        items += extra
        comps.queryItems = items
        guard let url = comps.url else { throw APIError.invalidServer }
        return url
    }

    private func assertOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.http(0) }
        guard (200...299).contains(http.statusCode) else { throw APIError.http(http.statusCode) }
    }

    private func escape(_ s: String) -> String {
        // Build a stricter path-segment allowed set — the stock
        // `.urlPathAllowed` leaves `/ ? # : @ %` alone, which breaks the URL
        // when a password contains any of them. We allow unreserved +
        // sub-delims only (RFC 3986 pchar minus `/?#:@%`).
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // ---- wire types ----

    // Every wire type here uses optionals everywhere because Xtream
    // panels wildly disagree on what counts as "present": some return null,
    // some omit the key, some send an empty string. Tolerating all of them
    // at decode time keeps provider-specific quirks out of the business logic.
    struct Category: Decodable {
        let categoryId: FlexibleId?
        let categoryName: String?
        enum CodingKeys: String, CodingKey {
            case categoryId   = "category_id"
            case categoryName = "category_name"
        }
    }

    struct LiveStream: Decodable {
        let streamId: FlexibleId?
        let name: String?
        let streamIcon: String?
        let epgChannelId: String?
        let categoryId: FlexibleId?
        let categoryName: String?
        enum CodingKeys: String, CodingKey {
            case streamId     = "stream_id"
            case name
            case streamIcon   = "stream_icon"
            case epgChannelId = "epg_channel_id"
            case categoryId   = "category_id"
            case categoryName = "category_name"
        }
    }

    struct VodStream: Decodable {
        let streamId: FlexibleId?
        let name: String?
        let streamIcon: String?
        let rating: String?
        let categoryId: FlexibleId?
        let containerExtension: String?
        enum CodingKeys: String, CodingKey {
            case streamId = "stream_id"
            case name
            case streamIcon = "stream_icon"
            case rating
            case categoryId = "category_id"
            case containerExtension = "container_extension"
        }
    }

    struct SeriesEntry: Decodable {
        let seriesId: FlexibleId?
        let name: String?
        let cover: String?
        let categoryId: FlexibleId?
        let plot: String?
        let releaseDate: String?
        let rating: String?
        let youtubeTrailer: String?
        enum CodingKeys: String, CodingKey {
            case seriesId = "series_id"
            case name, cover, plot, rating
            case categoryId = "category_id"
            case releaseDate = "release_date"
            case youtubeTrailer = "youtube_trailer"
        }
    }

    /// `get_series_info` body. `episodes` is a map of season → rows on most
    /// panels, but some send an array of arrays, and `info` is sometimes an
    /// empty array instead of an object — every field decodes leniently.
    struct SeriesInfoResponse: Decodable {
        let info: SeriesMeta?
        let episodes: [String: [EpisodeEntry]]
        enum CodingKeys: String, CodingKey { case info, episodes }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            info = try? c.decode(SeriesMeta.self, forKey: .info)
            if let map = try? c.decode([String: [EpisodeEntry]].self, forKey: .episodes) {
                episodes = map
            } else if let list = try? c.decode([[EpisodeEntry]].self, forKey: .episodes) {
                var map: [String: [EpisodeEntry]] = [:]
                for (i, rows) in list.enumerated() { map[String(i + 1)] = rows }
                episodes = map
            } else {
                episodes = [:]
            }
        }
    }

    struct SeriesMeta: Decodable {
        let name: String?
        let cover: String?
        let plot: String?
        let genre: String?
        let releaseDate: String?
        let rating: FlexibleId?
        let backdropPath: [String]?
        enum CodingKeys: String, CodingKey {
            case name, cover, plot, genre, rating
            case releaseDate = "releaseDate"
            case releaseDateSnake = "release_date"
            case backdropPath = "backdrop_path"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try? c.decode(String.self, forKey: .name)
            cover = try? c.decode(String.self, forKey: .cover)
            plot = try? c.decode(String.self, forKey: .plot)
            genre = try? c.decode(String.self, forKey: .genre)
            releaseDate = (try? c.decode(String.self, forKey: .releaseDate))
                ?? (try? c.decode(String.self, forKey: .releaseDateSnake))
            rating = try? c.decode(FlexibleId.self, forKey: .rating)
            // A list of URLs on most panels, a single string on a few.
            backdropPath = (try? c.decode([String].self, forKey: .backdropPath))
                ?? (try? c.decode(String.self, forKey: .backdropPath)).map { [$0] }
        }
    }

    struct EpisodeEntry: Decodable {
        let id: FlexibleId?
        let episodeNum: FlexibleId?
        let title: String?
        let containerExtension: String?
        let season: FlexibleId?
        let info: EpisodeInfo?
        enum CodingKeys: String, CodingKey {
            case id, title, season, info
            case episodeNum = "episode_num"
            case containerExtension = "container_extension"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decode(FlexibleId.self, forKey: .id)
            episodeNum = try? c.decode(FlexibleId.self, forKey: .episodeNum)
            title = try? c.decode(String.self, forKey: .title)
            containerExtension = try? c.decode(String.self, forKey: .containerExtension)
            season = try? c.decode(FlexibleId.self, forKey: .season)
            info = try? c.decode(EpisodeInfo.self, forKey: .info)
        }
    }

    struct EpisodeInfo: Decodable {
        let movieImage: String?
        let plot: String?
        let duration: String?
        enum CodingKeys: String, CodingKey {
            case plot, duration
            case movieImage = "movie_image"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            movieImage = try? c.decode(String.self, forKey: .movieImage)
            plot = try? c.decode(String.self, forKey: .plot)
            duration = try? c.decode(String.self, forKey: .duration)
        }
    }

    struct ShortEPGWrap: Decodable {
        let epgListings: [ShortEPGEntry]
        enum CodingKeys: String, CodingKey { case epgListings = "epg_listings" }
    }

    struct UserInfoResponse: Decodable {
        let userInfo: UserInfo?
        let serverInfo: ServerInfo?
        enum CodingKeys: String, CodingKey {
            case userInfo   = "user_info"
            case serverInfo = "server_info"
        }
    }

    struct UserInfo: Decodable {
        let username: String?
        let status: String?
        let auth: Int?
        let expDate: String?
        let isTrial: String?
        let activeCons: String?
        let maxConnections: String?
        enum CodingKeys: String, CodingKey {
            case username, status, auth
            case expDate        = "exp_date"
            case isTrial        = "is_trial"
            case activeCons     = "active_cons"
            case maxConnections = "max_connections"
        }
    }

    struct ServerInfo: Decodable {
        let url: String?
        let port: String?
        let httpsPort: String?
        let serverProtocol: String?
        enum CodingKeys: String, CodingKey {
            case url, port
            case httpsPort      = "https_port"
            case serverProtocol = "server_protocol"
        }
    }
}

/// Decoded short-EPG entry from Xtream. `title` and `description` are
/// base64-encoded on most panels — we try both base64 and raw text.
struct ShortEPGEntry: Decodable, Hashable {
    let id: String?
    let epgId: String?
    let title: String?
    let lang: String?
    let start: String?
    let end: String?
    let description: String?
    let channelId: String?
    enum CodingKeys: String, CodingKey {
        case id, lang, title, start, end, description
        case epgId = "epg_id"
        case channelId = "channel_id"
    }

    var decodedTitle: String {
        guard let t = title, let data = Data(base64Encoded: t), let s = String(data: data, encoding: .utf8)
        else { return title ?? "" }
        return s.isEmpty ? (title ?? "") : s
    }
    var decodedDescription: String {
        guard let d = description, let data = Data(base64Encoded: d), let s = String(data: data, encoding: .utf8)
        else { return description ?? "" }
        return s.isEmpty ? (description ?? "") : s
    }
}

/// Full Xtream catalogues, kept for the session.
///
/// Providers that ignore `search=` send the whole catalogue on every
/// query; keeping the last answer means opening a second title doesn't
/// download it all again. Entries expire so new uploads show up.
final class XtreamCatalogCache: @unchecked Sendable {
    static let shared = XtreamCatalogCache()

    private let lock = NSLock()
    private var entries: [String: (stored: Date, rows: Any)] = [:]
    private let lifetime: TimeInterval = 15 * 60

    static func key(_ c: XtreamCredentials, _ action: String) -> String {
        "\(c.normalizedHost)|\(c.username)|\(action)"
    }

    func get<T>(_ key: String) -> [T]? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[key], Date().timeIntervalSince(e.stored) < lifetime else { return nil }
        return e.rows as? [T]
    }

    func set<T>(_ key: String, _ rows: [T]) {
        lock.lock(); defer { lock.unlock() }
        entries[key] = (Date(), rows)
    }
}

/// A series from an Xtream provider, with its episodes grouped by season.
struct XtreamSeries: Hashable {
    let id: String
    let name: String
    let plot: String?
    let cover: String?
    let backdrop: String?
    let genre: String?
    let releaseDate: String?
    let rating: String?
    let seasons: [XtreamSeason]
}

struct XtreamSeason: Hashable, Identifiable {
    let number: Int
    let episodes: [XtreamEpisode]
    var id: Int { number }
}

struct XtreamEpisode: Hashable, Identifiable {
    let id: String
    let season: Int
    let number: Int
    let title: String
    let plot: String?
    let image: String?
    /// "HH:mm:ss" as the panel reports it.
    let duration: String?
    /// Ready-to-play carrier for `PlayerDestination.liveChannel`.
    let channel: IptvChannel
}

extension IptvChannel {
    /// Films (`xvod-`) and series episodes (`xep-`) from an Xtream provider
    /// share the channel model but have a timeline: they seek, resume and
    /// carry subtitle tracks like any other file.
    var isOnDemand: Bool { id.hasPrefix("xvod-") || id.hasPrefix("xep-") }

    /// The Xtream series id when this entry is a series rather than
    /// something playable — see `XtreamClient.fetchSeries`.
    var xtreamSeriesId: String? {
        let scheme = "xtream-series://"
        guard streamUrl.hasPrefix(scheme) else { return nil }
        let id = String(streamUrl.dropFirst(scheme.count))
        return id.isEmpty ? nil : id
    }
}

/// Xtream providers return ids as either JSON strings ("1234") or numbers
/// (1234) depending on the panel version. This decodes both so the client
/// stays generic.
struct FlexibleId: Decodable, Hashable {
    let value: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = s }
        else if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) {
            // Guard against trap in Int(d) on NaN / infinity / overflow.
            guard d.isFinite, abs(d) < 1e15 else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "Numeric id out of range"
                )
            }
            value = String(Int(d))
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Expected a scalar id (string/int/double)"
            )
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
