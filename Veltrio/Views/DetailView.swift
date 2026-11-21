import SwiftUI

struct DetailView: View {
    let destination: DetailDestination
    @Environment(AppStore.self) private var store
    @Environment(WatchStore.self) private var watch
    @Environment(\.dismiss) private var dismiss

    @State private var meta: Meta?
    @State private var streams: [LabeledStream] = []
    @State private var streamFilter: StreamFilter = .all
    @State private var selectedVideoId: String?
    @State private var selectedSeason: Int32?
    @State private var isLoadingStreams = false
    @State private var loadError: String?

    /// Media-server and IPTV copies of this title (or of the selected episode).
    @State private var direct: [DirectStream] = []
    @State private var isLoadingDirect = false
    /// Bumped per lookup so a slow answer for a previous episode can't
    /// replace the current one.
    @State private var directRequest = 0
    @State private var sourceFilter: SourceFilter = .all

    // Right column drill-down state for series. Default is the episodes
    // grid; picking an episode flips it to the streams view for that
    // episode, with a back link to return.
    private enum RightPane { case episodes, streams }
    @State private var rightPane: RightPane = .episodes

    // Manual S/E fallback — used when meta failed but the title looks like
    // a series.
    @State private var manualSeason: Int = 1
    @State private var manualEpisode: Int = 1
    @State private var manualForcedSeries = false

    private enum StreamFilter: String, CaseIterable, Identifiable {
        case all     = "All"
        case cached  = "⚡ Cached"
        case uhd     = "4K"
        case hd      = "1080p"
        var id: String { rawValue }
    }

    /// Which source the streams list shows. Addons are listed one by one
    /// so a single addon's results can be singled out.
    private enum SourceFilter: Hashable {
        case all
        case direct(DirectStream.Origin)
        case addon(String)
    }

    /// One row of the streams list.
    private enum StreamEntry: Identifiable {
        case addon(LabeledStream)
        case direct(DirectStream)
        var id: String {
            switch self {
            case .addon(let l):  return l.id.uuidString
            case .direct(let d): return d.id
            }
        }
    }

    private var selectedVideo: Video? {
        guard let id = selectedVideoId else { return nil }
        return meta?.videos.first(where: { $0.id == id })
    }
    private var currentSeason: Int32? { selectedVideo?.season }
    private var currentEpisode: Int32? { selectedVideo?.episode }
    private var isSeries: Bool { !(meta?.videos.isEmpty ?? true) }

