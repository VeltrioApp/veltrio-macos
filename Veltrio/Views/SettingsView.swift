import SwiftUI

/// Two-pane settings: left sidebar lists sections, right pane shows the
/// chosen one. Shape mirrors System Settings on macOS — scannable at a
/// glance instead of a long scrolling wall of toggles.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: Section = .playback
    /// The phone layout's open page. Debug builds: `-veltrioSettingsPage playback`.
    @State private var pagePath: [Section] = {
        #if DEBUG
        if let raw = UserDefaults.standard.string(forKey: "veltrioSettingsPage"),
           let section = Section.allCases.first(where: { "\($0)" == raw }) { return [section] }
        #endif
        return []
    }()

    enum Section: String, CaseIterable, Identifiable {
        #if os(iOS)
        case sources   = "Sources"
        #endif
        case playback  = "Playback"
        case languages = "Languages"
        case debrid    = "Debrid"
        case accounts  = "Accounts"
        case appearance = "Appearance"
        case storage   = "Storage"
        case devices   = "Other devices"
        case about     = "About"

        var id: String { rawValue }
        var icon: String {
            switch self {
            #if os(iOS)
            case .sources:    return "puzzlepiece.extension.fill"
            #endif
            case .playback:   return "play.rectangle.fill"
            case .languages:  return "character.bubble.fill"
            case .debrid:     return "bolt.fill"
            case .accounts:   return "person.crop.circle.fill"
            case .appearance: return "paintbrush.fill"
            case .storage:    return "externaldrive.fill"
            case .devices:    return "tv.fill"
            case .about:      return "info.circle.fill"
            }
        }
    }

    var body: some View {
        if Platform.isMac { split } else { stacked }
    }

    /// A phone: the sections as a list, each opening its page.
    private var stacked: some View {
        NavigationStack(path: $pagePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(Section.allCases.enumerated()), id: \.element) { index, section in
                        NavigationLink(value: section) {
                            HStack(spacing: 12) {
                                Image(systemName: section.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.accentText)
                                    .frame(width: 26)
                                Text(String(format: "%02d", index + 1))
                                    .font(Theme.Font.mono(10, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.textQuaternary)
                                Text(section.rawValue.localized)
                                    .font(Theme.Font.label(15, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.textQuaternary)
                            }
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Rule(color: Theme.Palette.hairline)
                    }
                }
                .padding(.horizontal, Theme.Layout.contentInset)
            }
            .background(Theme.Palette.background)
            .hidesNavigationBarOnPhone()
            .navigationDestination(for: Section.self) { section in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        page(section)
                    }
                    .padding(Theme.Layout.contentInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.Palette.background)
                .navigationBarTitleDisplayModeInlineOnPhone()
            }
        }
    }

    private var split: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(Theme.Palette.backgroundAlt)
            Rule(color: Theme.Palette.hairline)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    content
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Palette.background)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(Section.allCases.enumerated()), id: \.element) { index, section in
                SidebarRow(
                    section: section,
                    number: index + 1,
                    isSelected: selection == section
                ) {
                    selection = section
                }
            }
            Spacer()
        }
        .padding(.vertical, Theme.Spacing.lg)
        .padding(.horizontal, Theme.Spacing.lg)
    }

    @ViewBuilder
    private var content: some View { page(selection) }

    @ViewBuilder
    private func page(_ section: Section) -> some View {
        switch section {
        #if os(iOS)
        case .sources:    SourcesView()
        #endif
        case .playback:   PlaybackSettings()
        case .languages:  LanguageSettings()
        case .debrid:     DebridSettings()
        case .accounts:   AccountsSettings()
        case .appearance: AppearanceSettings()
        case .storage:    StorageSettings()
        case .devices:    DevicesSettings()
        case .about:      AboutSettings()
        }
    }
}

// MARK: - Sidebar row
//
// Same grammar as the top navigation: a mono numeral and a tracked
// upper-case label, an amber hairline marking the current section. No
// filled pills — nothing else in the app uses them.

