import SwiftUI

/// Hashable payload for an Xtream series page. Built from the series row
/// the IPTV browser or search returned, so the header can render before
/// `get_series_info` answers.
struct IptvSeriesDestination: Hashable {
    let seriesId: String
    let name: String
    let cover: String?

    /// `nil` when the channel is something playable rather than a series.
    init?(channel: IptvChannel) {
        guard let id = channel.xtreamSeriesId else { return nil }
        seriesId = id
        name = channel.name
        cover = channel.logoUrl
    }
}

/// Seasons and episodes of one Xtream series. Picking an episode pushes
/// the player with the episode's direct URL.
struct IptvSeriesView: View {
    let destination: IptvSeriesDestination

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var series: XtreamSeries?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var selectedSeason: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                content
            }
            .pageContainer()
            .padding(.top, Theme.pushedTopInset)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Theme.Palette.background)
        .ignoresTopSafeAreaOnMac()
        // The app draws its own Back button; the system navigation bar
        // would show a second one.
        .navigationBarBackButtonHidden(true)
        .task { await load() }
    }

    // MARK: - header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Back").eyebrow(Theme.Palette.textPrimary, tracking: 2.2)
                }
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1.5))
            }
            .buttonStyle(.plainRect)
            .escapeShortcut()

            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                cover
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    PageHeader(
                        eyebrow: eyebrow,
                        title: series?.name ?? destination.name
                    )
                    if let plot = series?.plot {
                        Text(plot)
                            .font(Theme.Font.body(13))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(6)
                            .frame(maxWidth: 680, alignment: .leading)
                    }
                }
            }
        }
    }

    private var eyebrow: String {
        var parts = [String(localized: "IPTV · Series")]
        if let genre = series?.genre { parts.append(genre) }
        if let year = series?.releaseDate?.prefix(4) { parts.append(String(year)) }
        if let rating = series?.rating, rating != "0" { parts.append("★ \(rating)") }
        return parts.joined(separator: " · ")
    }

    private var cover: some View {
        ZStack {
            Rectangle().fill(Theme.Palette.surface)
            if let s = series?.cover ?? destination.cover, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    }
                }
            } else {
                Image(systemName: "tv.and.mediabox")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.Palette.textQuaternary)
            }
        }
        .frame(width: 180)
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipped()
        .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
    }

    // MARK: - content

    @ViewBuilder
    private var content: some View {
        if let series, !series.seasons.isEmpty {
            episodesSection(series)
        } else if isLoading {
            loadingGrid
        } else if let loadError {
            message("Couldn't load episodes", detail: loadError, retry: true)
        } else if series != nil {
            message("No episodes", detail: "The provider lists this series without any episodes.", retry: false)
        }
    }

    private func episodesSection(_ series: XtreamSeries) -> some View {
        let active = series.seasons.first(where: { $0.number == selectedSeason })
            ?? series.seasons[0]
        let total = series.seasons.reduce(0) { $0 + $1.episodes.count }

        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Episodes",
                number: 1,
                subtitle: String(localized: "\(total) episodes") + " · " + String(localized: "\(series.seasons.count) seasons")
            )

            if series.seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(series.seasons) { season in
                            Chip(
                                label: String(localized: "Season \(season.number)"),
                                count: season.episodes.count,
                                isSelected: active.number == season.number
                            ) { selectedSeason = season.number }
                        }
                    }
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: Theme.Spacing.md)],
                spacing: Theme.Spacing.lg
            ) {
                ForEach(active.episodes) { episode in
                    NavigationLink(value: PlayerDestination(
                        kind: .liveChannel(channel: episode.channel),
                        title: episode.title
                    )) {
                        XtreamEpisodeCard(episode: episode, fallbackImage: series.cover)
                    }
                    .buttonStyle(.plainRect)
                }
            }
        }
    }

    private var loadingGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: Theme.Spacing.md)],
            spacing: Theme.Spacing.lg
        ) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    Rectangle().fill(Theme.Palette.surface)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .shimmer()
                    Rectangle().fill(Theme.Palette.surface)
                        .frame(width: 160, height: 11).shimmer()
                }
            }
        }
    }

    private func message(_ title: String, detail: String, retry: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title.localized).eyebrow(Theme.Palette.danger, tracking: 2.8)
            Text(detail.localized)
                .font(Theme.Font.body(13))
                .foregroundStyle(Theme.Palette.textSecondary)
            if retry {
                FrameButton(title: "Try again", icon: "arrow.clockwise") {
                    Task { await load() }
                }
            }
        }
    }

    // MARK: - loading

    private func load() async {
        guard !isLoading else { return }
        guard let ref = store.iptvPlaylists.first(where: { $0.id == store.selectedIptvPlaylistId }),
              let credentials = ref.xtream else {
            loadError = "Select the Xtream playlist this series comes from in the IPTV tab."
            return
        }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let result = try await XtreamClient().fetchSeriesInfo(credentials, seriesId: destination.seriesId)
            series = result
            if selectedSeason == nil { selectedSeason = result.seasons.first?.number }
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - Episode card

private struct XtreamEpisodeCard: View {
    let episode: XtreamEpisode
    let fallbackImage: String?

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("S\(episode.season) · E\(episode.number)")
                        .font(Theme.Font.mono(10, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(isHovering ? Theme.Palette.accentText : Theme.Palette.textTertiary)
                    if let duration = episode.duration {
                        Text(duration)
                            .font(Theme.Font.mono(10))
                            .foregroundStyle(Theme.Palette.textQuaternary)
                    }
                }
                Text(episode.title)
                    .font(Theme.Font.title(14))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let plot = episode.plot {
                    Text(plot)
                        .font(Theme.Font.body(12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
        }
        .contentShape(Rectangle())
        .pointerHover { h in
            isHovering = h
            Platform.pointingCursor(h)
        }
    }

    private var thumbnail: some View {
        ZStack {
            Rectangle().fill(Theme.Palette.surface)
            if let s = episode.image ?? fallbackImage, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                            .scaleEffect(isHovering ? 1.03 : 1.0)
                            .animation(.easeOut(duration: 0.25), value: isHovering)
                    }
                }
            }
            Image(systemName: "play.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .opacity(isHovering ? 0.9 : 0)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipped()
        .overlay(Rectangle().stroke(
            isHovering ? Theme.Palette.accent : Theme.Palette.border, lineWidth: 1
        ))
    }
}
