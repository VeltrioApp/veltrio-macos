import Foundation
import Observation

/// Top-level app state. One store, `@Observable`, so views just `@Environment`
/// it and SwiftUI handles dependency tracking per-property. Avoids the
/// ObservableObject re-render-everything trap.
///
/// Pinned to the main actor because every published field is consumed
/// directly by SwiftUI views; the only non-main code (torrent cleanup,
/// network fetches) goes through explicit `Task.detached` or awaited calls.
@MainActor
@Observable
final class AppStore {
    // -------------------- state --------------------
    private(set) var addons: [InstalledAddon] = []
    private(set) var catalogs: [CatalogKey: CatalogState] = [:]
    private(set) var isInstallingAddon = false
    private(set) var lastError: String?
    /// Addon IDs the user temporarily disabled. Kept out of
    /// `enabledAddons` + `fetchAllStreams` but not deleted, so toggling
    /// them back on is instant.
    private(set) var disabledAddonIds: Set<String> = []

    /// Public view of installed addons that are currently enabled, in the
    /// user's chosen order.
    var enabledAddons: [InstalledAddon] {
        addons.filter { !disabledAddonIds.contains($0.id) }
    }

    func isAddonEnabled(id: String) -> Bool {
        !disabledAddonIds.contains(id)
    }

    @MainActor
    func setAddonEnabled(id: String, enabled: Bool) {
        if enabled { disabledAddonIds.remove(id) }
        else       { disabledAddonIds.insert(id) }
        persistence.saveDisabled(disabledAddonIds)
    }

    @MainActor
    func moveAddon(from source: IndexSet, to destination: Int) {
        var list = addons
        list.move(fromOffsets: source, toOffset: destination)
        addons = list
        persistence.save(addons)
    }