private struct SidebarRow: View {
    let section: SettingsView.Section
    let number: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Rectangle()
                    .fill(isSelected ? Theme.Palette.accent : .clear)
                    .frame(width: 2, height: 16)
                Text(String(format: "%02d", number))
                    .font(Theme.Font.mono(10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(isSelected ? Theme.Palette.accentText : Theme.Palette.textQuaternary)
                Text(section.rawValue.localized)
                    .font(Theme.Font.label(12, weight: isSelected ? .bold : .medium))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(
                        isSelected
                            ? Theme.Palette.textPrimary
                            : (isHovering ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
                    )
                Spacer()
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainRect)
        .pointerHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

// MARK: - Playback

private struct PlaybackSettings: View {
    @State private var prefs = UserPrefs.shared

    var body: some View {
        SettingsPageHeader(
            title: "Playback",
            subtitle: "Defaults applied to every stream."
        )
        SettingsSection(title: "Behaviour") {
            Toggle(isOn: Binding(
                get: { prefs.autoplayNextEpisode },
                set: { prefs.autoplayNextEpisode = $0 }
            )) {
                SettingRowLabel(
                    title: "Auto-advance episodes",
                    hint: "Show the next-episode countdown when a series episode ends."
                )
            }
            .toggleStyle(.switch)
        }
        SettingsSection(title: "Decoder") {
            SettingsPicker(
                title: "Hardware decoder",
                hint: "auto-safe lets mpv pick the best decoder for each codec.",
                selection: Binding(get: { prefs.hwdec }, set: { prefs.hwdec = $0 }),
                options: [
                    ("auto-safe", "Automatic (safe)"),
                    ("auto", "Automatic (aggressive)"),
                    ("videotoolbox", "VideoToolbox"),
                    ("no", "Software only")
                ]
            )
        }
        SettingsSection(title: "Buffering") {
            SettingsStepper(
                title: "Cache size",
                hint: "In-memory buffer for live and torrent streams.",
                value: Binding(get: { prefs.cacheMiB }, set: { prefs.cacheMiB = $0 }),
                unit: "MiB",
                range: 50...1500,
                step: 50
            )
        }
    }
}

// MARK: - Languages

private struct LanguageSettings: View {
    @State private var prefs = UserPrefs.shared

    var body: some View {
        SettingsPageHeader(
            title: "Languages",
            subtitle: "Preferred audio and subtitle tracks."
        )
        SettingsSection(title: "Tracks") {
            SettingsPicker(
                title: "Preferred audio",
                hint: nil,
                selection: Binding(
                    get: { prefs.preferredAudioLang },
                    set: { prefs.preferredAudioLang = $0 }
                ),
                options: UserPrefs.supportedLanguages.map { ($0.code, $0.name) }
            )
            SettingsPicker(
                title: "Preferred subtitles",
                hint: nil,
                selection: Binding(
                    get: { prefs.preferredSubtitleLang },
                    set: { prefs.preferredSubtitleLang = $0 }
                ),
                options: UserPrefs.supportedLanguages.map { ($0.code, $0.name) }
            )
            Text("mpv auto-selects embedded tracks matching your language. Addon subtitles are attached automatically in the chosen language when the player opens.")
                .font(Theme.Font.caption(11))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }
}

// MARK: - Debrid

private struct DebridSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        SettingsPageHeader(
            title: "Debrid",
            subtitle: "Direct playback without seeding. Connect any provider; cached torrents fly."
        )
        RealDebridCard()
        AllDebridCard()
        ApiKeyDebridCard(
            provider: .torbox,
            keyPage: URL(string: "https://torbox.app/settings")!,
            isConnected: store.debrid.isTorBoxConnected,
            account: store.debrid.torBoxUser.map { ($0.email, $0.isPaid) },
            isConnecting: store.debrid.isConnectingTorBox,
            error: store.debrid.torBoxError,
            connect: { await store.debrid.connectTorBox(apiKey: $0) },
            disconnect: { store.debrid.disconnectTorBox() }
        )
        ApiKeyDebridCard(
            provider: .premiumize,
            keyPage: URL(string: "https://www.premiumize.me/account")!,
            isConnected: store.debrid.isPremiumizeConnected,
            account: store.debrid.premiumizeAccount.map { (nil, $0.isPremium) },
            isConnecting: store.debrid.isConnectingPremiumize,
            error: store.debrid.premiumizeError,
            connect: { await store.debrid.connectPremiumize(apiKey: $0) },
            disconnect: { store.debrid.disconnectPremiumize() }
        )
    }

}

// MARK: - API-key providers (TorBox, Premiumize)

/// Providers that only offer an API key: a link to the page that shows
/// it, a field to paste it in, and the same row chrome as the others.
private struct ApiKeyDebridCard: View {
    let provider: DebridProvider
    let keyPage: URL
    let isConnected: Bool
    /// (email, premium) once connected.
    let account: (String?, Bool)?
    let isConnecting: Bool
    let error: String?
    let connect: (String) async -> Void
    let disconnect: () -> Void

    @State private var key = ""

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                DebridRow(
                    brandColor: Color(hex: provider.brandColorHex),
                    title: provider.displayName,
                    status: {
                        DebridStatusLabel(email: account?.0, isPremium: account?.1 ?? false,
                                          isConnected: isConnected)
                    },
                    action: {
                        if isConnected {
                            FrameButton(title: "Disconnect", icon: "xmark", color: Theme.Palette.danger) {
                                disconnect()
                            }
                        }
                    }
                )
                if !isConnected {
                    Text(provider.shortTagline.localized)
                        .font(Theme.Font.caption(11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                    HStack(spacing: Theme.Spacing.sm) {
                        SecureField(String(localized: "API key"), text: $key)
                            .textFieldStyle(.plain)
                            .font(Theme.Font.mono(12))
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1))
                            .onSubmit { Task { await connect(key) } }
                        FrameButton(title: "Connect", icon: "arrow.right", color: Theme.Palette.accent,
                                    fill: Theme.Palette.accent, isLoading: isConnecting,
                                    isEnabled: !isConnecting && !key.isEmpty) {
                            Task { await connect(key) }
                        }
                    }
                    Link(destination: keyPage) {
                        Text(String(localized: "Find your API key on \(provider.displayName)"))
                            .font(Theme.Font.caption(11))
                            .foregroundStyle(Theme.Palette.accentText)
                    }
                }
                if let error {
                    DebridErrorLabel(message: error)
                }
            }
        }
    }
}

// MARK: - Shared Debrid row chrome

/// The header row every provider uses: brand badge, name, status line
/// and the action slot.
///
/// This used to be drawn three separate times. Real-Debrid and AllDebrid
/// each had their own badge (square vs rounded, and AllDebrid's was
/// 42pt against 38pt for the "coming" rows) and their own action button
/// (`FrameButton` for one, `PrimaryButtonStyle` for the other), so the
/// list looked like three unrelated products stacked on each other.
private struct DebridRow<Status: View, Action: View>: View {
    let brandColor: Color
    let title: String
    var isDimmed: Bool = false
    @ViewBuilder let status: () -> Status
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(isDimmed ? Theme.Palette.textSecondary : .white)
                .frame(width: 42, height: 42)
                .background(
                    Rectangle().fill(brandColor.opacity(isDimmed ? 0.35 : 1))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title.localized)
                    .font(Theme.Font.heading(15))
                    .foregroundStyle(isDimmed ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                status()
            }
            Spacer()
            action()
        }
    }
}

/// Status line under the provider name. Shared by every provider so the
/// wording and the colour of "Connected" can never drift apart.
private struct DebridStatusLabel: View {
    let email: String?
    let isPremium: Bool
    let isConnected: Bool

