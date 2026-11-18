import SwiftUI

/// Library tab: everything the user has saved or started. One clean
/// PageHeader with inline stats, a single row of chips for status + type,
/// and a grid of LibraryCards.
struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @Environment(WatchStore.self) private var watch

    @State private var filter: LibraryFilter = .all
    @State private var typeFilter: TypeFilter = .all

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all        = "All"
        case inProgress = "In progress"
        case saved      = "Saved"
        case watched    = "Watched"
        var id: String { rawValue }
    }

    enum TypeFilter: String, CaseIterable, Identifiable {
        case all    = "All types"
        case movies = "Movies"
        case series = "Series"
        var id: String { rawValue }
    }

    var body: some View {
        if watch.libraryItems.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Layout.sectionGap) {
                    PageHeader(
                        eyebrow: "No. \(watch.libraryItems.count) in your library",
                        title: "Collection",
                        subtitle: "\(watch.continueWatching.count) in progress · curated by you"
                    )
                    filters
                    grid
                }
                .pageContainer()
                .padding(.bottom, Theme.Spacing.xxl)
            }
        }
    }

    private var filters: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            HStack(spacing: 6) {
                ForEach(LibraryFilter.allCases) { f in
                    Chip(label: f.rawValue, isSelected: filter == f) { filter = f }
                }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(TypeFilter.allCases) { f in
                    Chip(
                        label: f.rawValue,
                        isSelected: typeFilter == f,
                        filledUnselected: false
                    ) { typeFilter = f }
                }
            }
        }
    }

    private var grid: some View {
        let items = filteredItems
        return Group {
            if items.isEmpty {
                VStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text("Nothing matches these filters")
                        .font(Theme.Font.heading(16))
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.xxl)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 158, maximum: 190), spacing: Theme.Spacing.lg)],
                    spacing: Theme.Spacing.lg
                ) {
                    ForEach(items) { entry in
                        LibraryCard(entry: entry)
                    }
                }
            }
        }
    }

    private var filteredItems: [WatchEntry] {
        watch.libraryItems.filter { e in
            let typeOK: Bool = {
                switch typeFilter {
                case .all:    return true
                case .movies: return e.type == "movie"
                case .series: return e.type == "series"
                }
            }()
            guard typeOK else { return false }
            switch filter {
            case .all:        return true
            case .inProgress: return e.isStarted && !e.watched
            case .saved:      return e.inLibrary
            case .watched:    return e.watched
            }
        }
    }

    /// Same editorial empty state as Home and Live: a numeral, a serif
    /// headline, a rule, then the sentence explaining what to do.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Numeral(n: 0)
            Text("Nothing saved,\nyet.")
                .font(Theme.Font.displaySerif(52, weight: .bold))
                .tracking(-1.2)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(nil)
            Rule().frame(maxWidth: 420)
            Text("Save a title from its detail page and it lands here, alongside everything you've started watching.")
                .font(Theme.Font.body(15))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 480, alignment: .leading)
        }
        .pageContainer()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - LibraryCard

private struct LibraryCard: View {
    let entry: WatchEntry

    @Environment(AppStore.self) private var store
    @Environment(WatchStore.self) private var watch

    var body: some View {
        let addon = resolvedAddon
        Group {
            if let addon {
                NavigationLink(value: DetailDestination(
                    addon: addon,
                    type: entry.type,
                    id: entry.contentId,
                    name: entry.name
                )) {
                    cardBody
                }
                .buttonStyle(.plain)
            } else {
                cardBody
            }
        }
        .contextMenu {
            Button {
                watch.markWatched(type: entry.type, id: entry.contentId, watched: !entry.watched)
            } label: {
                Label(
                    entry.watched ? "Mark as unwatched" : "Mark as watched",
                    systemImage: entry.watched ? "arrow.uturn.backward" : "checkmark"
                )
            }
            Button(role: .destructive) {
                watch.toggleLibrary(
                    type: entry.type, id: entry.contentId, name: entry.name,
                    poster: entry.poster, background: entry.background,
                    addonId: entry.addonId, addonName: entry.addonName
                )
            } label: {
                Label(entry.inLibrary ? "Remove from library" : "Add to library",
                      systemImage: "bookmark")
            }
            if entry.isStarted {
                Button(role: .destructive) {
                    watch.removeFromContinueWatching(type: entry.type, id: entry.contentId)
                } label: {
                    Label("Reset progress", systemImage: "trash")
                }
            }
        }
    }

    private var cardBody: some View {
        PosterCard(
            title: entry.name,
            posterURL: entry.poster,
            subtitle: subtitle,
            rating: nil
        )
        .overlay(alignment: .bottom) {
            if entry.isStarted && !entry.watched && entry.progressFraction > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.16))
                        Rectangle().fill(Theme.Palette.accent)
                            .frame(width: geo.size.width * entry.progressFraction)
                    }
                }
                .frame(height: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .padding(.horizontal, 4)
                .padding(.bottom, 48)
            }
        }
        .overlay(alignment: .topLeading) {
            if entry.watched {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .black))
                    Text("Watched").font(Theme.Font.label(10, weight: .bold))
                }
                .foregroundStyle(Theme.Palette.onSuccess)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Theme.Palette.success.opacity(0.9)))
                .padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if entry.inLibrary {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Theme.Palette.accentOnDark)
                    .padding(7)
                    .background(Circle().fill(.black.opacity(0.55)))
                    .padding(8)
            }
        }
    }

    private var subtitle: String? {
        if entry.type == "series", let last = entry.lastEpisodeId,
           let ep = entry.episodes[last], let s = ep.season, let e = ep.episode {
            return "S\(s) · E\(e)"
        }
        return entry.type.capitalized
    }

    private var resolvedAddon: InstalledAddon? {
        if let saved = entry.addonId, let addon = store.addons.first(where: { $0.id == saved }) {
            return addon
        }
        return store.addons.first {
            $0.manifest.resources.contains("meta") &&
            ($0.manifest.types.contains(entry.type) || $0.manifest.types.isEmpty)
        }
    }
}