    // IPTV
    enum IptvMode: String, CaseIterable, Identifiable {
        case live = "Live TV"
        case movies = "Movies"
        case series = "Series"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .live:   return "dot.radiowaves.left.and.right"
            case .movies: return "film.fill"
            case .series: return "tv.and.mediabox.fill"
            }
        }
    }

    private(set) var iptvPlaylists: [IptvPlaylistRef] = []
    private(set) var selectedIptvPlaylistId: UUID?
    private(set) var iptvChannels: [IptvChannel] = []
    private(set) var isLoadingIptv = false
    private(set) var iptvError: String?
    var iptvMode: IptvMode = .live
    private var iptvLoadTask: Task<Void, Never>?

    @MainActor
    func setIptvMode(_ mode: IptvMode) async {
        guard mode != iptvMode else { return }
        iptvMode = mode
        await refreshSelectedIptvPlaylist()
    }

    /// Does the selected playlist support the requested mode? VOD/Series
    /// only work for Xtream — M3U is live-only.
    func iptvSupports(_ mode: IptvMode) -> Bool {
        guard let id = selectedIptvPlaylistId,
              let ref = iptvPlaylists.first(where: { $0.id == id }) else { return false }
        if ref.isXtream { return true }
        return mode == .live
    }

    // -------------------- deps ---------------------
    private let client: StremioClient
    private let iptvClient: IptvClient
    private let xtreamClient: XtreamClient
    private let torrentEngine: TorrentEngine
    private let persistence: AddonPersistence
    private let iptvPersistence: IptvPersistence
    let debrid: DebridService
    let trakt: TraktService
    let jellyfin: JellyfinService
    let emby: EmbyService
    let plex: PlexService
    let casting: CastingService
    let downloads: DownloadManager
    let addonCatalog: AddonCatalogService
    /// Cross-source search. Lives here so the search page and any future
    /// search surface share one fan-out implementation.
    let unifiedSearch = UnifiedSearchService()

    init(
        client: StremioClient = StremioClient(),
        iptvClient: IptvClient = IptvClient(),
        xtreamClient: XtreamClient = XtreamClient(),
        torrentEngine: TorrentEngine = TorrentEngine(),
        persistence: AddonPersistence = AddonPersistence(),
        iptvPersistence: IptvPersistence = IptvPersistence(),
        debrid: DebridService? = nil,
        trakt: TraktService? = nil,
        jellyfin: JellyfinService? = nil,
        emby: EmbyService? = nil,
        plex: PlexService? = nil,
        casting: CastingService? = nil,
        downloads: DownloadManager? = nil,
        addonCatalog: AddonCatalogService? = nil
    ) {
        let debrid = debrid ?? DebridService()
        let trakt = trakt ?? TraktService()
        let jellyfin = jellyfin ?? JellyfinService()
        let emby = emby ?? EmbyService()
        let plex = plex ?? PlexService()
        let casting = casting ?? CastingService()
        let downloads = downloads ?? DownloadManager()
        let addonCatalog = addonCatalog ?? AddonCatalogService()
        self.client = client
        self.iptvClient = iptvClient
        self.xtreamClient = xtreamClient
        self.torrentEngine = torrentEngine
        self.persistence = persistence
        self.iptvPersistence = iptvPersistence
        self.debrid = debrid
        self.trakt = trakt
        self.jellyfin = jellyfin
        self.emby = emby
        self.plex = plex
        self.casting = casting
        self.downloads = downloads
        self.addonCatalog = addonCatalog
        self.addons = persistence.load()
        self.disabledAddonIds = persistence.loadDisabled()
        self.iptvPlaylists = iptvPersistence.load()
        self.selectedIptvPlaylistId = iptvPlaylists.first?.id

        // The search service needs the store, and the store owns the
        // service — the back-reference can only be closed here, once
        // every stored property is initialized.
        self.unifiedSearch.store = self
    }

    // -------------------- stream resolution ---------------------

    /// Turn a Stremio `Stream` into a URL the player can open. Routing:
    ///   - URL / External / YouTube → used as-is
    ///   - Torrent → try AllDebrid first (direct HTTPS, no seeding) and
    ///     fall back to the local librqbit engine if not cached or no
    ///     debrid configured
    func resolvePlayableUrl(
        for stream: Stream,
        season: Int32? = nil,
        episode: Int32? = nil
    ) async throws -> URL {
        switch stream.source {
        case .url(let s):
            guard let u = URL(string: s), Self.isPlayableScheme(u) else {
                throw VeltrioError.InvalidUrl(message: s)
            }
            return u
        case .youTube(let id):
            guard let u = URL(string: "https://www.youtube.com/watch?v=\(id)") else {
                throw VeltrioError.InvalidUrl(message: id)
            }
            return u
        case .external(let s):
            guard let u = URL(string: s), Self.isExternalOpenableScheme(u) else {
                throw VeltrioError.InvalidUrl(message: s)
            }
            return u
        case .torrent(let infoHash, let fileIdx, let sources):
            if let direct = await debrid.resolveViaAllDebrid(
                infoHash: infoHash, season: season, episode: episode
            ), let u = URL(string: direct) {
                return u
            }
            let local = try await torrentEngine.startStream(
                infoHash: infoHash, sources: sources, fileIdx: fileIdx
            )
            guard let u = URL(string: local) else {
                throw VeltrioError.Internal(message: "torrent engine returned bad URL")
            }
            return u
        }
    }

    /// Kick off an offline download of a stream. Mirrors `resolvePlayableUrl`
    /// to get a playable HTTP(S) URL (debrid → torrent HTTP server →
    /// direct), hands it to the DownloadManager. `contentId` is the
    /// Stremio id — we key downloads by that so the same item can't
    /// enqueue twice.
    func downloadStream(
        contentId: String,
        title: String,
        stream: Stream,
        season: Int32? = nil,
        episode: Int32? = nil
    ) async {
        do {
            let url = try await resolvePlayableUrl(for: stream, season: season, episode: episode)
            await MainActor.run {
                downloads.start(id: contentId, title: title, url: url)
            }
        } catch {
            DebugLog.shared.error("downloads", "resolve failed for \(contentId): \(error)")
        }
    }

    /// Fire-and-forget cleanup when the user closes the player.
    func stopTorrent(infoHash: String) {
        Task.detached { [torrentEngine] in
            do {
                try await torrentEngine.stopStream(infoHash: infoHash, deleteFiles: false)
            } catch {
                NSLog("Torrent stop failed for %@: %@", infoHash, "\(error)")
            }
        }
    }

    /// Whitelist of schemes we route into mpv. A hostile addon shouldn't
    /// be able to hand us `file://`, `smb://` or similar.
    private static func isPlayableScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "hls", "rtmp", "rtmps", "rtsp", "udp"].contains(scheme)
    }

    /// Whitelist for `NSWorkspace.shared.open`. Addons can drop into the
    /// system opener for things like magnet links or vendor-registered
    /// media URLs, but local and shell-adjacent schemes stay out.
    private static func isExternalOpenableScheme(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "magnet"].contains(scheme)
    }

    // -------------------- addons -------------------

    @MainActor
    func installAddon(url: String) async {
        isInstallingAddon = true
        defer { isInstallingAddon = false }
        // Only allow addon manifests served over http(s). Everything else
        // (file://, ftp://, custom schemes) is either a mistake or an
        // attempt to make the client read a local file / SSRF through the
        // Rust side.
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = URL(string: trimmed)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            lastError = "Addon URLs must start with http:// or https://."
            return
        }
        do {
            let manifest = try await client.fetchManifest(transportUrl: trimmed)
            if addons.contains(where: { $0.manifest.id == manifest.id }) {
                lastError = "Addon \(manifest.name) is already installed."
                return
            }
            let installed = InstalledAddon(manifest: manifest, addedAt: Date())
            addons.append(installed)
            persistence.save(addons)
            lastError = nil
        } catch {
            lastError = humanize(error)
        }
    }

    @MainActor
    func removeAddon(id: String) {
        addons.removeAll { $0.manifest.id == id }
        persistence.save(addons)
    }

    // -------------------- catalogs -----------------

    @MainActor
    func loadCatalog(addon: InstalledAddon, catalog: Catalog) async {
        let key = CatalogKey(addonId: addon.manifest.id, type: catalog.type, id: catalog.id)
        if case .loaded = catalogs[key] { return }
        catalogs[key] = .loading
        do {
            let items = try await client.fetchCatalog(
                transportUrl: addon.manifest.transportUrl,
                type: catalog.type,
                id: catalog.id,
                extras: []
            )
            catalogs[key] = .loaded(items)
        } catch {
            catalogs[key] = .failed(humanize(error))
        }
    }

    // -------------------- meta ---------------------

    func fetchMeta(addon: InstalledAddon, type: String, id: String) async throws -> Meta {
        try await client.fetchMeta(transportUrl: addon.manifest.transportUrl, type: type, id: id)
    }

    /// Try the preferred addon first, then every other enabled addon that
    /// advertises `meta` for this type. The first success wins. Returns
    /// a human-readable error string on complete failure so callers can
    /// surface what actually went wrong (timeout, 404, parse…) instead of
    /// a generic "Failed to load details."
    enum MetaFetchOutcome {
        case success(addon: InstalledAddon, meta: Meta)
        case failure(message: String)
    }

    func fetchMetaWithFallback(
        preferred: InstalledAddon,
        type: String,
        id: String
    ) async -> MetaFetchOutcome {
        var ordered: [InstalledAddon] = [preferred]
        for addon in enabledAddons where addon.id != preferred.id {
            guard addon.manifest.resources.contains("meta") else { continue }
            if addon.manifest.types.contains(type) || addon.manifest.types.isEmpty {
                ordered.append(addon)
            }
        }

        var lastError: String?
        for addon in ordered {
            do {
                let meta = try await Self.withTimeout(.seconds(15)) {
                    try await self.client.fetchMeta(
                        transportUrl: addon.manifest.transportUrl,
                        type: type, id: id
                    )
                }
                return .success(addon: addon, meta: meta)
            } catch is CancellationError {
                lastError = "Request timed out"
                continue
            } catch {
                lastError = humanize(error)
                continue
            }
        }
        return .failure(message: lastError ?? "No meta provider could answer.")
    }

    // -------------------- search -------------------

    /// Fire a single catalog's `search=` extra and return the results.
    /// Failures and timeouts become an empty list — the search page shows
    /// whichever addons answered quickly.
    func searchCatalog(addon: InstalledAddon, catalog: Catalog, query: String) async -> [MetaPreview] {
        do {
            return try await Self.withTimeout(.seconds(10)) {
                try await self.client.fetchCatalog(
                    transportUrl: addon.manifest.transportUrl,
                    type: catalog.type,
                    id: catalog.id,
                    extras: ["search=\(query)"]
                )
            }
        } catch {
            return []
        }
    }

    /// Catalog pagination — hits the Stremio `skip=` extra so the "See all"
    /// grid page can load 100+ items.
    func fetchCatalogPage(
        addon: InstalledAddon, catalog: Catalog,
        skip: Int, extras: [String] = []
    ) async -> [MetaPreview] {
        do {
            return try await Self.withTimeout(.seconds(15)) {
                try await self.client.fetchCatalog(
                    transportUrl: addon.manifest.transportUrl,
                    type: catalog.type,
                    id: catalog.id,
                    extras: extras + ["skip=\(skip)"]
                )
            }
        } catch {
            return []
        }
    }

    /// Score a stream for the "Play best" shortcut and sorted display.
    /// Rankings (high → low):
    ///   - AllDebrid-cached torrent (instant playback)
    ///   - Direct URL / HLS (no torrent latency)
    ///   - 4K > 1080p > 720p > 480p > unknown
    ///   - HDR/Dolby bonus
    ///   - Seeds (approximated from the title: "100 seeds" style)
    func scoreStream(_ labeled: LabeledStream) -> Int {
        var score = 0
        let name = (labeled.stream.name ?? "").uppercased()
        let title = (labeled.stream.title ?? "").uppercased()
        let hay = name + " " + title

        // Cache / source class
        if case .torrent(let hash, _, _) = labeled.stream.source {
            if debrid.isCached(hash) { score += 10_000 }
        } else if case .url = labeled.stream.source {
            score += 5_000
        } else if case .external = labeled.stream.source {
            score += 3_000
        }

        // Quality
        if hay.contains("2160P") || hay.contains("4K") { score += 2_000 }
        else if hay.contains("1080P") { score += 1_500 }
        else if hay.contains("720P")  { score += 1_000 }
        else if hay.contains("480P")  { score += 500 }

        if hay.contains("HDR")   { score += 200 }
        if hay.contains("DOLBY") { score += 150 }
        if hay.contains("ATMOS") { score += 150 }

        // Seeds (torrentio-style suffix: "👤 150 / ⚡ …")
        if let seeds = Self.extractSeeds(from: name) { score += min(seeds, 500) }
        return score
    }

    private static func extractSeeds(from s: String) -> Int? {
        let digits = s.split(whereSeparator: { !$0.isNumber })
        return digits.first.flatMap { Int($0) }
    }

    /// Streams can come from any installed addon that supports the `stream`
    /// resource for this content type. We fan out in parallel and merge.
    /// Each addon is capped at `perAddonTimeout` so one slow/hung addon
    /// can't sit on the whole result; failures are logged but swallowed
    /// so the UI shows whatever came back in time.
    func fetchAllStreams(for type: String, id: String) async -> [LabeledStream] {
        let eligible = enabledAddons.filter { addon in
            addon.manifest.resources.contains("stream") &&
            (addon.manifest.types.contains(type) || addon.manifest.types.isEmpty)
        }
        let perAddonTimeout: Duration = .seconds(15)
        return await withTaskGroup(of: [LabeledStream].self) { group in
            for addon in eligible {
                group.addTask { [client] in
                    do {
                        return try await Self.withTimeout(perAddonTimeout) {
                            let streams = try await client.fetchStreams(
                                transportUrl: addon.manifest.transportUrl,
                                type: type,
                                id: id
                            )
                            return streams.map {
                                LabeledStream(stream: $0, addonName: addon.manifest.name)
                            }
                        }
                    } catch {
                        let msg = "\(error)"
                        let name = addon.manifest.name
                        Task { @MainActor in
                            DebugLog.shared.error("streams/\(name)", msg)
                        }
                        return []
                    }
                }
            }
            var merged: [LabeledStream] = []
            for await chunk in group { merged.append(contentsOf: chunk) }
            return merged
        }
    }

    /// Runs `op` with a hard deadline; throws on timeout so the caller can
    /// treat it exactly like any other addon failure.
    private static func withTimeout<T: Sendable>(
        _ duration: Duration,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // -------------------- IPTV ---------------------

    @MainActor
    func addIptvPlaylist(name: String, url: String) async {
        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedUrl.isEmpty else { return }
        let ref = IptvPlaylistRef(
            id: UUID(),
            name: trimmedName.isEmpty ? displayNameFromUrl(trimmedUrl) : trimmedName,
            url: trimmedUrl,
            xtream: nil,
            addedAt: Date()
        )
        iptvPlaylists.append(ref)
        iptvPersistence.save(iptvPlaylists)
        await selectIptvPlaylist(id: ref.id)
    }

    @MainActor
    func addXtreamPlaylist(name: String, credentials: XtreamCredentials) async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let fallbackName = URL(string: credentials.normalizedHost)?.host ?? "Xtream"
        let ref = IptvPlaylistRef(
            id: UUID(),
            name: trimmedName.isEmpty ? fallbackName : trimmedName,
            url: "",
            xtream: credentials,
            addedAt: Date()
        )
        iptvPlaylists.append(ref)
        iptvPersistence.save(iptvPlaylists)
        await selectIptvPlaylist(id: ref.id)
    }

    /// Quick authentication probe. Returns a user-friendly error message
    /// on failure, `nil` on success. Used by the Add sheet's "Test" button.
    func verifyXtream(_ credentials: XtreamCredentials) async -> String? {
        do {
            _ = try await xtreamClient.verify(credentials)
            return nil
        } catch {
            return humanize(error)
        }
    }

    @MainActor
    func removeIptvPlaylist(id: UUID) {
        // Drop any Keychain-held Xtream password for this playlist.
        XtreamKeychain.delete(for: id)
        iptvPlaylists.removeAll { $0.id == id }
        iptvPersistence.save(iptvPlaylists)
        if selectedIptvPlaylistId == id {
            iptvLoadTask?.cancel()
            selectedIptvPlaylistId = iptvPlaylists.first?.id
            iptvChannels = []
            if let next = selectedIptvPlaylistId {
                Task { await selectIptvPlaylist(id: next) }
            }
        }
    }

    @MainActor
    func selectIptvPlaylist(id: UUID) async {
        guard let ref = iptvPlaylists.first(where: { $0.id == id }) else { return }
        selectedIptvPlaylistId = id
        await loadIptvChannels(from: ref)
    }

    @MainActor
    func refreshSelectedIptvPlaylist() async {
        guard let id = selectedIptvPlaylistId,
              let ref = iptvPlaylists.first(where: { $0.id == id }) else { return }
        await loadIptvChannels(from: ref)
    }

    @MainActor
    private func loadIptvChannels(from ref: IptvPlaylistRef) async {
        // Cancel an in-flight load so the last-click wins and we don't end
        // up with channels from playlist A rendered under selection B.
        iptvLoadTask?.cancel()
        let targetId = ref.id
        isLoadingIptv = true
        iptvError = nil

        let mode = iptvMode
        let task = Task { [xtreamClient, iptvClient] in
            do {
                let channels: [IptvChannel]
                if let creds = ref.xtream {
                    switch mode {
                    case .live:   channels = try await xtreamClient.fetchLiveChannels(creds)
                    case .movies: channels = try await xtreamClient.fetchVOD(creds)
                    case .series: channels = try await xtreamClient.fetchSeries(creds)
                    }
                } else {
                    let playlist = try await iptvClient.loadPlaylist(sourceUrl: ref.url)
                    channels = playlist.channels
                }
                try Task.checkCancellation()
                await MainActor.run {
                    // Guard against a late result for a playlist the user
                    // already switched away from.
                    guard self.selectedIptvPlaylistId == targetId else { return }
                    self.iptvChannels = channels
                    self.isLoadingIptv = false
                }
            } catch is CancellationError {
                // The caller moved on to another playlist; stay quiet.
            } catch {
                await MainActor.run {
                    guard self.selectedIptvPlaylistId == targetId else { return }
                    self.iptvChannels = []
                    self.iptvError = self.humanize(error)
                    self.isLoadingIptv = false
                }
            }
        }
        iptvLoadTask = task
        await task.value
    }

    private func displayNameFromUrl(_ url: String) -> String {
        if let host = URL(string: url)?.host { return host }
        return "Playlist"
    }

    // -------------------- helpers ------------------

    private func humanize(_ error: Error) -> String {
        if let v = error as? VeltrioError {
            switch v {
            case .Network(let message):     return "Network: \(message)"
            case .Parse(let message):       return "Parse: \(message)"
            case .InvalidUrl(let message):  return "Invalid URL: \(message)"
            case .NotFound(let message):    return "Not found: \(message)"
            case .Unsupported(let message): return "Unsupported: \(message)"
            case .Internal(let message):    return "Internal: \(message)"
            }
        }
        return error.localizedDescription
    }
}

