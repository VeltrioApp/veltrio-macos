import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(WatchStore.self) private var watch
    @State private var tmdb = TmdbService.shared
    @State private var tmdbKeyInput = ""
    #if os(tvOS)
    @State private var focusedItem: (addon: InstalledAddon, item: MetaPreview)?
    #endif

    var body: some View {
        Group {
            #if os(tvOS)
            if homeAddons.isEmpty {
                ScrollView {
                    emptyState
                        .padding(.top, Theme.navBarInset + 60)
                        .padding(.bottom, Theme.Spacing.xxl)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if let hero = heroItem {
                        EditorialHero(item: hero.item, addon: hero.addon)
                            .id(hero.item.id)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.25), value: hero.item.id)
                    } else {
                        Color.clear.frame(height: 400)
                    }
                    ScrollView {
                        rows
                            .pageContainer()
                            .padding(.top, Theme.Spacing.md)
                            .padding(.bottom, Theme.Spacing.xxl)
                    }
                }
            }
            #else
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if homeAddons.isEmpty {
                        emptyState
                            .padding(.top, Theme.navBarInset + 60)
                    } else {
                        if let hero = heroItem {
                            EditorialHero(item: hero.item, addon: hero.addon)
                                .id(hero.item.id)
                                .transition(.opacity)
                                .animation(.easeInOut(duration: 0.25), value: hero.item.id)
                        } else {
                            Color.clear.frame(height: Theme.navBarInset + 60)
                        }
                        rows
                            .pageContainer()
                            .padding(.top, Theme.Spacing.xxl)
                    }
                }
                .padding(.bottom, Theme.Spacing.xxl)
            }
            #endif
        }
        .onChange(of: tmdb.revision) { _, _ in
            store.clearCatalogCache()
        }
        .task {
            await store.stremioAccount.syncOnLaunchIfNeeded(into: watch)
        }
    }

    private var homeAddons: [InstalledAddon] { store.homeAddons }

    private var rows: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.sectionGap) {
            if tmdb.isConnected {
                #if os(tvOS)
                HomeDiscoverBar { addon, meta in focusedItem = (addon, meta) }
                #else
                HomeDiscoverBar()
                #endif
            }
            // Continue watching takes slot 01 when present; the first
            // catalog then starts at 02. The numerals are a design element
            // that carries the editorial grammar.
            if !watch.continueWatching.isEmpty {
                continueWatchingRow(number: 1)
            }
            let base = watch.continueWatching.isEmpty ? 1 : 2
            ForEach(Array(catalogIndex.enumerated()), id: \.offset) { offset, pair in
                #if os(tvOS)
                CatalogRow(addon: pair.addon, catalog: pair.catalog, number: base + offset) { addon, meta in
                    focusedItem = (addon, meta)
                }
                .task(id: "\(pair.addon.id)|\(pair.catalog.type)|\(pair.catalog.id)|\(tmdb.revision)") {
                    await store.loadCatalog(addon: pair.addon, catalog: pair.catalog)
                }
                #else
                CatalogRow(addon: pair.addon, catalog: pair.catalog, number: base + offset)
                    .task(id: "\(pair.addon.id)|\(pair.catalog.type)|\(pair.catalog.id)|\(tmdb.revision)") {
                        await store.loadCatalog(addon: pair.addon, catalog: pair.catalog)
                    }
                #endif
            }
        }
    }

    private typealias CatalogPair = (addon: InstalledAddon, catalog: Catalog)
    private var catalogIndex: [CatalogPair] {
        homeAddons.flatMap { addon in
            addon.manifest.catalogs.map { (addon, $0) }
        }
    }

    private func continueWatchingRow(number: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                "Continue Watching",
                number: number,
                subtitle: String(localized: "\(watch.continueWatching.count) in progress")
            )
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    ForEach(watch.continueWatching) { entry in
                        if let addon = resolveAddon(for: entry) {
                            NavigationLink(value: DetailDestination(
                                addon: addon,
                                type: entry.type,
                                id: entry.contentId,
                                name: entry.name
                            )) {
                                ContinueCard(entry: entry).frame(width: Platform.isMac ? 280 : 240)
                            }
                            .buttonStyle(.plainRect)
                            .contextMenu {
                                Button(role: .destructive) {
                                    watch.removeFromContinueWatching(
                                        type: entry.type, id: entry.contentId
                                    )
                                } label: {
                                    Label("Remove from Continue Watching", systemImage: "minus.circle")
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.sm)
            }
        }
    }

    private func resolveAddon(for entry: WatchEntry) -> InstalledAddon? {
        store.metaAddon(for: entry.type, preferredId: entry.addonId)
    }

    private var heroItem: (addon: InstalledAddon, item: MetaPreview)? {
        #if os(tvOS)
        if let focused = focusedItem { return focused }
        #endif
        for addon in homeAddons {
            for catalog in addon.manifest.catalogs {
                let key = CatalogKey(addonId: addon.id, type: catalog.type, id: catalog.id)
                if case .loaded(let metas) = store.catalogs[key],
                   let featured = metas.first(where: { $0.background != nil }) ?? metas.first {
                    return (addon, featured)
                }
            }
        }
        return nil
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Numeral(n: 0)
            Text("A quiet room,\nwith nothing on.")
                .font(Theme.Font.displaySerif(52, weight: .bold))
                .tracking(-1.2)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(nil)
            Rule().frame(maxWidth: 420)
            Text("Connect your free TMDB API key (themoviedb.org/settings/api) to browse movies, series, synopses and search in your language.")
                .font(Theme.Font.body(15))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 480, alignment: .leading)
            HStack(spacing: Theme.Spacing.sm) {
                SecureField("TMDB API key or Read Access Token", text: $tmdbKeyInput)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.mono(13))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Theme.Palette.surface)
                    .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
                    .frame(maxWidth: 360)
                CTAButton(title: tmdb.isBusy ? "Connecting…" : "Connect TMDB", icon: "checkmark") {
                    Task {
                        if await tmdb.connect(rawKey: tmdbKeyInput) { tmdbKeyInput = "" }
                    }
                }
                .disabled(tmdb.isBusy || tmdbKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let err = tmdb.error {
                Text(err)
                    .font(Theme.Font.caption(12))
                    .foregroundStyle(Theme.Palette.danger)
            }
            TextLinkButton(title: "Open sources", icon: "arrow.right") {
                NotificationCenter.default.post(name: .veltrioGoto, object: NavItem.addons)
            }
            .padding(.top, Theme.Spacing.sm)
        }
        .pageContainer()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - TMDB Discover filter bar

