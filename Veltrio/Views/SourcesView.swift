import SwiftUI
import UniformTypeIdentifiers

/// The Sources tab: everything the app can search and play from.
///
/// Five kinds of source, one place:
///
///   1. **Stremio addons** — installed, enabled, reorderable.
///   2. **Addon catalogue** — the community catalogue from
///      stremio-addons.net, browsable and one-tap installable.
///   3. **Media servers** — Jellyfin, Emby, Plex.
///   4. **IPTV** — M3U playlists and Xtream Codes providers.
///   5. **Manual install** — paste any manifest URL.
///
/// The tab used to be called "Sources" but only held Stremio addons, so
/// a Jellyfin server or an IPTV playlist had no home: they were buried
/// in Settings, where connecting one read like a preference rather than
/// like adding a source the user searches from.
struct SourcesView: View {
    @Environment(AppStore.self) private var store

    @State private var inputURL: String = ""
    @State private var showingInstaller: Bool = false
    @State private var showingCatalog: Bool = false
    @State private var showingIPTVManager: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.sectionGap) {
                PageHeader(
                    eyebrow: "\(store.addons.count) addon\(store.addons.count == 1 ? "" : "s") · \(connectedServerCount) server\(connectedServerCount == 1 ? "" : "s") · \(store.iptvPlaylists.count) playlist\(store.iptvPlaylists.count == 1 ? "" : "s")",
                    title: "Sources",
                    subtitle: "Every catalogue, server and stream resolver that feeds this app."
                ) {
                    TextLinkButton(
                        title: showingInstaller ? "Close" : "Add source",
                        icon: showingInstaller ? "xmark" : "plus",
                        color: Theme.Palette.accentText
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                            showingInstaller.toggle()
                        }
                    }
                }

                if showingInstaller || store.addons.isEmpty {
                    installCard
                }

                // ---- 01 · Stremio addons ----
                if !store.addons.isEmpty {
                    installedSection
                }

                // ---- 02 · Addon catalogue ----
                addonCatalogSection

                // ---- 03 · Media servers ----
                mediaServersSection

                // ---- 04 · IPTV ----
                iptvSection

                // ---- 05 · Suggested ----
                suggestedSection
            }
            .pageContainer()
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Theme.Palette.background)
        .sheet(isPresented: $showingCatalog) {
            AddonCatalogSheet()
                .frame(minWidth: 860, idealWidth: 960, minHeight: 600, idealHeight: 700)
        }
        .sheet(isPresented: $showingIPTVManager) {
            IPTVManagerSheet()
                .frame(minWidth: 520, idealWidth: 600, minHeight: 420, idealHeight: 520)
        }
    }

    private var connectedServerCount: Int {
        [store.jellyfin.isConnected, store.emby.isConnected, store.plex.isConnected]
            .filter { $0 }.count
    }

    // MARK: - 01 · Installed Stremio addons

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Installed addons",
                number: 1,
                subtitle: "\(store.addons.count) · reorder with the arrows"
            )
            VStack(spacing: Theme.Spacing.sm) {
                ForEach(Array(store.addons.enumerated()), id: \.element.id) { index, addon in
                    AddonRow(
                        addon: addon,
                        isEnabled: store.isAddonEnabled(id: addon.id),
                        onToggle: { on in store.setAddonEnabled(id: addon.id, enabled: on) },
                        onRemove: { store.removeAddon(id: addon.id) },
                        onMoveUp: index == 0 ? nil : {
                            store.moveAddon(from: IndexSet(integer: index), to: index - 1)
                        },
                        onMoveDown: index == store.addons.count - 1 ? nil : {
                            store.moveAddon(from: IndexSet(integer: index), to: index + 2)
                        }
                    )
                }
            }
        }
    }

    // MARK: - 02 · Addon catalogue

    private var addonCatalogSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Addon catalogue",
                number: 2,
                subtitle: "stremio-addons.net"
            ) {
                TextLinkButton(
                    title: "Browse",
                    icon: "arrow.right",
                    color: Theme.Palette.accentText
                ) {
                    showingCatalog = true
                }
            }

            SurfaceCard {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.Palette.accentText)
                        .frame(width: 42, height: 42)
                        .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Community catalogue")
                            .font(Theme.Font.heading(15))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text("Browse hundreds of addons from stremio-addons.net and install any of them without leaving the app.")
                            .font(Theme.Font.caption(11))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(2)
                    }
                    Spacer()
                    FrameButton(title: "Browse",
                                icon: "arrow.right",
                                color: Theme.Palette.accent,
                                fill: Theme.Palette.accent) {
                        showingCatalog = true
                    }
                }
            }
        }
    }

    // MARK: - 03 · Media servers

    private var mediaServersSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Media servers",
                number: 3,
                subtitle: "Your own libraries"
            )
            JellyfinCard()
            EmbyCard()
            PlexCard()
        }
    }

    // MARK: - 04 · IPTV

    private var iptvSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Live TV",
                number: 4,
                subtitle: "M3U playlists and Xtream providers"
            ) {
                TextLinkButton(
                    title: "Manage",
                    icon: "arrow.right",
                    color: Theme.Palette.accentText
                ) {
                    showingIPTVManager = true
                }
            }

            SurfaceCard {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if store.iptvPlaylists.isEmpty {
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(Theme.Palette.accentText)
                                .frame(width: 42, height: 42)
                                .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No playlist yet")
                                    .font(Theme.Font.heading(15))
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                Text("Add an M3U URL or an Xtream Codes provider. Channels then show up in Live and in search.")
                                    .font(Theme.Font.caption(11))
                                    .foregroundStyle(Theme.Palette.textTertiary)
                                    .lineLimit(2)
                            }
                            Spacer()
                        }
                    } else {
                        ForEach(store.iptvPlaylists) { ref in
                            HStack(spacing: Theme.Spacing.md) {
                                Image(systemName: ref.isXtream ? "server.rack" : "doc.text")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(Theme.Palette.accentText)
                                    .frame(width: 42, height: 42)
                                    .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ref.name)
                                        .font(Theme.Font.label(13, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                    Text(ref.isXtream ? "Xtream Codes" : "M3U playlist")
                                        .font(Theme.Font.caption(11))
                                        .foregroundStyle(Theme.Palette.textTertiary)
                                }
                                Spacer()
                                if ref.id == store.selectedIptvPlaylistId {
                                    Text("ACTIVE")
                                        .font(Theme.Font.eyebrow(10, weight: .bold))
                                        .tracking(1.8)
                                        .foregroundStyle(Theme.Palette.success)
                                }
                            }
                            if ref.id != store.iptvPlaylists.last?.id {
                                Rule().padding(.vertical, Theme.Spacing.sm)
                            }
                        }
                    }

                    FrameButton(title: store.iptvPlaylists.isEmpty ? "Add playlist" : "Manage playlists",
                                icon: "plus",
                                color: Theme.Palette.accent,
                                fill: Theme.Palette.accent) {
                        showingIPTVManager = true
                    }
                }
            }
        }
    }

    // MARK: - Manual install

    private var installCard: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    Text("Install from URL")
                        .font(Theme.Font.heading(15))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    if store.addons.count > 0 {
                        Button {
                            withAnimation { showingInstaller = false }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .frame(width: 22, height: 22)
                                .background(Rectangle().fill(Theme.Palette.surfaceHover))
                        }
                        .buttonStyle(.plain)
                    }
                }
                HStack(spacing: Theme.Spacing.sm) {
                    TextField("https://example.com/manifest.json", text: $inputURL)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.body(13))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, 10)
                        .background(
                            Rectangle().fill(Theme.Palette.backgroundAlt)
                                .overlay(
                                    Rectangle().stroke(Theme.Palette.border, lineWidth: 1)
                                )
                        )
                        .onSubmit { Task { await install(inputURL) } }

                    FrameButton(title: store.isInstallingAddon ? "Installing…" : "Install",
                                icon: "arrow.down",
                                color: Theme.Palette.accent,
                                fill: Theme.Palette.accent,
                                isLoading: store.isInstallingAddon,
                                isEnabled: !store.isInstallingAddon
                                    && !inputURL.trimmingCharacters(in: .whitespaces).isEmpty) {
                        Task { await install(inputURL) }
                    }
                }
                if let err = store.lastError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(err).lineLimit(2)
                    }
                    .font(Theme.Font.caption(12))
                    .foregroundStyle(Theme.Palette.danger)
                }
            }
        }
    }

    // MARK: - Suggested

    private var suggestedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader("Suggested")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.Spacing.md)],
                spacing: Theme.Spacing.md
            ) {
                ForEach(AddonPersistence.suggestedAddons) { suggestion in
                    SuggestedCard(
                        suggestion: suggestion,
                        isInstalled: store.addons.contains { $0.manifest.transportUrl.contains(suggestion.url) },
                        onAdd: { Task { await install(suggestion.url) } }
                    )
                }
            }
        }
    }

    private func install(_ url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        await store.installAddon(url: trimmed)
        if store.lastError == nil { inputURL = "" }
    }
}