// -------------------- supporting types -------------------

struct InstalledAddon: Identifiable, Hashable {
    let manifest: Manifest
    let addedAt: Date
    var id: String { manifest.id }

    static func == (l: InstalledAddon, r: InstalledAddon) -> Bool { l.manifest.id == r.manifest.id }
    func hash(into hasher: inout Hasher) { hasher.combine(manifest.id) }
}

struct CatalogKey: Hashable {
    let addonId: String
    let type: String
    let id: String
}

enum CatalogState {
    case loading
    case loaded([MetaPreview])
    case failed(String)
}

struct LabeledStream: Identifiable {
    let stream: Stream
    let addonName: String
    let id = UUID()
}

// ---------- persistence DTO ----------
//
// UniFFI's structs aren't `Codable`, and adding retroactive conformance
// would collide with its generated `Equatable`/`Hashable`. We serialize
// through a tiny mirror DTO instead; the DTO is the only shape we commit
// to disk, so changes to the FFI structs don't break saved addon lists.
struct InstalledAddonDTO: Codable {
    var addedAt: Date
    var manifest: ManifestDTO

    init(_ addon: InstalledAddon) {
        addedAt = addon.addedAt
        manifest = ManifestDTO(addon.manifest)
    }
    func toModel() -> InstalledAddon {
        InstalledAddon(manifest: manifest.toModel(), addedAt: addedAt)
    }
}