private struct HomeDiscoverBar: View {
    var onFocus: ((InstalledAddon, MetaPreview) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Streaming platform hub cards — full-width row on Mac/TV, scrollable on phone
            if Platform.isMac || Platform.isTV {
                HStack(spacing: Platform.isTV ? 18 : 12) {
                    ForEach(TmdbService.discoverProviders) { p in
                        NavigationLink(value: ProviderDestination(provider: p)) {
                            ProviderHubCard(provider: p, fullWidth: true)
                        }
                        .buttonStyle(.plainRect)
                    }
                }
                .padding(.vertical, 4)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(TmdbService.discoverProviders) { p in
                            NavigationLink(value: ProviderDestination(provider: p)) {
                                ProviderHubCard(provider: p, fullWidth: false)
                            }
                            .buttonStyle(.plainRect)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            // Genre hub cards — full-width row on Mac/TV, scrollable on phone
            if Platform.isMac || Platform.isTV {
                HStack(spacing: Platform.isTV ? 16 : 10) {
                    ForEach(TmdbService.discoverGenres) { g in
                        NavigationLink(value: GenreDestination(genre: g)) {
                            GenreHubCard(genre: g, fullWidth: true)
                        }
                        .buttonStyle(.plainRect)
                    }
                }
                .padding(.vertical, 2)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(TmdbService.discoverGenres) { g in
                            NavigationLink(value: GenreDestination(genre: g)) {
                                GenreHubCard(genre: g, fullWidth: false)
                            }
                            .buttonStyle(.plainRect)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - Editorial Hero
//
// Asymmetric. Left column is an editorial text block set on hairlines —
// vertical "NOW SHOWING" eyebrow, massive serif title, metadata row,
// synopsis. Right side is a full-bleed still that bleeds off the right
// edge, with a soft left wipe so text stays legible.

private struct EditorialHero: View {
    let item: MetaPreview
    let addon: InstalledAddon
    @Environment(WatchStore.self) private var watch
    private let prefs = UserPrefs.shared

    @State private var kenBurns: Bool = false
    private let height: CGFloat = Platform.isMac ? 640 : (Platform.isTV ? 400 : 470)

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Full-bleed backdrop, right-anchored.
            backdrop
                .frame(height: height)
                .clipped()

            // Hard left wipe — more editorial than a radial fuzz.
            // The wipe follows the theme so the text on top of it keeps
            // its contrast (dark mode: black wipe, light text; light
            // mode: white wipe, dark text).
            LinearGradient(
                stops: [
                    .init(color: Theme.Palette.scrim,                        location: 0.0),
                    .init(color: Theme.Palette.scrim,                        location: 0.28),
                    .init(color: Theme.Palette.scrim.opacity(0.80),          location: 0.42),
                    .init(color: Theme.Palette.scrim.opacity(0.0),           location: 0.70)
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: height)
            .allowsHitTesting(false)

            // Bottom edge fade so the hero walks into the catalog rows.
            // Fades to the page background, not to black: the hero is
            // the top of the page, so it has to dissolve into whatever
            // the page's canvas is.
            VStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    colors: [.clear, Theme.Palette.background],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 180)
            }
            .frame(height: height)
            .allowsHitTesting(false)

            overlay
                .padding(.horizontal, Theme.Layout.contentInset)
                .padding(.top, Theme.navBarInset + Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xl)
                .frame(maxWidth: 900, maxHeight: height, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !prefs.reduceMotion else { return }
            withAnimation(.easeInOut(duration: 22).repeatForever(autoreverses: true)) {
                kenBurns = true
            }
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        ZStack {
            Theme.Palette.background
            if let bgString = item.background ?? item.poster,
               let url = URL(string: bgString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        // Drawn over a neutral frame: a scaled-to-fill image
                        // would otherwise widen the page past a phone's screen.
                        Color.clear.overlay(alignment: .trailing) {
                            img.resizable()
                                .scaledToFill()
                                .scaleEffect(kenBurns ? 1.05 : 1.0, anchor: .topTrailing)
                        }
                        .clipped()
                    default:
                        Theme.Palette.background
                    }
                }
            }
            LinearGradient(
                colors: [.clear, .clear, Theme.Palette.scrim.opacity(0.55)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private var overlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Vertical eyebrow + source credit.
            HStack(spacing: Theme.Spacing.md) {
                Rectangle().fill(Theme.Palette.accent).frame(width: 36, height: 1)
                Text("Now showing")
                    .eyebrow(Theme.Palette.accentText, tracking: 3.0)
                Text("· via \(addon.manifest.name)")
                    .eyebrow(Theme.Palette.textTertiary, tracking: 2.0)
            }
            .padding(.bottom, Theme.Spacing.lg)

            // Title in serif, tight tracking, large.
            Text(item.name)
                .font(Theme.Font.displaySerif(Platform.isTV ? 54 : 78, weight: .bold))
                .tracking(Platform.isTV ? -1.4 : -2.2)
                .lineSpacing(Platform.isTV ? -4 : -6)
                .foregroundStyle(Theme.Palette.heroText)
                .shadow(color: .black.opacity(0.6), radius: 20, y: 6)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            // Hairline then meta row.
            Rule(color: .white.opacity(0.2)).frame(maxWidth: 280).padding(.top, Platform.isTV ? Theme.Spacing.sm : Theme.Spacing.lg)
            metaFacts.padding(.top, Platform.isTV ? Theme.Spacing.xs : Theme.Spacing.md)

            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(Theme.Font.body(Platform.isTV ? 16 : 15))
                    .foregroundStyle(Theme.Palette.heroTextSecondary)
                    .lineLimit(Platform.isTV ? 2 : 3)
                    .frame(maxWidth: Platform.isTV ? 760 : 580, alignment: .leading)
                    .padding(.top, Platform.isTV ? Theme.Spacing.sm : Theme.Spacing.lg)
            }

            #if !os(tvOS)
            HStack(spacing: Theme.Spacing.md) {
                NavigationLink(value: DetailDestination(
                    addon: addon, type: item.type, id: item.id, name: item.name
                )) {
                    HeroPrimaryLabel(
                        title: isResuming ? "Resume" : "Watch now",
                        icon: "play.fill"
                    )
                }
                .buttonStyle(.plainRect)

                NavigationLink(value: DetailDestination(
                    addon: addon, type: item.type, id: item.id, name: item.name
                )) {
                    HeroSecondaryLabel(title: "Details", icon: "info.circle")
                }
                .buttonStyle(.plainRect)
            }
            .padding(.top, Theme.Spacing.lg)
            #endif
        }
    }

    private var isResuming: Bool {
        watch.entry(type: item.type, id: item.id)?.isStarted ?? false
    }

    private var metaFacts: some View {
        var facts: [MetaRow.Fact] = []
        if let rating = item.imdbRating {
            facts.append(.init(label: rating, icon: "star.fill", color: Theme.Palette.accentText))
        }
        if let release = item.releaseInfo {
            facts.append(.init(label: release, color: Theme.Palette.heroTextSecondary))
        }
        facts.append(.init(label: item.type, color: Theme.Palette.heroTextSecondary))
        if !item.genres.isEmpty {
            facts.append(.init(label: item.genres.prefix(2).joined(separator: " · "),
                               color: Theme.Palette.heroTextSecondary))
        }
        return MetaRow(facts: facts)
    }
}

/// NavigationLink labels — need plain views (not Button). These mirror
/// CTAButton / GhostButton geometry so they read as real buttons.
private struct HeroPrimaryLabel: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 12, weight: .black))
            Text(title.localized)
                .font(Theme.Font.eyebrow(11, weight: .heavy))
                .tracking(2.6)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .background(Rectangle().fill(Theme.Palette.accent))
        .overlay(Rectangle().stroke(Theme.Palette.accent, lineWidth: 2))
        .foregroundStyle(Theme.Palette.onAccent)
        .shadow(color: Theme.Palette.accentGlow, radius: 22, y: 10)
    }
}

