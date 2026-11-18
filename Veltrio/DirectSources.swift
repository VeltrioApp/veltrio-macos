import Foundation

/// A ready-to-play copy of an IMDB title that doesn't come from a Stremio
/// addon: a file in the user's Jellyfin library, or a film or episode on
/// their IPTV provider. Listed beside the addon streams on the detail
/// page.
struct DirectStream: Identifiable {
    enum Origin: Hashable {
        case jellyfin
        case iptv

        var label: String {
            switch self {
            case .jellyfin: return "Jellyfin"
            case .iptv:     return "IPTV"
            }
        }
    }

    let id: String
    let origin: Origin
    /// The copy's own name — the provider's "NF - The Irishman (2019)",
    /// or the library item's title.
    let title: String
    /// Provider category, or the video stream description for a library
    /// file.
    let detail: String?
    /// Short language tags: "FR", "VOSTFR", "EN"…
    let languages: [String]
    let destination: PlayerDestination
}

/// Finds the Jellyfin and IPTV copies of an IMDB title.
@MainActor
enum DirectSourceFinder {
    /// - Parameters:
    ///   - imdbId: the title's IMDB id (`tt…`); for a series, the series id.
    ///   - season, episode: set for an episode, nil for a film.
    static func find(store: AppStore, imdbId: String, title: String, year: Int?,
                     season: Int?, episode: Int?, poster: String?) async -> [DirectStream] {
        async let library = jellyfin(store: store, imdbId: imdbId, title: title, year: year,
                                     season: season, episode: episode, poster: poster)
        async let provider = iptv(store: store, title: title, year: year,
                                  season: season, episode: episode)
        return await library + provider
    }

    private static func jellyfin(store: AppStore, imdbId: String, title: String, year: Int?,
                                 season: Int?, episode: Int?, poster: String?) async -> [DirectStream] {
        let service = store.jellyfin
        guard service.isConnected else { return [] }
        let matches: [JellyfinService.Match]
        if let season, let episode {
            matches = await service.findEpisode(seriesImdbId: imdbId, title: title, year: year,
                                                season: season, episode: episode)
        } else {
            matches = await service.findMovie(imdbId: imdbId, title: title, year: year)
        }
        return matches.compactMap { m in
            guard let url = service.streamUrl(for: m.item.id) else { return nil }
            let name = m.item.seriesName.map { "\($0) · \(m.item.name)" } ?? m.item.name
            return DirectStream(
                id: "jellyfin|\(m.item.id)",
                origin: .jellyfin,
                title: name,
                detail: m.video,
                languages: m.audioLanguages.map(shortLanguage),
                destination: PlayerDestination(
                    kind: .libraryItem(.init(
                        url: url, serverName: "Jellyfin", itemId: m.item.id,
                        poster: poster, itemType: m.item.type
                    )),
                    title: title
                )
            )
        }
    }

    /// Every Xtream playlist is asked, not only the selected one: the
    /// user wants to see every copy they can play.
    private static func iptv(store: AppStore, title: String, year: Int?,
                             season: Int?, episode: Int?) async -> [DirectStream] {
        let playlists = store.iptvPlaylists.filter { $0.xtream != nil }
        guard !playlists.isEmpty else { return [] }
        let client = XtreamClient()
        var out: [DirectStream] = []
        for ref in playlists {
            guard let credentials = ref.xtream else { continue }
            let label = playlists.count > 1 ? ref.name : nil
            if let season, let episode {
                for (series, ep) in await client.findEpisode(credentials, title: title, year: year,
                                                             season: season, episode: episode) {
                    out.append(DirectStream(
                        id: "iptv|\(ref.id)|\(ep.channel.id)",
                        origin: .iptv,
                        title: series.name,
                        detail: [series.group, label].compactMap { $0 }.joined(separator: " · "),
                        languages: XtreamClient.language(category: series.group, name: series.name)
                            .map { [$0] } ?? [],
                        destination: PlayerDestination(kind: .liveChannel(channel: ep.channel),
                                                       title: ep.title)
                    ))
                }
            } else {
                for film in await client.findMovie(credentials, title: title, year: year) {
                    out.append(DirectStream(
                        id: "iptv|\(ref.id)|\(film.id)",
                        origin: .iptv,
                        title: film.name,
                        detail: [film.group, label].compactMap { $0 }.joined(separator: " · "),
                        languages: XtreamClient.language(category: film.group, name: film.name)
                            .map { [$0] } ?? [],
                        destination: PlayerDestination(kind: .liveChannel(channel: film),
                                                       title: title)
                    ))
                }
            }
        }
        return out
    }

    /// Jellyfin reports ISO 639-2 codes; show the same short tags the
    /// IPTV rows use.
    private static func shortLanguage(_ code: String) -> String {
        let map = ["fre": "FR", "fra": "FR", "eng": "EN", "ara": "AR", "ger": "DE", "deu": "DE",
                   "spa": "ES", "ita": "IT", "dut": "NL", "nld": "NL", "tur": "TR", "por": "PT",
                   "jpn": "JA", "kor": "KO", "chi": "ZH", "zho": "ZH", "rus": "RU", "pol": "PL"]
        return map[code.lowercased()] ?? code.uppercased()
    }
}