// MARK: - Addon catalogue sheet

/// Browses the community addon catalogue and installs from it.
private struct AddonCatalogSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var selectedSource: AddonCatalogService.Source = .officialCollection
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    sourcePicker
                    if store.addonCatalog.isLoading && store.addonCatalog.addons.isEmpty {
                        loading
                    } else if let err = store.addonCatalog.error, store.addonCatalog.addons.isEmpty {
                        errorState(err)
                    } else {
                        catalogGrid
                    }
                }
                .padding(Theme.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Palette.background)
        }
        .background(Theme.Palette.background)
        .task {
            if store.addonCatalog.addons.isEmpty {
                await store.addonCatalog.load(includeCommunity: true)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Addon catalogue")
                        .eyebrow(Theme.Palette.accentText, tracking: 2.8)
                    Text("stremio-addons.net")
                        .font(Theme.Font.displaySerif(28, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                Spacer()
                FrameButton(title: "Close", icon: "xmark",
                            color: Theme.Palette.textPrimary) {
                    dismiss()
                }
            }

            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                TextField("Search addons by name…", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body(14))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .focused($fieldFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .frame(width: 26, height: 26)
                            .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 9)
            .background(Rectangle().fill(Theme.Palette.backgroundAlt))
            .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
        }
        .padding(Theme.Spacing.lg)
    }

    private var sourcePicker: some View {
        HStack(spacing: 6) {
            ForEach([AddonCatalogService.Source.officialCollection,
                     .communitySite], id: \.rawValue) { source in
                Chip(
                    label: source == .officialCollection ? "Official collection" : "Community site",
                    isSelected: selectedSource == source
                ) {
                    selectedSource = source
                    Task { await loadFor(source) }
                }
            }
            Spacer()
            if store.addonCatalog.isLoading {
                ProgressView().controlSize(.small).tint(Theme.Palette.accent)
            }
            Text("\(filtered.count) addons")
                .eyebrow(Theme.Palette.textTertiary)
        }
    }

    private var loading: some View {
        VStack(spacing: Theme.Spacing.md) {
            ProgressView().controlSize(.large)
            Text("Fetching the catalogue…")
                .font(Theme.Font.body(13))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xxl)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Could not load the catalogue")
                .eyebrow(Theme.Palette.danger, tracking: 2.8)
            Text(message)
                .font(Theme.Font.body(13))
                .foregroundStyle(Theme.Palette.textSecondary)
            FrameButton(title: "Try again", icon: "arrow.clockwise",
                        color: Theme.Palette.accent, fill: Theme.Palette.accent) {
                Task { await store.addonCatalog.load() }
            }
        }
        .padding(.vertical, Theme.Spacing.xl)
    }

    private var catalogGrid: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260), spacing: Theme.Spacing.md)],
                spacing: Theme.Spacing.md
            ) {
                ForEach(filtered) { addon in
                    CatalogAddonCard(addon: addon)
                }
            }

            // The community site has ~70 pages of 10. Pull them in as the
            // user asks for more rather than fetching all 700 up front.
            if selectedSource == .communitySite && store.addonCatalog.hasMoreCommunityPages {
                HStack {
                    Spacer()
                    FrameButton(title: store.addonCatalog.isLoading ? "Loading…" : "Load more",
                                icon: "arrow.down",
                                color: Theme.Palette.accentText,
                                isLoading: store.addonCatalog.isLoading,
                                isEnabled: !store.addonCatalog.isLoading) {
                        Task { await store.addonCatalog.loadMoreCommunityPages(count: 3) }
                    }
                    Spacer()
                }
                .padding(.top, Theme.Spacing.sm)
            }
        }
    }

    /// Filter by the selected source and the search text.
    private var filtered: [CatalogAddon] {
        var list = store.addonCatalog.addons(for: selectedSource)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.name.lowercased().contains(q)
                || ($0.description?.lowercased().contains(q) ?? false)
        }
    }

    private func loadFor(_ source: AddonCatalogService.Source) async {
        switch source {
        case .officialCollection:
            await store.addonCatalog.load(includeCommunity: false)
        case .communitySite:
            await store.addonCatalog.load(includeCommunity: true)
        case .none:
            break
        }
    }
}