private struct HeroSecondaryLabel: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(title.localized)
                .font(Theme.Font.eyebrow(11, weight: .bold))
                .tracking(2.4)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .overlay(Rectangle().stroke(Theme.Palette.heroText, lineWidth: 1.5))
        .foregroundStyle(Theme.Palette.heroText)
    }
}

// MARK: - Catalog row (numbered)

struct CatalogRow: View {
    let addon: InstalledAddon
    let catalog: Catalog
    var number: Int = 1
    var onFocus: ((InstalledAddon, MetaPreview) -> Void)? = nil

    @Environment(AppStore.self) private var store
    #if os(tvOS)
    @FocusState private var focusedId: String?
    #endif

    private var key: CatalogKey {
        CatalogKey(addonId: addon.id, type: catalog.type, id: catalog.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(
                catalog.name,
                number: number,
                subtitle: "\(addon.manifest.name) · \(catalog.type.localized)"
            ) {
                if case .loaded(let metas) = store.catalogs[key], metas.count >= 10 {
                    NavigationLink(value: CatalogDestination(addon: addon, catalog: catalog)) {
                        HStack(spacing: 8) {
                            Text("View all")
                                .eyebrow(Theme.Palette.textSecondary, tracking: 2.2)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    .buttonStyle(.plainRect)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                content
                    .padding(.vertical, Theme.Spacing.sm)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.catalogs[key] {
        case .loading, .none: LoadingRow()
        case .failed(let message):
            Text(message.localized)
                .font(Theme.Font.body(12))
                .foregroundStyle(Theme.Palette.danger)
        case .loaded(let metas):
            if metas.isEmpty {
                Text("No items.")
                    .font(Theme.Font.caption(12))
                    .foregroundStyle(Theme.Palette.textTertiary)
            } else {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    ForEach(metas.prefix(20), id: \.id) { meta in
                        NavigationLink(value: DetailDestination(
                            addon: addon, type: meta.type, id: meta.id, name: meta.name
                        )) {
                            PosterCard(
                                title: meta.name,
                                posterURL: meta.poster,
                                subtitle: meta.releaseInfo,
                                rating: meta.imdbRating
                            )
                            .frame(width: Platform.isMac ? 180 : 124)
                        }
                        .buttonStyle(.plainRect)
                        #if os(tvOS)
                        .focused($focusedId, equals: meta.id)
                        #endif
                    }
                }
                #if os(tvOS)
                .onChange(of: focusedId) { _, newId in
                    if let newId, let hit = metas.first(where: { $0.id == newId }) {
                        onFocus?(addon, hit)
                    }
                }
                #endif
            }
        }
    }
}

struct DetailDestination: Hashable {
    let addon: InstalledAddon
    let type: String
    let id: String
    let name: String
}

// MARK: - Continue card (landscape, editorial)

private struct ContinueCard: View {
    let entry: WatchEntry
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay {
                    ZStack(alignment: .bottomLeading) {
                        Rectangle().fill(Theme.Palette.surface)
                        background
                            .scaleEffect(isHovering ? 1.03 : 1.0)
                            .animation(.easeOut(duration: 0.3), value: isHovering)

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.65)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .allowsHitTesting(false)

                        // Episode marker, bottom-left.
                        if entry.type == "series", let last = entry.lastEpisodeId,
                           let ep = entry.episodes[last],
                           let s = ep.season, let e = ep.episode {
                            Text("S\(s) · E\(e)")
                                .font(Theme.Font.mono(10, weight: .semibold))
                                .tracking(1.2)
                                .foregroundStyle(Theme.Palette.accentOnDark)
                                .padding(10)
                        }
                    }
                }
                .clipped()
                .overlay(
                    Rectangle().stroke(
                        isHovering ? Theme.Palette.accent : Theme.Palette.border,
                        lineWidth: 1
                    )
                )
                .overlay(alignment: .bottom) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Theme.Palette.border)
                            Rectangle().fill(Theme.Palette.accent)
                                .frame(width: geo.size.width * entry.progressFraction)
                        }
                    }
                    .frame(height: 2)
                }
                .shadow(isHovering ? Theme.Shadow.hero : Theme.Shadow.card)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(Theme.Font.title(14))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(resumeLabel)
                    .font(Theme.Font.mono(10))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .pointerHover { isHovering = $0 }
    }

    @ViewBuilder
    private var background: some View {
        if let bgStr = entry.background ?? entry.poster,
           let url = URL(string: bgStr) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var resumeLabel: String {
        let (pos, dur): (Double, Double) = {
            if entry.type == "series", let last = entry.lastEpisodeId,
               let ep = entry.episodes[last] {
                return (ep.position, ep.duration)
            }
            return (entry.position, entry.duration)
        }()
        guard dur > 0 else { return String(localized: "NOT STARTED") }
        let remaining = max(0, dur - pos)
        let mins = Int(remaining / 60)
        return mins <= 1 ? String(localized: "ENDING SOON") : String(localized: "\(mins) MIN LEFT")
    }

    private var placeholder: some View {
        Theme.Palette.backgroundAlt.overlay(
            Image(systemName: "film")
                .font(.system(size: 26))
                .foregroundStyle(Theme.Palette.textQuaternary)
        )
    }
}

