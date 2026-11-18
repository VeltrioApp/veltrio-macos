import SwiftUI

/// Hashable payload for the "See all" catalog page.
struct CatalogDestination: Hashable {
    let addon: InstalledAddon
    let catalog: Catalog
}

/// Full-screen grid view of one catalog. Paginates via Stremio's `skip=`
/// extra — scrolling to the bottom loads the next page until the addon
/// stops returning new items.
struct CatalogGridView: View {
    let destination: CatalogDestination

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var items: [MetaPreview] = []
    @State private var isLoading = false
    @State private var isExhausted = false
    @State private var pagesLoaded = 0
    // Optional genre filter driven by the catalog's own extras.
    @State private var selectedGenre: String? = nil

    private let pageSize = 100

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                if !availableGenres.isEmpty { genreBar }
                grid
                if !isExhausted { loadMore }
            }
            .pageContainer()
            .padding(.top, Theme.pushedTopInset)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Theme.Palette.background)
        .ignoresSafeArea(edges: .top)
        // The app draws its own Back button; the system navigation bar
        // would show a second one.
        .navigationBarBackButtonHidden(true)
        .task(id: selectedGenre) { await reset() }
    }

    // MARK: - header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
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
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            PageHeader(
                eyebrow: "\(destination.addon.manifest.name) · \(destination.catalog.type)",
                title: destination.catalog.name,
                subtitle: "\(items.count) item\(items.count == 1 ? "" : "s") loaded" + (isExhausted ? " · all pages fetched" : "")
            )
        }
    }

    // MARK: - genre bar

    private var availableGenres: [String] {
        destination.catalog.extra
            .first(where: { $0.name == "genre" })?
            .options ?? []
    }

    private var genreBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Chip(label: "All", isSelected: selectedGenre == nil) {
                    selectedGenre = nil
                }
                ForEach(availableGenres, id: \.self) { genre in
                    Chip(label: genre, isSelected: selectedGenre == genre) {
                        selectedGenre = genre
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - grid

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 158, maximum: 190), spacing: Theme.Spacing.md)],
            spacing: Theme.Spacing.md
        ) {
            ForEach(items, id: \.id) { meta in
                NavigationLink(value: DetailDestination(
                    addon: destination.addon,
                    type: meta.type,
                    id: meta.id,
                    name: meta.name
                )) {
                    PosterCard(
                        title: meta.name,
                        posterURL: meta.poster,
                        subtitle: meta.releaseInfo,
                        rating: meta.imdbRating
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var loadMore: some View {
        VStack(spacing: Theme.Spacing.sm) {
            if isLoading {
                ProgressView().controlSize(.regular).tint(Theme.Palette.accent)
                Text("Loading more…")
                    .font(Theme.Font.label(11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            } else if !items.isEmpty {
                FrameButton(title: "Load more", color: Theme.Palette.textPrimary) {
                    Task { await loadNextPage() }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.lg)
        .task {
            // Auto-load the next page when this view scrolls into view
            // (infinite scroll on top of the explicit button).
            if !items.isEmpty && !isLoading && !isExhausted {
                await loadNextPage()
            }
        }
    }

    // MARK: - loading

    private var extras: [String] {
        var out: [String] = []
        if let g = selectedGenre { out.append("genre=\(g)") }
        return out
    }

    @MainActor
    private func reset() async {
        items = []
        pagesLoaded = 0
        isExhausted = false
        await loadNextPage()
    }

    @MainActor
    private func loadNextPage() async {
        guard !isLoading, !isExhausted else { return }
        isLoading = true
        defer { isLoading = false }
        let page = await store.fetchCatalogPage(
            addon: destination.addon,
            catalog: destination.catalog,
            skip: pagesLoaded * pageSize,
            extras: extras
        )
        // Dedupe by id so a provider that pages with overlap doesn't
        // duplicate posters.
        let existing = Set(items.map(\.id))
        let fresh = page.filter { !existing.contains($0.id) }
        items.append(contentsOf: fresh)
        pagesLoaded += 1
        if fresh.isEmpty { isExhausted = true }
    }
}