    // MARK: - Body
    //
    // Layout: the backdrop sits as a heavily-darkened full-page atmosphere
    // behind everything (recovers the 360pt the old banner stole), and the
    // content is a single two-column split — info/actions/episodes on the
    // left, streams on the right, separated by a vertical hairline.

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                atmosphericBackdrop
                    .frame(height: 760)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)

                if geo.size.width < 700 {
                    // A phone: one column, info then streams, the page scrolling.
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                            infoColumn
                            Rule(color: Theme.Palette.border, weight: 1)
                            streamsColumn
                        }
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.top, Theme.Spacing.sm)
                        .padding(.bottom, Theme.Spacing.xxl)
                    }
                    .environment(\.compactPage, true)
                } else {

                // The page itself doesn't scroll: the info column and the
                // streams list each scroll on their own, so the list stays
                // beside the title however long it gets.
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        infoColumn
                            .frame(width: leftWidth(for: geo.size.width))
                            .padding(.horizontal, Theme.Layout.contentInset)
                            .padding(.top, Theme.pushedTopInset + Theme.Spacing.lg)
                            .padding(.bottom, Theme.Spacing.xl)
                    }
                    .frame(width: leftWidth(for: geo.size.width) + Theme.Layout.contentInset * 2)

                    Rule(color: Theme.Palette.border, weight: 1)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)

                    streamsColumn
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.top, Theme.pushedTopInset + Theme.Spacing.lg)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                }
            }
        }
        .background(Theme.Palette.background)
        .ignoresTopSafeAreaOnMac()
        // The app draws its own Back button, so the system navigation bar
        // would show a second one. Hiding the bar also reclaims the ~72pt
        // it was reserving at the top of the page.
        .navigationBarBackButtonHidden(true)
        .task { await load() }
    }

    /// Reserve ~44% to the info column, cap it at 560pt so the streams
    /// side stays generous on wider displays.
    private func leftWidth(for total: CGFloat) -> CGFloat {
        let frac = total * 0.44
        return min(max(frac, 380), 560)
    }

    // MARK: - Atmospheric backdrop (full-page, faded)
    //
    // No more 360pt banner. The backdrop sits as a low-opacity, darkened
    // image behind the whole page, with a long fade into pure black at
    // the bottom so content below the top third stays flat.

    @ViewBuilder
    private var atmosphericBackdrop: some View {
        ZStack {
            Theme.Palette.background

            if let bgString = meta?.background ?? meta?.poster,
               let url = URL(string: bgString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        Color.clear.overlay(alignment: .top) {
                            img.resizable().scaledToFill()
                        }
                        .clipped()
                            .opacity(0.32)
                            .blur(radius: 0.5)
                    default:
                        Theme.Palette.background
                    }
                }
            }

            // Long vertical fade down to the page background so the
            // image only lives in the top third. The fade follows the
            // theme (black in dark mode, paper in light mode) so the
            // page dissolves into its own canvas in both.
            LinearGradient(
                stops: [
                    .init(color: Theme.Palette.scrim.opacity(0.35), location: 0.00),
                    .init(color: Theme.Palette.scrim.opacity(0.65), location: 0.45),
                    .init(color: Theme.Palette.scrim,                location: 0.90)
                ],
                startPoint: .top, endPoint: .bottom
            )

            // Subtle left wipe so the title eyebrow + headline that sit
            // in the info column always read on top of the busiest part
            // of the image.
            LinearGradient(
                colors: [Theme.Palette.scrim.opacity(0.55), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Left: info column

    @ViewBuilder
    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            backLink
            titleBlock
            posterBlock
            metaFacts
            if let description = meta?.description, !description.isEmpty {
                Text(description)
                    .font(Theme.Font.body(14))
                    .foregroundStyle(Theme.Palette.heroTextSecondary)
                    .lineSpacing(3)
            }

            Rule()

            actionButtons

            if let loadError {
                errorBanner(loadError)
            }

            if let cast = meta?.cast, !cast.isEmpty {
                Rule().padding(.vertical, Theme.Spacing.sm)
                castBlock(
                    cast: cast,
                    director: meta?.director ?? [],
                    writer: meta?.writer ?? []
                )
            }
        }
    }

    /// Top-of-column eyebrow + serif title. Moved here from the deleted
    /// banner so the atmospheric backdrop stays unobstructed.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Rectangle().fill(Theme.Palette.accent).frame(width: 28, height: 1)
                Text(destination.addon.manifest.name)
                    .eyebrow(Theme.Palette.accentText, tracking: 2.8)
                Text(verbatim: "· " + (meta?.type ?? destination.type).localized.capitalized)
                    .eyebrow(Theme.Palette.textTertiary, tracking: 1.8)
            }
            Text(meta?.name ?? destination.name)
                .font(Theme.Font.displaySerif(42, weight: .bold))
                .tracking(-1.0)
                .foregroundStyle(Theme.Palette.heroText)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
    }

    /// A horizontal poster + lead facts panel at the top of the info column.
    @ViewBuilder
    private var posterBlock: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            smallPoster
            VStack(alignment: .leading, spacing: 8) {
                Text("Overview")
                    .eyebrow(Theme.Palette.textTertiary, tracking: 2.4)
                if let release = meta?.releaseInfo {
                    labeledFact("Released", release)
                }
                if let runtime = meta?.runtime {
                    labeledFact("Runtime", runtime)
                }
                if !(meta?.genres ?? []).isEmpty {
                    labeledFact("Genres", (meta?.genres ?? []).joined(separator: ", "))
                }
                if let rating = meta?.imdbRating {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Palette.accentText)
                        Text(rating)
                            .font(Theme.Font.mono(12, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text("IMDb")
                            .eyebrow(Theme.Palette.textTertiary, tracking: 1.6)
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var smallPoster: some View {
        ZStack {
            Rectangle().fill(Theme.Palette.surface)
            if let poster = meta?.poster, let url = URL(string: poster) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: posterPlaceholder
                    }
                }
            } else {
                posterPlaceholder
            }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .frame(width: 140)
        .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
        .shadow(Theme.Shadow.card)
    }

    private var posterPlaceholder: some View {
        LinearGradient(
            colors: [Theme.Palette.surface, Theme.Palette.surfaceElevated],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    private func labeledFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.localized).eyebrow(Theme.Palette.textQuaternary, tracking: 1.8)
            Text(value)
                .font(Theme.Font.body(13))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var metaFacts: some View {
        let facts = buildMetaFacts()
        if !facts.isEmpty {
            MetaRow(facts: facts)
        }
    }

    private func buildMetaFacts() -> [MetaRow.Fact] {
        var facts: [MetaRow.Fact] = []
        if let rating = meta?.imdbRating {
            facts.append(.init(label: rating, icon: "star.fill", color: Theme.Palette.accentText))
        }
        if let runtime = meta?.runtime {
            facts.append(.init(label: runtime, icon: "clock"))
        }
        if let release = meta?.releaseInfo {
            facts.append(.init(label: release, icon: "calendar"))
        }
        return facts
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: Theme.Spacing.md) {
            playButton
            saveButton
        }
    }

    @ViewBuilder
    private var playButton: some View {
        let best = visibleEntries.first
        let payload = best.map { playerDestination(for: $0) }
        NavigationLink(value: payload) {
            HStack(spacing: 12) {
                if isLoadingAny && allEntriesEmpty {
                    ProgressView().veltrioControlSize(.small).tint(Theme.Palette.background)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .black))
                }
                Text(playButtonText)
                    .font(Theme.Font.eyebrow(11, weight: .heavy))
                    .tracking(2.6)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Rectangle().fill(Theme.Palette.accent))
            .overlay(Rectangle().stroke(Theme.Palette.accent, lineWidth: 2))
            .foregroundStyle(Theme.Palette.onAccent)
            .shadow(color: Theme.Palette.accentGlow, radius: 18, y: 8)
            .opacity(best == nil ? 0.5 : 1)
        }
        .buttonStyle(.plainRect)
        .disabled(best == nil)
    }

    private var saveButton: some View {
        let inLibrary = watch.isInLibrary(type: destination.type, id: destination.id)
        return FrameButton(
            title: inLibrary ? "In library" : "Save",
            icon: inLibrary ? "bookmark.fill" : "bookmark",
            color: inLibrary ? Theme.Palette.accentText : Theme.Palette.textPrimary,
            fill: nil
        ) {
            watch.toggleLibrary(
                type: destination.type,
                id: destination.id,
                name: meta?.name ?? destination.name,
                poster: meta?.poster,
                background: meta?.background,
                addonId: destination.addon.id,
                addonName: destination.addon.manifest.name
            )
        }
    }

    private var playButtonText: String {
        if allEntriesEmpty && isLoadingAny { return String(localized: "Loading streams") }
        if allEntriesEmpty { return String(localized: "No stream") }
        if isSeries, let ep = currentEpisode, let season = currentSeason {
            return String(localized: "Play S\(season)E\(ep)")
        }
        return String(localized: "Watch now")
    }

    private func castBlock(cast: [String], director: [String], writer: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Credits").eyebrow(Theme.Palette.textTertiary, tracking: 2.4)
            if !director.isEmpty {
                labeledFact("Directed", director.prefix(3).joined(separator: ", "))
            }
            if !writer.isEmpty {
                labeledFact("Written", writer.prefix(3).joined(separator: ", "))
            }
            labeledFact("Cast", cast.prefix(6).joined(separator: ", "))
        }
    }

    // MARK: - Right: episodes (if series) + streams

    @ViewBuilder
    private var streamsColumn: some View {
        if isSeries, let meta {
            // Drill-down: either the episodes grid, or the streams for
            // the chosen episode with a back affordance.
            switch rightPane {
            case .episodes:
                ScrollUnlessCompact {
                    episodesSection(meta.videos)
                        .padding(.bottom, Theme.Spacing.xl)
                }
            case .streams:
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    streamsForEpisodeHeader
                    streamsSection
                }
            }
        } else if canFallbackSeries {
            VStack(alignment: .leading, spacing: Theme.Layout.sectionGap) {
                manualEpisodePicker
                if !allEntriesEmpty || isLoadingAny {
                    streamsSection
                }
            }
        } else {
            streamsSection
        }
    }

    /// Breadcrumb + back link + "now streaming" header shown above the
    /// streams list for a chosen series episode.
    @ViewBuilder
    private var streamsForEpisodeHeader: some View {
        if let meta, let vid = selectedVideoId,
           let episode = meta.videos.first(where: { $0.id == vid }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                // Back link — real framed button, not a hairline.
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        rightPane = .episodes
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 10, weight: .bold))
                        Text("Back to episodes")
                            .font(Theme.Font.eyebrow(10, weight: .bold))
                            .tracking(2.0)
                            .textCase(.uppercase)
                    }
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1.5))
                }
                .buttonStyle(.plainRect)

                // Selected episode banner: horizontal thumbnail + title.
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    episodeThumb(episode)
                        .frame(width: 180)
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                    VStack(alignment: .leading, spacing: 6) {
                        if let s = episode.season, let e = episode.episode {
                            Text("Season \(s) · Episode \(e)")
                                .eyebrow(Theme.Palette.accentText, tracking: 2.4)
                        }
                        Text(episode.title)
                            .font(Theme.Font.title(18))
                            .tracking(-0.2)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(2)
                        if let released = episode.released {
                            Text(released)
                                .font(Theme.Font.mono(10))
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        if let overview = episode.overview, !overview.isEmpty {
                            Text(overview)
                                .font(Theme.Font.body(12))
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(3)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private func episodeThumb(_ video: Video) -> some View {
        ZStack {
            Rectangle().fill(Theme.Palette.surface)
            if let thumb = video.thumbnail, let url = URL(string: thumb) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: EmptyView()
                    }
                }
            }
        }
        .clipped()
        .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
    }

    /// When meta failed AND the content type looks like a series, offer a
    /// bare S/E picker so the user can still pull streams for a specific
    /// episode via the Stremio id convention `imdbid:season:episode`.
    private var canFallbackSeries: Bool {
        meta == nil &&
        (destination.type == "series" || manualForcedSeries) &&
        destination.id.hasPrefix("tt")
    }

    private var manualEpisodePicker: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .lastTextBaseline) {
                HStack(spacing: 10) {
                    Numeral(n: 1)
                    Text("Season & episode")
                        .font(Theme.Font.title(20))
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                Spacer()
                Text("MANUAL · METADATA MISSING")
                    .font(Theme.Font.mono(10))
                    .tracking(1.4)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Rule()
            Text("Metadata couldn't be loaded, but you can still pick an episode. Streams providers only need the IMDb id + season + episode to answer.")
                .font(Theme.Font.body(13))
                .foregroundStyle(Theme.Palette.textSecondary)

            HStack(spacing: Theme.Spacing.lg) {
                stepperBlock(label: "Season",
                             value: Binding(get: { manualSeason },
                                            set: { manualSeason = max(1, $0) }))
                stepperBlock(label: "Episode",
                             value: Binding(get: { manualEpisode },
                                            set: { manualEpisode = max(1, $0) }))
                Spacer()
                CTAButton(
                    title: String(localized: "Fetch S\(manualSeason)E\(manualEpisode)"),
                    icon: "arrow.right",
                    tint: Theme.Palette.accent,
                    textColor: Theme.Palette.background
                ) {
                    Task { await loadManualEpisodeStreams() }
                }
            }
        }
    }

    private func stepperBlock(label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.localized).eyebrow(Theme.Palette.textTertiary, tracking: 2.0)
            HStack(spacing: 0) {
                Button { value.wrappedValue = max(1, value.wrappedValue - 1) } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: 34, height: 34)
                        .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1.5))
                }
                .buttonStyle(.plainRect)
                Text("\(value.wrappedValue)")
                    .font(Theme.Font.mono(18, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(width: 60, height: 34)
                    .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1.5))
                Button { value.wrappedValue += 1 } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: 34, height: 34)
                        .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1.5))
                }
                .buttonStyle(.plainRect)
            }
        }
    }

    private func loadManualEpisodeStreams() async {
        let composite = "\(destination.id):\(manualSeason):\(manualEpisode)"
        await loadStreams(for: composite, type: "series")
    }

    // MARK: - Episodes section (horizontal, thumbnail-rich)
    //
    // Lives in the right column above Streams for a series. Season chips
    // at the top, then a grid of episode cards with real 16:9 thumbnails,
    // S/E numerals, title and a one-line overview. The selected episode
    // gets an amber ring + plays into Streams below.

    private func episodesSection(_ videos: [Video]) -> some View {
        let bySeason = Dictionary(grouping: videos.filter { $0.season != nil }) { $0.season! }
        let seasons = bySeason.keys.sorted()
        let activeSeason = selectedSeason ?? currentSeason ?? seasons.first ?? 1
        let episodesForSeason = (bySeason[activeSeason] ?? [])
            .sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }

        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .lastTextBaseline) {
                HStack(spacing: 10) {
                    Numeral(n: 1)
                    Text("Episodes")
                        .font(Theme.Font.title(20))
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                Spacer()
                Text("\(videos.count) EPISODES · \(seasons.count) SEASON\(seasons.count == 1 ? "" : "S")")
                    .font(Theme.Font.mono(10))
                    .tracking(1.4)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Rule()

            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(seasons, id: \.self) { season in
                            Chip(
                                label: String(localized: "Season \(season)"),
                                count: bySeason[season]?.count ?? 0,
                                isSelected: activeSeason == season
                            ) { selectedSeason = season }
                        }
                    }
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: Theme.Spacing.md)],
                spacing: Theme.Spacing.md
            ) {
                ForEach(episodesForSeason, id: \.id) { video in
                    EpisodeCard(
                        video: video,
                        isSelected: selectedVideoId == video.id
                    ) {
                        selectedVideoId = video.id
                        withAnimation(.easeOut(duration: 0.18)) {
                            rightPane = .streams
                        }
                        Task { await loadStreams(for: video.id) }
                    }
                }
            }
        }
    }

    // MARK: - Streams section

    /// Header and filters stay put; only the list below them scrolls.
    private var streamsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .lastTextBaseline) {
                HStack(spacing: 10) {
                    Numeral(n: isSeries ? 2 : 1)
                    Text("Streams")
                        .font(Theme.Font.title(20))
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                Spacer()
                Text(streamsSubtitle)
                    .font(Theme.Font.mono(10))
                    .tracking(1.4)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Rule()

            if !allEntriesEmpty {
                sourceFilters
                streamFilters
            }

            ScrollUnlessCompact {
                Group {
                    if allEntriesEmpty && isLoadingAny {
                        streamsLoading
                    } else if allEntriesEmpty && loadError == nil {
                        streamsEmpty
                    } else if visibleEntries.isEmpty {
                        Text("Nothing matches these filters.")
                            .font(Theme.Font.body(13))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .padding(.vertical, Theme.Spacing.lg)
                    } else {
                        streamsBody
                    }
                }
                .padding(.bottom, Theme.Spacing.xl)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var streamsBody: some View {
        LazyVStack(spacing: 10) {
            ForEach(visibleEntries) { entry in
                switch entry {
                case .addon(let labeled):
                    NavigationLink(value: playerDestination(for: labeled)) {
                        StreamRow(labeled: labeled)
                    }
                    .buttonStyle(.plainRect)
                    .contextMenu { downloadMenu(for: labeled) }
                case .direct(let d):
                    NavigationLink(value: playerDestination(for: d)) {
                        DirectStreamRow(stream: d)
                    }
                    .buttonStyle(.plainRect)
                }
            }
        }
    }

    private var streamsSubtitle: String {
        let total = streams.count + direct.count
        if isLoadingAny && total == 0 { return String(localized: "FETCHING FROM EVERY SOURCE") }
        var text = String(localized: "\(visibleEntries.count) OF \(total) SHOWN")
        if isLoadingDirect { text += " · " + String(localized: "LOOKING IN YOUR LIBRARIES & IPTV") }
        else if isLoadingStreams { text += " · " + String(localized: "ADDONS STILL ANSWERING") }
        return text
    }

    private var isLoadingAny: Bool { isLoadingStreams || isLoadingDirect }
    private var allEntriesEmpty: Bool { streams.isEmpty && direct.isEmpty }

    /// Source chips: everything, the user's libraries, the IPTV provider,
    /// then each addon that answered.
    private var sourceOptions: [(filter: SourceFilter, label: String, count: Int)] {
        var out: [(SourceFilter, String, Int)] = [(.all, "All sources", streams.count + direct.count)]
        for origin in [DirectStream.Origin.jellyfin, .emby, .plex, .iptv] {
            let count = direct.filter { $0.origin == origin }.count
            if count > 0 { out.append((.direct(origin), origin.label, count)) }
        }
        var addonCounts: [String: Int] = [:]
        var addonOrder: [String] = []
        for s in streams {
            if addonCounts[s.addonName] == nil { addonOrder.append(s.addonName) }
            addonCounts[s.addonName, default: 0] += 1
        }
        for name in addonOrder { out.append((.addon(name), name, addonCounts[name] ?? 0)) }
        return out
    }

    private var sourceFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(sourceOptions, id: \.filter) { option in
                    Chip(label: option.label, count: option.count,
                         isSelected: sourceFilter == option.filter) {
                        sourceFilter = option.filter
                    }
                    .padding(.trailing, 12)
                }
            }
        }
    }

    /// Library and IPTV copies first — they play straight away — then
    /// addon streams, ranked.
    private var visibleEntries: [StreamEntry] {
        let directs = direct
            .filter { d in
                switch sourceFilter {
                case .all:                return true
                case .direct(let origin): return d.origin == origin
                case .addon:              return false
                }
            }
            .filter { d in
                let text = (d.title + " " + (d.detail ?? "")).uppercased()
                switch streamFilter {
                case .all:    return true
                case .cached: return false
                case .uhd:    return StreamResolution.of(text) == "4K"
                case .hd:     return StreamResolution.of(text) == "1080P"
                }
            }
            // Stable: library copies keep their order ahead of IPTV.
            .enumerated()
            .sorted { ($0.element.origin.isLibrary ? 0 : 1, $0.offset) < ($1.element.origin.isLibrary ? 0 : 1, $1.offset) }
            .map(\.element)
        let addons = sortedStreams.filter { s in
            switch sourceFilter {
            case .all:             return true
            case .addon(let name): return s.addonName == name
            default:               return false
            }
        }
        return directs.map(StreamEntry.direct) + addons.map(StreamEntry.addon)
    }

    private var streamFilters: some View {
        HStack(spacing: 0) {
            ForEach(StreamFilter.allCases) { f in
                Chip(label: f.rawValue, isSelected: streamFilter == f) {
                    streamFilter = f
                }
                .padding(.trailing, 12)
            }
            Spacer()
        }
    }

    private var sortedStreams: [LabeledStream] {
        let filtered = streams.filter { s in
            switch streamFilter {
            case .all: return true
            case .cached:
                if case .torrent(let hash, _, _) = s.stream.source {
                    return store.debrid.isCached(hash)
                }
                return false
            case .uhd: return StreamResolution.of(quality(s)) == "4K"
            case .hd:  return StreamResolution.of(quality(s)) == "1080P"
            }
        }
        return filtered.sorted { store.scoreStream($0) > store.scoreStream($1) }
    }

    @ViewBuilder
    private func downloadMenu(for labeled: LabeledStream) -> some View {
        let title = meta?.name ?? destination.name
        let id: String = {
            if let vid = selectedVideoId { return vid }
            return destination.id
        }()
        if store.downloads.items.contains(where: { $0.id == id && $0.status == .completed }) {
            Button {
                store.downloads.remove(id: id)
            } label: {
                Label("Remove local copy", systemImage: "trash")
            }
        } else {
            Button {
                Task {
                    await store.downloadStream(
                        contentId: id, title: title,
                        stream: labeled.stream,
                        season: currentSeason, episode: currentEpisode
                    )
                }
            } label: {
                Label("Download for offline", systemImage: "arrow.down.circle")
            }
        }
    }

    private func quality(_ s: LabeledStream) -> String {
        ((s.stream.name ?? "") + " " + (s.stream.title ?? "")).uppercased()
    }

    private var streamsLoading: some View {
        VStack(spacing: 10) {
            ForEach(0..<5, id: \.self) { _ in
                Rectangle().fill(Theme.Palette.surface)
                    .frame(height: 68)
                    .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
                    .shimmer()
            }
        }
    }

    private var streamsEmpty: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Nothing on the line.")
                .font(Theme.Font.title(18))
                .foregroundStyle(Theme.Palette.textPrimary)
            Rule().frame(maxWidth: 240)
            Text(isSeries && selectedVideoId == nil
                 ? "Pick an episode on the left to query sources."
                 : "Install another source with stream support, or try a different title.")
                .font(Theme.Font.body(13))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 480, alignment: .leading)
        }
        .padding(.vertical, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.danger)
                Text("Metadata unavailable")
                    .eyebrow(Theme.Palette.danger, tracking: 2.2)
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Text("Retry")
                        .font(Theme.Font.eyebrow(10, weight: .bold))
                        .tracking(2.0)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1))
                }
                .buttonStyle(.plainRect)
            }
            Text(message.localized)
                .font(Theme.Font.body(12))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(3)
            Text("Streams are still being fetched from any source that recognises this ID.")
                .font(Theme.Font.caption(11))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(Theme.Palette.danger.opacity(0.4), lineWidth: 1))
        .background(Theme.Palette.danger.opacity(0.08))
    }

    // MARK: - Back link

    /// Back affordance, in the content flow.
    ///
    /// It used to be an `.overlay` pinned to the top-left corner of the
    /// window, floating on top of the atmospheric backdrop. Two problems:
    /// it sat on top of the title once the page scrolled, and it was the
    /// only thing in that corner, so it read as a floating chip rather
    /// than part of the page.
    ///
    /// It is now the first element of the info column — same treatment as
    /// the "Back to episodes" link further down — so it scrolls with the
    /// content and never covers anything.
    private var backLink: some View {
        Button {
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left")
                    .font(.system(size: 10, weight: .bold))
                Text("Back")
                    .eyebrow(Theme.Palette.textPrimary, tracking: 2.2)
            }
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1.5))
        }
        .buttonStyle(.plainRect)
        .escapeShortcut()
    }

    // MARK: - Helpers

    private func playerDestination(for entry: StreamEntry) -> PlayerDestination {
        switch entry {
        case .addon(let labeled): return playerDestination(for: labeled)
        case .direct(let d):      return playerDestination(for: d)
        }
    }

    /// A media-server or IPTV copy, recording progress under this title.
    private func playerDestination(for d: DirectStream) -> PlayerDestination {
        let isSeriesType = (meta?.type ?? destination.type) == "series"
        var dest = d.destination
        dest.watchContext = .init(
            contentType: isSeriesType ? "series" : "movie",
            contentId: destination.id,
            videoId: isSeriesType ? selectedVideoId : nil,
            season: currentSeason ?? (canFallbackSeries ? Int32(manualSeason) : nil),
            episode: currentEpisode ?? (canFallbackSeries ? Int32(manualEpisode) : nil),
            poster: meta?.poster,
            background: meta?.background,
            addonId: destination.addon.id,
            addonName: destination.addon.manifest.name
        )
        return dest
    }

    private func playerDestination(for labeled: LabeledStream) -> PlayerDestination {
        let isSeriesType = (meta?.type ?? destination.type) == "series"
        // Fall back to the manual S/E picker values when meta failed but
        // the user is driving the series flow by hand.
        let effSeason  = currentSeason  ?? (canFallbackSeries ? Int32(manualSeason)  : nil)
        let effEpisode = currentEpisode ?? (canFallbackSeries ? Int32(manualEpisode) : nil)
        let payload = PlayerDestination.StreamPayload(
            stream: labeled.stream,
            addonId: destination.addon.id,
            addonName: labeled.addonName,
            contentId: destination.id,
            contentType: isSeriesType ? "series" : "movie",
            videoId: isSeriesType ? selectedVideoId : nil,
            season: effSeason,
            episode: effEpisode,
            poster: meta?.poster,
            background: meta?.background
        )
        return PlayerDestination(
            kind: .stream(payload),
            title: meta?.name ?? destination.name
        )
    }

    private func load() async {
        loadError = nil
        let result = await store.fetchMetaWithFallback(
            preferred: destination.addon,
            type: destination.type,
            id: destination.id
        )
        switch result {
        case .success(_, let fetched):
            meta = fetched
            if fetched.videos.isEmpty {
                await loadStreams(for: destination.id)
            } else if let first = fetched.videos
                .filter({ $0.season != nil })
                .sorted(by: { ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0) })
                .first {
                selectedSeason = first.season
                selectedVideoId = first.id
                await loadStreams(for: first.id)
            }
        case .failure(let message):
            // Metadata lookup failed across every meta-capable addon. Keep
            // a minimal title in place and still fetch streams — the user
            // can usually watch even without IMDb metadata.
            loadError = message
            await loadStreams(for: destination.id)
        }
    }

    private func loadStreams(for id: String, type: String? = nil) async {
        sourceFilter = .all
        async let lookup: Void = loadDirect(for: id)
        isLoadingStreams = true
        streams = await store.fetchAllStreams(for: type ?? destination.type, id: id)
        isLoadingStreams = false
        Task { await store.debrid.prefetchAvailability(for: streams) }
        await lookup
    }

    /// Media-server and IPTV copies for a Stremio video id: `tt123` for a
    /// film, `tt123:season:episode` for an episode.
    private func loadDirect(for id: String) async {
        directRequest += 1
        let request = directRequest
        direct = []
        let parts = id.split(separator: ":").map(String.init)
        guard let imdbId = parts.first, imdbId.hasPrefix("tt") else { return }
        let season = parts.count == 3 ? Int(parts[1]) : nil
        let episode = parts.count == 3 ? Int(parts[2]) : nil

        isLoadingDirect = true
        let found = await DirectSourceFinder.find(
            store: store, imdbId: imdbId,
            title: meta?.name ?? destination.name,
            year: (meta?.releaseInfo).flatMap { Int($0.prefix(4)) },
            season: season, episode: episode,
            poster: meta?.poster
        )
        guard request == directRequest else { return }
        direct = found
        isLoadingDirect = false
    }
}