// MARK: - Streaming Platform Hub Cards & Page

struct ProviderDestination: Hashable {
    let provider: TmdbService.DiscoverProvider
}

struct GenreDestination: Hashable {
    let genre: TmdbService.DiscoverGenre
}

private struct GenreHubCard: View {
    let genre: TmdbService.DiscoverGenre
    var fullWidth: Bool = false
    @State private var isHovering = false

    private var accentColor: Color {
        let r = Double((genre.accentHex >> 16) & 0xFF) / 255.0
        let g = Double((genre.accentHex >> 8) & 0xFF) / 255.0
        let b = Double(genre.accentHex & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    var body: some View {
        let w: CGFloat = Platform.isTV ? 210 : (Platform.isMac ? 156 : 130)
        let h: CGFloat = Platform.isTV ? 104 : (Platform.isMac ? 76 : 66)

        ZStack {
            LinearGradient(
                colors: [accentColor.opacity(0.42), Theme.Palette.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 6) {
                Image(systemName: genre.icon)
                    .font(.system(size: Platform.isTV ? 26 : (Platform.isMac ? 20 : 17), weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(genre.label)
                    .font(.system(size: Platform.isTV ? 17 : (Platform.isMac ? 13 : 12), weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: fullWidth ? .infinity : w)
        .frame(height: h)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isHovering ? Theme.Palette.accent : Theme.Palette.border, lineWidth: isHovering ? 1.8 : 1)
        )
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .pointerHover { h in
            isHovering = h
            Platform.pointingCursor(h)
        }
    }
}

struct GenreHubView: View {
    let genre: TmdbService.DiscoverGenre
    @Environment(\.dismiss) private var dismiss
    @State private var tmdb = TmdbService.shared

    @State private var popularMovies: [MetaPreview]?
    @State private var popularSeries: [MetaPreview]?
    @State private var topMovies: [MetaPreview]?
    @State private var topSeries: [MetaPreview]?

    private var accentColor: Color {
        let r = Double((genre.accentHex >> 16) & 0xFF) / 255.0
        let g = Double((genre.accentHex >> 8) & 0xFF) / 255.0
        let b = Double(genre.accentHex & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 11, weight: .bold))
                            Text(AppLocalization.isFrench ? "RETOUR" : "BACK")
                                .eyebrow(Theme.Palette.textSecondary, tracking: 2.0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.Palette.surface)
                        .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plainRect)

                    HStack(spacing: Theme.Spacing.lg) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(accentColor.opacity(0.3))
                            .frame(width: 72, height: 72)
                            .overlay {
                                Image(systemName: genre.icon)
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.textPrimary)
                            }
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(accentColor.opacity(0.6), lineWidth: 1.5)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppLocalization.isFrench ? "GENRE" : "GENRE")
                                .eyebrow(Theme.Palette.accentText, tracking: 2.4)
                            Text(genre.label)
                                .font(Theme.Font.display(Platform.isTV ? 48 : 34))
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        Spacer()
                    }
                    .padding(Theme.Spacing.lg)
                    .background(
                        LinearGradient(
                            colors: [accentColor.opacity(0.35), Theme.Palette.surface.opacity(0.5)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.Palette.border, lineWidth: 1)
                    )
                }
                .pageContainer()
                .padding(.top, Theme.pushedTopInset + Theme.Spacing.md)

                hubRow(number: 1, title: AppLocalization.isFrench ? "Films populaires" : "Popular Movies", items: popularMovies)
                hubRow(number: 2, title: AppLocalization.isFrench ? "Séries populaires" : "Popular Series", items: popularSeries)
                hubRow(number: 3, title: AppLocalization.isFrench ? "Films les mieux notés" : "Top Rated Movies", items: topMovies)
                hubRow(number: 4, title: AppLocalization.isFrench ? "Séries les mieux notées" : "Top Rated Series", items: topSeries)
            }
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Theme.Palette.background)
        .navigationBarBackButtonHidden(true)
        .ignoresTopSafeAreaOnMac()
        .task(id: "\(genre.movieId)|\(tmdb.revision)") {
            async let pm = try? tmdb.discover(type: "movie", genreId: genre.movieId, sortBy: "popularity.desc")
            async let ps = try? tmdb.discover(type: "series", genreId: genre.tvId, sortBy: "popularity.desc")
            async let tm = try? tmdb.discover(type: "movie", genreId: genre.movieId, sortBy: "vote_average.desc", minVotes: 150)
            async let ts = try? tmdb.discover(type: "series", genreId: genre.tvId, sortBy: "vote_average.desc", minVotes: 150)
            popularMovies = await pm ?? []
            popularSeries = await ps ?? []
            topMovies = await tm ?? []
            topSeries = await ts ?? []
        }
    }

    @ViewBuilder
    private func hubRow(number: Int, title: String, items: [MetaPreview]?) -> some View {
        let addon = tmdb.virtualAddon()
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title, number: number)
                .pageContainer()
            if let items {
                if items.isEmpty {
                    Text("No items.")
                        .font(Theme.Font.caption(12))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .pageContainer()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: Theme.Spacing.md) {
                            ForEach(items, id: \.id) { meta in
                                NavigationLink(value: DetailDestination(
                                    addon: addon, type: meta.type, id: meta.id, name: meta.name
                                )) {
                                    PosterCard(
                                        title: meta.name,
                                        posterURL: meta.poster,
                                        subtitle: meta.releaseInfo,
                                        rating: meta.imdbRating
                                    )
                                    .frame(width: Platform.isMac ? 180 : (Platform.isTV ? 200 : 124))
                                }
                                .buttonStyle(.plainRect)
                            }
                        }
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.vertical, 4)
                    }
                }
            } else {
                HStack {
                    ProgressView()
                    Spacer()
                }
                .pageContainer()
            }
        }
    }
}