    var body: some View {
        if let email {
            HStack(spacing: 4) {
                Text(email).foregroundStyle(Theme.Palette.textSecondary)
                if isPremium {
                    Text("· Premium")
                        .foregroundStyle(Theme.Palette.success)
                        .fontWeight(.semibold)
                }
            }
            .font(Theme.Font.body(12))
        } else if isConnected {
            Text("Connected")
                .font(Theme.Font.body(12))
                .foregroundStyle(Theme.Palette.success)
        } else {
            Text("Not connected")
                .font(Theme.Font.body(12))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }
}

/// Inline error, shown under the provider it belongs to. Errors are
/// stored per provider now, so a failed Real-Debrid attempt can no
/// longer surface under the AllDebrid card.
private struct DebridErrorLabel: View {
    let message: String
    var body: some View {
        Text(message.localized)
            .font(Theme.Font.caption(12))
            .foregroundStyle(Theme.Palette.danger)
    }
}

// MARK: - Accounts (Trakt)

private struct AccountsSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        SettingsPageHeader(
            title: "Accounts",
            subtitle: "Sync progress and bridge your personal library."
        )
        StremioAccountCard()
        TmdbSettingsCard()
        TraktCard()
        SimklCard()
    }

    private func bridgeCard(name: String, blurb: String, tagline: String, icon: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 42, height: 42)
                .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(Theme.Font.label(13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(blurb.localized).font(Theme.Font.caption(11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Text(tagline)
                .font(Theme.Font.eyebrow(10, weight: .bold))
                .tracking(1.8)
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Rectangle().fill(Theme.Palette.surface.opacity(0.5))
                .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
        )
    }
}

private struct TraktCard: View {
    @Environment(AppStore.self) private var store
    @Environment(WatchStore.self) private var watch

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "chart.bar.doc.horizontal.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Rectangle().fill(Color(hex: 0xED1C24)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Trakt").font(Theme.Font.heading(15))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        statusLabel
                    }
                    Spacer()
                    actionButton
                }
                if let code = store.trakt.pendingDevice {
                    TraktActivationView(code: code, onCancel: {
                        store.trakt.cancelDeviceAuth()
                    })
                }
                if let err = store.trakt.connectionError {
                    Text(err.localized)
                        .font(Theme.Font.caption(12))
                        .foregroundStyle(Theme.Palette.danger)
                }
                Text("Veltrio scrobbles start / pause / stop events to Trakt as you watch, and can import your watchlist and watched history into Collection.")
                    .font(Theme.Font.caption(11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                if store.trakt.isConnected {
                    ImportRow(isWorking: store.trakt.isImporting, result: store.trakt.lastImport,
                              title: "Import watchlist & history") {
                        await store.trakt.importLibrary(into: watch)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let u = store.trakt.user {
            Text("\(u.name ?? u.username)" + (u.isVip ? "  ·  VIP" : ""))
                .font(Theme.Font.body(12))
                .foregroundStyle(Theme.Palette.success)
        } else if store.trakt.isConnected {
            Text("Connected")
                .font(Theme.Font.body(12))
                .foregroundStyle(Theme.Palette.success)
        } else {
            Text("Not connected")
                .font(Theme.Font.body(12))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if store.trakt.isConnected {
            FrameButton(title: "Disconnect",
                        icon: "arrow.right",
                        color: Theme.Palette.danger) { store.trakt.disconnect() }
        } else if store.trakt.pendingDevice != nil {
            FrameButton(title: "Cancel", icon: "xmark",
                        color: Theme.Palette.textSecondary) { store.trakt.cancelDeviceAuth() }
        } else {
            FrameButton(title: "Connect",
                        icon: "arrow.right",
                        color: Theme.Palette.accent,
                        fill: Theme.Palette.accent,
                        isLoading: store.trakt.isConnecting,
                        isEnabled: !store.trakt.isConnecting) {
                Task { await store.trakt.startDeviceAuth() }
            }
        }
    }
}

/// "Import …" button with its spinner and the last result line.
private struct ImportRow: View {
    let isWorking: Bool
    let result: String?
    let title: String
    let action: () async -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            FrameButton(title: title, icon: "arrow.down.circle", isLoading: isWorking, isEnabled: !isWorking) {
                Task { await action() }
            }
            if let result {
                Text(result)
                    .font(Theme.Font.caption(11))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }
}

// MARK: - TMDB metadata localization

private struct TmdbSettingsCard: View {
    @State private var tmdb = TmdbService.shared
    @State private var apiKey = ""

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    Rectangle().fill(Color(hex: 0x01B4E4)).frame(width: 4, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TMDB")
                            .font(Theme.Font.heading(16))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text(tmdb.isConnected ? "CONNECTED" : "OPTIONAL · LOCALIZED METADATA")
                            .font(Theme.Font.mono(10, weight: .semibold))
                            .foregroundStyle(tmdb.isConnected ? Theme.Palette.success : Theme.Palette.textTertiary)
                    }
                    Spacer()
                    if tmdb.isConnected {
                        FrameButton(title: "Disconnect", icon: "xmark", color: Theme.Palette.danger) {
                            tmdb.disconnect()
                        }
                    }
                }

                Text("Translates movie and series titles and synopses into your chosen language using a free TMDB API key (themoviedb.org/settings/api). Transferred automatically when pairing a TV.")
                    .font(Theme.Font.caption(12))
                    .foregroundStyle(Theme.Palette.textSecondary)

                if tmdb.isConnected {
                    HStack(spacing: 12) {
                        Text("Metadata language")
                            .font(Theme.Font.label(13, weight: .medium))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { tmdb.language },
                            set: { tmdb.setLanguage($0) }
                        )) {
                            ForEach(TmdbService.languages, id: \.code) { item in
                                Text(item.label).tag(item.code)
                            }
                        }
                        .labelsHidden()
                    }
                } else {
                    HStack(spacing: Theme.Spacing.sm) {
                        SecureField("TMDB API key or Read Access Token", text: $apiKey)
                            .textFieldStyle(.plain)
                            .font(Theme.Font.mono(12))
                            .padding(10)
                            .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1))
                        FrameButton(
                            title: "Connect",
                            icon: "arrow.right",
                            color: Theme.Palette.onAccent,
                            fill: Theme.Palette.accent,
                            isLoading: tmdb.isBusy,
                            isEnabled: !tmdb.isBusy && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
                        ) {
                            Task {
                                if await tmdb.connect(rawKey: apiKey) { apiKey = "" }
                            }
                        }
                    }
                }

                if let err = tmdb.error {
                    Text(err).font(Theme.Font.caption(12)).foregroundStyle(Theme.Palette.danger)
                }
            }
        }
    }
}

// MARK: - Stremio account

private struct StremioAccountCard: View {
    @Environment(AppStore.self) private var store
    @Environment(WatchStore.self) private var watch
    @State private var email = ""
    @State private var password = ""
    @State private var addonResult: String?
    @State private var isImportingAddons = false

