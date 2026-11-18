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
/// silently: a Jellyfin server that's down must not stop the Stremio
/// results from appearing. Results are published as each source answers,
/// so a slow IPTV provider doesn't hold back the addons, and they are
/// grouped by what they are — Movies, Series — not by where they came
/// from.
@MainActor
@Observable
final class UnifiedSearchService {
    private(set) var groups: [SearchGroup] = []
    private(set) var isSearching = false
    private(set) var lastQuery: String = ""

    struct SearchGroup: Identifiable {
        let kind: SearchResult.MediaKind
        var results: [SearchResult]
        var id: String { kind.rawValue }
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

    /// Order results appear in within a group, whichever source answers
    /// first.
    private static let sourceOrder: [SearchResult.Source] = [.stremio, .iptv]

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
            // IMDB titles only for now. Media-server and IPTV matches are
            // to be attached to these titles rather than listed beside
            // them, so their search functions below are not fanned out.
            group.addTask { @MainActor in (.stremio, await self.searchStremio(query)) }

            for await (source, hits) in group {
                guard current == generation, !Task.isCancelled else { continue }
                bySource[source] = hits
                publish(bySource)
            }
        }

        if current == generation { isSearching = false }
    }

    private func publish(_ bySource: [SearchResult.Source: [SearchResult]]) {
        let all = Self.sourceOrder.flatMap { bySource[$0] ?? [] }
        groups = [SearchResult.MediaKind.movie, .series].compactMap { kind in
            let hits = all.filter { $0.mediaKind == kind }
            return hits.isEmpty ? nil : SearchGroup(kind: kind, results: hits)
        }
    }

    // MARK: - Stremio addons

    private func searchStremio(_ query: String) async -> [SearchResult] {
        struct Candidate: Hashable { let addon: InstalledAddon; let catalog: Catalog }

        var candidates: [Candidate] = []
        for addon in (store?.addons ?? []) where addon.manifest.resources.contains("catalog") {
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
                        // IMDB titles only: addons that answer with their
                        // own ids (`kitsu:`, provider-specific…) list
                        // things the other sources can't be matched to.
                        guard meta.id.hasPrefix("tt") else { return nil }
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

    /// Films and series from the selected Xtream provider. Live channels
    /// are deliberately left out — they're searched from the IPTV tab —
    /// and an M3U playlist is live-only, so it contributes nothing here.
    private func searchIPTV(_ query: String) async -> [SearchResult] {
        guard let store,
              let ref = store.iptvPlaylists.first(where: { $0.id == store.selectedIptvPlaylistId }),
              let credentials = ref.xtream else { return [] }

        let found = await XtreamClient().search(credentials: credentials, query: query, limit: 40)
        return found.map { channel in
            let isSeries = channel.xtreamSeriesId != nil
            return SearchResult(
                id: "iptv|\(channel.id)",
                source: .iptv,
                mediaKind: isSeries ? .series : .movie,
                title: channel.name,
                subtitle: "IPTV",
                posterURL: channel.logoUrl.flatMap(URL.init(string:)),
                kind: isSeries ? "series" : "movie",
                channel: channel
            )
        }
    }
}
