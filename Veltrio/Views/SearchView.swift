import SwiftUI

/// Full-screen search for films and series.
///
/// IMDB titles from the installed addons in two rows, Movies and Series,
/// then the IPTV provider's own films and series, each row filling in as
/// its source answers. Live channels are not searched here; the IPTV tab
/// has its own channel search.
struct SearchView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    /// The unified service owns the parallel fan-out across sources.
    private var unified: UnifiedSearchService { store.unifiedSearch }
    private var groups: [UnifiedSearchService.SearchGroup] { unified.groups }
    private var isSearching: Bool { unified.isSearching }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                searchField
                content
            }
            .pageContainer()
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Theme.Palette.background)
        .ignoresSafeArea(edges: .top)
        // The app draws its own Back button; the system navigation bar
        // would show a second one.
        .navigationBarBackButtonHidden(true)
        // Results live on the shared service so they survive opening one
        // and coming back. A fresh search page (empty field) starts clean.
        .onAppear {
            fieldFocused = true
            if query.isEmpty { unified.clear() }
        }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: Theme.Spacing.xl) {
            Button {
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 10, weight: .bold))
                    Text("Back")
                        .eyebrow(Theme.Palette.textTertiary, tracking: 2.2)
                }
            }
            .buttonStyle(.plainRect)
            .keyboardShortcut(.escape, modifiers: [])

            Spacer()
            if isSearching {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(Theme.Palette.accent)
                    Text("Searching").eyebrow(Theme.Palette.textTertiary)
                }
            } else if !groups.isEmpty {
                Text("\(totalHits) result\(totalHits == 1 ? "" : "s")")
                    .eyebrow(Theme.Palette.textTertiary, tracking: 2.2)
            }
        }
        .padding(.top, Theme.pushedTopInset)
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Search")
                .eyebrow(Theme.Palette.accentText, tracking: 2.8)
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                TextField("Movies, series…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.displaySerif(42, weight: .bold))
                    .tracking(-0.8)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .focused($fieldFocused)
                    .onSubmit { runSearch() }
                    .onChange(of: query) { _, _ in runSearchDebounced() }
                if !query.isEmpty {
                    Button {
                        query = ""
                        searchTask?.cancel()
                        unified.clear()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .frame(width: 30, height: 30)
                            .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plainRect)
                }
            }
            Rule()
        }
    }

    // MARK: - content

    private var totalHits: Int {
        groups.reduce(0) { $0 + $1.results.count }
    }

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            emptyHint
        } else if groups.isEmpty && !isSearching {
            noResults
        } else {
            resultsGroups
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Numeral(n: 0)
            Text("What are we watching?")
                .font(Theme.Font.displaySerif(42, weight: .bold))
                .tracking(-0.8)
                .foregroundStyle(Theme.Palette.textPrimary)
            Rule().frame(maxWidth: 420)
            Text("Type a title. Movies and series from IMDB appear as you type, then your IPTV provider's.")
                .font(Theme.Font.body(14))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 520, alignment: .leading)
        }
        .padding(.top, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var noResults: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Nothing found")
                .eyebrow(Theme.Palette.danger, tracking: 2.8)
            Text("“\(query)”")
                .font(Theme.Font.displaySerif(36, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(Theme.Palette.textPrimary)
            Rule().frame(maxWidth: 420)
            Text("Try a shorter query, or connect a source in Settings → Sources.")
                .font(Theme.Font.body(13))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.top, Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resultsGroups: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.sectionGap) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    SectionHeader(
                        group.section.label,
                        number: index + 1,
                        subtitle: "\(group.results.count)"
                    )
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 158, maximum: 190), spacing: Theme.Spacing.md)],
                        spacing: Theme.Spacing.md
                    ) {
                        ForEach(group.results) { result in
                            resultCell(result)
                        }
                    }
                }
            }
        }
    }

    /// Each result navigates to whatever its source can actually open.
    @ViewBuilder
    private func resultCell(_ result: SearchResult) -> some View {
        switch result.source {
        case .stremio:
            if let addon = result.addon, let contentId = result.contentId {
                NavigationLink(value: DetailDestination(
                    addon: addon,
                    type: result.kind,
                    id: contentId,
                    name: result.title
                )) {
                    poster(result)
                }
                .buttonStyle(.plainRect)
            }
        case .iptv:
            if let channel = result.channel, let series = IptvSeriesDestination(channel: channel) {
                NavigationLink(value: series) {
                    poster(result)
                }
                .buttonStyle(.plainRect)
            } else if let channel = result.channel {
                NavigationLink(value: PlayerDestination(
                    kind: .liveChannel(channel: channel),
                    title: channel.name
                )) {
                    poster(result)
                }
                .buttonStyle(.plainRect)
            }
        }
    }

    private func poster(_ result: SearchResult) -> some View {
        PosterCard(
            title: result.title,
            posterURL: result.posterURL?.absoluteString,
            subtitle: result.subtitle,
            rating: nil
        )
    }

    // MARK: - search driver

    private func runSearchDebounced() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            unified.clear()
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            await unified.search(q)
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchTask?.cancel()
        searchTask = Task { @MainActor in await unified.search(q) }
    }
}