// MARK: - Episode card (right column grid)
//
// 16:9 thumbnail at top. Below: S/E tag in mono, title in serif, released
// date, and a short overview. Hover reveals a play-pill in the thumbnail
// bottom-right; the selected one wears an amber frame and label.

private struct EpisodeCard: View {
    let video: Video
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if let s = video.season, let e = video.episode {
                            Text("S\(s) · E\(e)")
                                .font(Theme.Font.mono(10, weight: .semibold))
                                .tracking(1.4)
                                .foregroundStyle(isSelected ? Theme.Palette.accentText : Theme.Palette.textTertiary)
                        }
                        if let released = video.released {
                            Text(released)
                                .font(Theme.Font.mono(10))
                                .foregroundStyle(Theme.Palette.textQuaternary)
                        }
                        Spacer()
                        if isSelected {
                            Text("NOW SELECTED")
                                .font(Theme.Font.mono(9, weight: .semibold))
                                .tracking(1.4)
                                .foregroundStyle(Theme.Palette.accentText)
                        }
                    }
                    Text(video.title)
                        .font(Theme.Font.title(14))
                        .tracking(-0.2)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let overview = video.overview, !overview.isEmpty {
                        Text(overview)
                            .font(Theme.Font.body(12))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
        }
        .buttonStyle(.plainRect)
        .pointerHover { h in
            isHovering = h
            Platform.pointingCursor(h)
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.Palette.surface)
            if let thumb = video.thumbnail, let url = URL(string: thumb) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                            .scaleEffect(isHovering ? 1.03 : 1.0)
                            .animation(.easeOut(duration: 0.25), value: isHovering)
                            .clipped()
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }

            LinearGradient(
                colors: [.clear, .clear, .black.opacity(0.65)],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)

            // Big S/E numeral top-left.
            if let s = video.season, let e = video.episode {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("S\(s)")
                        .font(Theme.Font.mono(10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                    Text("E\(e)")
                        .font(Theme.Font.displaySerif(24, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(10)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
            }

            // Hover play tag.
            if isHovering || isSelected {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9, weight: .black))
                    Text(isSelected ? "Selected" : "Play")
                        .font(Theme.Font.eyebrow(9, weight: .bold))
                        .tracking(1.8)
                        .textCase(.uppercase)
                }
                .foregroundStyle(Theme.Palette.onAccent)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Rectangle().fill(Theme.Palette.accent))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(8)
                .transition(.opacity)
            }
        }
        .aspectRatio(16.0/9.0, contentMode: .fit)
        .overlay(
            Rectangle().stroke(
                isSelected ? Theme.Palette.accent :
                    (isHovering ? Theme.Palette.borderStrong : Theme.Palette.border),
                lineWidth: isSelected ? 2 : 1
            )
        )
        .shadow(isHovering || isSelected ? Theme.Shadow.card : Theme.Shadow.subtle)
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [Theme.Palette.surface, Theme.Palette.surfaceElevated],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .overlay(
            Image(systemName: "play.tv")
                .font(.system(size: 28))
                .foregroundStyle(Theme.Palette.textQuaternary)
        )
    }
}