    private var account: StremioAccountService { store.stremioAccount }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "puzzlepiece.extension.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Rectangle().fill(Color(hex: 0x7B5BF5)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Stremio").font(Theme.Font.heading(15))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        if let mail = account.email, account.isConnected {
                            Text(mail).font(Theme.Font.body(12)).foregroundStyle(Theme.Palette.success)
                        } else {
                            Text("Not connected").font(Theme.Font.body(12)).foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                    Spacer()
                    if account.isConnected {
                        FrameButton(title: "Disconnect", icon: "xmark", color: Theme.Palette.danger) {
                            account.signOut()
                        }
                    }
                }
                if account.isConnected {
                    ImportRow(isWorking: account.isWorking, result: account.lastResult, title: "Import library") {
                        await account.importLibrary(into: watch)
                    }
                    HStack(spacing: Theme.Spacing.md) {
                        FrameButton(title: "Install account addons", icon: "puzzlepiece.extension",
                                    isLoading: isImportingAddons, isEnabled: !isImportingAddons) {
                            Task { await importAddons() }
                        }
                        if let addonResult {
                            Text(addonResult).font(Theme.Font.caption(11)).foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                } else if Platform.isMac {
                    HStack(spacing: Theme.Spacing.sm) {
                        stremioEmail
                        stremioPassword
                        stremioConnect
                    }
                } else {
                    // A phone: the fields one under the other.
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        stremioEmail
                        stremioPassword
                        stremioConnect
                    }
                }
                if let err = account.error {
                    Text(err.localized).font(Theme.Font.caption(12)).foregroundStyle(Theme.Palette.danger)
                }
                Text("Imports your Stremio library — saved titles, watched films and where you stopped — and can install the addons on your account. Nothing is written back to Stremio.")
                    .font(Theme.Font.caption(11))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private var stremioEmail: some View {
        TextField(String(localized: "Email"), text: $email)
            .plainEntry()
            #if os(iOS)
            .keyboardType(.emailAddress)
            .textContentType(.username)
            #endif
            .textFieldStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1))
    }

    private var stremioPassword: some View {
        SecureField(String(localized: "Password"), text: $password)
            .textFieldStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1))
            .onSubmit { Task { await account.signIn(email: email, password: password) } }
    }

    private var stremioConnect: some View {
        FrameButton(title: "Connect", icon: "arrow.right", color: Theme.Palette.accent,
                    fill: Theme.Palette.accent, isLoading: account.isWorking,
                    isEnabled: !account.isWorking && !email.isEmpty && !password.isEmpty) {
            Task {
                await account.signIn(email: email, password: password)
                if account.isConnected { password = "" }
            }
        }
    }

    private func importAddons() async {
        isImportingAddons = true
        defer { isImportingAddons = false }
        let installed = Set(store.addons.map(\.manifest.transportUrl))
        let urls = await account.addonURLs(excluding: installed)
        for url in urls { await store.installAddon(url: url) }
        addonResult = String(localized: "\(urls.count) addons installed")
    }
}

// MARK: - SIMKL

private struct SimklCard: View {
    @Environment(AppStore.self) private var store
    @Environment(WatchStore.self) private var watch

    private var simkl: SimklService { store.simkl }

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    Text("S")
                        .font(.system(size: 20, weight: .black))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Rectangle().fill(Color(hex: 0x1F1F1F)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SIMKL").font(Theme.Font.heading(15))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text((simkl.isConnected ? "Connected" : "Not connected").localized)
                            .font(Theme.Font.body(12))
                            .foregroundStyle(simkl.isConnected ? Theme.Palette.success : Theme.Palette.textTertiary)
                    }
                    Spacer()
                    if simkl.isConnected {
                        FrameButton(title: "Disconnect", icon: "xmark", color: Theme.Palette.danger) { simkl.disconnect() }
                    } else if simkl.pendingPin != nil {
                        FrameButton(title: "Cancel", icon: "xmark", color: Theme.Palette.textSecondary) { simkl.cancelPinFlow() }
                    } else if simkl.isAvailable {
                        FrameButton(title: "Connect", icon: "arrow.right", color: Theme.Palette.accent,
                                    fill: Theme.Palette.accent, isLoading: simkl.isConnecting,
                                    isEnabled: !simkl.isConnecting) {
                            Task { await simkl.startPinFlow() }
                        }
                    }
                }
                if let pin = simkl.pendingPin {
                    DebridActivationView(
                        providerName: "SIMKL", codeLabel: "CODE", code: pin.userCode,
                        openURL: pin.verificationURL, copyLabel: "Copy code",
                        instructions: "Open the link, enter the code, and confirm. Veltrio is polling — the connection completes automatically."
                    )
                }
                if simkl.isConnected {
                    ImportRow(isWorking: simkl.isImporting, result: simkl.lastImport, title: "Import lists") {
                        await simkl.importLibrary(into: watch)
                    }
                }
                if let err = simkl.error {
                    Text(err.localized).font(Theme.Font.caption(12)).foregroundStyle(Theme.Palette.danger)
                }
                Text((simkl.isAvailable
                      ? "Scrobbles what you watch to SIMKL and imports your plan-to-watch and completed lists."
                      : "SIMKL needs this build to carry a SIMKL client id (VELTRIO_SIMKL_CLIENT_ID, from simkl.com/settings/developer).").localized)
                    .font(Theme.Font.caption(11))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }
}

