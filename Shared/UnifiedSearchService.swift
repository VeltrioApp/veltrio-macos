import Foundation
import Observation

/// One search hit, from any source.
///
/// The app has several kinds of catalogue — Stremio addons, Jellyfin,
/// Emby, Plex, an IPTV provider's films and series — and they all answer
/// "what is this?" with different shapes. `SearchResult` flattens them
/// into one row the search UI can render without caring where it came
/// from.
struct SearchResult: Identifiable, Hashable {
    /// Which catalogue produced this hit. Drives where a click goes, not
    /// how results are grouped.
    enum Source: String, Hashable {
        case stremio
        case iptv

        var label: String {
            switch self {
            case .stremio: return "Addons"
            case .iptv:    return "IPTV"
            }
        }
    }

    /// What the result is. Search only returns films and series; live
    /// channels are searched from the IPTV tab.
    enum MediaKind: String, Hashable {
        case movie
        case series

        var label: String {
            switch self {
            case .movie:  return "Movies"
            case .series: return "Series"
            }
        }
    }

    let id: String
    let source: Source
    let mediaKind: MediaKind
    let title: String
    let subtitle: String?
    let posterURL: URL?
    let kind: String

    /// The addon that owns this result, for Stremio hits. Needed to push
    /// a detail destination.
    var addon: InstalledAddon?

    /// The Stremio content id (`tt1234567` and friends) for addon hits.
    ///
    /// Kept as its own field rather than parsed back out of `id`: the id
    /// is a composite used for uniqueness, and re-deriving the content id
    /// from it by string surgery breaks the moment an addon id contains
    /// the separator.
    var contentId: String?


    /// Xtream film or series row, for IPTV hits.
    var channel: IptvChannel?

    static func == (l: SearchResult, r: SearchResult) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Searches every configured catalogue at once.
///
/// The sources are queried in parallel and each one is allowed to fail
/// silently. Results are published as each source answers, so a slow IPTV
/// provider doesn't hold back the addons.
///
/// IMDB titles from the addons fill the Movies and Series rows. The IPTV
/// provider's films and series follow in their own row, minus any whose
/// title is already an IMDB result: those are reached from that title's
/// page, where the provider's copy is listed among its streams.
@MainActor
@Observable
final class UnifiedSearchService {
    private(set) var groups: [SearchGroup] = []
    private(set) var isSearching = false
    private(set) var lastQuery: String = ""

    struct SearchGroup: Identifiable {
        enum Section: String {
            case movies, series, iptv

            var label: String {
                switch self {
                case .movies: return "Movies"
                case .series: return "Series"
                case .iptv:   return "IPTV"
                }
            }
        }

        let section: Section
        var results: [SearchResult]
        var id: String { section.rawValue }
    }

    /// The store this service queries.
    ///
    /// Weak, and assigned after the store is fully initialized: the store
    /// owns this service, so a strong reference here would be a cycle, and
    /// the store cannot be handed over during its own init.
    weak var store: AppStore?

    /// Bumped on every search so answers from a superseded query, still
    /// in flight, can't overwrite the current results.
    private var generation = 0

    func clear() {
        generation += 1
        groups = []
        isSearching = false
        lastQuery = ""
    }

    /// Run a search across every source, publishing `groups` as each
    /// source answers.
    func search(_ rawQuery: String) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        generation += 1
        let current = generation
        lastQuery = rawQuery
        groups = []
        guard query.count >= 2 else {
            isSearching = false
            return
        }

        isSearching = true
        var bySource: [SearchResult.Source: [SearchResult]] = [:]

        // Each source is independent. A failure in one must not take the
        // others down, so every task returns an empty array on error
        // rather than throwing.
        await withTaskGroup(of: (SearchResult.Source, [SearchResult]).self) { group in
            group.addTask { @MainActor in (.stremio, await self.searchStremio(query)) }
            group.addTask { @MainActor in (.iptv, await self.searchIPTV(query)) }

            for await (source, hits) in group {
                guard current == generation, !Task.isCancelled else { continue }
                bySource[source] = hits
                publish(bySource)
            }
        }

        if current == generation { isSearching = false }
    }