// MARK: - Stream row (right column list)

private struct StreamRow: View {
    let labeled: LabeledStream
    @Environment(AppStore.self) private var store
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            sourceBadge
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    ForEach(qualityTags, id: \.self) { tag in
                        tagChip(tag, color: Theme.Palette.accentText)
                    }
                    if isCached {
                        tagChip(String(localized: "⚡ CACHED"), color: Theme.Palette.success)
                    }
                }
                Text(primaryLabel)
                    .font(Theme.Font.title(13))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let subtitle = secondaryLabel {
                    Text(subtitle)
                        .font(Theme.Font.caption(11))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Text(labeled.addonName.uppercased())
                    .font(Theme.Font.mono(9, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.Palette.textQuaternary)
            }
            Spacer()
            // Play icon — small, clean, no amber circle pill.
            Image(systemName: "play.fill")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(
                    isHovering ? Theme.Palette.accentText : Theme.Palette.textSecondary
                )
                .frame(width: 32, height: 32)
                .overlay(Rectangle().stroke(
                    isHovering ? Theme.Palette.accent : Theme.Palette.borderStrong,
                    lineWidth: 1.5
                ))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            Rectangle().fill(
                isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surface
            )
        )
        .overlay(
            Rectangle().stroke(
                isHovering ? Theme.Palette.accent : Theme.Palette.border,
                lineWidth: 1
            )
        )
        .pointerHover { h in
            isHovering = h
            Platform.pointingCursor(h)
        }
    }

    private var primaryLabel: String {
        labeled.stream.name ?? labeled.stream.title ?? "Stream"
    }

    private var secondaryLabel: String? {
        guard let title = labeled.stream.title, title != labeled.stream.name else { return nil }
        return title
    }

    private var qualityTags: [String] {
        let haystack = ((labeled.stream.name ?? "") + " " + (labeled.stream.title ?? "")).uppercased()
        let candidates = ["4K", "2160P", "1080P", "720P", "480P", "HDR", "DOLBY", "ATMOS"]
        var found: [String] = []
        for c in candidates where StreamResolution.has(haystack, c) {
            if (c == "2160P" && found.contains("4K")) || (c == "4K" && found.contains("2160P")) { continue }
            found.append(c == "2160P" ? "4K" : c)
            if found.count >= 3 { break }
        }
        return found
    }

    private func tagChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.Font.mono(9, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Rectangle().stroke(color.opacity(0.4), lineWidth: 1))
    }

    private var isCached: Bool {
        if case .torrent(let hash, _, _) = labeled.stream.source {
            return store.debrid.isCached(hash)
        }
        return false
    }

    private var sourceBadge: some View {
        let (icon, color): (String, Color) = {
            switch labeled.stream.source {
            case .url:       return ("globe", Theme.Palette.textSecondary)
            case .torrent:   return ("arrow.down.circle.fill", Theme.Palette.textSecondary)
            case .youTube:   return ("play.rectangle.fill", Theme.Palette.danger)
            case .external:  return ("arrow.up.right.square.fill", Theme.Palette.success)
            }
        }()
        return Image(systemName: icon)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 44, height: 44)
            .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
    }
}

