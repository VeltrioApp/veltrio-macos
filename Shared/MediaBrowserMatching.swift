import Foundation

/// A media-server copy of an IMDB title, with what the stream list shows
/// about it. Shared by Jellyfin, Emby and Plex.
struct MediaServerMatch: Identifiable {
    let itemId: String
    let name: String
    let type: String
    let seriesName: String?
    /// "1080p HEVC SDR", as the server labels the video stream.
    let video: String?
    /// Audio languages as ISO 639-2 codes ("fre", "eng").
    let audioLanguages: [String]
    /// Set when the server can't build a play URL from the id alone (Plex
    /// plays the media part, not the item).
    var streamURL: URL? = nil
    var id: String { itemId }
}

/// Finds a title in a Jellyfin or Emby library. Both servers come from
/// the same codebase and answer these calls identically.
struct MediaBrowserMatcher {
    let serverUrl: String
    let userId: String
    let session: URLSession
    /// The server's auth headers, token included.
    let headers: [String: String]

    /// The library's copies of one film, matched on the IMDB id the server
    /// stores from its metadata providers; title and year are the fallback
    /// for items it couldn't identify.
    func findMovie(imdbId: String, title: String, year: Int?) async -> [MediaServerMatch] {
        await findItems(type: "Movie", imdbId: imdbId, title: title, year: year)
    }

    /// The library's copies of one episode: the series is matched like a
    /// film, then the episode is looked up by season and number.
    func findEpisode(seriesImdbId: String, title: String, year: Int?,
                     season: Int, episode: Int) async -> [MediaServerMatch] {
        let series = await findItems(type: "Series", imdbId: seriesImdbId, title: title, year: year)
        var found: [MediaServerMatch] = []
        for s in series {
            var comps = URLComponents(string: "\(serverUrl)/Shows/\(s.itemId)/Episodes")
            comps?.queryItems = [
                URLQueryItem(name: "UserId", value: userId),
                URLQueryItem(name: "Season", value: String(season)),
                URLQueryItem(name: "Fields", value: "MediaStreams"),
            ]
            guard let url = comps?.url, let rows = await fetch(url) else { continue }
            found += rows.filter { $0.parentIndex == season && $0.episodeIndex == episode }
                .map(Self.match)
        }
        return found
    }

    private func findItems(type: String, imdbId: String, title: String, year: Int?) async -> [MediaServerMatch] {
        var comps = URLComponents(string: "\(serverUrl)/Users/\(userId)/Items")
        comps?.queryItems = [
            URLQueryItem(name: "SearchTerm", value: title),
            URLQueryItem(name: "IncludeItemTypes", value: type),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Fields", value: "ProviderIds,ProductionYear,MediaStreams"),
            URLQueryItem(name: "Limit", value: "20"),
        ]
        guard let url = comps?.url, let rows = await fetch(url) else { return [] }
        return rows.filter { r in
            if let imdb = r.providerIds?.first(where: { $0.key.lowercased() == "imdb" })?.value {
                return imdb.lowercased() == imdbId.lowercased()
            }
            return MediaServerTitles.same(r.name, title, theirYear: r.productionYear, year: year)
        }
        .map(Self.match)
    }

    private struct RawItem: Decodable {
        let id: String
        let name: String
        let itemType: String
        let seriesName: String?
        let parentIndex: Int?
        let episodeIndex: Int?
        let productionYear: Int?
        let providerIds: [String: String]?
        let mediaStreams: [RawStream]?
        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case itemType = "Type"
            case seriesName = "SeriesName"
            case parentIndex = "ParentIndexNumber"
            case episodeIndex = "IndexNumber"
            case productionYear = "ProductionYear"
            case providerIds = "ProviderIds"
            case mediaStreams = "MediaStreams"
        }
    }

    private struct RawStream: Decodable {
        let type: String?
        let language: String?
        let displayTitle: String?
        enum CodingKeys: String, CodingKey {
            case type = "Type"
            case language = "Language"
            case displayTitle = "DisplayTitle"
        }
    }

    private func fetch(_ url: URL) async -> [RawItem]? {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        struct Envelope: Decodable {
            let items: [RawItem]
            enum CodingKeys: String, CodingKey { case items = "Items" }
        }
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return nil }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.items
    }

    private static func match(_ r: RawItem) -> MediaServerMatch {
        let streams = r.mediaStreams ?? []
        var languages: [String] = []
        for s in streams where s.type == "Audio" {
            if let l = s.language, !l.isEmpty, !languages.contains(l) { languages.append(l) }
        }
        return MediaServerMatch(
            itemId: r.id, name: r.name, type: r.itemType, seriesName: r.seriesName,
            video: streams.first(where: { $0.type == "Video" })?.displayTitle,
            audioLanguages: languages
        )
    }
}

enum MediaServerTitles {
    /// Title equality for items a server couldn't tie to an IMDB id:
    /// case and accents ignored, years within one of each other.
    static func same(_ theirs: String, _ ours: String, theirYear: Int?, year: Int?) -> Bool {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        guard fold(theirs) == fold(ours) else { return false }
        if let year, let theirYear { return abs(theirYear - year) <= 1 }
        return true
    }
}