private struct TraktActivationView: View {
    let code: TraktDeviceCode
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Rule()
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                VStack(spacing: 4) {
                    Text("Code").eyebrow(Theme.Palette.textTertiary, tracking: 1.6)
                    Text(code.userCode)
                        .font(Theme.Font.mono(22, weight: .heavy))
                        .foregroundStyle(Theme.Palette.accentText)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .overlay(Rectangle().stroke(Theme.Palette.accent.opacity(0.4), lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Authorise on Trakt.tv")
                        .font(Theme.Font.heading(14))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Visit the URL, paste the code, and confirm. Veltrio polls until Trakt accepts.")
                        .font(Theme.Font.body(12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    HStack(spacing: Theme.Spacing.sm) {
                        FrameButton(title: "Open Trakt",
                                    icon: "arrow.up.right",
                                    color: Theme.Palette.accent,
                                    fill: Theme.Palette.accent) {
                            if let u = URL(string: code.verificationUrl) {
                                Platform.open(u)
                            }
                        }
                        FrameButton(title: "Copy code",
                                    icon: "doc.on.doc",
                                    color: Theme.Palette.textPrimary) {
                            Platform.copy(code.userCode)
                        }
                        ProgressView().veltrioControlSize(.small)
                            .padding(.leading, Theme.Spacing.sm)
                    }
                }
                Spacer()
            }
        }
    }
}

// MARK: - Download row

private struct DownloadRow: View {
    let item: DownloadItem
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            statusIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(Theme.Font.label(13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(item.status.rawValue.uppercased())
                        .eyebrow(color(for: item.status), tracking: 1.8)
                    if item.bytesExpected > 0 {
                        Text("\(sizeString(item.bytesDownloaded))  /  \(sizeString(item.bytesExpected))")
                            .font(Theme.Font.mono(10))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    if let err = item.errorMessage {
                        Text(err.localized)
                            .font(Theme.Font.mono(10))
                            .foregroundStyle(Theme.Palette.danger)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            // Progress
            ProgressView(value: item.progress)
                .progressViewStyle(.linear)
                .tint(color(for: item.status))
                .frame(width: 100)
            FrameButton(title: "Remove", icon: "trash",
                        color: Theme.Palette.danger, action: onRemove)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .overlay(alignment: .bottom) {
            Rule(color: Theme.Palette.hairline)
        }
    }

    private var statusIcon: some View {
        Image(systemName: {
            switch item.status {
            case .queued, .downloading: return "arrow.down.circle"
            case .completed:            return "checkmark.circle.fill"
            case .paused:               return "pause.circle"
            case .failed:               return "xmark.octagon"
            }
        }())
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(color(for: item.status))
        .frame(width: 24)
    }

    private func color(for s: DownloadItem.Status) -> Color {
        switch s {
        case .queued, .downloading: return Theme.Palette.accent
        case .completed:            return Theme.Palette.success
        case .paused:               return Theme.Palette.textTertiary
        case .failed:               return Theme.Palette.danger
        }
    }

    private func sizeString(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }
}


// MARK: - Appearance

private struct AppearanceSettings: View {
    @State private var prefs = UserPrefs.shared

    var body: some View {
        SettingsPageHeader(
            title: "Appearance",
            subtitle: "How Veltrio looks and feels."
        )
        SettingsSection(title: "Motion") {
            Toggle(isOn: Binding(
                get: { prefs.reduceMotion },
                set: { prefs.reduceMotion = $0 }
            )) {
                SettingRowLabel(
                    title: "Reduce hero motion",
                    hint: "Stop the slow background pan on the home hero."
                )
            }
            .toggleStyle(.switch)
        }
        SettingsSection(title: "Theme") {
            Text("Nightfall is tuned for the main app experience; Daybreak is a serviceable light mode for daytime use. Changes apply immediately.")
                .font(Theme.Font.caption(11))
                .foregroundStyle(Theme.Palette.textTertiary)

            HStack(spacing: 12) {
                ForEach(UserPrefs.ColorSchemePreference.allCases) { opt in
                    themeSwatch(for: opt)
                }
                Spacer()
            }
        }
    }

    /// Three side by side fit a phone's settings card.
    private static let swatchWidth: CGFloat = Platform.isMac ? 100 : 86

    private func themeSwatch(for opt: UserPrefs.ColorSchemePreference) -> some View {
        let isSelected = prefs.colorScheme == opt
        return Button {
            prefs.colorScheme = opt
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                themePreview(opt)
                    .frame(width: Self.swatchWidth, height: 64)
                    .overlay(
                        Rectangle().stroke(
                            isSelected ? Theme.Palette.accent : Theme.Palette.border,
                            lineWidth: isSelected ? 2 : 1
                        )
                    )
                Text(opt.label.localized)
                    .font(Theme.Font.eyebrow(10, weight: .bold))
                    .tracking(1.8)
                    .frame(width: Self.swatchWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(
                        isSelected ? Theme.Palette.accentText : Theme.Palette.textSecondary
                    )
            }
        }
        .buttonStyle(.plainRect)
    }

    @ViewBuilder
    private func themePreview(_ opt: UserPrefs.ColorSchemePreference) -> some View {
        switch opt {
        case .dark:
            ZStack(alignment: .topLeading) {
                Color.black
                Circle().fill(Theme.Palette.accent)
                    .frame(width: 14, height: 14)
                    .padding(10)
            }
        case .light:
            ZStack(alignment: .topLeading) {
                Color(hex: 0xF7F3EC)
                Circle().fill(Theme.Palette.accent)
                    .frame(width: 14, height: 14)
                    .padding(10)
            }
        case .system:
            HStack(spacing: 0) {
                Color.black
                Color(hex: 0xF7F3EC)
            }
            .overlay(alignment: .center) {
                Circle().fill(Theme.Palette.accent).frame(width: 14, height: 14)
            }
        }
    }
}

// MARK: - Storage / About

private struct StorageSettings: View {
    @Environment(AppStore.self) private var store
    @State private var log = DebugLog.shared
    @State private var filter: DebugLog.Level? = nil

    var body: some View {
        SettingsPageHeader(
            title: "Storage & debug",
            subtitle: "Downloads, torrent sessions, caches, and the in-session log."
        )
        SettingsSection(title: "Downloads") {
            if store.downloads.items.isEmpty {
                Text(LocalizedStringKey(Platform.isMac
                    ? "No downloads yet. Right-click a stream in Detail → Download for offline."
                    : "No downloads yet. Touch and hold a stream on a title's page → Download for offline."))
                    .font(Theme.Font.caption(11))
                    .foregroundStyle(Theme.Palette.textTertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.downloads.items) { d in
                        DownloadRow(item: d, onRemove: {
                            store.downloads.remove(id: d.id)
                        })
                    }
                }
            }
        }
        SettingsSection(title: "Torrents") {
            SettingRowLabel(
                title: "Download location",
                hint: Platform.isMac ? "librqbit downloads live under Application Support. Stop and cleanup happens on player close."
                                     : "Torrents download into the app's cache, which iOS may clear when space runs low. Stop and cleanup happens on player close."
            )
        }
        SettingsSection(title: "Log") {
            // Filters and actions on one line, or two where they don't fit.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.sm) {
                    logFilters
                    Spacer()
                    logActions
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    logFilters
                    HStack(spacing: Theme.Spacing.sm) { logActions }
                }
            }

            logList
        }
    }

