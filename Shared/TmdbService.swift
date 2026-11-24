import Foundation
import Observation

/// Native TMDB catalog, search, and metadata service for macOS, iOS, and tvOS.
/// Replaces Cinemeta so every catalog row, hero, search result, title page,
/// and episode list is localized in the user's chosen language while resolving
/// IMDb IDs (`external_ids.imdb_id`) for Stremio stream addons.
@MainActor
@Observable
final class TmdbService {
    static let shared = TmdbService()

    static let addonId = "tmdb"
    static let transportUrl = "tmdb://api.themoviedb.org/3"
    static let keyService = "com.veltrio.tmdb.key"
    static let langService = "com.veltrio.tmdb.lang"

    private static let base = "https://api.themoviedb.org/3"
    private static let imgPoster = "https://image.tmdb.org/t/p/w500"
    private static let imgBackdrop = "https://image.tmdb.org/t/p/w1280"
    private static let imgLogo = "https://image.tmdb.org/t/p/w500"
    private static let imgStill = "https://image.tmdb.org/t/p/w500"

    static let languages: [(code: String, label: String)] = [
        ("fr-FR", "Français"),
        ("en-US", "English"),
        ("es-ES", "Español"),
        ("de-DE", "Deutsch"),
        ("it-IT", "Italiano"),
        ("pt-BR", "Português"),
        ("ja-JP", "日本語"),
    ]

    struct LocalizedMeta: Sendable {
        let title: String?
        let overview: String?
    }

    struct TitleExtras: Sendable {
        let trailerURL: URL?
        let recommendations: [MetaPreview]
    }

    private(set) var isConnected = false
    private(set) var language = "fr-FR"
    private(set) var isBusy = false
    private(set) var error: String?
    /// Incremented whenever connection or language changes so Home & caches invalidate.
    private(set) var revision = 0

    private var localizeCache: [String: LocalizedMeta] = [:]
    private var genreCache: [String: [Int: String]] = [:]
    private var extrasCache: [String: TitleExtras] = [:]

    func extras(for id: String) -> TitleExtras? {
        extrasCache["\(id)|\(effectiveLanguage())"]
    }

    private init() {
        reload()
    }

    private func defaultLanguage() -> String {
        AppLocalization.isFrench ? "fr-FR" : "en-US"
    }

    func virtualAddon() -> InstalledAddon {
        let fr = AppLocalization.isFrench
        let skipExtra = ExtraProp(name: "skip", isRequired: false, options: nil, optionsLimit: nil)
        let searchExtra = ExtraProp(name: "search", isRequired: false, options: nil, optionsLimit: nil)
        let manifest = Manifest(
            id: Self.addonId,
            version: "3.0.0",
            name: "TMDB",
            description: fr ? "Catalogues et fiches localisées via The Movie Database." : "Localized catalogs and metadata via The Movie Database.",
            logo: nil,
            background: nil,
            types: ["movie", "series"],
            resources: ["catalog", "meta"],
            catalogs: [
                Catalog(type: "movie", id: "trending", name: fr ? "Films populaires" : "Trending Movies", extra: [skipExtra, searchExtra]),
                Catalog(type: "series", id: "trending", name: fr ? "Séries populaires" : "Trending Series", extra: [skipExtra, searchExtra]),
                Catalog(type: "movie", id: "now_playing", name: fr ? "Au cinéma" : "Now Playing", extra: [skipExtra]),
                Catalog(type: "series", id: "on_the_air", name: fr ? "Séries du moment" : "On The Air", extra: [skipExtra]),
                Catalog(type: "movie", id: "top_rated", name: fr ? "Films les mieux notés" : "Top Rated Movies", extra: [skipExtra]),
                Catalog(type: "series", id: "top_rated", name: fr ? "Séries les mieux notées" : "Top Rated Series", extra: [skipExtra]),
            ],
            idPrefixes: ["tmdb:", "tt"],
            transportUrl: Self.transportUrl
        )
        return InstalledAddon(manifest: manifest, addedAt: Date(timeIntervalSince1970: 0))
    }

