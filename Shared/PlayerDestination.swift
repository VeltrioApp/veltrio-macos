import Foundation

/// Navigation destination carrying everything we need to resolve + play.
/// Two flavours:
///   - `.stream`  — Stremio addon stream (movie/episode), goes through the
///     store's torrent/debrid resolution pipeline.
///   - `.liveChannel` — IPTV/Xtream channel with a direct URL and no
///     seekable timeline. Same mpv backend, different control surface.
struct PlayerDestination: Hashable {
    /// All the metadata we need to drive the player and the watch store.
    /// `contentId` is the stable Stremio/IMDB id; `videoId` is the episode
    /// id (same as contentId for movies).
    struct StreamPayload: Hashable {
        let stream: Stream
        let addonId: String
        let addonName: String
        let contentId: String
        let contentType: String   // "movie" | "series"
        let videoId: String?      // episode id (series) or nil (movie)
        let season: Int32?
        let episode: Int32?
        let poster: String?
        let background: String?
    }

    /// A direct-play item from a personal media server (Jellyfin, Emby).
    ///
    /// These servers hand out a ready-to-play URL, so there is nothing to
    /// resolve through the addon pipeline — the URL is already known.
    struct LibraryPayload: Hashable {
        let url: URL
        let serverName: String
        let itemId: String
        let poster: String?
        /// "Movie", "Episode", …
        let itemType: String
    }

    enum Kind: Hashable {
        case stream(StreamPayload)
        case liveChannel(channel: IptvChannel)
        case libraryItem(LibraryPayload)
    }

    /// Where progress is recorded for a non-addon item. A media-server or
    /// IPTV copy opened from a title's page records under that title's
    /// IMDB id, so resume, "watched", Continue Watching and Trakt behave
    /// exactly as for an addon stream. (Addon streams carry this in their
    /// payload.)
    struct WatchContext: Hashable {
        let contentType: String   // "movie" | "series"
        let contentId: String
        let videoId: String?
        let season: Int32?
        let episode: Int32?
        let poster: String?
        let background: String?
        let addonId: String?
        let addonName: String?
    }

    let kind: Kind
    let title: String
    var watchContext: WatchContext? = nil

    /// Live TV only. Xtream films and episodes travel as `.liveChannel`
    /// too but have a timeline, so they get the seek bar and track menus.
    var isLive: Bool {
        if case .liveChannel(let c) = kind { return !c.isOnDemand }
        return false
    }

    /// The artwork the player chrome should show.
    var artworkUrl: String? {
        switch kind {
        case .stream(let p):      return p.background ?? p.poster
        case .liveChannel(let c): return c.logoUrl
        case .libraryItem(let l): return l.poster
        }
    }

    var subtitle: String? {
        switch kind {
        case .stream(let p):
            if let season = p.season, let episode = p.episode {
                return String(localized: "Season \(season) · Episode \(episode)") + " · \(p.addonName)"
            }
            return p.addonName
        case .liveChannel(let c):
            return c.group
        case .libraryItem(let l):
            return "\(l.serverName) · \(l.itemType)"
        }
    }

    var logoUrl: String? {
        if case .liveChannel(let c) = kind { return c.logoUrl }
        if case .libraryItem(let l) = kind { return l.poster }
        return nil
    }

    /// The underlying Stremio stream, when there is one — used for source
    /// routing (YouTube/external fallbacks, torrent teardown).
    var streamSource: StreamSource? {
        if case .stream(let p) = kind { return p.stream.source }
        return nil
    }
}