    private var logFilters: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Chip(label: "All",   isSelected: filter == nil)         { filter = nil }
            Chip(label: "Info",  isSelected: filter == .info)       { filter = .info }
            Chip(label: "Warn",  isSelected: filter == .warn)       { filter = .warn }
            Chip(label: "Error", isSelected: filter == .error)      { filter = .error }
        }
    }

    @ViewBuilder
    private var logActions: some View {
        FrameButton(title: "Copy", icon: "doc.on.doc",
                    color: Theme.Palette.textPrimary) { log.copyToPasteboard() }
        FrameButton(title: "Clear", icon: "trash",
                    color: Theme.Palette.danger) { log.clear() }
    }

    private var logList: some View {
        let entries = filtered
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if entries.isEmpty {
                    Text("Log is empty.")
                        .font(Theme.Font.caption(11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.vertical, Theme.Spacing.md)
                }
                ForEach(entries.reversed()) { e in
                    logRow(e)
                }
            }
        }
        .frame(height: 280)
        .background(Theme.Palette.background)
        .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
    }

    private func logRow(_ e: DebugLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timeString(e.timestamp))
                .font(Theme.Font.mono(10))
                .foregroundStyle(Theme.Palette.textQuaternary)
                .frame(width: 70, alignment: .leading)
            Text(e.level.rawValue.uppercased())
                .font(Theme.Font.mono(9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(color(for: e.level))
                .frame(width: 44, alignment: .leading)
            Text(e.source)
                .font(Theme.Font.mono(10, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 180, alignment: .leading)
                .lineLimit(1)
            Text(e.message)
                .font(Theme.Font.mono(10))
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(2)
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private var filtered: [DebugLog.Entry] {
        guard let f = filter else { return log.entries }
        return log.entries.filter { $0.level == f }
    }

    private func color(for l: DebugLog.Level) -> Color {
        switch l {
        case .info:  Theme.Palette.textTertiary
        case .warn:  Theme.Palette.warning
        case .error: Theme.Palette.danger
        }
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

/// Sending this device's settings to a Veltrio TV (Android TV) on the same
/// network: it finds the TVs waiting with a code, or takes an address.
private struct DevicesSettings: View {
    @Environment(AppStore.self) private var store
    @Environment(WatchStore.self) private var watch
    @State private var browser = PairingBrowser()
    @State private var target: PairingSender.Target?
    @State private var address = ""
    @State private var code = ""
    @State private var sending = false
    @State private var result: String?
    @State private var error: String?

    var body: some View {
        SettingsPageHeader(
            title: "Send to a TV",
            subtitle: "Set up a Veltrio TV (Android TV, Google TV) in one step: your sources, accounts and Collection, sent over the local network, encrypted with a key tied to the code the TV shows."
        )
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("On the TV, open Veltrio, then “From a phone” at the bottom of the left menu: it shows up here with a code.")
                    .font(Theme.Font.body(13))
                    .foregroundStyle(Theme.Palette.textSecondary)
                if browser.targets.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().veltrioControlSize(.small)
                        Text("Looking for a waiting TV…").font(Theme.Font.body(13)).foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                ForEach(browser.targets) { t in
                    Button {
                        target = t
                        address = ""
                        result = nil
                        error = nil
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "tv").foregroundStyle(t == target ? Theme.Palette.accent : Theme.Palette.textSecondary)
                            Text(t.name).font(Theme.Font.label(14, weight: .semibold)).foregroundStyle(Theme.Palette.textPrimary)
                            Spacer()
                        }
                        .padding(12)
                        .overlay(Rectangle().stroke(t == target ? Theme.Palette.accent : Theme.Palette.border, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Text("Not in the list? The address shown on the TV:")
                    .font(Theme.Font.caption(12)).foregroundStyle(Theme.Palette.textTertiary)
                TextField("192.168.1.20:8765", text: $address)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.mono(13))
                    .padding(10)
                    .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1))
                    .onChange(of: address) { _, v in if !v.isEmpty { target = PairingSender.manualTarget(v) } }
                if let target {
                    Text("Code shown on \(target.name)")
                        .font(Theme.Font.caption(12)).foregroundStyle(Theme.Palette.textTertiary)
                    TextField("000000", text: $code)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.mono(20, weight: .bold))
                        .padding(10)
                        .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1))
                        .onChange(of: code) { _, v in code = String(v.filter(\.isNumber).prefix(6)) }
                    FrameButton(title: sending ? "Sending…" : "Send", icon: "paperplane.fill",
                                color: Theme.Palette.accent, fill: Theme.Palette.accent) {
                        send(to: target)
                    }
                    .disabled(code.count != 6 || sending)
                }
                if let result {
                    Text("Received by the TV: \(result).").font(Theme.Font.body(13)).foregroundStyle(Theme.Palette.success)
                }
                if let error {
                    Text(error).font(Theme.Font.body(13)).foregroundStyle(Theme.Palette.danger)
                }
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func send(to target: PairingSender.Target) {
        sending = true
        error = nil
        result = nil
        let bundle = PairingSender.collect(store: store, watch: watch)
        Task {
            do {
                result = try await PairingSender.send(bundle, to: target, code: code)
            } catch {
                self.error = error.localizedDescription
            }
            sending = false
        }
    }
}

private struct AboutSettings: View {
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        SettingsPageHeader(title: "About")
        SurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Veltrio").font(Theme.Font.heading(18))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("v\(appVersion) · Core \(coreVersion())")
                    .font(Theme.Font.mono(11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text("Every source, one native player.")
                    .font(Theme.Font.body(13))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.top, 6)
            }
        }
        // Collected from macOS's diagnostic reports: nothing to show on iOS.
        #if os(macOS)
        MacUpdatesCard()
        #elseif os(iOS)
        IOSUpdatesCard(currentVersion: appVersion)
        #elseif os(tvOS)
        TVUpdatesCard(currentVersion: appVersion)
        #endif
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Welcome guide").font(Theme.Font.heading(15))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Re-run the initial setup assistant to configure your catalog and languages.")
                    .font(Theme.Font.body(13))
                    .foregroundStyle(Theme.Palette.textSecondary)
                FrameButton(title: "Show welcome guide", icon: "sparkles") {
                    UserPrefs.shared.hasCompletedOnboarding = false
                    NotificationCenter.default.post(name: .veltrioShowOnboarding, object: nil)
                }
            }
        }
        #if os(macOS)
        SurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Crash reports").font(Theme.Font.heading(15))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(crashReportSummary)
                    .font(Theme.Font.body(13))
                    .foregroundStyle(Theme.Palette.textSecondary)
                FrameButton(title: "Show in Finder", icon: "folder") {
                    CrashReports.revealInFinder()
                }
            }
        }
        #endif
    }

    private var crashReportSummary: String {
        let count = CrashReports.reports().count
        if count == 0 {
            return String(localized: "No crash or hang reported. If one happens, macOS hands the report over at the next launch and it lands here.")
        }
        return String(localized: "\(count) reports from the last 60 days. Attach them to a bug report.")
    }
}

