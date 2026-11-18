import SwiftUI
import AppKit
import IOKit.pwr_mgt

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

/// Full-page player. Pushed onto the NavigationStack from DetailView — no
/// sheets, no popups. mpv renders into the embedded NSOpenGLView, the UI
/// overlays premium controls on top with auto-hide, keyboard shortcuts
/// and a seek bar driven by mpv property observation.
struct PlayerView: View {
    let destination: PlayerDestination

    @Environment(AppStore.self) private var store
    @Environment(WatchStore.self) private var watch
    @Environment(\.dismiss) private var dismiss

    /// Observed instead of injected so changes in Settings apply in real time.
    private let prefs = UserPrefs.shared

    @State private var controller = PlayerController()
    @State private var resolvedUrl: URL?
    @State private var resolveError: String?
    @State private var isResolving = true
    /// Torrent infohash we actually started on the Rust side, if any.
    /// We stop by this exact hash on disappear so an aborted resolve that
    /// finished AFTER the user hit Back doesn't leak a seeding session.
    @State private var startedTorrentHash: String?
    /// IOKit assertion that stops the display from sleeping while
    /// playback is active. Released on disappear. Without it the screen
    /// dims after a few minutes if the user isn't touching the mouse.
    @State private var sleepAssertionId: IOPMAssertionID = 0
    @State private var didSeekToResume = false
    /// SIMKL gets one `start` per session and a `stop` on the way out.
    @State private var simklStarted = false
    @State private var progressTask: Task<Void, Never>?
    @State private var showNextEpisodeOverlay = false
    @State private var nextEpisodeCountdown = 10

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var showMediaInfo = false

    // XMLTV / Xtream short EPG for the current live channel.
    @State private var epgNow: ShortEPGEntry?
    @State private var epgNext: ShortEPGEntry?
    @State private var epgVisible = true
    @State private var epgHideTask: Task<Void, Never>?

