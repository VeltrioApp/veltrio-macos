import SwiftUI
import UniformTypeIdentifiers

struct IPTVView: View {
    @Environment(AppStore.self) private var store

    @State private var showAddSheet = false
    @State private var searchText = ""
    @State private var selectedGroup: String?
    /// Channel grid, or the XMLTV guide when the playlist has one.
    @State private var showGuide = false

    var body: some View {
        ZStack {
            if store.iptvPlaylists.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddPlaylistSheet()
        }
        #if DEBUG
        // Simulator checks: `-veltrioAddPlaylist YES` opens this sheet.
        .onAppear { if UserDefaults.standard.bool(forKey: "veltrioAddPlaylist") { showAddSheet = true } }
        #endif
    }

    // MARK: - main content

    @ViewBuilder
    private var content: some View {
        if store.iptvMode == .live && !(showGuide && guideAvailable) && !store.iptvChannels.isEmpty {
            // TV-app layout: fixed screen, the channel list scrolls.
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                compactHeader
                if currentIsXtream {
                    modeSwitcher
                }
                filterBar
                LiveTVView(channels: filteredChannels, numbers: channelNumbers, groups: groups,
                           selectedGroup: $selectedGroup)
                    .frame(maxHeight: .infinity)
            }
            .pageContainer()
            .padding(.top, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.lg)
        } else {
            scrollingContent
        }
    }

    private var compactHeader: some View {
        HStack(alignment: .lastTextBaseline, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "Broadcast · \(store.iptvChannels.count) channels"))
                    .eyebrow(Theme.Palette.accentText, tracking: 2.8)
                Text(currentPlaylist?.name ?? String(localized: "Live TV"))
                    .font(Theme.Font.displaySerif(30, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
            if store.isLoadingIptv {
                ProgressView().controlSize(.small).tint(Theme.Palette.accent)
            }
            playlistMenu
            TextLinkButton(title: "Add playlist", icon: "plus", color: Theme.Palette.accentText) {
                showAddSheet = true
            }
        }
    }

    /// Channel numbers follow the playlist's order, so they don't change
    /// when a group or a search narrows the list.
    private var channelNumbers: [String: Int] {
        Dictionary(store.iptvChannels.enumerated().map { ($1.id, $0 + 1) }, uniquingKeysWith: { first, _ in first })
    }

    private var scrollingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                if currentIsXtream {
                    modeSwitcher
                }
                filterBar
                if !groups.isEmpty {
                    groupPills
                }
                if showGuide && guideAvailable {
                    EpgGuideView(channels: filteredChannels)
                } else {
                    channelGrid
                }
            }
            .pageContainer()
            .padding(.bottom, Theme.Spacing.xxl)
        }
    }

    private var currentIsXtream: Bool {
        guard let id = store.selectedIptvPlaylistId,
              let ref = store.iptvPlaylists.first(where: { $0.id == id }) else { return false }
        return ref.isXtream
    }

    private var modeSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(AppStore.IptvMode.allCases) { mode in
                Chip(
                    label: mode.rawValue,
                    icon: mode.icon,
                    isSelected: store.iptvMode == mode
                ) {
                    Task { await store.setIptvMode(mode) }
                }
            }
            Spacer()
        }
    }

    // MARK: - header

    private var header: some View {
        PageHeader(
            eyebrow: String(localized: "Broadcast · \(store.iptvChannels.count) channels"),
            title: currentPlaylist?.name ?? "Live TV",
            subtitle: subtitleText
        ) {
            HStack(spacing: Theme.Spacing.lg) {
                if store.isLoadingIptv {
                    ProgressView().controlSize(.small).tint(Theme.Palette.accent)
                }
                if !store.iptvPlaylists.isEmpty {
                    playlistMenu
                }
                TextLinkButton(
                    title: "Add playlist",
                    icon: "plus",
                    color: Theme.Palette.accentText
                ) { showAddSheet = true }
            }
        }
    }

    private var subtitleText: String {
        let total = store.iptvChannels.count
        let countText = total == 0 ? String(localized: "No channels yet") : String(localized: "\(total) channels")
        if store.iptvPlaylists.count > 1 {
            return countText + " · " + String(localized: "\(store.iptvPlaylists.count) playlists")
        }
        return countText
    }

    private var playlistMenu: some View {
        Menu {
            Section("Switch playlist") {
                ForEach(store.iptvPlaylists) { ref in
                    Button {
                        Task { await store.selectIptvPlaylist(id: ref.id) }
                    } label: {
                        if ref.id == store.selectedIptvPlaylistId {
                            Label(ref.name, systemImage: "checkmark")
                        } else {
                            Text(ref.name)
                        }
                    }
                }
            }
            Divider()
            Button {
                Task { await store.refreshSelectedIptvPlaylist() }
            } label: {
                Label("Refresh current", systemImage: "arrow.clockwise")
            }
            .disabled(store.isLoadingIptv)
            if let id = store.selectedIptvPlaylistId {
                Button(role: .destructive) {
                    store.removeIptvPlaylist(id: id)
                } label: {
                    Label("Remove playlist", systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 38, height: 38)
                .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1.5))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playlist options")
    }

    // MARK: - filter bar

    private var filterBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                TextField("Search channels", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.textPrimary)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .buttonStyle(.plainRect)
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 10)
            .background(
                Rectangle().fill(Theme.Palette.surface)
            )
            .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))

            if guideAvailable {
                HStack(spacing: 4) {
                    Chip(label: "Channels", icon: "square.grid.2x2", isSelected: !showGuide) { showGuide = false }
                    Chip(label: "Guide", icon: "calendar", isSelected: showGuide) { showGuide = true }
                }
            } else if store.epg.isLoading && store.iptvMode == .live {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading the TV guide…").eyebrow(Theme.Palette.textTertiary)
                }
            }

            if let error = store.iptvError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error.localized).lineLimit(1)
                }
                .font(Theme.Font.label(11, weight: .semibold))
                .foregroundStyle(Theme.Palette.danger)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 6)
                .background(Rectangle().fill(Theme.Palette.danger.opacity(0.12)))
                .overlay(Rectangle().stroke(Theme.Palette.danger.opacity(0.35), lineWidth: 1))
            }
        }
    }

    // MARK: - group pills

    private var groupPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Chip(
                    label: "All",
                    icon: "square.grid.2x2",
                    count: store.iptvChannels.count,
                    isSelected: selectedGroup == nil
                ) { selectedGroup = nil }

                ForEach(groups, id: \.name) { g in
                    Chip(
                        label: g.name,
                        icon: iconFor(group: g.name),
                        count: g.count,
                        isSelected: selectedGroup == g.name
                    ) { selectedGroup = g.name }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func iconFor(group: String) -> String {
        let lower = group.lowercased()
        if lower.contains("news")   { return "newspaper.fill" }
        if lower.contains("sport")  { return "sportscourt.fill" }
        if lower.contains("movie") || lower.contains("cine") || lower.contains("film") { return "film.fill" }
        if lower.contains("kid") || lower.contains("jeune") || lower.contains("cartoon") { return "star.fill" }
        if lower.contains("music")  { return "music.note" }
        if lower.contains("doc")    { return "books.vertical.fill" }
        if lower.contains("série") || lower.contains("series") || lower.contains("tv show") { return "tv.and.mediabox" }
        if lower.contains("adult")  { return "exclamationmark.triangle.fill" }
        if lower.contains("ungrouped") { return "square.dashed" }
        return "tv.fill"
    }

    // MARK: - channel grid

    private var channelGrid: some View {
        Group {
            if store.isLoadingIptv && store.iptvChannels.isEmpty {
                loadingGrid
            } else if filteredChannels.isEmpty {
                noMatchState
            } else {
                LazyVGrid(columns: columns, spacing: Theme.Spacing.lg) {
                    ForEach(filteredChannels, id: \.id) { channel in
                        // A series has no URL of its own; it opens its
                        // episode list instead of the player.
                        if let series = IptvSeriesDestination(channel: channel) {
                            NavigationLink(value: series) {
                                ChannelTile(channel: channel)
                            }
                            .buttonStyle(.plainRect)
                        } else {
                            NavigationLink(value: PlayerDestination(
                                kind: .liveChannel(channel: channel),
                                title: channel.name
                            )) {
                                ChannelTile(channel: channel)
                            }
                            .buttonStyle(.plainRect)
                        }
                    }
                }
            }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: Theme.Spacing.lg)]
    }

    private var loadingGrid: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.lg) {
            ForEach(0..<10, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill(Theme.Palette.surface)
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                        .shimmer()
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Theme.Palette.surface)
                        .frame(height: 11)
                        .frame(maxWidth: 110)
                        .shimmer()
                }
            }
        }
    }

    private var noMatchState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: searchText.isEmpty ? "tv.slash" : "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(searchText.isEmpty ? "No channels in this group" : "No results")
                .font(Theme.Font.heading(16))
                .foregroundStyle(Theme.Palette.textPrimary)
            if !searchText.isEmpty {
                Text("No channel matches “\(searchText)”.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Palette.surface.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 1)
                )
        )
    }

    // MARK: - empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Numeral(n: 0)
            Text("Dead air.")
                .font(Theme.Font.displaySerif(64, weight: .bold))
                .tracking(-1.4)
                .foregroundStyle(Theme.Palette.textPrimary)
            Rule().frame(maxWidth: 420)
            Text("Add an M3U playlist URL to tune in. Xtream providers and local files are supported — credentials never leave this device.")
                .font(Theme.Font.body(15))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 520, alignment: .leading)
            TextLinkButton(
                title: "Add playlist",
                icon: "arrow.right",
                color: Theme.Palette.accentText
            ) { showAddSheet = true }
                .padding(.top, Theme.Spacing.sm)
        }
        .pageContainer()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - derived

    private var currentPlaylist: IptvPlaylistRef? {
        guard let id = store.selectedIptvPlaylistId else { return nil }
        return store.iptvPlaylists.first { $0.id == id }
    }

    private var groups: [(name: String, count: Int)] {
        let grouped = Dictionary(grouping: store.iptvChannels) { $0.group ?? "Ungrouped" }
        return grouped
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.name < $1.name }
    }

    private var guideAvailable: Bool { store.iptvMode == .live && store.epg.hasGuide }

    private var filteredChannels: [IptvChannel] {
        var list = store.iptvChannels
        if let group = selectedGroup {
            list = list.filter { ($0.group ?? "Ungrouped") == group }
        }
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !needle.isEmpty {
            list = list.filter { $0.name.lowercased().contains(needle) }
        }
        return list
    }
}