private struct ProviderHubCard: View {
    let provider: TmdbService.DiscoverProvider
    var fullWidth: Bool = false
    @State private var isHovering = false

    private var brandColor: Color {
        let r = Double((provider.brandHex >> 16) & 0xFF) / 255.0
        let g = Double((provider.brandHex >> 8) & 0xFF) / 255.0
        let b = Double(provider.brandHex & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    var body: some View {
        let w: CGFloat = Platform.isTV ? 228 : (Platform.isMac ? 176 : 142)
        let h: CGFloat = Platform.isTV ? 128 : (Platform.isMac ? 104 : 82)
        let logoSize: CGFloat = Platform.isTV ? 66 : (Platform.isMac ? 54 : 44)

        ZStack {
            LinearGradient(
                colors: [brandColor.opacity(0.45), Theme.Palette.surface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.Palette.backgroundAlt)
                    .frame(width: logoSize, height: logoSize)
                    .overlay {
                        if let url = URL(string: provider.logoURL) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let img):
                                    img.resizable().scaledToFill()
                                default:
                                    Color.clear
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                Text(provider.name)
                    .font(.system(size: Platform.isTV ? 18 : (Platform.isMac ? 13 : 12), weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: fullWidth ? .infinity : w)
        .frame(height: h)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isHovering ? Theme.Palette.accent : Theme.Palette.border, lineWidth: isHovering ? 1.8 : 1)
        )
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .pointerHover { h in
            isHovering = h
            Platform.pointingCursor(h)
        }
    }
}

struct ProviderHubView: View {
    let provider: TmdbService.DiscoverProvider
    @Environment(\.dismiss) private var dismiss
    @State private var tmdb = TmdbService.shared

    @State private var popularMovies: [MetaPreview]?
    @State private var popularSeries: [MetaPreview]?
    @State private var topMovies: [MetaPreview]?
    @State private var topSeries: [MetaPreview]?

    private var brandColor: Color {
        let r = Double((provider.brandHex >> 16) & 0xFF) / 255.0
        let g = Double((provider.brandHex >> 8) & 0xFF) / 255.0
        let b = Double(provider.brandHex & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                // Branded header
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.left")
                                .font(.system(size: 11, weight: .bold))
                            Text(AppLocalization.isFrench ? "RETOUR" : "BACK")
                                .eyebrow(Theme.Palette.textSecondary, tracking: 2.0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.Palette.surface)
                        .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plainRect)

                    HStack(spacing: Theme.Spacing.lg) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Theme.Palette.surface)
                            .frame(width: 72, height: 72)
                            .overlay {
                                if let url = URL(string: provider.logoURL) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .success(let img):
                                            img.resizable().scaledToFill()
                                        default:
                                            Color.clear
                                        }
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .shadow(color: brandColor.opacity(0.45), radius: 18, y: 6)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(AppLocalization.isFrench ? "PLATEFORME" : "PLATFORM")
                                .eyebrow(Theme.Palette.accentText, tracking: 2.4)
                            Text(provider.name)
                                .font(Theme.Font.display(Platform.isTV ? 48 : 34))
                                .foregroundStyle(Theme.Palette.textPrimary)
                        }
                        Spacer()
                    }
                    .padding(Theme.Spacing.lg)
                    .background(
                        LinearGradient(
                            colors: [brandColor.opacity(0.35), Theme.Palette.surface.opacity(0.5)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.Palette.border, lineWidth: 1)
                    )
                }
                .pageContainer()
                .padding(.top, Theme.pushedTopInset + Theme.Spacing.md)

                hubRow(number: 1, title: AppLocalization.isFrench ? "Films populaires" : "Popular Movies", items: popularMovies)
                hubRow(number: 2, title: AppLocalization.isFrench ? "Séries populaires" : "Popular Series", items: popularSeries)
                hubRow(number: 3, title: AppLocalization.isFrench ? "Films les mieux notés" : "Top Rated Movies", items: topMovies)
                hubRow(number: 4, title: AppLocalization.isFrench ? "Séries les mieux notées" : "Top Rated Series", items: topSeries)
            }
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Theme.Palette.background)
        .navigationBarBackButtonHidden(true)
        .ignoresTopSafeAreaOnMac()
        .task(id: "\(provider.id)|\(tmdb.revision)") {
            async let pm = try? tmdb.discover(type: "movie", providerId: provider.id, sortBy: "popularity.desc")
            async let ps = try? tmdb.discover(type: "series", providerId: provider.id, sortBy: "popularity.desc")
            async let tm = try? tmdb.discover(type: "movie", providerId: provider.id, sortBy: "vote_average.desc", minVotes: 150)
            async let ts = try? tmdb.discover(type: "series", providerId: provider.id, sortBy: "vote_average.desc", minVotes: 150)
            popularMovies = await pm ?? []
            popularSeries = await ps ?? []
            topMovies = await tm ?? []
            topSeries = await ts ?? []
        }
    }

    @ViewBuilder
    private func hubRow(number: Int, title: String, items: [MetaPreview]?) -> some View {
        let addon = tmdb.virtualAddon()
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            SectionHeader(title, number: number)
                .pageContainer()
            if let items {
                if items.isEmpty {
                    Text("No items.")
                        .font(Theme.Font.caption(12))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .pageContainer()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: Theme.Spacing.md) {
                            ForEach(items, id: \.id) { meta in
                                NavigationLink(value: DetailDestination(
                                    addon: addon, type: meta.type, id: meta.id, name: meta.name
                                )) {
                                    PosterCard(
                                        title: meta.name,
                                        posterURL: meta.poster,
                                        subtitle: meta.releaseInfo,
                                        rating: meta.imdbRating
                                    )
                                    .frame(width: Platform.isMac ? 180 : (Platform.isTV ? 200 : 124))
                                }
                                .buttonStyle(.plainRect)
                            }
                        }
                        .padding(.horizontal, Theme.Layout.contentInset)
                        .padding(.vertical, 4)
                    }
                }
            } else {
                HStack {
                    ProgressView()
                    Spacer()
                }
                .pageContainer()
            }
        }
    }
}