// MARK: - Catalogue addon card

private struct CatalogAddonCard: View {
    let addon: CatalogAddon
    @Environment(AppStore.self) private var store

    @State private var isResolving = false

    private var isInstalled: Bool {
        store.addons.contains { $0.manifest.id == addon.id }
    }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    Group {
                        if let logo = addon.logo, let url = URL(string: logo) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image): image.resizable().scaledToFit()
                                default:
                                    Image(systemName: "puzzlepiece.extension.fill")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.accentText)
                                }
                            }
                        } else {
                            Image(systemName: "puzzlepiece.extension.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Theme.Palette.accentText)
                        }
                    }
                    .frame(width: 44, height: 44)
                    .padding(4)
                    .background(Rectangle().fill(Theme.Palette.backgroundAlt))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(addon.name)
                            .font(Theme.Font.label(14, weight: .bold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(2)
                        if let version = addon.version {
                            Text("v\(version)")
                                .font(Theme.Font.caption(10))
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }

                if let desc = addon.description, !desc.isEmpty {
                    Text(desc)
                        .font(Theme.Font.caption(11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(3)
                }

                if !addon.capabilities.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(addon.capabilities, id: \.self) { capability in
                            Text(capability)
                                .font(Theme.Font.caption(10))
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Rectangle().fill(Theme.Palette.accentSoft))
                        }
                    }
                }

                FrameButton(title: isInstalled ? "Installed" : (isResolving ? "Installing…" : "Install"),
                            icon: isInstalled ? "checkmark" : "arrow.down",
                            color: isInstalled ? Theme.Palette.success : Theme.Palette.accent,
                            fill: isInstalled ? nil : Theme.Palette.accent,
                            isLoading: isResolving,
                            isEnabled: !isInstalled && !isResolving) {
                    Task { await install() }
                }
            }
        }
    }

    private func install() async {
        isResolving = true
        defer { isResolving = false }
        var url = addon.transportUrl
        if url == nil {
            // Community entries don't carry a manifest URL — resolve it
            // from the addon's detail page, which lists its mirrors.
            url = await store.addonCatalog.resolveTransportUrl(slug: addon.slug)
        }
        guard let url else { return }
        await store.installAddon(url: url)
    }
}