// MARK: - channel tile

private struct ChannelTile: View {
    let channel: IptvChannel

    @Environment(AppStore.self) private var store
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            logoSurface
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(Theme.Font.label(13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let now = store.epg.current(for: channel) {
                    // What's on now, with how far into it we are.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(now.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .lineLimit(1)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Theme.Palette.hairline)
                                    Rectangle().fill(Theme.Palette.accent)
                                        .frame(width: geo.size.width * now.progress(at: context.date))
                                }
                            }
                            .frame(height: 2)
                        }
                    }
                } else if let group = channel.group {
                    Text(group)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .onHover { isHovering = $0 }
    }

    private var logoSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(Theme.Palette.surface)

            // Subtle inner gradient so solid-color logos sit nicely.
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.04), .clear],
                        startPoint: .top, endPoint: .bottom
                    )
                )

            if let logoString = channel.logoUrl, let url = URL(string: logoString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .scaledToFit()
                            .padding(16)
                    default:
                        logoPlaceholder
                    }
                }
            } else {
                logoPlaceholder
            }

            // Hover vignette + play affordance.
            if isHovering {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(.black.opacity(0.35))
                ZStack {
                    Circle().fill(.white.opacity(0.92)).frame(width: 46, height: 46)
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 3)
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .black))
                        .foregroundStyle(.black)
                        .offset(x: 1)
                }
                .transition(.scale.combined(with: .opacity))
            }

            // Selection ring on hover.
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Theme.Palette.accentStrong, Theme.Palette.accentWarm],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    lineWidth: isHovering ? 2 : 0
                )

            // Live indicator tag (top-left).
            HStack(spacing: 4) {
                Circle().fill(Theme.Palette.danger).frame(width: 6, height: 6)
                Text("LIVE")
                    .font(Theme.Font.label(9, weight: .black))
                    .tracking(0.6)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(.black.opacity(0.55)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
        }
        .aspectRatio(16.0/9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .shadow(isHovering ? Theme.Shadow.card : Theme.Shadow.subtle)
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isHovering)
    }

    private var logoPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "tv")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(initials(from: channel.name))
                .font(Theme.Font.label(13, weight: .bold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
        }
    }

    private func initials(from name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        let chars = words.prefix(3).compactMap { $0.first }.map { String($0) }
        return chars.joined().uppercased()
    }
}