    // Catchup / timeshift for the current live channel.
    @State private var catchupEntries: [ShortEPGEntry] = []
    @State private var showCatchupSheet = false

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var hoverTime: Double? = nil

    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if isResolving {
                    loadingState
                } else if let error = resolveError {
                    errorState(error)
                } else if let error = controller.playbackError {
                    errorState(error)
                } else if case .youTube = destination.streamSource {
                    externalFallback(label: "Open in YouTube")
                } else if case .external = destination.streamSource {
                    externalFallback(label: "Open in default app")
                } else if let url = resolvedUrl {
                    MPVPlayer(url: url, controller: controller)
                        .ignoresSafeArea()
                }
            }

            // Click-to-toggle pause when the hit target is the video itself
            // (not the overlay controls).
            if resolvedUrl != nil {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { controller.togglePause() }
                    .allowsHitTesting(controlsVisible == false)
            }

            if controlsVisible || isResolving || resolveError != nil {
                controlsOverlay
                    .transition(.opacity)
            }

            // Buffering indicator floats in the center, under the top bar.
            if controller.isBuffering && resolvedUrl != nil {
                ProgressView()
                    .controlSize(.large)
                    .colorScheme(.dark)
                    .padding(16)
                    .background(Circle().fill(.black.opacity(0.4)))
            }

            if showNextEpisodeOverlay {
                nextEpisodeOverlay
                    .transition(.opacity)
            }

            if showMediaInfo {
                mediaInfoPanel
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if controller.isInSkippableIntro {
                skipIntroOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
                    .padding(.trailing, Theme.Spacing.xl)
                    .padding(.bottom, 130)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            if showCatchupSheet {
                catchupSheet
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if destination.isLive, epgVisible, epgNow != nil {
                epgOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomLeading)
                    .padding(.leading, Theme.Spacing.xl)
                    .padding(.bottom, 120)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .windowToolbar)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .overlay(alignment: .top) { castBanner }
        .onAppear {
            focused = true
            resetHideTimer()
            preventDisplaySleep()
            startProgressReporting()
            store.chromecast.startDiscovery()
            // Let the app's Playback menu reach this player.
            ActivePlayback.shared.register(controller)
            // Push language preferences into mpv BEFORE the first file is
            // loaded so track auto-selection picks the right language.
            controller.applyLanguagePreferences(
                audio: prefs.preferredAudioLang,
                subtitle: prefs.preferredSubtitleLang
            )
            fetchExternalSubtitles()
            fetchLiveEPG()
            fetchCatchupEPG()
        }
        .onChange(of: controller.isPaused) { _, paused in
            // Pause lifts the display-sleep guard; resume reinstates it.
            if paused { releaseDisplaySleep() } else { preventDisplaySleep() }
        }
        .onChange(of: resolvedUrl) { _, newUrl in
            store.casting.setStreamURL(newUrl)
            // Fresh file loaded — jump to the saved position if any.
            // We do it here (not at `.task`) because MPV only accepts a
            // seek after FILE_LOADED, which the controller signals via
            // a non-zero duration.
            _ = newUrl
        }
        .onChange(of: controller.duration) { _, dur in
            if dur > 0, !didSeekToResume {
                if let (type, id, videoId) = watchIdentity() {
                    let resume = watch.resumePosition(type: type, id: id, videoId: videoId)
                    if resume > 10 {
                        controller.seek(to: resume)
                    }
                    didSeekToResume = true
                }
            }
        }
        .onKeyPress(.space)      { controller.togglePause(); return .handled }
        .onKeyPress(.leftArrow)  {
            if destination.isLive { return .ignored }
            controller.skip(by: -10); flashControls(); return .handled
        }
        .onKeyPress(.rightArrow) {
            if destination.isLive { return .ignored }
            controller.skip(by: 10); flashControls(); return .handled
        }
        .onKeyPress("f")         { toggleFullScreen(); return .handled }
        .onKeyPress("m")         { controller.toggleMute(); flashControls(); return .handled }
        .onKeyPress(.escape)     { handleEscape(); return .handled }
        .onKeyPress("z")         { controller.bumpSubDelay(by: -0.1); flashControls(); return .handled }
        .onKeyPress("x")         { controller.bumpSubDelay(by: 0.1); flashControls(); return .handled }
        .onKeyPress("[")         { controller.setSpeed(max(0.25, controller.speed - 0.1)); flashControls(); return .handled }
        .onKeyPress("]")         { controller.setSpeed(min(3.0, controller.speed + 0.1)); flashControls(); return .handled }
        .onKeyPress("s")         { controller.skipIntro(); flashControls(); return .handled }
        .onKeyPress("i")         { showMediaInfo.toggle(); return .handled }
        .onKeyPress("a")         { cycleAspect(); return .handled }
        .onKeyPress("g")         {
            if destination.isLive {
                epgVisible.toggle()
                if epgVisible { scheduleEPGHide() }
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.upArrow)    { controller.setVolume(controller.volume + 5); flashControls(); return .handled }
        .onKeyPress(.downArrow)  { controller.setVolume(controller.volume - 5); flashControls(); return .handled }
        .onContinuousHover { phase in
            if case .active = phase { flashControls() }
        }
        .task { await resolve() }
        .onChange(of: controller.eofReached) { _, done in
            if done {
                // For live TV / movies we exit; for a series the overlay
                // picks the next episode (or the user dismisses it).
                if !destination.isLive, case .stream(let p) = destination.kind,
                   p.contentType == "series", prefs.autoplayNextEpisode {
                    // Overlay is shown via the `showNextEpisodeOverlay` state.
                    showNextEpisodeOverlay = true
                } else {
                    dismiss()
                }
            }
        }
        .onDisappear {
            // Stop the exact torrent we actually started. Using
            // `destination.streamSource` here would miss the case where
            // the user backed out before resolve() finished — the engine
            // would then start the session seconds LATER and never be
            // stopped. `startedTorrentHash` is only set after startStream.
            if let hash = startedTorrentHash {
                store.stopTorrent(infoHash: hash)
            }
            hideTask?.cancel()
            progressTask?.cancel()
            store.chromecast.stopDiscovery()
            ActivePlayback.shared.unregister(controller)
            // One last progress flush so the exact position the user left
            // on lands in the WatchStore (the debounced save picks it up).
            reportProgress()
            if simklStarted, let p = watchContext, controller.duration > 0 {
                let pct = controller.position / controller.duration * 100
                Task { [simkl = store.simkl] in
                    await simkl.scrobble(.stop, imdbId: p.contentId, season: p.season, episode: p.episode, progress: pct)
                }
            }
            releaseDisplaySleep()
        }
    }

    // MARK: - watch progress

    /// (type, id, videoId) for the WatchStore. Nil for anything we don't
    /// track (live channels).
    private func watchIdentity() -> (String, String, String?)? {
        guard let c = watchContext else { return nil }
        return (c.contentType, c.contentId, c.videoId)
    }

    /// The progress record for what's playing: the addon payload, the
    /// title context a detail page attached, or — for an IPTV film or
    /// episode opened from the IPTV tab, which has no IMDB id — the
    /// provider's own id under the "iptv" type, kept for resume only.
    private var watchContext: PlayerDestination.WatchContext? {
        switch destination.kind {
        case .stream(let p):
            return .init(contentType: p.contentType, contentId: p.contentId, videoId: p.videoId,
                         season: p.season, episode: p.episode, poster: p.poster,
                         background: p.background, addonId: p.addonId, addonName: p.addonName)
        case .liveChannel(let c) where c.isOnDemand:
            return destination.watchContext ?? .init(
                contentType: "iptv", contentId: c.id, videoId: nil, season: nil, episode: nil,
                poster: c.logoUrl, background: nil, addonId: nil, addonName: nil
            )
        case .liveChannel:
            return nil
        case .libraryItem:
            return destination.watchContext
        }
    }

    private func startProgressReporting() {
        progressTask?.cancel()
        progressTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                if Task.isCancelled { return }
                reportProgress()
            }
        }
    }

    // MARK: - next episode overlay

    private var nextEpisodeOverlay: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.Palette.accent, Theme.Palette.accentWarm],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                Text("Episode finished")
                    .font(Theme.Font.display(28))
                    .foregroundStyle(.white)
                Text("Back to episodes in \(nextEpisodeCountdown)s")
                    .font(Theme.Font.label(13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                HStack(spacing: Theme.Spacing.md) {
                    Button {
                        showNextEpisodeOverlay = false
                        nextEpisodeCountdown = 10
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                            Text("Stay here").font(Theme.Font.label(14, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(.ultraThinMaterial))
                        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plainRect)
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet")
                            Text("Episodes").font(Theme.Font.label(14, weight: .bold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(.white))
                        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                    }
                    .buttonStyle(.plainRect)
                }
            }
        }
        .task(id: showNextEpisodeOverlay) {
            guard showNextEpisodeOverlay else { return }
            nextEpisodeCountdown = 10
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                if !showNextEpisodeOverlay { return }
                nextEpisodeCountdown -= 1
            }
            if showNextEpisodeOverlay { dismiss() }
        }
    }

    // MARK: - external subtitles

    private func fetchExternalSubtitles() {
        guard case .stream(let p) = destination.kind else { return }
        controller.isFetchingExternalSubs = true
        Task { @MainActor in
            let fetcher = SubtitleFetcher()
            let subs = await fetcher.fetchAll(
                addons: store.addons,
                type: p.contentType,
                id: p.contentId,
                videoId: p.videoId
            )
            controller.externalSubtitles = subs
            controller.isFetchingExternalSubs = false

            // Auto-attach a subtitle in the preferred language (if any)
            // as soon as the file has started playing — mpv's `slang`
            // only covers embedded tracks. Match tolerantly:
            //   1. Exact code (eng, fre, …)
            //   2. 2-letter / 3-letter synonyms (en ↔ eng, fr ↔ fra/fre)
            //   3. Prefix match fallback
            if !prefs.preferredSubtitleLang.isEmpty,
               let match = pickBestSubtitle(from: subs, preferred: prefs.preferredSubtitleLang) {
                controller.addExternalSubtitle(
                    url: match.url, title: match.displayLanguage, lang: match.lang
                )
            }
        }
    }

    // MARK: - Live EPG (Xtream short EPG)

    /// Fetch now/next for the current live channel, if the selected
    /// playlist is Xtream. M3U playlists don't carry EPG data — the
    /// overlay simply stays hidden.
    private func fetchLiveEPG() {
        guard case .liveChannel(let channel) = destination.kind else { return }
        // Parse the xtream stream id from the id convention "xtream-<sid>".
        let prefix = "xtream-"
        guard channel.id.hasPrefix(prefix) else {
            // M3U channels: now/next from the playlist's XMLTV guide.
            if let now = store.epg.current(for: channel) {
                epgNow = Self.shortEntry(now)
                epgNext = store.epg.next(for: channel).map(Self.shortEntry)
                epgVisible = true
                scheduleEPGHide()
            }
            return
        }
        let streamId = String(channel.id.dropFirst(prefix.count))

        guard let selId = store.selectedIptvPlaylistId,
              let ref = store.iptvPlaylists.first(where: { $0.id == selId }),
              let creds = ref.xtream else { return }

        Task { @MainActor in
            let client = XtreamClient()
            let entries = await client.fetchShortEPG(creds, streamId: streamId)
            let now = Date()
            // Entries are ordered by start; pick the one containing `now`
            // for "now" and the one after as "next".
            let nowIdx = entries.firstIndex { e in
                guard let s = parseEpgDate(e.start), let f = parseEpgDate(e.end)
                else { return false }
                return s <= now && now < f
            }
            if let i = nowIdx {
                epgNow = entries[i]
                epgNext = (i + 1 < entries.count) ? entries[i + 1] : nil
            } else {
                // No slot matches wall-clock time (panel skew). Fall back
                // to the first two slots.
                epgNow  = entries.first
                epgNext = entries.count > 1 ? entries[1] : nil
            }
            epgVisible = epgNow != nil
            scheduleEPGHide()
        }
    }

    /// The overlay renders Xtream's short-EPG entries; an XMLTV programme
    /// is shown through the same shape (UTC "yyyy-MM-dd HH:mm:ss"). Title
    /// and description are base64-encoded like Xtream's: the overlay
    /// decodes them, and a plain four-letter title can otherwise pass for
    /// base64 and come out as garbage.
    private static func shortEntry(_ p: EpgProgramme) -> ShortEPGEntry {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let b64 = { (s: String) in Data(s.utf8).base64EncodedString() }
        return ShortEPGEntry(id: nil, epgId: nil, title: b64(p.title), lang: nil,
                             start: f.string(from: p.start), end: f.string(from: p.end),
                             description: p.description.map(b64), channelId: p.channelId)
    }

    private func scheduleEPGHide() {
        epgHideTask?.cancel()
        epgHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            withAnimation { epgVisible = false }
        }
    }

    // MARK: - Catchup

    private func fetchCatchupEPG() {
        guard case .liveChannel(let channel) = destination.kind,
              channel.id.hasPrefix("xtream-"),
              let selId = store.selectedIptvPlaylistId,
              let ref = store.iptvPlaylists.first(where: { $0.id == selId }),
              let creds = ref.xtream
        else { return }
        let streamId = String(channel.id.dropFirst("xtream-".count))
        Task { @MainActor in
            let client = XtreamClient()
            let entries = await client.fetchCatchupEPG(creds, streamId: streamId)
            self.catchupEntries = entries.reversed()  // newest first
        }
    }

    private func jumpToCatchup(entry: ShortEPGEntry) {
        guard case .liveChannel(let channel) = destination.kind,
              channel.id.hasPrefix("xtream-"),
              let selId = store.selectedIptvPlaylistId,
              let ref = store.iptvPlaylists.first(where: { $0.id == selId }),
              let creds = ref.xtream,
              let start = parseEpgDate(entry.start),
              let end = parseEpgDate(entry.end)
        else { return }
        let streamId = String(channel.id.dropFirst("xtream-".count))
        let duration = max(30, Int(end.timeIntervalSince(start) / 60))
        if let url = XtreamClient().timeshiftURL(
            creds, streamId: streamId, start: start, durationMinutes: duration
        ) {
            resolvedUrl = url
            showCatchupSheet = false
            flashControls()
        }
    }

    private func parseEpgDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        // Xtream returns "YYYY-MM-DD HH:mm:ss" in the panel timezone or UTC.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: s)
    }

    private func formatEpgTime(_ s: String?) -> String {
        guard let d = parseEpgDate(s) else { return "" }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: d)
    }

    @ViewBuilder
    private var epgOverlay: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let n = epgNow {
                epgCard(label: "NOW", entry: n, color: Theme.Palette.accentOnDark)
            }
            if let n = epgNext {
                epgCard(label: "NEXT", entry: n, color: Theme.Palette.textPrimary.opacity(0.7))
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
    }

    private func epgCard(label: String, entry: ShortEPGEntry, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(label.localized)
                    .font(Theme.Font.eyebrow(10, weight: .black))
                    .tracking(2.4)
                    .foregroundStyle(color)
                Rectangle().fill(color).frame(width: 18, height: 1)
                Text("\(formatEpgTime(entry.start)) – \(formatEpgTime(entry.end))")
                    .font(Theme.Font.mono(10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Text(entry.decodedTitle)
                .font(Theme.Font.title(16))
                .foregroundStyle(.white)
                .lineLimit(1)
            let desc = entry.decodedDescription
            if !desc.isEmpty {
                Text(desc)
                    .font(Theme.Font.body(12))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.45))
        .overlay(Rectangle().stroke(.white.opacity(0.12), lineWidth: 1))
    }

    /// ISO 639-1 (2-letter) ↔ ISO 639-2 (3-letter) synonym table for the
    /// languages Settings exposes. Returns a set of equivalent codes for
    /// matching purposes.
    private func languageSynonyms(for code: String) -> Set<String> {
        let lower = code.lowercased()
        let map: [String: [String]] = [
            "en":  ["eng"], "eng": ["en"],
            "fr":  ["fre", "fra"], "fre": ["fr", "fra"], "fra": ["fr", "fre"],
            "es":  ["spa"], "spa": ["es"],
            "de":  ["ger", "deu"], "ger": ["de", "deu"], "deu": ["de", "ger"],
            "it":  ["ita"], "ita": ["it"],
            "pt":  ["por"], "por": ["pt"],
            "ru":  ["rus"], "rus": ["ru"],
            "ja":  ["jpn"], "jpn": ["ja"],
            "ko":  ["kor"], "kor": ["ko"],
            "zh":  ["chi", "zho"], "chi": ["zh", "zho"], "zho": ["zh", "chi"],
            "ar":  ["ara"], "ara": ["ar"],
            "nl":  ["dut", "nld"], "dut": ["nl", "nld"], "nld": ["nl", "dut"],
            "sv":  ["swe"], "swe": ["sv"],
            "pl":  ["pol"], "pol": ["pl"],
            "tr":  ["tur"], "tur": ["tr"],
            "hi":  ["hin"], "hin": ["hi"]
        ]
        var out: Set<String> = [lower]
        if let aliases = map[lower] {
            out.formUnion(aliases.map { $0.lowercased() })
        }
        return out
    }

    private func pickBestSubtitle(
        from subs: [AddonSubtitle], preferred: String
    ) -> AddonSubtitle? {
        let candidates = languageSynonyms(for: preferred)
        // Tier 1: exact (any synonym) match.
        if let hit = subs.first(where: {
            candidates.contains(($0.lang ?? "").lowercased())
        }) { return hit }
        // Tier 2: prefix match (e.g. preferred=fr, sub.lang=fra-FR).
        if let hit = subs.first(where: {
            let l = ($0.lang ?? "").lowercased()
            return candidates.contains { l.hasPrefix($0) }
        }) { return hit }
        return nil
    }

    private func loadLocalSubtitle() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["srt", "ass", "ssa", "vtt", "sub", "idx"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller.addExternalSubtitle(
            url: url.absoluteString,
            title: url.lastPathComponent,
            lang: nil
        )
    }

    private func reportProgress() {
        guard let p = watchContext else { return }
        guard controller.duration > 0, controller.position > 0 else { return }
        watch.reportProgress(
            type: p.contentType,
            id: p.contentId,
            name: destination.title,
            position: controller.position,
            duration: controller.duration,
            poster: p.poster,
            background: p.background,
            addonId: p.addonId,
            addonName: p.addonName,
            videoId: p.videoId,
            season: p.season,
            episode: p.episode
        )
        if !simklStarted, store.simkl.isConnected, p.contentId.hasPrefix("tt") {
            simklStarted = true
            let pct = controller.position / controller.duration * 100
            Task { [simkl = store.simkl] in
                await simkl.scrobble(.start, imdbId: p.contentId, season: p.season, episode: p.episode, progress: pct)
            }
        }
        // Fire-and-forget scrobble to Trakt. Only when connected AND the
        // content id is an IMDb id (Trakt is IMDb-keyed).
        if p.contentId.hasPrefix("tt"), store.trakt.isConnected {
            let pct = controller.duration > 0
                ? (controller.position / controller.duration) * 100.0
                : 0
            let action: TraktService.ScrobbleAction = controller.isPaused ? .pause : .start
            Task { [action, pct, trakt = store.trakt] in
                await trakt.scrobble(
                    action: action,
                    imdbId: p.contentId,
                    season: p.season,
                    episode: p.episode,
                    progress: pct
                )
            }
        }
    }

    // MARK: - display sleep

    private func preventDisplaySleep() {
        guard sleepAssertionId == 0 else { return }
        let reason = "Veltrio playback" as CFString
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionId
        )
    }

    private func releaseDisplaySleep() {
        guard sleepAssertionId != 0 else { return }
        IOPMAssertionRelease(sleepAssertionId)
        sleepAssertionId = 0
    }

    // MARK: - catchup sheet

    private var catchupSheet: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("Catchup").eyebrow(Theme.Palette.accentOnDark, tracking: 2.6)
                Spacer()
                Button {
                    showCatchupSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .overlay(Rectangle().stroke(.white.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plainRect)
            }
            Text("Jump back to any programme from the last 24 hours. Timeshift URL is built on the fly.")
                .font(Theme.Font.caption(11))
                .foregroundStyle(.white.opacity(0.6))
            Rule(color: .white.opacity(0.15))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(catchupEntries, id: \.self) { e in
                        Button {
                            jumpToCatchup(entry: e)
                        } label: {
                            catchupRow(e)
                        }
                        .buttonStyle(.plainRect)
                    }
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 400, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.55))
        .overlay(Rectangle().stroke(.white.opacity(0.1), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func catchupRow(_ e: ShortEPGEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(formatEpgTime(e.start))
                .font(Theme.Font.mono(10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.decodedTitle)
                    .font(Theme.Font.title(13))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                let d = e.decodedDescription
                if !d.isEmpty {
                    Text(d)
                        .font(Theme.Font.caption(11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "play.fill")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(Theme.Palette.accentOnDark)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.clear)
        .contentShape(Rectangle())
    }

    // MARK: - skip intro overlay

    private var skipIntroOverlay: some View {
        Button {
            controller.skipIntro()
            flashControls()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 11, weight: .black))
                Text("Skip intro")
                    .font(Theme.Font.eyebrow(11, weight: .heavy))
                    .tracking(2.4)
                    .textCase(.uppercase)
                Rectangle().fill(Theme.Palette.onAccent)
                    .frame(width: 18, height: 1)
            }
            .foregroundStyle(Theme.Palette.onAccent)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Rectangle().fill(Theme.Palette.accent))
            .shadow(color: Theme.Palette.accentGlow, radius: 20, y: 8)
        }
        .buttonStyle(.plainRect)
        .onHover { h in
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // No key equivalent here: `s` is bound on the player root with
        // `onKeyPress` (below), which fires only while the player is on
        // screen and cannot shadow a text field elsewhere in the app.
    }

    // MARK: - media info panel
    //
    // Right-side drawer that lists codecs, resolution, bitrate, HDR flag
    // and active tracks. Toggled with the info button or `i`.

    private var mediaInfoPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("Media info")
                    .eyebrow(Theme.Palette.accentOnDark, tracking: 2.6)
                Spacer()
                Button {
                    showMediaInfo = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .overlay(Rectangle().stroke(.white.opacity(0.2), lineWidth: 1))
                }
                .buttonStyle(.plainRect)
            }
            Rule(color: .white.opacity(0.15))

            if let res = controller.videoResolution {
                infoLine("Resolution", res)
            }
            if let codec = controller.videoCodec {
                infoLine("Video codec", codec)
            }
            if let fps = controller.videoFps, fps > 0 {
                infoLine("Frame rate", String(format: "%.3f fps", fps))
            }
            if let br = controller.videoBitrate, br > 0 {
                infoLine("Video bitrate", String(format: "%.1f Mbps", Double(br) / 1_000_000))
            }
            if let codec = controller.audioCodec {
                infoLine("Audio codec", codec)
            }
            if controller.hdrDetected {
                HStack(spacing: 6) {
                    Text("HDR")
                        .font(Theme.Font.eyebrow(10, weight: .black))
                        .tracking(2.0)
                        .foregroundStyle(Theme.Palette.onAccent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Rectangle().fill(Theme.Palette.accent))
                    Text("Tone mapping: \(controller.toneMappingPreset.rawValue)")
                        .font(Theme.Font.caption(11))
                        .foregroundStyle(.white.opacity(0.75))
                }
            }

            if !controller.audioTracks.isEmpty {
                Rule(color: .white.opacity(0.15)).padding(.vertical, 2)
                Text("Audio tracks (\(controller.audioTracks.count))")
                    .eyebrow(.white.opacity(0.65), tracking: 2.0)
                ForEach(controller.audioTracks) { t in
                    infoLine(t.displayName, t.secondaryLabel ?? "")
                }
            }
            if !controller.subtitleTracks.isEmpty {
                Rule(color: .white.opacity(0.15)).padding(.vertical, 2)
                Text("Subtitles (\(controller.subtitleTracks.count))")
                    .eyebrow(.white.opacity(0.65), tracking: 2.0)
                ForEach(controller.subtitleTracks) { t in
                    infoLine(t.displayName, t.secondaryLabel ?? "")
                }
            }

            Spacer()
            Text("Profile · \(controller.playbackProfile.rawValue)")
                .font(Theme.Font.caption(10))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 340, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.55))
        .overlay(Rectangle().stroke(.white.opacity(0.1), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func infoLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.localized)
                .font(Theme.Font.caption(11))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(Theme.Font.mono(11))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
        }
    }

    /// Keyboard "a" — cycle through aspect modes.
    private func cycleAspect() {
        let modes = PlayerController.AspectMode.allCases
        let next = modes.firstIndex(of: controller.aspectMode).map { ($0 + 1) % modes.count } ?? 0
        controller.setAspectMode(modes[next])
        flashControls()
    }

    // MARK: - overlay

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .black))
                    Text("Back")
                        .font(Theme.Font.label(13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.md + 2)
                .padding(.vertical, 9)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
            }
            .buttonStyle(.plainRect)
            // No key equivalent here. Escape is handled on the player
            // root: it leaves full screen first, and only leaves the
            // player on a second press. Binding it to this button too
            // would make Escape dismiss the player outright.

            if destination.isLive {
                liveBadge
            }

            if let logoURL = destination.logoUrl, let url = URL(string: logoURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        Color.clear
                    }
                }
                .frame(width: 36, height: 36)
                .padding(4)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(destination.title)
                    .font(Theme.Font.label(14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle = destination.subtitle {
                    Text(subtitle)
                        .font(Theme.Font.label(11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }

            Spacer()

            audioTrackMenu
            subtitleTrackMenu
            speedMenu
            aspectMenu
            profileMenu
            castMenu
            if destination.isLive && !catchupEntries.isEmpty {
                Button {
                    showCatchupSheet.toggle()
                } label: {
                    glassIcon("clock.arrow.circlepath",
                              badge: "\(catchupEntries.count)")
                }
                .buttonStyle(.plainRect)
                .help("Catchup / timeshift")
            }

            Button {
                showMediaInfo.toggle()
            } label: {
                glassIcon(showMediaInfo ? "info.circle.fill" : "info.circle")
            }
            .buttonStyle(.plainRect)
            .help("Media info (I)")

            Button {
                toggleFullScreen()
            } label: {
                glassIcon("arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plainRect)
            .help("Toggle fullscreen (F)")
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.lg)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.65), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        )
    }

    private var bottomBar: some View {
        VStack(spacing: Theme.Spacing.md) {
            if !destination.isLive {
                seekBar
            }
            HStack(spacing: Theme.Spacing.md) {
                if destination.isLive {
                    playPauseButton
                } else {
                    controlButton(system: "gobackward.10", help: "Skip back 10s (←)") {
                        controller.skip(by: -10); flashControls()
                    }
                    playPauseButton
                    controlButton(system: "goforward.10", help: "Skip forward 10s (→)") {
                        controller.skip(by: 10); flashControls()
                    }
                }

                Spacer()

                if destination.isLive {
                    livePositionLabel
                } else {
                    timeLabel
                        .frame(minWidth: 130, alignment: .trailing)
                }

                volumeControl
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xl)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
        )
    }

    private var liveBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.Palette.danger).frame(width: 7, height: 7)
                .shadow(color: Theme.Palette.danger.opacity(0.6), radius: 6)
            Text("LIVE")
                .font(Theme.Font.label(11, weight: .black))
                .tracking(0.8)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.55)))
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
    }

    private var livePositionLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 11, weight: .bold))
            Text(controller.isBuffering ? "Buffering…" : "Live")
                .font(Theme.Font.label(12, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }

    // MARK: - seek bar

    private var seekBar: some View {
        let duration = max(controller.duration, 0)
        let displayed = isScrubbing ? scrubValue : controller.position
        return HStack(spacing: Theme.Spacing.sm) {
            Text(format(displayed))
                .font(Theme.Font.label(11, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
                .frame(width: 54, alignment: .leading)

            ZStack(alignment: .topLeading) {
                SeekSlider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : controller.position },
                        set: { scrubValue = $0 }
                    ),
                    range: 0...(duration > 0 ? duration : 1),
                    onEditingChanged: { editing in
                        if editing {
                            isScrubbing = true
                            scrubValue = controller.position
                        } else {
                            isScrubbing = false
                            controller.seek(to: scrubValue)
                        }
                    },
                    hoverTime: $hoverTime,
                    chapters: controller.chapters.map { ($0.title, $0.startSeconds) },
                    duration: duration
                )
                .disabled(duration <= 0)
                .frame(height: 16)

                if let t = hoverTime, duration > 0 {
                    scrubTooltip(at: t, duration: duration)
                }
            }

            Text("-" + format(max(duration - displayed, 0)))
                .font(Theme.Font.label(11, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
        }
    }

    /// Floating tooltip above the seek bar: shows the time + chapter title
    /// at the hovered position. Pure-SwiftUI, no thumbnail decode yet.
    @ViewBuilder
    private func scrubTooltip(at t: Double, duration: Double) -> some View {
        GeometryReader { geo in
            let frac = max(0, min(1, t / duration))
            let x = geo.size.width * frac
            VStack(spacing: 4) {
                if let ch = chapterContaining(time: t) {
                    Text(ch.title)
                        .font(Theme.Font.eyebrow(9, weight: .bold))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Palette.accentOnDark)
                        .lineLimit(1)
                        .frame(maxWidth: 180)
                }
                Text(format(t))
                    .font(Theme.Font.mono(11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .background(Color.black.opacity(0.6))
            .overlay(Rectangle().stroke(.white.opacity(0.12), lineWidth: 1))
            .fixedSize()
            .offset(x: x - 50, y: -46)
        }
        .frame(height: 0)
        .allowsHitTesting(false)
    }

    private func chapterContaining(time: Double) -> PlayerController.Chapter? {
        let sorted = controller.chapters.sorted { $0.startSeconds < $1.startSeconds }
        return sorted.last(where: { $0.startSeconds <= time })
    }

    // MARK: - audio / subs / speed menus

    private func glassIcon(_ system: String, badge: String? = nil) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: system)
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
            if let badge {
                Text(badge)
                    .font(Theme.Font.label(9, weight: .black))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.white))
                    .overlay(Capsule().stroke(.black.opacity(0.1), lineWidth: 0.5))
                    .offset(x: 3, y: 3)
            }
        }
    }

    @ViewBuilder
    private var audioTrackMenu: some View {
        if controller.audioTracks.count > 1 {
            Menu {
                ForEach(controller.audioTracks) { track in
                    Button {
                        controller.setAudioTrack(track.id)
                        flashControls()
                    } label: {
                        trackMenuLabel(track, isActive: track.id == controller.currentAudioId)
                    }
                }
            } label: {
                glassIcon("waveform")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Audio track")
        }
    }

    @ViewBuilder
    private var subtitleTrackMenu: some View {
        if !destination.isLive {
            Menu {
                Button {
                    controller.setSubtitleTrack(0)
                    flashControls()
                } label: {
                    if controller.currentSubtitleId == 0 {
                        Label("Off", systemImage: "checkmark")
                    } else {
                        Text("Off")
                    }
                }
                if !controller.subtitleTracks.isEmpty {
                    Divider()
                    Section("Embedded") {
                        ForEach(controller.subtitleTracks) { track in
                            Button {
                                controller.setSubtitleTrack(track.id)
                                flashControls()
                            } label: {
                                trackMenuLabel(track, isActive: track.id == controller.currentSubtitleId)
                            }
                        }
                    }
                }
                if !controller.externalSubtitles.isEmpty {
                    Divider()
                    Section("From addons") {
                        ForEach(controller.externalSubtitles) { sub in
                            Button {
                                controller.addExternalSubtitle(
                                    url: sub.url, title: sub.displayLanguage, lang: sub.lang
                                )
                                flashControls()
                            } label: {
                                Text("\(sub.displayLanguage)   \(sub.addonName)")
                            }
                        }
                    }
                }
                Divider()
                Button {
                    loadLocalSubtitle()
                } label: {
                    Label("Load from file…", systemImage: "doc.badge.plus")
                }
                if controller.subDelay != 0 {
                    Divider()
                    Button {
                        controller.setSubDelay(0)
                    } label: {
                        Text(String(format: "Delay: %+.1fs — reset".localized, controller.subDelay))
                    }
                }
            } label: {
                glassIcon(
                    controller.currentSubtitleId == 0 && !hasAttachedExternalSub
                        ? "captions.bubble"
                        : "captions.bubble.fill",
                    badge: controller.isFetchingExternalSubs ? "…" : nil
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Subtitles (Z / X for delay)")
        }
    }

    private var hasAttachedExternalSub: Bool {
        // When the user picks an addon/local sub, sid becomes > 0 and the
        // track appears in subtitleTracks. The "fill" icon is a good
        // proxy for "there's a subtitle active or ready".
        controller.currentSubtitleId > 0
    }

    private var speedMenu: some View {
        let options: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
        return Menu {
            ForEach(options, id: \.self) { s in
                Button {
                    controller.setSpeed(s)
                    flashControls()
                } label: {
                    let label = s == 1.0 ? String(localized: "Normal") : String(format: "%g×", s)
                    if abs(controller.speed - s) < 0.01 {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label.localized)
                    }
                }
            }
        } label: {
            glassIcon(
                "gauge.with.dots.needle.67percent",
                badge: controller.speed != 1.0 ? String(format: "%g×", controller.speed) : nil
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed")
    }

    private var aspectMenu: some View {
        Menu {
            Section("Aspect ratio") {
                ForEach(PlayerController.AspectMode.allCases) { mode in
                    Button {
                        controller.setAspectMode(mode)
                        flashControls()
                    } label: {
                        if controller.aspectMode == mode {
                            Label(mode.rawValue.localized, systemImage: "checkmark")
                        } else {
                            Text(mode.rawValue.localized)
                        }
                    }
                }
            }
            Divider()
            Section("Zoom") {
                Button { controller.bumpZoom(by: 0.1); flashControls() } label: { Label("Zoom in", systemImage: "plus.magnifyingglass") }
                Button { controller.bumpZoom(by: -0.1); flashControls() } label: { Label("Zoom out", systemImage: "minus.magnifyingglass") }
                Button { controller.resetZoom(); flashControls() } label: {
                    Label(String(format: "Reset  (%+.1f)".localized, controller.videoZoom), systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            glassIcon(
                "aspectratio",
                badge: controller.aspectMode == .auto && controller.videoZoom == 0 ? nil : controller.aspectMode.rawValue
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Aspect ratio & zoom")
    }

    private var castMenu: some View {
        Menu {
            Section("Cast to") {
                ForEach(CastingService.CastTarget.allCases) { target in
                    Button {
                        handleCast(target)
                    } label: {
                        let status = store.casting.status(for: target)
                        Label("\(target.rawValue)   —   \(status)",
                              systemImage: target.icon)
                    }
                    .disabled(isDisabledTarget(target))
                }
            }
            Section("Chromecast") {
                if !ChromecastService.canCast(resolvedUrl) {
                    Text("This stream plays from this Mac (torrent) and can't be sent to a Chromecast. A debrid service makes it castable.")
                } else if store.chromecast.devices.isEmpty {
                    Text("Searching for Chromecasts on your network…")
                } else {
                    ForEach(store.chromecast.devices) { device in
                        Button { castTo(device) } label: { Label(device.name, systemImage: "tv") }
                    }
                }
                if store.chromecast.isCasting {
                    Button { stopCasting() } label: { Label("Stop casting", systemImage: "stop.fill") }
                }
            }
        } label: {
            glassIcon("airplayvideo")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Cast / AirPlay / PiP")
    }

    private func isDisabledTarget(_ target: CastingService.CastTarget) -> Bool {
        switch target {
        case .airplay:          return !store.casting.isAirPlayAvailable
        case .pictureInPicture: return !store.casting.isPipAvailable
        }
    }

    /// Hands the stream to a Chromecast at the current position and pauses
    /// it here; stopping resumes it here.
    private func castTo(_ device: ChromecastService.Device) {
        guard let url = resolvedUrl else { return }
        if !controller.isPaused { controller.togglePause() }
        store.chromecast.cast(url, title: destination.title, poster: destination.artworkUrl,
                              isLive: destination.isLive, startAt: controller.position, to: device)
    }

    private func stopCasting() {
        store.chromecast.stop()
        if controller.isPaused { controller.togglePause() }
    }

    @ViewBuilder
    private var castBanner: some View {
        switch store.chromecast.state {
        case .connecting(let name), .casting(let name):
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "tv").font(.system(size: 14, weight: .bold))
                Text(store.chromecast.state == .casting(name)
                     ? String(localized: "Playing on \(name)") : String(localized: "Connecting to \(name)…"))
                    .font(Theme.Font.label(13, weight: .semibold))
                FrameButton(title: "Stop", icon: "stop.fill", color: .white) { stopCasting() }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
            .background(Rectangle().fill(.black.opacity(0.75)))
            .padding(.top, 70)
        case .failed(let why):
            Text(why)
                .font(Theme.Font.label(12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.sm)
                .background(Rectangle().fill(Theme.Palette.danger.opacity(0.85)))
                .padding(.top, 70)
        case .idle:
            EmptyView()
        }
    }

    private func handleCast(_ target: CastingService.CastTarget) {
        switch target {
        case .airplay:
            store.casting.openAirPlayPicker(anchor: NSApp.keyWindow?.contentView)
        case .pictureInPicture:
            // Future: spawn a secondary AVPlayer window with the same URL
            // at the current position, start PiP there, pause mpv.
            break
        }
    }

    private var profileMenu: some View {
        Menu {
            Section("Playback profile") {
                ForEach(PlayerController.PlaybackProfile.allCases) { p in
                    Button {
                        controller.applyPlaybackProfile(p)
                        flashControls()
                    } label: {
                        if controller.playbackProfile == p {
                            Label(p.rawValue, systemImage: "checkmark")
                        } else {
                            Text(p.rawValue)
                        }
                    }
                }
            }
            Divider()
            Section("Tone mapping") {
                ForEach(PlayerController.ToneMappingPreset.allCases) { t in
                    Button {
                        controller.setToneMappingPreset(t)
                        flashControls()
                    } label: {
                        if controller.toneMappingPreset == t {
                            Label(t.rawValue, systemImage: "checkmark")
                        } else {
                            Text(t.rawValue)
                        }
                    }
                }
            }
            Divider()
            Toggle("Audio passthrough (DTS / AC3 / EAC3)",
                   isOn: Binding(
                    get: { controller.audioPassthroughEnabled },
                    set: { controller.setAudioPassthrough($0); flashControls() }
                   ))
        } label: {
            glassIcon(
                "slider.horizontal.3",
                badge: controller.playbackProfile == .balanced ? nil : controller.playbackProfile.rawValue.prefix(1).uppercased()
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Video & audio presets")
    }

    @ViewBuilder
    private func trackMenuLabel(_ track: MediaTrack, isActive: Bool) -> some View {
        let name = track.displayName
        let detail = track.secondaryLabel.map { "   \($0)" } ?? ""
        if isActive {
            Label("\(name)\(detail)", systemImage: "checkmark")
        } else {
            Text("\(name)\(detail)")
        }
    }

    // MARK: - control buttons

    private var playPauseButton: some View {
        Button {
            controller.togglePause()
            flashControls()
        } label: {
            Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 20, weight: .black))
                .foregroundStyle(.black)
                .frame(width: 54, height: 54)
                .background(
                    Circle().fill(.white)
                )
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        }
        .buttonStyle(.plainRect)
        // No key equivalent on this button: the player root already binds
        // Space with `onKeyPress`, and a view-level equivalent would race
        // it (two toggles for one press, so pause would look dead).
    }

    private func controlButton(system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plainRect)
        .help(help.localized)
    }

    private var timeLabel: some View {
        HStack(spacing: 4) {
            Text(format(isScrubbing ? scrubValue : controller.position))
                .foregroundStyle(.white)
            Text("/")
                .foregroundStyle(.white.opacity(0.4))
            Text(format(controller.duration))
                .foregroundStyle(.white.opacity(0.75))
        }
        .font(Theme.Font.label(12, weight: .semibold))
        .monospacedDigit()
    }

    private var volumeControl: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                controller.toggleMute()
                flashControls()
            } label: {
                Image(systemName: muteIcon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plainRect)
            .help("Mute (M)")

            SeekSlider(
                value: Binding(
                    get: { controller.volume },
                    set: { controller.setVolume($0) }
                ),
                range: 0...100,
                onEditingChanged: { _ in flashControls() }
            )
            .frame(width: 100)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 2)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var muteIcon: String {
        if controller.isMuted || controller.volume == 0 { return "speaker.slash.fill" }
        if controller.volume < 34 { return "speaker.wave.1.fill" }
        if controller.volume < 67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - states

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large).colorScheme(.dark)
            Text(statusLabel)
                .foregroundStyle(.white.opacity(0.9))
                .font(Theme.Font.label(13, weight: .semibold))
            Text(destination.title)
                .foregroundStyle(.white.opacity(0.6))
                .font(.system(size: 12))
        }
    }

    private func errorState(_ error: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.yellow)
            Text("Couldn't open this stream")
                .font(Theme.Font.heading(18))
                .foregroundStyle(.white)
            Text(error.localized)
                .foregroundStyle(.white.opacity(0.8))
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: Theme.Spacing.sm) {
                FrameButton(title: "Retry",
                            icon: "arrow.clockwise",
                            color: Theme.Palette.accent,
                            fill: Theme.Palette.accent) {
                    // Wipe previous failure state and re-run resolve/load.
                    resolveError = nil
                    controller.playbackError = nil
                    resolvedUrl = nil
                    Task { await resolve() }
                }
                FrameButton(title: "Back", color: .white) {
                    dismiss()
                }
            }
            .padding(.top, 6)
        }
    }

    private func externalFallback(label: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.up.right.square.fill")
                .font(.system(size: 42))
                .foregroundStyle(.white)
            Text(label.localized)
                .font(Theme.Font.heading(18))
                .foregroundStyle(.white)
            if let url = resolvedUrl {
                // Show the destination before opening it so a hostile addon
                // can't quietly launch an arbitrary custom-scheme handler.
                Text(url.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 24)
            }
            HStack(spacing: Theme.Spacing.sm) {
                FrameButton(title: label,
                            icon: "arrow.up.right",
                            color: Theme.Palette.accent,
                            fill: Theme.Palette.accent) {
                    if let url = resolvedUrl, isSafeExternalURL(url) {
                        NSWorkspace.shared.open(url)
                    }
                    dismiss()
                }
                FrameButton(title: "Cancel", color: .white) {
                    dismiss()
                }
            }
        }
    }

    private func isSafeExternalURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "magnet"].contains(scheme)
    }

    private var statusLabel: String {
        if destination.isLive { return String(localized: "Connecting to live stream…") }
        if case .torrent = destination.streamSource {
            return String(localized: "Preparing torrent — connecting to peers…")
        }
        return String(localized: "Loading stream…")
    }

    // MARK: - helpers

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private func flashControls() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.18)) { controlsVisible = true }
        }
        resetHideTimer()
    }

    private func resetHideTimer() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            if controller.isPaused { return }
            withAnimation(.easeOut(duration: 0.22)) { controlsVisible = false }
        }
    }

    private func toggleFullScreen() {
        if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            window.toggleFullScreen(nil)
        }
    }

    /// Escape leaves full screen before it leaves the player.
    ///
    /// The expected behaviour in a video player is Escape = "get me out of
    /// full screen", and only a second Escape = "leave the player". The
    /// old binding dismissed the player outright, which meant Escape could
    /// never get you out of full screen without also throwing away the
    /// playback position.
    private func handleEscape() {
        if isWindowFullScreen {
            toggleFullScreen()
        } else {
            dismiss()
        }
    }

    /// Whether the app's window is currently in macOS full screen.
    ///
    /// `NSWindow.styleMask` is the only source of truth available from
    /// SwiftUI; `NSApp.keyWindow` can be nil while the transition runs, so
    /// we fall back to the first visible window.
    private var isWindowFullScreen: Bool {
        let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible })
        guard let window else { return false }
        return window.styleMask.contains(.fullScreen)
    }

    private func resolve() async {
        isResolving = true
        defer { isResolving = false }
        switch destination.kind {
        case .stream(let p):
            do {
                let url = try await store.resolvePlayableUrl(
                    for: p.stream, season: p.season, episode: p.episode
                )
                // The user may have hit Back while we were awaiting. If the
                // Task got cancelled, bail out — but if a torrent session
                // started on the Rust side, stop it; otherwise it would
                // seed forever with no owner.
                if Task.isCancelled {
                    if case .torrent(let hash, _, _) = p.stream.source {
                        store.stopTorrent(infoHash: hash)
                    }
                    return
                }
                if case .torrent(let hash, _, _) = p.stream.source {
                    startedTorrentHash = hash
                }
                resolvedUrl = url
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                resolveError = humanize(error)
            }
        case .liveChannel(let channel):
            if let u = URL(string: channel.streamUrl) {
                resolvedUrl = u
            } else {
                resolveError = String(localized: "The channel URL is not valid.")
            }
        case .libraryItem(let item):
            // Jellyfin and Emby hand out a ready-to-play URL; nothing to
            // resolve through the addon pipeline.
            resolvedUrl = item.url
        }
    }

    private func humanize(_ error: Error) -> String {
        if let v = error as? VeltrioError {
            switch v {
            case .Network(let m), .Parse(let m), .InvalidUrl(let m),
                 .NotFound(let m), .Unsupported(let m), .Internal(let m):
                return m
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Styled slider

/// Custom thin slider styled for a dark, cinematic surface — the stock
/// macOS `Slider` looks out of place over the player's glass controls.
/// Supports chapter marks painted into the rail and publishes a hover
/// time so the parent view can show a scrub tooltip.
private struct SeekSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }
    var hoverTime: Binding<Double?> = .constant(nil)
    var chapters: [(title: String, start: Double)] = []
    var duration: Double = 0

    @State private var dragging = false
    @State private var isHovering = false

    private var normalized: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return max(0, min(1, (value - range.lowerBound) / span))
    }

    var body: some View {
        GeometryReader { geo in
            let height: CGFloat = isHovering || dragging ? 8 : 4
            let knobSize: CGFloat = isHovering || dragging ? 14 : 0
            let width = geo.size.width

            ZStack(alignment: .leading) {
                // Rail
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: height)

                // Progress
                Capsule()
                    .fill(Theme.Palette.accent)
                    .frame(width: max(height, normalized * width), height: height)

                // Chapter marks
                if duration > 0 {
                    ForEach(Array(chapters.enumerated()), id: \.offset) { _, c in
                        let frac = max(0, min(1, c.start / duration))
                        Rectangle()
                            .fill(Color.white.opacity(0.65))
                            .frame(width: 2, height: height + 4)
                            .offset(x: frac * width - 1, y: 0)
                    }
                }

                // Knob
                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    .offset(x: max(0, normalized * width - knobSize / 2))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 24)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    isHovering = true
                    if duration > 0 {
                        let frac = max(0, min(1, loc.x / max(width, 1)))
                        hoverTime.wrappedValue = frac * duration
                    }
                case .ended:
                    isHovering = false
                    hoverTime.wrappedValue = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        let frac = max(0, min(1, v.location.x / max(width, 1)))
                        let span = range.upperBound - range.lowerBound
                        value = range.lowerBound + frac * span
                        if duration > 0 {
                            hoverTime.wrappedValue = frac * duration
                        }
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: dragging)
        }
        .frame(height: 24)
    }
}