#if os(macOS)
private struct MacUpdatesCard: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Updates")
                    .font(Theme.Font.heading(15))
                    .foregroundStyle(Theme.Palette.textPrimary)

                Toggle("Check automatically for updates", isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { updater.automaticallyChecks = $0 }
                ))
                .toggleStyle(.switch)

                if let statusLine {
                    Text(statusLine)
                        .font(Theme.Font.body(13))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                HStack(spacing: Theme.Spacing.sm) {
                    if let update = updater.availableUpdate {
                        FrameButton(
                            title: String(localized: "Download v\(update.version)"),
                            icon: "arrow.down.circle",
                            color: Theme.Palette.onAccent,
                            fill: Theme.Palette.accent
                        ) {
                            updater.openDownload()
                        }
                    }
                    FrameButton(
                        title: "Check for Updates",
                        icon: "arrow.triangle.2.circlepath",
                        isLoading: updater.status == .checking
                    ) {
                        updater.checkForUpdates()
                    }
                }
            }
        }
    }

    private var statusLine: String? {
        switch updater.status {
        case .idle:
            return updater.usesSparkle
                ? String(localized: "Updates are downloaded and installed automatically via Sparkle.")
                : String(localized: "Checks GitHub Releases for new macOS versions.")
        case .checking:
            return String(localized: "Checking for updates…")
        case .upToDate:
            return String(localized: "Veltrio \(updater.currentVersion) is up to date.")
        case .available(let u):
            return String(localized: "Version \(u.version) is available.")
        case .failed(let message):
            return message
        }
    }
}
#elseif os(iOS)
private struct IOSUpdatesCard: View {
    let currentVersion: String
    @Environment(\.openURL) private var openURL
    @State private var isChecking = false
    @State private var statusText: String?
    @State private var availableVersion: String?
    @State private var releaseURL: URL?

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Updates")
                    .font(Theme.Font.heading(15))
                    .foregroundStyle(Theme.Palette.textPrimary)

                Text(statusText ?? String(localized: "TestFlight updates automatically. You can also check GitHub Releases for the latest iOS build."))
                    .font(Theme.Font.body(13))
                    .foregroundStyle(Theme.Palette.textSecondary)

                HStack(spacing: Theme.Spacing.sm) {
                    if let ver = availableVersion, let url = releaseURL {
                        FrameButton(
                            title: String(localized: "Download v\(ver)"),
                            icon: "arrow.down.circle",
                            color: Theme.Palette.onAccent,
                            fill: Theme.Palette.accent
                        ) {
                            openURL(url)
                        }
                    }
                    FrameButton(
                        title: "Check for Updates",
                        icon: "arrow.triangle.2.circlepath",
                        isLoading: isChecking
                    ) {
                        Task { await check() }
                    }
                }
            }
        }
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        let api = URL(string: "https://api.github.com/repos/VeltrioApp/veltrio-ios/releases?per_page=1")!
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                statusText = String(localized: "Could not reach GitHub Releases.")
                return
            }
            struct Release: Decodable {
                let tag_name: String
                let html_url: String
                let draft: Bool
            }
            let releases = try JSONDecoder().decode([Release].self, from: data)
            guard let latest = releases.first(where: { !$0.draft }) else {
                statusText = String(localized: "Veltrio \(currentVersion) is up to date.")
                availableVersion = nil
                releaseURL = nil
                return
            }
            let tag = latest.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if isNewer(tag, than: currentVersion), let url = URL(string: latest.html_url) {
                availableVersion = tag
                releaseURL = url
                statusText = String(localized: "Version \(tag) is available.")
            } else {
                availableVersion = nil
                releaseURL = nil
                statusText = String(localized: "Veltrio \(currentVersion) is up to date.")
            }
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let core = s.split(separator: "-").first.map(String.init) ?? s
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}
#elseif os(tvOS)
private struct TVUpdatesCard: View {
    let currentVersion: String
    @State private var isChecking = false
    @State private var statusText: String?

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Updates")
                    .font(Theme.Font.heading(15))
                    .foregroundStyle(Theme.Palette.textPrimary)

                Text(statusText ?? String(localized: "TestFlight updates automatically. You can also check GitHub Releases for the latest Apple TV build."))
                    .font(Theme.Font.body(13))
                    .foregroundStyle(Theme.Palette.textSecondary)

                FrameButton(
                    title: "Check for Updates",
                    icon: "arrow.triangle.2.circlepath",
                    isLoading: isChecking
                ) {
                    Task { await check() }
                }
            }
        }
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        let api = URL(string: "https://api.github.com/repos/VeltrioApp/veltrio-tvos/releases?per_page=1")!
        var req = URLRequest(url: api)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                statusText = String(localized: "Could not reach GitHub Releases.")
                return
            }
            struct Release: Decodable {
                let tag_name: String
                let draft: Bool
            }
            let releases = try JSONDecoder().decode([Release].self, from: data)
            guard let latest = releases.first(where: { !$0.draft }) else {
                statusText = String(localized: "Veltrio \(currentVersion) is up to date.")
                return
            }
            let tag = latest.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if isNewer(tag, than: currentVersion) {
                statusText = String(localized: "Version \(tag) is available.")
            } else {
                statusText = String(localized: "Veltrio \(currentVersion) is up to date.")
            }
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let core = s.split(separator: "-").first.map(String.init) ?? s
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}
#endif

// MARK: - Settings primitives

private struct SettingsPageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.localized)
                    .font(Theme.Font.displaySerif(34, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle.localized)
                        .font(Theme.Font.body(13))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Rule()
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title.localized)
                .eyebrow(Theme.Palette.accentText, tracking: 2.4)
            SurfaceCard {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    content()
                }
            }
        }
    }
}