// MARK: - Direct stream row (media servers / IPTV)
//
// Same frame as `StreamRow`. Language tags lead, since on an IPTV
// provider the language is usually what tells two copies apart.

private struct DirectStreamRow: View {
    let stream: DirectStream
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Image(systemName: stream.origin.isLibrary ? "server.rack" : "dot.radiowaves.left.and.right")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 44, height: 44)
                .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 5) {
                if !tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(stream.languages, id: \.self) { tagChip($0, color: Theme.Palette.success) }
                        ForEach(qualityTags, id: \.self) { tagChip($0, color: Theme.Palette.accentText) }
                    }
                }
                Text(stream.title)
                    .font(Theme.Font.title(13))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let detail = stream.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.Font.caption(11))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(1)
                }
                Text(stream.origin.label.uppercased())
                    .font(Theme.Font.mono(9, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Theme.Palette.textQuaternary)
            }
            Spacer()
            Image(systemName: "play.fill")
                .font(.system(size: 13, weight: .black))
                .foregroundStyle(isHovering ? Theme.Palette.accentText : Theme.Palette.textSecondary)
                .frame(width: 32, height: 32)
                .overlay(Rectangle().stroke(
                    isHovering ? Theme.Palette.accent : Theme.Palette.borderStrong,
                    lineWidth: 1.5
                ))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Rectangle().fill(isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surface))
        .overlay(Rectangle().stroke(isHovering ? Theme.Palette.accent : Theme.Palette.border, lineWidth: 1))
        .pointerHover { h in
            isHovering = h
            Platform.pointingCursor(h)
        }
    }

    private var tags: [String] { stream.languages + qualityTags }

    private var qualityTags: [String] {
        let haystack = (stream.title + " " + (stream.detail ?? "")).uppercased()
        var found: [String] = []
        for (needle, tag) in [("2160", "4K"), ("4K", "4K"), ("1080", "1080P"), ("720", "720P"), ("HDR", "HDR")]
        where haystack.contains(needle) && !found.contains(tag) {
            found.append(tag)
        }
        return found
    }

    private func tagChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Theme.Font.mono(9, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Rectangle().stroke(color.opacity(0.4), lineWidth: 1))
    }
}
