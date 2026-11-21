import SwiftUI

/// Which media server a Collection page or a series page belongs to.
enum MediaServerKind: String, Hashable, CaseIterable {
    case jellyfin, emby, plex

    var label: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .emby:     return "Emby"
        case .plex:     return "Plex"
        }
    }

    @MainActor
    func service(in store: AppStore) -> MediaLibraryBrowsing {
        switch self {
        case .jellyfin: return store.jellyfin
        case .emby:     return store.emby
        case .plex:     return store.plex
        }
    }
}

/// A series from a media server that has no IMDB id, so it can't open on
/// a title page: its episodes are listed straight from the server.
struct MediaServerSeriesDestination: Hashable {
    let server: MediaServerKind
    let item: MediaLibraryItem
}

// MARK: - Library browser (inside the Collection tab)

/// One server's libraries: a chip per library, then its films and series,
/// a page at a time.
struct MediaLibraryBrowser: View {
    let server: MediaServerKind

    @Environment(AppStore.self) private var store

    @State private var sections: [MediaLibrarySection] = []
    @State private var selected: MediaLibrarySection?
    @State private var items: [MediaLibraryItem] = []
    @State private var total = 0
    @State private var isLoading = false
    @State private var didLoadSections = false

    private let pageSize = 60

    private var service: MediaLibraryBrowsing { server.service(in: store) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if !sections.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(sections) { section in
                            Chip(label: section.name, isSelected: selected == section) {
                                selected = section
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            content
        }
        .task(id: server) { await loadSections() }
        .task(id: selected) { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if didLoadSections && sections.isEmpty {
            Text("No film or series library on this server.")
                .font(Theme.Font.body(13))
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.vertical, Theme.Spacing.xl)
        } else if items.isEmpty && isLoading {
            LoadingRow()
        } else if items.isEmpty && selected != nil {
            Text("This library is empty.")
                .font(Theme.Font.body(13))
                .foregroundStyle(Theme.Palette.textSecondary)
                .padding(.vertical, Theme.Spacing.xl)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 158, maximum: 190), spacing: Theme.Spacing.lg)],
                spacing: Theme.Spacing.lg
            ) {
                ForEach(items) { item in
                    cell(item)
                }
            }
            if items.count < total {
                FrameButton(title: "Load more", icon: "arrow.down", isLoading: isLoading) {
                    Task { await loadPage() }
                }
                .padding(.top, Theme.Spacing.md)
            }
        }
    }

    /// Identified titles open on their IMDB page, where this server's copy
    /// sits among the other sources. Films the server couldn't identify
    /// play directly; such series list their episodes.
    @ViewBuilder
    private func cell(_ item: MediaLibraryItem) -> some View {
        let poster = PosterCard(title: item.title, posterURL: item.posterURL?.absoluteString,
                                subtitle: item.year.map(String.init))
        if let imdb = item.imdbId, let addon = store.metaAddon(for: item.type) {
            NavigationLink(value: DetailDestination(addon: addon, type: item.type, id: imdb, name: item.title)) {
                poster
            }
            .buttonStyle(.plainRect)
        } else if item.type == "series" {
            NavigationLink(value: MediaServerSeriesDestination(server: server, item: item)) {
                poster
            }
            .buttonStyle(.plainRect)
        } else if let url = item.streamURL ?? service.libraryStreamURL(for: item.id) {
            NavigationLink(value: PlayerDestination(
                kind: .libraryItem(.init(url: url, serverName: server.label, itemId: item.id,
                                         poster: item.posterURL?.absoluteString, itemType: "Movie")),
                title: item.title
            )) {
                poster
            }
            .buttonStyle(.plainRect)
        } else {
            poster.opacity(0.5)
        }
    }

    private func loadSections() async {
        sections = await service.librarySections()
        didLoadSections = true
        if selected == nil || !sections.contains(where: { $0 == selected }) {
            selected = sections.first
        }
    }

    private func reload() async {
        items = []
        total = 0
        await loadPage()
    }

    private func loadPage() async {
        guard let section = selected, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let page = await service.libraryItems(in: section, start: items.count, limit: pageSize)
        // The section may have changed while the page was loading.
        guard section == selected else { return }
        items += page.items
        total = page.total
    }
}

// MARK: - Series without an IMDB id

struct MediaServerSeriesView: View {
    let destination: MediaServerSeriesDestination

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var episodes: [MediaLibraryEpisode] = []
    @State private var isLoading = true
    @State private var selectedSeason: Int?

    private var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left").font(.system(size: 10, weight: .bold))
                        Text("Back").eyebrow(Theme.Palette.textPrimary, tracking: 2.2)
                    }
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1.5))
                }
                .buttonStyle(.plainRect)
                .escapeShortcut()

                PageHeader(eyebrow: destination.server.label, title: destination.item.title,
                           subtitle: destination.item.year.map(String.init))

                if isLoading {
                    LoadingRow()
                } else if episodes.isEmpty {
                    Text("No episodes")
                        .font(Theme.Font.body(13))
                        .foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    if seasons.count > 1 {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(seasons, id: \.self) { season in
                                    Chip(label: String(localized: "Season \(season)"),
                                         count: episodes.filter { $0.season == season }.count,
                                         isSelected: activeSeason == season) { selectedSeason = season }
                                }
                            }
                        }
                    }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: Theme.Spacing.md)],
                        spacing: Theme.Spacing.lg
                    ) {
                        ForEach(episodes.filter { $0.season == activeSeason }) { episode in
                            episodeCell(episode)
                        }
                    }
                }
            }
            .pageContainer()
            .padding(.top, Theme.pushedTopInset)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Theme.Palette.background)
        .ignoresTopSafeAreaOnMac()
        .navigationBarBackButtonHidden(true)
        .task {
            episodes = await destination.server.service(in: store).libraryEpisodes(of: destination.item)
                .sorted { ($0.season, $0.number) < ($1.season, $1.number) }
            isLoading = false
        }
    }

    private var activeSeason: Int { selectedSeason ?? seasons.first ?? 1 }

    @ViewBuilder
    private func episodeCell(_ episode: MediaLibraryEpisode) -> some View {
        let service = destination.server.service(in: store)
        if let url = episode.streamURL ?? service.libraryStreamURL(for: episode.id) {
            NavigationLink(value: PlayerDestination(
                kind: .libraryItem(.init(url: url, serverName: destination.server.label, itemId: episode.id,
                                         poster: destination.item.posterURL?.absoluteString, itemType: "Episode")),
                title: "\(destination.item.title) · \(episode.title)"
            )) {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        Rectangle().fill(Theme.Palette.surface)
                        if let still = episode.stillURL {
                            AsyncImage(url: still) { phase in
                                if case .success(let img) = phase { img.resizable().scaledToFill() }
                            }
                        }
                    }
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipped()
                    .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
                    Text("S\(episode.season) · E\(episode.number)")
                        .font(Theme.Font.mono(10, weight: .semibold))
                        .tracking(1.4)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(episode.title)
                        .font(Theme.Font.title(14))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plainRect)
        }
    }
}