    func reload() {
        let wasConnected = isConnected
        let prevLang = language
        let key = Keychain.get(service: Self.keyService)?.trimmingCharacters(in: .whitespacesAndNewlines)
        isConnected = key != nil && !(key?.isEmpty ?? true)
        let saved = Keychain.get(service: Self.langService)?.trimmingCharacters(in: .whitespacesAndNewlines)
        language = (saved?.isEmpty == false) ? saved! : defaultLanguage()
        error = nil
        if isConnected != wasConnected || language != prevLang {
            localizeCache.removeAll()
            genreCache.removeAll()
            extrasCache.removeAll()
            revision += 1
        }
    }

    func setLanguage(_ lang: String) {
        let clean = lang.isEmpty ? defaultLanguage() : lang
        Keychain.set(clean, service: Self.langService)
        language = clean
        localizeCache.removeAll()
        genreCache.removeAll()
        revision += 1
    }

    @discardableResult
    func connect(rawKey: String) async -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            error = "Enter a TMDB API key or Read Access Token.".localized
            return false
        }
        isBusy = true
        error = nil
        defer { isBusy = false }
        guard let req = buildRequest(path: "/configuration", key: key) else {
            error = "Invalid TMDB request.".localized
            return false
        }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(code) else {
                error = "Invalid TMDB key (HTTP \(code))."
                return false
            }
            Keychain.set(key, service: Self.keyService)
            if (Keychain.get(service: Self.langService) ?? "").isEmpty {
                let def = defaultLanguage()
                Keychain.set(def, service: Self.langService)
                language = def
            }
            localizeCache.removeAll()
            genreCache.removeAll()
            isConnected = true
            revision += 1
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func disconnect() {
        Keychain.delete(service: Self.keyService)
        localizeCache.removeAll()
        genreCache.removeAll()
        isConnected = false
        error = nil
        revision += 1
    }

    // MARK: - Catalogs & Search

    func bumpRevision() {
        revision += 1
    }

    func fetchCatalog(type: String, catalogId: String, skip: Int = 0) async throws -> [MetaPreview] {
        guard let key = currentKey() else { return [] }
        let lang = effectiveLanguage()
        let page = (skip / 20) + 1
        let isSeries = type.lowercased() == "series"
        let kids = UserPrefs.shared.kidsMode
        let path: String
        if kids {
            let endpoint = isSeries ? "tv" : "movie"
            let sort = catalogId == "top_rated" ? "vote_average.desc&vote_count.gte=100" : "popularity.desc"
            let cert = isSeries ? "" : "&certification_country=US&certification.lte=PG"
            path = "/discover/\(endpoint)?language=\(lang)&page=\(page)&include_adult=false&with_genres=10751|16&sort_by=\(sort)\(cert)"
        } else {
            switch (isSeries, catalogId) {
            case (false, "trending"):    path = "/trending/movie/week?language=\(lang)&page=\(page)"
            case (true, "trending"):     path = "/trending/tv/week?language=\(lang)&page=\(page)"
            case (false, "now_playing"): path = "/movie/now_playing?language=\(lang)&page=\(page)"
            case (true, "on_the_air"):   path = "/tv/on_the_air?language=\(lang)&page=\(page)"
            case (false, "top_rated"):   path = "/movie/top_rated?language=\(lang)&page=\(page)"
            case (true, "top_rated"):    path = "/tv/top_rated?language=\(lang)&page=\(page)"
            default: return []
            }
        }
        let genres = await genreMap(isSeries: isSeries, lang: lang, key: key)
        let data = try await get(path: path, key: key)
        let resp = try JSONDecoder().decode(TmdbListResponse.self, from: data)
        return resp.results.compactMap { parsePreview($0, type: isSeries ? "series" : "movie", genres: genres) }
    }

    func search(query: String, type: String) async throws -> [MetaPreview] {
        guard let key = currentKey() else { return [] }
        let lang = effectiveLanguage()
        let isSeries = type.lowercased() == "series"
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let endpoint = isSeries ? "tv" : "movie"
        let genres = await genreMap(isSeries: isSeries, lang: lang, key: key)
        let data = try await get(path: "/search/\(endpoint)?query=\(q)&language=\(lang)&include_adult=false", key: key)
        let resp = try JSONDecoder().decode(TmdbListResponse.self, from: data)
        let kids = UserPrefs.shared.kidsMode
        return resp.results
            .filter { item in
                guard kids else { return true }
                if item.adult == true { return false }
                let gids = item.genre_ids ?? []
                return gids.isEmpty || gids.contains(10751) || gids.contains(16)
            }
            .compactMap { parsePreview($0, type: isSeries ? "series" : "movie", genres: genres) }
    }

    struct DiscoverProvider: Identifiable, Hashable {
        let id: Int
        let name: String
        let logoURL: String
        let brandHex: UInt32
    }

    static let discoverProviders: [DiscoverProvider] = [
        .init(id: 8,    name: "Netflix",     logoURL: "https://image.tmdb.org/t/p/w154/pbpMk2JmcoNnQwx5JGpXngfoWtp.jpg", brandHex: 0xE50914),
        .init(id: 350,  name: "Apple TV+",   logoURL: "https://image.tmdb.org/t/p/w154/2E03IAZsX4ZaUqM7tXlctEPMGWS.jpg", brandHex: 0x2C2C2E),
        .init(id: 337,  name: "Disney+",     logoURL: "https://image.tmdb.org/t/p/w154/97yvRBw1GzX7fXprcF80er19ot.jpg", brandHex: 0x113CCF),
        .init(id: 119,  name: "Prime Video", logoURL: "https://image.tmdb.org/t/p/w154/pvske1MyAoymrs5bguRfVqYiM9a.jpg", brandHex: 0x00A8E1),
        .init(id: 1899, name: "Max",         logoURL: "https://image.tmdb.org/t/p/w154/jbe4gVSfRlbPTdESXhEKpornsfu.jpg", brandHex: 0x002BE7),
        .init(id: 381,  name: "Canal+",      logoURL: "https://image.tmdb.org/t/p/w154/eBXzkFEupZjKaIKY7zBUaSdCY8I.jpg", brandHex: 0x1C1C1E),
    ]

    struct DiscoverGenre: Identifiable, Hashable {
        let movieId: Int
        let tvId: Int
        let fr: String
        let en: String
        let icon: String
        let accentHex: UInt32
        var id: Int { movieId }
        var label: String { AppLocalization.isFrench ? fr : en }
    }

    static let discoverGenres: [DiscoverGenre] = [
        .init(movieId: 28,  tvId: 10759, fr: "Action",       en: "Action",      icon: "flame.fill",               accentHex: 0xD94E28),
        .init(movieId: 878, tvId: 10765, fr: "Sci-Fi",       en: "Sci-Fi",      icon: "sparkles",                 accentHex: 0x3B82F6),
        .init(movieId: 35,  tvId: 35,    fr: "Comédie",      en: "Comedy",      icon: "theatermasks.fill",        accentHex: 0xEAB308),
        .init(movieId: 18,  tvId: 18,    fr: "Drame",        en: "Drama",       icon: "film.fill",                accentHex: 0xA855F7),
        .init(movieId: 53,  tvId: 9648,  fr: "Thriller",     en: "Thriller",    icon: "eye.fill",                 accentHex: 0x64748B),
        .init(movieId: 16,  tvId: 16,    fr: "Animation",    en: "Animation",   icon: "wand.and.stars",           accentHex: 0xEC4899),
        .init(movieId: 27,  tvId: 9648,  fr: "Horreur",      en: "Horror",      icon: "moon.stars.fill",          accentHex: 0x991B1B),
        .init(movieId: 99,  tvId: 99,    fr: "Documentaire", en: "Documentary", icon: "globe.europe.africa.fill", accentHex: 0x10B981),
    ]

    func discover(type: String, genreId: Int? = nil, providerId: Int? = nil, page: Int = 1, sortBy: String = "popularity.desc", minVotes: Int? = nil) async throws -> [MetaPreview] {
        guard let key = currentKey() else { return [] }
        let lang = effectiveLanguage()
        let region = lang.split(separator: "-").last.map(String.init) ?? "FR"
        let isSeries = type.lowercased() == "series"
        let endpoint = isSeries ? "tv" : "movie"
        let kids = UserPrefs.shared.kidsMode
        var params = [
            "language=\(lang)",
            "sort_by=\(sortBy)",
            "include_adult=false",
            "page=\(page)",
        ]
        if let minVotes { params.append("vote_count.gte=\(minVotes)") }
        if kids {
            params.append("with_genres=10751|16")
            if !isSeries { params.append("certification_country=US&certification.lte=PG") }
        } else if let genreId {
            params.append("with_genres=\(genreId)")
        }
        if let providerId {
            params.append("with_watch_providers=\(providerId)")
            params.append("watch_region=\(region)")
        }
        let genres = await genreMap(isSeries: isSeries, lang: lang, key: key)
        let data = try await get(path: "/discover/\(endpoint)?\(params.joined(separator: "&"))", key: key)
        let resp = try JSONDecoder().decode(TmdbListResponse.self, from: data)
        return resp.results.compactMap { parsePreview($0, type: isSeries ? "series" : "movie", genres: genres) }
    }

    /// Searches TMDB for a person by name and returns their combined movie & TV filmography.
    func fetchPersonCredits(name: String) async throws -> [MetaPreview] {
        guard let key = currentKey() else { return [] }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        let lang = effectiveLanguage()
        let q = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clean
        let searchData = try await get(path: "/search/person?query=\(q)&language=\(lang)&include_adult=false", key: key)
        let searchResp = try JSONDecoder().decode(TmdbPersonSearchResponse.self, from: searchData)
        guard let personId = searchResp.results.first?.id else { return [] }

        let creditsData = try await get(path: "/person/\(personId)/combined_credits?language=\(lang)", key: key)
        let creditsResp = try JSONDecoder().decode(TmdbPersonCreditsResponse.self, from: creditsData)
        let movieGenres = await genreMap(isSeries: false, lang: lang, key: key)
        let tvGenres = await genreMap(isSeries: true, lang: lang, key: key)
        let kids = UserPrefs.shared.kidsMode
        var seen = Set<String>()
        let all = ((creditsResp.cast ?? []) + (creditsResp.crew ?? []))
            .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
        var out: [MetaPreview] = []
        for item in all {
            guard let mt = item.media_type, (mt == "movie" || mt == "tv") else { continue }
            let dedupKey = "\(mt):\(item.id)"
            guard seen.insert(dedupKey).inserted else { continue }
            if kids {
                if item.adult == true { continue }
                let gids = item.genre_ids ?? []
                if !gids.isEmpty && !gids.contains(10751) && !gids.contains(16) { continue }
            }
            let isSeries = mt == "tv"
            if let preview = parsePreview(item, type: isSeries ? "series" : "movie", genres: isSeries ? tvGenres : movieGenres) {
                out.append(preview)
                if out.count >= 24 { break }
            }
        }
        return out
    }

    // MARK: - Full Meta + Episodes

    func fetchMeta(type: String, id: String) async throws -> Meta {
        guard let key = currentKey() else {
            throw NSError(domain: "TmdbService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Connect your TMDB API key in Settings."])
        }
        let lang = effectiveLanguage()
        let isSeries = type.lowercased() == "series"
        guard let tmdbId = try await resolveTmdbId(id: id, isSeries: isSeries, lang: lang, key: key) else {
            throw NSError(domain: "TmdbService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Title not found on TMDB."])
        }

        let mediaType = isSeries ? "tv" : "movie"
        let langShort = String(lang.prefix(while: { $0 != "-" }))
        let path = "/\(mediaType)/\(tmdbId)?language=\(lang)&append_to_response=external_ids,credits,images,videos,recommendations&include_image_language=\(langShort),en,null"
        let data = try await get(path: path, key: key)
        let detail = try JSONDecoder().decode(TmdbDetailResponse.self, from: data)

        let imdbId = [detail.external_ids?.imdb_id, detail.imdb_id, id.hasPrefix("tt") ? id : nil]
            .compactMap { $0 }
            .first(where: { $0.hasPrefix("tt") })
        let canonicalId = imdbId ?? "tmdb:\(tmdbId)"

        let title = (detail.title ?? detail.name ?? detail.original_title ?? detail.original_name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let overview = detail.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        let poster = detail.poster_path.map { Self.imgPoster + $0 }
        let backdrop = detail.backdrop_path.map { Self.imgBackdrop + $0 }
        let logo = pickLogo(detail.images?.logos ?? [], langShort: langShort)
        let rating = detail.vote_average.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil }
        let dateStr = detail.release_date ?? detail.first_air_date
        let year = dateStr.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
        let runtimeMin = isSeries ? detail.episode_run_time?.first : detail.runtime
        let runtime: String? = runtimeMin.flatMap { m in
            guard m > 0 else { return nil }
            let h = m / 60, rem = m % 60
            if h > 0 && rem > 0 { return "\(h) h \(rem) min" }
            if h > 0 { return "\(h) h" }
            return "\(m) min"
        }
        let genres = (detail.genres ?? []).map(\.name)
        let cast = (detail.credits?.cast ?? []).prefix(12).map(\.name)
        let crew = detail.credits?.crew ?? []
        let directors: [String] = isSeries
            ? (detail.created_by ?? []).map(\.name)
            : crew.filter { $0.job == "Director" }.map(\.name)
        var writerSeen = Set<String>()
        let writers = crew
            .filter { $0.department == "Writing" }
            .map(\.name)
            .filter { writerSeen.insert($0).inserted }
            .prefix(4)

        var videos: [Video] = []
        if isSeries {
            videos = await fetchEpisodes(tmdbId: tmdbId, canonicalId: canonicalId, seasons: detail.seasons ?? [], lang: lang, key: key)
        }

        let trailerURL = pickTrailer(detail.videos?.results ?? [], langShort: langShort)
        let genresMap = await genreMap(isSeries: isSeries, lang: lang, key: key)
        let recs = (detail.recommendations?.results ?? [])
            .prefix(12)
            .compactMap { parsePreview($0, type: isSeries ? "series" : "movie", genres: genresMap) }
        let titleExtras = TitleExtras(trailerURL: trailerURL, recommendations: recs)
        extrasCache["\(canonicalId)|\(lang)"] = titleExtras
        extrasCache["tmdb:\(tmdbId)|\(lang)"] = titleExtras
        extrasCache["\(id)|\(lang)"] = titleExtras

        return Meta(
            id: canonicalId,
            type: isSeries ? "series" : "movie",
            name: title,
            poster: poster,
            posterShape: "poster",
            background: backdrop,
            logo: logo,
            description: (overview?.isEmpty == false) ? overview : nil,
            imdbRating: rating,
            releaseInfo: year,
            runtime: runtime,
            genres: genres,
            cast: Array(cast),
            director: directors,
            writer: Array(writers),
            videos: videos
        )
    }

    private func fetchEpisodes(tmdbId: String, canonicalId: String, seasons: [TmdbSeasonRef], lang: String, key: String) async -> [Video] {
        let seasonNums = seasons.map(\.season_number).filter { $0 > 0 }.sorted().prefix(30)
        return await withTaskGroup(of: (Int, [Video]).self) { group in
            for sNum in seasonNums {
                group.addTask { [self] in
                    do {
                        let data = try await self.get(path: "/tv/\(tmdbId)/season/\(sNum)?language=\(lang)", key: key)
                        let s = try JSONDecoder().decode(TmdbSeasonResponse.self, from: data)
                        let eps = (s.episodes ?? []).map { ep -> Video in
                            let epTitle = (ep.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                                ?? "Episode \(ep.episode_number)"
                            return Video(
                                id: "\(canonicalId):\(sNum):\(ep.episode_number)",
                                title: epTitle,
                                season: Int32(sNum),
                                episode: Int32(ep.episode_number),
                                thumbnail: ep.still_path.map { Self.imgStill + $0 },
                                overview: (ep.overview?.isEmpty == false) ? ep.overview : nil,
                                released: ep.air_date
                            )
                        }
                        return (sNum, eps)
                    } catch {
                        return (sNum, [])
                    }
                }
            }
            var bySeason: [(Int, [Video])] = []
            for await pair in group { bySeason.append(pair) }
            return bySeason.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    private func resolveTmdbId(id: String, isSeries: Bool, lang: String, key: String) async throws -> String? {
        if id.hasPrefix("tmdb:") { return String(id.dropFirst(5)) }
        if id.hasPrefix("tt") {
            let data = try await get(path: "/find/\(id)?external_source=imdb_id&language=\(lang)", key: key)
            let decoded = try JSONDecoder().decode(TmdbFindResponse.self, from: data)
            let primary = (isSeries ? decoded.tv_results?.first : decoded.movie_results?.first)
                ?? (isSeries ? decoded.movie_results?.first : decoded.tv_results?.first)
            return primary.map { String($0.id) }
        }
        return Int(id).map { String($0) }
    }

    func localize(imdbId: String, type: String) async -> LocalizedMeta? {
        guard let key = currentKey(), imdbId.hasPrefix("tt") else { return nil }
        let lang = effectiveLanguage()
        let cacheKey = "\(imdbId)|\(type)|\(lang)"
        if let hit = localizeCache[cacheKey] { return hit }
        do {
            let data = try await get(path: "/find/\(imdbId)?external_source=imdb_id&language=\(lang)", key: key)
            let decoded = try JSONDecoder().decode(TmdbFindResponse.self, from: data)
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
            localizeCache[cacheKey] = result
            return result
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func currentKey() -> String? {
        guard let k = Keychain.get(service: Self.keyService)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !k.isEmpty else { return nil }
        return k
    }

    private func effectiveLanguage() -> String {
        language.isEmpty ? defaultLanguage() : language
    }

    private func genreMap(isSeries: Bool, lang: String, key: String) async -> [Int: String] {
        let cacheKey = "\(isSeries ? "tv" : "movie")|\(lang)"
        if let hit = genreCache[cacheKey] { return hit }
        do {
            let endpoint = isSeries ? "tv" : "movie"
            let data = try await get(path: "/genre/\(endpoint)/list?language=\(lang)", key: key)
            let resp = try JSONDecoder().decode(TmdbGenreResponse.self, from: data)
            let map = Dictionary(uniqueKeysWithValues: resp.genres.map { ($0.id, $0.name) })
            genreCache[cacheKey] = map
            return map
        } catch {
            return [:]
        }
    }

    private func parsePreview(_ item: TmdbListItem, type: String, genres: [Int: String]) -> MetaPreview? {
        let title = (item.title ?? item.name ?? item.original_title ?? item.original_name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let dateStr = item.release_date ?? item.first_air_date
        let year = dateStr.flatMap { $0.count >= 4 ? String($0.prefix(4)) : nil }
        let rating = item.vote_average.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil }
        let itemGenres = (item.genre_ids ?? []).compactMap { genres[$0] }
        let overview = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MetaPreview(
            id: "tmdb:\(item.id)",
            type: type,
            name: title,
            poster: item.poster_path.map { Self.imgPoster + $0 },
            posterShape: "poster",
            background: item.backdrop_path.map { Self.imgBackdrop + $0 },
            logo: nil,
            description: (overview?.isEmpty == false) ? overview : nil,
            imdbRating: rating,
            releaseInfo: year,
            genres: itemGenres
        )
    }

    private func pickLogo(_ logos: [TmdbImage], langShort: String) -> String? {
        let chosen = logos.first(where: { $0.iso_639_1 == langShort })
            ?? logos.first(where: { $0.iso_639_1 == "en" })
            ?? logos.first
        return chosen.map { Self.imgLogo + $0.file_path }
    }

    private func pickTrailer(_ videos: [TmdbVideoItem], langShort: String) -> URL? {
        let yt = videos.filter { $0.site?.lowercased() == "youtube" && !($0.key ?? "").isEmpty }
        guard !yt.isEmpty else { return nil }
        let chosen = yt.first(where: { $0.type == "Trailer" && $0.iso_639_1 == langShort })
            ?? yt.first(where: { $0.type == "Trailer" })
            ?? yt.first(where: { $0.type == "Teaser" })
            ?? yt.first
        return chosen?.key.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") }
    }

    private nonisolated func buildRequest(path: String, key: String) -> URLRequest? {
        let isBearer = key.count > 40 || key.contains(".")
        let sep = path.contains("?") ? "&" : "?"
        let urlStr = isBearer ? "\(Self.base)\(path)" : "\(Self.base)\(path)\(sep)api_key=\(key)"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if isBearer { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private nonisolated func get(path: String, key: String) async throws -> Data {
        guard let req = buildRequest(path: path, key: key) else {
            throw NSError(domain: "TmdbService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid TMDB URL"])
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(code) else {
            throw NSError(domain: "TmdbService", code: code, userInfo: [NSLocalizedDescriptionKey: "TMDB HTTP \(code)"])
        }
        return data
    }
}

// MARK: - TMDB DTOs

private struct TmdbListResponse: Decodable { let results: [TmdbListItem] }
private struct TmdbListItem: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let original_title: String?
    let original_name: String?
    let overview: String?
    let poster_path: String?
    let backdrop_path: String?
    let release_date: String?
    let first_air_date: String?
    let vote_average: Double?
    let genre_ids: [Int]?
    let adult: Bool?
    let media_type: String?
    let popularity: Double?
}
private struct TmdbPersonSearchResponse: Decodable { let results: [TmdbNamed] }
private struct TmdbPersonCreditsResponse: Decodable {
    let cast: [TmdbListItem]?
    let crew: [TmdbListItem]?
}
private struct TmdbFindResponse: Decodable {
    let movie_results: [TmdbListItem]?
    let tv_results: [TmdbListItem]?
}
private struct TmdbGenreResponse: Decodable { let genres: [TmdbNamed] }
private struct TmdbNamed: Decodable { let id: Int; let name: String }
private struct TmdbPerson: Decodable { let name: String; let job: String?; let department: String? }
private struct TmdbCredits: Decodable { let cast: [TmdbPerson]?; let crew: [TmdbPerson]? }
private struct TmdbImage: Decodable { let file_path: String; let iso_639_1: String? }
private struct TmdbImages: Decodable { let logos: [TmdbImage]? }
private struct TmdbExternalIds: Decodable { let imdb_id: String? }
private struct TmdbSeasonRef: Decodable { let season_number: Int }
private struct TmdbDetailResponse: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let original_title: String?
    let original_name: String?
    let overview: String?
    let poster_path: String?
    let backdrop_path: String?
    let release_date: String?
    let first_air_date: String?
    let vote_average: Double?
    let runtime: Int?
    let episode_run_time: [Int]?
    let genres: [TmdbNamed]?
    let credits: TmdbCredits?
    let created_by: [TmdbPerson]?
    let images: TmdbImages?
    let external_ids: TmdbExternalIds?
    let imdb_id: String?
    let seasons: [TmdbSeasonRef]?
    let videos: TmdbVideoList?
    let recommendations: TmdbListResponse?
}
private struct TmdbVideoList: Decodable { let results: [TmdbVideoItem]? }
private struct TmdbVideoItem: Decodable {
    let key: String?
    let site: String?
    let type: String?
    let iso_639_1: String?
}
private struct TmdbSeasonResponse: Decodable { let episodes: [TmdbEpisodeItem]? }
private struct TmdbEpisodeItem: Decodable {
    let episode_number: Int
    let name: String?
    let overview: String?
    let still_path: String?
    let air_date: String?
}