    private func publish(_ bySource: [SearchResult.Source: [SearchResult]]) {
        let imdb = bySource[.stremio] ?? []
        let imdbTitles = Set(imdb.map { XtreamClient.normalizedTitle($0.title) })
        let iptv = (bySource[.iptv] ?? []).filter {
            !imdbTitles.contains(XtreamClient.normalizedTitle($0.title))
        }
        let sections: [(SearchGroup.Section, [SearchResult])] = [
            (.movies, imdb.filter { $0.mediaKind == .movie }),
            (.series, imdb.filter { $0.mediaKind == .series }),
            (.iptv, iptv),
        ]
        groups = sections.compactMap { section, hits in
            hits.isEmpty ? nil : SearchGroup(section: section, results: hits)
        }
    }

    // MARK: - Stremio addons

    private func searchStremio(_ query: String) async -> [SearchResult] {
        struct Candidate: Hashable { let addon: InstalledAddon; let catalog: Catalog }

        var candidates: [Candidate] = []
        for addon in (store?.homeAddons ?? []) where addon.manifest.resources.contains("catalog") {
            for catalog in addon.manifest.catalogs
            where catalog.extra.contains(where: { $0.name == "search" })
                && Self.mediaKind(stremioType: catalog.type) != nil {
                candidates.append(Candidate(addon: addon, catalog: catalog))
            }
        }
        guard !candidates.isEmpty else { return [] }

        var hits: [SearchResult] = []
        await withTaskGroup(of: [SearchResult].self) { group in
            for c in candidates {
                group.addTask { @MainActor in
                    guard let store = self.store else { return [] }
                    let metas = await store.searchCatalog(
                        addon: c.addon, catalog: c.catalog, query: query
                    )
                    return metas.compactMap { meta in
                        // Addons also publish "tv" and "channel" catalogs;
                        // search only shows films and series.
                        guard let kind = Self.mediaKind(stremioType: meta.type) else { return nil }
                        // Accept IMDb ids (`tt...`) and native TMDB ids (`tmdb:...`),
                        // which resolve to canonical IMDb ids when the title opens.
                        guard meta.id.hasPrefix("tt") || meta.id.hasPrefix("tmdb:") else { return nil }
                        return SearchResult(
                            id: "stremio|\(c.addon.id)|\(meta.id)",
                            source: .stremio,
                            mediaKind: kind,
                            title: meta.name,
                            subtitle: meta.releaseInfo ?? c.addon.manifest.name,
                            posterURL: meta.poster.flatMap(URL.init(string:)),
                            kind: meta.type,
                            addon: c.addon,
                            contentId: meta.id
                        )
                    }
                }
            }
            for await result in group {
                hits.append(contentsOf: result)
            }
        }
        // The same film from two addons is not two results — keep the
        // first. A film and a series can share a title, so the kind is
        // part of the key.
        var seen = Set<String>()
        return hits.filter { seen.insert("\($0.mediaKind.rawValue)|\($0.title.lowercased())").inserted }
    }

    private static func mediaKind(stremioType: String) -> SearchResult.MediaKind? {
        switch stremioType {
        case "movie":  return .movie
        case "series": return .series
        default:       return nil
        }
    }

    // MARK: - IPTV

    /// Films and series from the selected Xtream provider, matched on every
    /// word of the query (many providers ignore `search=`). Live channels
    /// are deliberately left out — they're searched from the IPTV tab —
    /// and an M3U playlist is live-only, so it contributes nothing here.
    private func searchIPTV(_ query: String) async -> [SearchResult] {
        guard let store,
              let ref = store.iptvPlaylists.first(where: { $0.id == store.selectedIptvPlaylistId }),
              let credentials = ref.xtream else { return [] }

        let found = await XtreamClient().search(credentials: credentials, query: query, limit: 40)
        let kids = UserPrefs.shared.kidsMode
        return found
            .filter { !kids || !UserPrefs.isAdultIptvGroup($0.group ?? "") }
            .map { channel in
            let isSeries = channel.xtreamSeriesId != nil
            return SearchResult(
                id: "iptv|\(channel.id)",
                source: .iptv,
                mediaKind: isSeries ? .series : .movie,
                title: channel.name,
                // Language first: it's what tells two copies apart.
                subtitle: [XtreamClient.language(category: channel.group, name: channel.name),
                           channel.group].compactMap { $0 }.joined(separator: " · "),
                posterURL: channel.logoUrl.flatMap(URL.init(string:)),
                kind: isSeries ? "series" : "movie",
                channel: channel
            )
        }
    }
}