// MARK: - add sheet

private enum AddPlaylistMode: String, CaseIterable {
    case xtream = "Xtream"
    case m3u    = "M3U URL"
    case file   = "Local file"

    var icon: String {
        switch self {
        case .xtream: return "key.fill"
        case .m3u:    return "link"
        case .file:   return "doc.fill"
        }
    }
}

struct AddPlaylistSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var mode: AddPlaylistMode = .xtream
    @State private var name = ""

    // M3U URL mode
    @State private var url = ""
    @State private var choosingFile = false

    // Xtream mode
    @State private var xtreamHost = ""
    @State private var xtreamUser = ""
    @State private var xtreamPass = ""
    @State private var xtreamOutput: XtreamOutput = .ts
    @State private var revealPassword = false

    // Xtream "Test connection" affordance
    @State private var isTesting = false
    @State private var testResult: TestResult?
    private enum TestResult: Equatable { case ok(String?), error(String) }

    @FocusState private var focusedField: Field?
    private enum Field { case url, host, user, pass }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().background(Theme.Palette.border)
            modePicker
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.top, Theme.Spacing.md)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    field(label: "Name (optional)", placeholder: namePlaceholder, text: $name, plain: false)

                    switch mode {
                    case .xtream: xtreamForm
                    case .m3u:    m3uForm
                    case .file:   fileForm
                    }

                    hint
                        .padding(.top, 2)
                }
                .padding(Theme.Spacing.lg)
            }
            .macSheetFrame(maxHeight: 340)

            Divider().background(Theme.Palette.border)
            footerBar
        }
        .macSheetFrame(width: 560)
        .background(Theme.Palette.background)
        .onAppear { focusInitial() }
    }

    // MARK: header / mode / footer

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Add IPTV playlist")
                    .font(Theme.Font.display(20))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Connect an Xtream provider, paste an M3U URL, or load a local file.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.Palette.surface))
            }
            .buttonStyle(.plainRect)
        }
        .padding(Theme.Spacing.lg)
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(AddPlaylistMode.allCases, id: \.self) { m in
                Button {
                    mode = m
                    focusInitial()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: m.icon)
                            .font(.system(size: 11, weight: .bold))
                        Text(m.rawValue.localized)
                            .font(Theme.Font.label(12, weight: mode == m ? .bold : .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(mode == m ? .white : Theme.Palette.textSecondary)
                    .padding(.horizontal, Platform.isMac ? Theme.Spacing.md : Theme.Spacing.sm)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background(
                        Rectangle().fill(
                            mode == m
                                ? AnyShapeStyle(LinearGradient(
                                    colors: [Theme.Palette.accent, Theme.Palette.accentWarm.opacity(0.9)],
                                    startPoint: .leading, endPoint: .trailing))
                                : AnyShapeStyle(Color.clear)
                        )
                    )
                }
                .buttonStyle(.plainRect)
            }
        }
        .padding(4)
        .background(Rectangle().fill(Theme.Palette.surface))
        .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
    }

    private var footerBar: some View {
        HStack {
            Spacer()
            FrameButton(title: "Cancel", color: Theme.Palette.textPrimary) {
                dismiss()
            }
            FrameButton(title: "Add playlist",
                        icon: "plus",
                        color: Theme.Palette.accent,
                        fill: Theme.Palette.accent,
                        isEnabled: canSubmit) {
                submit()
            }
        }
        .padding(Theme.Spacing.lg)
    }

    // MARK: forms

    private var m3uForm: some View {
        field(
            label: "M3U URL",
            placeholder: "http://example.com/get.php?username=…&type=m3u",
            text: $url,
            focus: .url
        )
    }

    private var fileForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Local path")
                .font(Theme.Font.label(11, weight: .bold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .tracking(0.6)
            HStack(spacing: Theme.Spacing.sm) {
                TextField("/path/to/playlist.m3u", text: $url)
                    .plainEntry()
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                            .fill(Theme.Palette.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                            .stroke(Theme.Palette.border, lineWidth: 1)
                    )
                    .focused($focusedField, equals: .url)

                FrameButton(title: "Choose…", color: Theme.Palette.textPrimary) {
                    pickFile()
                }
                .fileImporter(isPresented: $choosingFile, allowedContentTypes: Self.playlistTypes) { result in
                    if case .success(let picked) = result { url = Self.keep(picked) }
                }
            }
        }
    }

    private var xtreamForm: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            field(
                label: "Server",
                placeholder: "http://your-provider.com:8080",
                text: $xtreamHost,
                focus: .host
            )
            HStack(spacing: Theme.Spacing.md) {
                field(label: "Username", placeholder: "user", text: $xtreamUser, focus: .user)
                xtreamPasswordField
            }
            outputPicker
            HStack(spacing: Theme.Spacing.sm) {
                FrameButton(title: isTesting ? "Testing…" : "Test connection",
                            icon: isTesting ? nil : "checkmark.shield",
                            color: Theme.Palette.textPrimary,
                            isLoading: isTesting,
                            isEnabled: !isTesting && canBuildXtreamURL) {
                    Task { await runTest() }
                }
                if let testResult {
                    testResultLabel(testResult)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func testResultLabel(_ result: TestResult) -> some View {
        switch result {
        case .ok(let detail):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text((detail ?? "Connection OK").localized)
                    .lineLimit(1)
            }
            .font(Theme.Font.label(11, weight: .semibold))
            .foregroundStyle(Theme.Palette.success)
        case .error(let message):
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                Text(message.localized)
                    .lineLimit(1)
            }
            .font(Theme.Font.label(11, weight: .semibold))
            .foregroundStyle(Theme.Palette.danger)
        }
    }

    private var xtreamPasswordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password")
                .font(Theme.Font.label(11, weight: .bold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .tracking(0.6)
            HStack(spacing: 6) {
                Group {
                    if revealPassword {
                        TextField("••••••••", text: $xtreamPass).plainEntry()
                    } else {
                        SecureField("••••••••", text: $xtreamPass).plainEntry()
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.textPrimary)
                .focused($focusedField, equals: .pass)

                Button {
                    revealPassword.toggle()
                } label: {
                    Image(systemName: revealPassword ? "eye.slash.fill" : "eye.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plainRect)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .stroke(Theme.Palette.border, lineWidth: 1)
            )
        }
    }

    private var outputPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Stream format")
                .font(Theme.Font.label(11, weight: .bold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .tracking(0.6)
            HStack(spacing: 6) {
                ForEach(XtreamOutput.allCases, id: \.self) { out in
                    Button {
                        xtreamOutput = out
                    } label: {
                        VStack(spacing: 1) {
                            Text(out.rawValue.uppercased())
                                .font(Theme.Font.label(12, weight: xtreamOutput == out ? .bold : .semibold))
                            Text(out.blurb.localized)
                                .font(.system(size: 10))
                                .foregroundStyle(xtreamOutput == out ? .white.opacity(0.85) : Theme.Palette.textTertiary)
                        }
                        .foregroundStyle(xtreamOutput == out ? .white : Theme.Palette.textSecondary)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).fill(
                                xtreamOutput == out
                                    ? AnyShapeStyle(LinearGradient(
                                        colors: [Theme.Palette.accent, Theme.Palette.accentWarm.opacity(0.9)],
                                        startPoint: .leading, endPoint: .trailing))
                                    : AnyShapeStyle(Theme.Palette.surface)
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .stroke(xtreamOutput == out ? .clear : Theme.Palette.border, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plainRect)
                }
            }
        }
    }

    @ViewBuilder
    private var hint: some View {
        switch mode {
        case .xtream:
            Text("Uses the Xtream Codes JSON API (`player_api.php`) to fetch categories, logos and streams directly — no M3U dump parsing. Credentials stay on this device.")
        case .m3u:
            Text("Any URL that returns an M3U playlist works, including provider-built `/get.php?…&type=m3u` links.")
        case .file:
            Text("Point to a `.m3u` / `.m3u8` file on disk. Useful for testing or offline curation.")
        }
    }

    // MARK: actions

    private var canSubmit: Bool {
        switch mode {
        case .m3u:    return !url.trimmingCharacters(in: .whitespaces).isEmpty
        case .file:   return !url.trimmingCharacters(in: .whitespaces).isEmpty
        case .xtream: return canBuildXtreamURL
        }
    }

    private var canBuildXtreamURL: Bool {
        !normalizedXtreamHost.isEmpty
            && !xtreamUser.trimmingCharacters(in: .whitespaces).isEmpty
            && !xtreamPass.isEmpty
    }

    private func runTest() async {
        isTesting = true
        testResult = nil
        defer { isTesting = false }
        let creds = buildCredentials()
        if let error = await store.verifyXtream(creds) {
            testResult = .error(error)
        } else {
            testResult = .ok(String(localized: "Authenticated"))
        }
    }

    private func buildCredentials() -> XtreamCredentials {
        XtreamCredentials(
            host: normalizedXtreamHost,
            username: xtreamUser.trimmingCharacters(in: .whitespaces),
            password: xtreamPass,
            output: xtreamOutput.rawValue
        )
    }

    private func submit() {
        switch mode {
        case .m3u:
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            Task { await store.addIptvPlaylist(name: name, url: trimmed) }
        case .file:
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let final = trimmed.hasPrefix("file://") ? trimmed : "file://\(trimmed)"
            Task { await store.addIptvPlaylist(name: name, url: final) }
        case .xtream:
            guard canBuildXtreamURL else { return }
            Task { await store.addXtreamPlaylist(name: name, credentials: buildCredentials()) }
        }
        dismiss()
    }

    private func pickFile() { choosingFile = true }

    private static let playlistTypes: [UTType] =
        ["m3u", "m3u8"].compactMap { UTType(filenameExtension: $0) } + [.plainText, .data]

    /// The playlist's path. On a Mac the file stays where it is (read again
    /// on each load); on iOS a picked document is only readable for a
    /// moment, so it's copied into the app first.
    private static func keep(_ picked: URL) -> String {
        #if os(macOS)
        return picked.path
        #else
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Playlists", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(UUID().uuidString + "." + (picked.pathExtension.isEmpty ? "m3u" : picked.pathExtension))
        do {
            try FileManager.default.copyItem(at: picked, to: target)
            return target.path
        } catch {
            return picked.path
        }
        #endif
    }

    private func focusInitial() {
        focusedField = {
            switch mode {
            case .xtream: return .host
            case .m3u, .file: return .url
            }
        }()
    }

    // MARK: Xtream URL building

    private var normalizedXtreamHost: String {
        var host = xtreamHost.trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix("/") { host.removeLast() }
        if host.isEmpty { return "" }
        if !host.contains("://") { host = "http://\(host)" }
        return host
    }

    private var namePlaceholder: String {
        switch mode {
        case .xtream: return "My Xtream provider"
        case .m3u:    return "My provider"
        case .file:   return "Local list"
        }
    }

    // MARK: field helper

    private func field(
        label: String,
        placeholder: String,
        text: Binding<String>,
        focus: Field? = nil,
        plain: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.localized)
                .font(Theme.Font.label(11, weight: .bold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .tracking(0.6)
            TextField(placeholder.localized, text: text)
                .if(plain) { $0.plainEntry() }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.textPrimary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .fill(Theme.Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .stroke(Theme.Palette.border, lineWidth: 1)
                )
                .if(focus != nil) { v in
                    v.focused($focusedField, equals: focus!)
                }
        }
    }
}

private enum XtreamOutput: String, CaseIterable {
    case ts    = "ts"
    case m3u8  = "m3u8"
    case rtmp  = "rtmp"

    var blurb: String {
        switch self {
        case .ts:   return "Most compatible"
        case .m3u8: return "HLS variant"
        case .rtmp: return "Legacy"
        }
    }
}
