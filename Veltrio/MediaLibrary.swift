import Foundation

/// Browsing a media server's own libraries (Collection tab), in one shape
/// for Jellyfin, Emby and Plex.

/// A library on the server: "Films", "Séries TV", "Kids"…
struct MediaLibrarySection: Identifiable, Hashable {
    let id: String
    let name: String
    /// Plex needs the kind to ask for the right item type.
    let kind: Kind

    enum Kind: Hashable { case movies, shows, mixed }
}

/// A film or series in a library.
struct MediaLibraryItem: Identifiable, Hashable {
    let id: String
    let title: String
    let year: Int?
    /// "movie" or "series", as the rest of the app spells them.
    let type: String
    /// Set when the server identified the title; it then opens on its
    /// IMDB page, where this copy is listed among the streams.
    let imdbId: String?
    let posterURL: URL?
    /// Plex plays a media part, not the item: its URL is known from the
    /// listing. Jellyfin and Emby build it from the id.
    var streamURL: URL? = nil
}

/// One episode of a series that has no IMDB id.
struct MediaLibraryEpisode: Identifiable, Hashable {
    let id: String
    let season: Int
    let number: Int
    let title: String
    let stillURL: URL?
    var streamURL: URL? = nil
}

struct MediaLibraryPage {
    let items: [MediaLibraryItem]
    /// Total in the library, for "Load more".
    let total: Int
}

/// The same browsing calls on any of the three servers.
@MainActor
protocol MediaLibraryBrowsing: AnyObject {
    var isConnected: Bool { get }
    var libraryServerName: String { get }
    func librarySections() async -> [MediaLibrarySection]
    func libraryItems(in section: MediaLibrarySection, start: Int, limit: Int) async -> MediaLibraryPage
    func libraryEpisodes(of item: MediaLibraryItem) async -> [MediaLibraryEpisode]
    func libraryStreamURL(for itemId: String) -> URL?
}

// MARK: - Jellyfin / Emby

extension MediaBrowserMatcher {
    /// The user's libraries, from `/Users/{id}/Views`. Music, photos and
    /// live TV are left out: the app plays films and series.
    func sections() async -> [MediaLibrarySection] {
        guard let url = URL(string: "\(serverUrl)/Users/\(userId)/Views") else { return [] }
        struct View: Decodable {
            let Id: String
            let Name: String
            let CollectionType: String?
        }
        struct Envelope: Decodable { let Items: [View] }
        guard let env: Envelope = await get(url) else { return [] }
        return env.Items.compactMap { v in
            switch v.CollectionType {
            case "movies":           return .init(id: v.Id, name: v.Name, kind: .movies)
            case "tvshows":          return .init(id: v.Id, name: v.Name, kind: .shows)
            case nil, "mixed", "homevideos": return .init(id: v.Id, name: v.Name, kind: .mixed)
            default:                 return nil
            }
        }
    }

    func items(in section: MediaLibrarySection, start: Int, limit: Int) async -> MediaLibraryPage {
        var comps = URLComponents(string: "\(serverUrl)/Users/\(userId)/Items")
        comps?.queryItems = [
            URLQueryItem(name: "ParentId", value: section.id),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "Fields", value: "ProviderIds,ProductionYear"),
            URLQueryItem(name: "StartIndex", value: String(start)),
            URLQueryItem(name: "Limit", value: String(limit)),
        ]
        struct Item: Decodable {
            let Id: String
            let Name: String
            let ItemType: String
            let ProductionYear: Int?
            let ProviderIds: [String: String]?
            let ImageTags: [String: String]?
            enum CodingKeys: String, CodingKey {
                case Id, Name, ProductionYear, ProviderIds, ImageTags
                case ItemType = "Type"
            }
        }
        struct Envelope: Decodable { let Items: [Item]; let TotalRecordCount: Int? }
        guard let url = comps?.url, let env: Envelope = await get(url) else {
            return MediaLibraryPage(items: [], total: 0)
        }
        let items = env.Items.map { i in
            MediaLibraryItem(
                id: i.Id, title: i.Name, year: i.ProductionYear,
                type: i.ItemType == "Series" ? "series" : "movie",
                imdbId: i.ProviderIds?.first(where: { $0.key.lowercased() == "imdb" })?.value,
                posterURL: i.ImageTags?["Primary"].flatMap {
                    URL(string: "\(serverUrl)/Items/\(i.Id)/Images/Primary?maxWidth=360&tag=\($0)&quality=90")
                }
            )
        }
        return MediaLibraryPage(items: items, total: env.TotalRecordCount ?? items.count)
    }

    func episodes(ofSeries id: String) async -> [MediaLibraryEpisode] {
        var comps = URLComponents(string: "\(serverUrl)/Shows/\(id)/Episodes")
        comps?.queryItems = [URLQueryItem(name: "UserId", value: userId)]
        struct Episode: Decodable {
            let Id: String
            let Name: String?
            let ParentIndexNumber: Int?
            let IndexNumber: Int?
            let ImageTags: [String: String]?
        }
        struct Envelope: Decodable { let Items: [Episode] }
        guard let url = comps?.url, let env: Envelope = await get(url) else { return [] }
        return env.Items.map { e in
            let number = e.IndexNumber ?? 0
            return MediaLibraryEpisode(
                id: e.Id, season: e.ParentIndexNumber ?? 1, number: number,
                title: e.Name ?? String(localized: "Episode \(number)"),
                stillURL: e.ImageTags?["Primary"].flatMap {
                    URL(string: "\(serverUrl)/Items/\(e.Id)/Images/Primary?maxWidth=480&tag=\($0)&quality=90")
                }
            )
        }
    }

    private func get<T: Decodable>(_ url: URL) async -> T? {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode)
        else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

extension JellyfinService: MediaLibraryBrowsing {
    var libraryServerName: String { "Jellyfin" }
    func librarySections() async -> [MediaLibrarySection] { await browser?.sections() ?? [] }
    func libraryItems(in section: MediaLibrarySection, start: Int, limit: Int) async -> MediaLibraryPage {
        await browser?.items(in: section, start: start, limit: limit) ?? MediaLibraryPage(items: [], total: 0)
    }
    func libraryEpisodes(of item: MediaLibraryItem) async -> [MediaLibraryEpisode] {
        await browser?.episodes(ofSeries: item.id) ?? []
    }
    func libraryStreamURL(for itemId: String) -> URL? { streamUrl(for: itemId) }
}

extension EmbyService: MediaLibraryBrowsing {
    var libraryServerName: String { "Emby" }
    func librarySections() async -> [MediaLibrarySection] { await browser?.sections() ?? [] }
    func libraryItems(in section: MediaLibrarySection, start: Int, limit: Int) async -> MediaLibraryPage {
        await browser?.items(in: section, start: start, limit: limit) ?? MediaLibraryPage(items: [], total: 0)
    }
    func libraryEpisodes(of item: MediaLibraryItem) async -> [MediaLibraryEpisode] {
        await browser?.episodes(ofSeries: item.id) ?? []
    }
    func libraryStreamURL(for itemId: String) -> URL? { streamUrl(for: itemId) }
}