struct ManifestDTO: Codable {
    var id: String
    var version: String
    var name: String
    var description: String?
    var logo: String?
    var background: String?
    var types: [String]
    var resources: [String]
    var catalogs: [CatalogDTO]
    var idPrefixes: [String]
    var transportUrl: String

    init(_ m: Manifest) {
        id = m.id; version = m.version; name = m.name
        description = m.description; logo = m.logo; background = m.background
        types = m.types; resources = m.resources
        catalogs = m.catalogs.map(CatalogDTO.init)
        idPrefixes = m.idPrefixes; transportUrl = m.transportUrl
    }
    func toModel() -> Manifest {
        Manifest(
            id: id, version: version, name: name,
            description: description, logo: logo, background: background,
            types: types, resources: resources,
            catalogs: catalogs.map { $0.toModel() },
            idPrefixes: idPrefixes, transportUrl: transportUrl
        )
    }
}

struct CatalogDTO: Codable {
    var type: String
    var id: String
    var name: String
    var extra: [ExtraPropDTO]

    init(_ c: Catalog) {
        type = c.type; id = c.id; name = c.name
        extra = c.extra.map(ExtraPropDTO.init)
    }
    func toModel() -> Catalog {
        Catalog(type: type, id: id, name: name, extra: extra.map { $0.toModel() })
    }
}

struct ExtraPropDTO: Codable {
    var name: String
    var isRequired: Bool
    var options: [String]?
    var optionsLimit: UInt32?

    init(_ e: ExtraProp) {
        name = e.name; isRequired = e.isRequired
        options = e.options; optionsLimit = e.optionsLimit
    }
    func toModel() -> ExtraProp {
        ExtraProp(name: name, isRequired: isRequired, options: options, optionsLimit: optionsLimit)
    }
}