private struct SettingRowLabel: View {
    let title: String
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.localized)
                .font(Theme.Font.label(13, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            if let hint {
                Text(hint.localized)
                    .font(Theme.Font.caption(11))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }
}

private struct SettingsPicker: View {
    let title: String
    let hint: String?
    let selection: Binding<String>
    let options: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingRowLabel(title: title, hint: hint)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { option in
                    Text(option.1.localized).tag(option.0)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .leading)
        }
    }
}

private struct SettingsStepper: View {
    let title: String
    let hint: String?
    let value: Binding<Int>
    let unit: String
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingRowLabel(title: title, hint: hint)
            #if os(tvOS)
            // No Stepper on tvOS: − and + buttons.
            HStack(spacing: Theme.Spacing.md) {
                Button { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) } label: { Image(systemName: "minus") }
                Text("\(value.wrappedValue) \(unit)")
                    .font(Theme.Font.label(12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Button { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) } label: { Image(systemName: "plus") }
            }
            #else
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue) \(unit)")
                    .font(Theme.Font.label(12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            #endif
        }
    }
}

// MARK: - Real-Debrid card

private struct RealDebridCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                DebridRow(
                    brandColor: Color(hex: DebridProvider.realDebrid.brandColorHex),
                    title: "Real-Debrid",
                    status: {
                        DebridStatusLabel(
                            email: store.debrid.realDebridUser?.email,
                            isPremium: store.debrid.realDebridUser?.isPremium ?? false,
                            isConnected: store.debrid.isRealDebridConnected
                        )
                    },
                    action: { actionButton }
                )
                if let error = store.debrid.realDebridError {
                    DebridErrorLabel(message: error)
                }
                if let code = store.debrid.pendingRdDevice {
                    DebridActivationView(
                        providerName: "Real-Debrid",
                        codeLabel: "CODE",
                        code: code.userCode,
                        openURL: URL(string: code.verificationUrl),
                        copyLabel: "Copy code",
                        instructions: "Open the link, enter the code, and confirm. Veltrio is polling — the connection completes automatically."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if store.debrid.isRealDebridConnected {
            FrameButton(title: "Disconnect",
                        icon: "xmark",
                        color: Theme.Palette.danger) {
                store.debrid.disconnectRealDebrid()
            }
        } else if store.debrid.pendingRdDevice != nil {
            FrameButton(title: "Cancel", icon: "xmark",
                        color: Theme.Palette.textSecondary) {
                store.debrid.cancelRealDebridDeviceFlow()
            }
        } else {
            FrameButton(title: "Connect",
                        icon: "arrow.right",
                        color: Theme.Palette.accent,
                        fill: Theme.Palette.accent,
                        isLoading: store.debrid.isConnectingRealDebrid,
                        isEnabled: !store.debrid.isConnectingRealDebrid) {
                Task { await store.debrid.startRealDebridDeviceFlow() }
            }
        }
    }
}

/// The panel shown while a provider waits for the user to confirm an
/// authorisation code.
///
/// Real-Debrid (device code) and AllDebrid (PIN) used to have two
/// separate panels that differed in the separator (`Rule` vs `Divider`),
/// the size of the code (22pt vs 26pt) and how the code was boxed
/// (stroked vs filled). They now share one.
private struct DebridActivationView: View {
    let providerName: String
    let codeLabel: String
    let code: String
    let openURL: URL?
    let copyLabel: String
    let instructions: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Rule()
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                VStack(spacing: 4) {
                    Text(codeLabel.localized)
                        .font(Theme.Font.eyebrow(10, weight: .bold))
                        .tracking(1.6)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text(code)
                        .font(Theme.Font.mono(24, weight: .heavy))
                        .foregroundStyle(Theme.Palette.accentText)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(
                            Rectangle().fill(Theme.Palette.accentSoft)
                        )
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Validate on \(providerName)")
                        .font(Theme.Font.heading(14))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(instructions.localized)
                        .font(Theme.Font.body(12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    HStack(spacing: Theme.Spacing.sm) {
                        FrameButton(title: String(localized: "Open \(providerName)"),
                                    icon: "arrow.up.right",
                                    color: Theme.Palette.accent,
                                    fill: Theme.Palette.accent) {
                            if let openURL { Platform.open(openURL) }
                        }
                        FrameButton(title: copyLabel,
                                    icon: "doc.on.doc",
                                    color: Theme.Palette.textPrimary) {
                            Platform.copy(code)
                        }
                        ProgressView().veltrioControlSize(.small)
                            .padding(.leading, Theme.Spacing.sm)
                    }
                }
                Spacer()
            }
        }
    }
}

// MARK: - AllDebrid card

private struct AllDebridCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                DebridRow(
                    brandColor: Color(hex: DebridProvider.allDebrid.brandColorHex),
                    title: "AllDebrid",
                    status: {
                        DebridStatusLabel(
                            email: store.debrid.allDebridUser?.email,
                            isPremium: store.debrid.allDebridUser?.isPremium ?? false,
                            isConnected: store.debrid.isAllDebridConnected
                        )
                    },
                    action: { actionButton }
                )
                if let error = store.debrid.allDebridError {
                    DebridErrorLabel(message: error)
                }
                if let pin = store.debrid.pendingPin {
                    DebridActivationView(
                        providerName: "AllDebrid",
                        codeLabel: "PIN",
                        code: pin.pin,
                        openURL: URL(string: pin.userUrl),
                        copyLabel: "Copy PIN",
                        instructions: "Open the link, enter the PIN, and confirm. Veltrio is polling — the connection completes automatically."
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if store.debrid.isAllDebridConnected {
            FrameButton(title: "Disconnect",
                        icon: "xmark",
                        color: Theme.Palette.danger) {
                store.debrid.disconnectAllDebrid()
            }
        } else if store.debrid.pendingPin != nil {
            FrameButton(title: "Cancel", icon: "xmark",
                        color: Theme.Palette.textSecondary) {
                store.debrid.cancelAllDebridPinFlow()
            }
        } else {
            FrameButton(title: "Connect",
                        icon: "arrow.right",
                        color: Theme.Palette.accent,
                        fill: Theme.Palette.accent,
                        isLoading: store.debrid.isConnectingAllDebrid,
                        isEnabled: !store.debrid.isConnectingAllDebrid) {
                Task { await store.debrid.startAllDebridPinFlow() }
            }
        }
    }
}