// MARK: - IPTV manager sheet

/// Add, switch and remove IPTV playlists.
private struct IPTVManagerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var showAddPlaylist = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live TV")
                        .eyebrow(Theme.Palette.accentText, tracking: 2.8)
                    Text("Playlists")
                        .font(Theme.Font.displaySerif(28, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                Spacer()
                FrameButton(title: "Close", icon: "xmark",
                            color: Theme.Palette.textPrimary) {
                    dismiss()
                }
            }
            .padding(Theme.Spacing.lg)
            Rule()

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if store.iptvPlaylists.isEmpty {
                        Text("No playlist yet. Add an M3U URL or an Xtream Codes provider below.")
                            .font(Theme.Font.body(13))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .padding(.vertical, Theme.Spacing.md)
                    } else {
                        ForEach(store.iptvPlaylists) { ref in
                            HStack(spacing: Theme.Spacing.md) {
                                Image(systemName: ref.isXtream ? "server.rack" : "doc.text")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Theme.Palette.accentText)
                                    .frame(width: 34, height: 34)
                                    .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ref.name)
                                        .font(Theme.Font.label(13, weight: .semibold))
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                    Text(ref.isXtream ? "Xtream Codes" : "M3U playlist")
                                        .font(Theme.Font.caption(11))
                                        .foregroundStyle(Theme.Palette.textTertiary)
                                }
                                Spacer()
                                if ref.id == store.selectedIptvPlaylistId {
                                    Text("ACTIVE")
                                        .font(Theme.Font.eyebrow(10, weight: .bold))
                                        .tracking(1.8)
                                        .foregroundStyle(Theme.Palette.success)
                                } else {
                                    FrameButton(title: "Use",
                                                color: Theme.Palette.textPrimary) {
                                        Task { await store.selectIptvPlaylist(id: ref.id) }
                                    }
                                }
                                Button {
                                    store.removeIptvPlaylist(id: ref.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(Theme.Palette.danger)
                                        .frame(width: 30, height: 30)
                                        .overlay(Rectangle().stroke(Theme.Palette.danger.opacity(0.4), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, Theme.Spacing.sm)
                            if ref.id != store.iptvPlaylists.last?.id {
                                Rule()
                            }
                        }
                    }

                    Rule().padding(.vertical, Theme.Spacing.sm)

                    FrameButton(title: "Add playlist", icon: "plus", action: { showAddPlaylist = true })
                }
                .padding(Theme.Spacing.lg)
            }
            .background(Theme.Palette.background)
        }
        .background(Theme.Palette.background)
        .sheet(isPresented: $showAddPlaylist) {
            AddPlaylistSheet()
        }
    }
}
