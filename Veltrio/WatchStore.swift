import Foundation
import Observation

/// One entry in the user's library / watch history. Keyed by stable
/// (type, id) coming from the addon — `id` is usually an IMDB or Stremio
/// id, which stays constant across addon swaps.
///
/// `season`/`episode` are nested lookups on the same object for series.
/// Keeping a single top-level entry per title (with an `episodes` dict)
/// lets us answer "have I started this show?" in one lookup.
struct WatchEntry: Codable, Hashable, Identifiable {
    let type: String          // "movie" | "series" | "channel"
    let contentId: String     // Stremio/IMDB id, or `xtream-<id>` for live TV
    var name: String
    var poster: String?
    var background: String?
    // Addon that surfaced this entry — used to re-open DetailView without
    // a round-trip through catalogs.
    var addonId: String?
    var addonName: String?
    // Movie / single-video progress (seconds). For series, the "furthest
    // watched" episode is stored in `lastEpisode` and its progress lives
    // under `episodes[videoId]`.
    var position: Double = 0
    var duration: Double = 0
    var watched: Bool = false
    // Series-only
    var episodes: [String: EpisodeProgress] = [:]
    var lastEpisodeId: String?
    // Favorites / watchlist
    var inLibrary: Bool = false
    // Timestamps
    var addedAt: Date = .now
    var lastWatchedAt: Date = .now

    var id: String { "\(type)|\(contentId)" }

    /// Fraction 0…1 of how far through the content we are. For series,
    /// this reflects the last episode started.
    var progressFraction: Double {
        let (pos, dur): (Double, Double) = {
            if type == "series", let last = lastEpisodeId, let ep = episodes[last] {
                return (ep.position, ep.duration)
            }
            return (position, duration)
        }()
        guard dur > 0 else { return 0 }
        return max(0, min(1, pos / dur))
    }

    var isStarted: Bool {
        if type == "series" { return lastEpisodeId != nil }
        return position > 10
    }
}

struct EpisodeProgress: Codable, Hashable {
    var season: Int32?
    var episode: Int32?
    var position: Double
    var duration: Double
    var watched: Bool
    var updatedAt: Date
}

/// Persisted library + watch history. All mutations route through here so
/// Home's "Continue Watching" row, DetailView's progress badges and the
/// Library tab stay in sync automatically via `@Observable`.
@MainActor
@Observable
final class WatchStore {
    private(set) var entries: [String: WatchEntry] = [:]

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        if let fileURL { self.fileURL = fileURL }
        else {
            let support = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = support.appendingPathComponent("Veltrio", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("watch.json")
        }
        load()
    }

    // MARK: - queries

    func entry(type: String, id: String) -> WatchEntry? {
        entries[key(type: type, id: id)]
    }

    private func key(type: String, id: String) -> String { "\(type)|\(id)" }

    /// Position (in seconds) to resume at — 0 means start from the top.
    /// For series, uses the episode currently selected; otherwise the
    /// movie's own position. If we're within 10s of the end, start over.
    func resumePosition(type: String, id: String, videoId: String? = nil) -> Double {
        guard let entry = entry(type: type, id: id) else { return 0 }
        let (pos, dur): (Double, Double)
        if type == "series", let vid = videoId, let ep = entry.episodes[vid] {
            (pos, dur) = (ep.position, ep.duration)
        } else {
            (pos, dur) = (entry.position, entry.duration)
        }
        // Near-end snap: "resume" a near-finished item from scratch so the
        // user sees the opening again instead of 10s of credits.
        if dur > 0, pos > dur - 30 { return 0 }
        return pos
    }

    /// Everything currently in "Continue Watching" — in-progress or just
    /// finished, most-recent first.
    var continueWatching: [WatchEntry] {
        entries.values
            .filter { $0.isStarted && !$0.watched }
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
    }

    /// Library tab contents (favorites/watchlist + history), most-recent first.
    var libraryItems: [WatchEntry] {
        entries.values
            .filter { $0.inLibrary || $0.isStarted }
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
    }

    func isInLibrary(type: String, id: String) -> Bool {
        entry(type: type, id: id)?.inLibrary == true
    }

    // MARK: - mutations

    /// Called ~every 10s during playback + on player dismiss. Writes the
    /// current position for a movie or an episode and marks the title as
    /// watched if we crossed the 90% threshold.
    func reportProgress(
        type: String,
        id: String,
        name: String,
        position: Double,
        duration: Double,
        poster: String? = nil,
        background: String? = nil,
        addonId: String? = nil,
        addonName: String? = nil,
        videoId: String? = nil,
        season: Int32? = nil,
        episode: Int32? = nil
    ) {
        let k = key(type: type, id: id)
        var e = entries[k] ?? WatchEntry(type: type, contentId: id, name: name)
        e.name = name
        if let poster { e.poster = poster }
        if let background { e.background = background }
        if let addonId { e.addonId = addonId }
        if let addonName { e.addonName = addonName }
        e.lastWatchedAt = .now

        let watchedThreshold = 0.9

        if type == "series", let vid = videoId {
            var ep = e.episodes[vid] ?? EpisodeProgress(
                season: season, episode: episode,
                position: 0, duration: 0,
                watched: false, updatedAt: .now
            )
            ep.position = position
            ep.duration = duration
            ep.season = season ?? ep.season
            ep.episode = episode ?? ep.episode
            if duration > 0, position / duration >= watchedThreshold { ep.watched = true }
            ep.updatedAt = .now
            e.episodes[vid] = ep
            e.lastEpisodeId = vid
        } else {
            e.position = position
            e.duration = duration
            if duration > 0, position / duration >= watchedThreshold { e.watched = true }
        }
        entries[k] = e
        scheduleSave()
    }

    func toggleLibrary(type: String, id: String, name: String,
                       poster: String?, background: String?,
                       addonId: String?, addonName: String?) {
        let k = key(type: type, id: id)
        var e = entries[k] ?? WatchEntry(type: type, contentId: id, name: name)
        e.name = name
        if let poster { e.poster = poster }
        if let background { e.background = background }
        if let addonId { e.addonId = addonId }
        if let addonName { e.addonName = addonName }
        e.inLibrary.toggle()
        if e.inLibrary {
            e.addedAt = .now
            e.lastWatchedAt = .now
        }
        entries[k] = e
        scheduleSave()
    }

    func markWatched(type: String, id: String, videoId: String? = nil, watched: Bool = true) {
        let k = key(type: type, id: id)
        guard var e = entries[k] else { return }
        if type == "series", let vid = videoId, var ep = e.episodes[vid] {
            ep.watched = watched
            if watched { ep.position = ep.duration }
            else       { ep.position = 0 }
            e.episodes[vid] = ep
        } else {
            e.watched = watched
            if watched { e.position = max(e.position, e.duration) }
            else       { e.position = 0 }
        }
        e.lastWatchedAt = .now
        entries[k] = e
        scheduleSave()
    }

    func removeFromContinueWatching(type: String, id: String) {
        let k = key(type: type, id: id)
        guard var e = entries[k] else { return }
        e.position = 0
        e.duration = 0
        e.episodes.removeAll()
        e.lastEpisodeId = nil
        if e.inLibrary {
            entries[k] = e        // keep it in Library, just clear progress
        } else {
            entries.removeValue(forKey: k)
        }
        scheduleSave()
    }

    // MARK: - persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([WatchEntry].self, from: data) {
            entries = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            // Debounce writes: a stream of 10s progress ticks shouldn't
            // flush to disk on every update.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func flush() async {
        let snapshot = Array(entries.values)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
