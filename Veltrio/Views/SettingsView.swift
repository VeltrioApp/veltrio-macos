import SwiftUI

/// Two-pane settings: left sidebar lists sections, right pane shows the
/// chosen one. Shape mirrors System Settings on macOS — scannable at a
/// glance instead of a long scrolling wall of toggles.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: Section = .playback

    enum Section: String, CaseIterable, Identifiable {
        case playback  = "Playback"
        case languages = "Languages"
        case debrid    = "Debrid"
        case accounts  = "Accounts"
        case appearance = "Appearance"
        case storage   = "Storage"
        case about     = "About"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .playback:   return "play.rectangle.fill"
            case .languages:  return "character.bubble.fill"
            case .debrid:     return "bolt.fill"
            case .accounts:   return "person.crop.circle.fill"
            case .appearance: return "paintbrush.fill"
            case .storage:    return "externaldrive.fill"
            case .about:      return "info.circle.fill"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(Theme.Palette.backgroundAlt)
            Divider().background(Theme.Palette.hairline)
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
            ForEach(Section.allCases) { section in
                SidebarRow(
                    section: section,
                    isSelected: selection == section
                ) {
                    selection = section
                }
            }
            Spacer()
        }
        .padding(.vertical, Theme.Spacing.md)
        .padding(.horizontal, Theme.Spacing.sm)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .playback:   PlaybackSettings()
        case .languages:  LanguageSettings()
        case .debrid:     DebridSettings()
        case .accounts:   AccountsSettings()
        case .appearance: AppearanceSettings()
        case .storage:    StorageSettings()
        case .about:      AboutSettings()
        }
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let section: SettingsView.Section
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        isSelected ? Theme.Palette.onAccent : Theme.Palette.textSecondary
                    )
                    .frame(width: 20)
                Text(section.rawValue)
                    .font(Theme.Font.label(13, weight: isSelected ? .bold : .semibold))
                    .foregroundStyle(
                        isSelected ? Theme.Palette.onAccent : Theme.Palette.textSecondary
                    )
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(
                    isSelected
                        ? Theme.Palette.accent
                        : (isHovering ? Theme.Palette.surfaceHover : Color.clear)
                )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
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
        comingProvider(.premiumize)
        comingProvider(.torbox)
    }

    /// A provider that isn't wired up yet.
    ///
    /// It goes through the same `DebridRow` chrome as the live providers
    /// so the list reads as one set — identical badge geometry, type and
    /// rule. Only the action slot differs: a "COMING" marker instead of
    /// a button.
    private func comingProvider(_ p: DebridProvider) -> some View {
        SurfaceCard {
            DebridRow(
                brandColor: Color(hex: p.brandColorHex),
                title: p.displayName,
                isDimmed: true,
                status: {
                    Text(p.shortTagline)
                        .font(Theme.Font.caption(11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                },
                action: {
                    Text("COMING")
                        .font(Theme.Font.eyebrow(10, weight: .bold))
                        .tracking(1.8)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
                }
            )
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
                Text(title)
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
        Text(message)
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
        TraktCard()
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
                Text(blurb).font(Theme.Font.caption(11))
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
                    Text(err)
                        .font(Theme.Font.caption(12))
                        .foregroundStyle(Theme.Palette.danger)
                }
                Text("Veltrio scrobbles start / pause / stop events to Trakt as you watch. Your Trakt library can be pulled into Collection later.")
                    .font(Theme.Font.caption(11))
                    .foregroundStyle(Theme.Palette.textTertiary)
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
                                NSWorkspace.shared.open(u)
                            }
                        }
                        FrameButton(title: "Copy code",
                                    icon: "doc.on.doc",
                                    color: Theme.Palette.textPrimary) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code.userCode, forType: .string)
                        }
                        ProgressView().controlSize(.small)
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
                        Text(err)
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

    private func themeSwatch(for opt: UserPrefs.ColorSchemePreference) -> some View {
        let isSelected = prefs.colorScheme == opt
        return Button {
            prefs.colorScheme = opt
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                themePreview(opt)
                    .frame(width: 100, height: 64)
                    .overlay(
                        Rectangle().stroke(
                            isSelected ? Theme.Palette.accent : Theme.Palette.border,
                            lineWidth: isSelected ? 2 : 1
                        )
                    )
                Text(opt.label)
                    .font(Theme.Font.eyebrow(10, weight: .bold))
                    .tracking(1.8)
                    .foregroundStyle(
                        isSelected ? Theme.Palette.accentText : Theme.Palette.textSecondary
                    )
            }
        }
        .buttonStyle(.plain)
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
                Text("No downloads yet. Right-click a stream in Detail → Download for offline.")
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
                hint: "librqbit downloads live under Application Support. Stop and cleanup happens on player close."
            )
        }
        SettingsSection(title: "Log") {
            HStack(spacing: Theme.Spacing.sm) {
                Chip(label: "All",   isSelected: filter == nil)         { filter = nil }
                Chip(label: "Info",  isSelected: filter == .info)       { filter = .info }
                Chip(label: "Warn",  isSelected: filter == .warn)       { filter = .warn }
                Chip(label: "Error", isSelected: filter == .error)      { filter = .error }
                Spacer()
                FrameButton(title: "Copy", icon: "doc.on.doc",
                            color: Theme.Palette.textPrimary) { log.copyToPasteboard() }
                FrameButton(title: "Clear", icon: "trash",
                            color: Theme.Palette.danger) { log.clear() }
            }

            logList
        }
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
                .textSelection(.enabled)
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
    }

    private var crashReportSummary: String {
        let count = CrashReports.reports().count
        if count == 0 {
            return "No crash or hang reported. If one happens, macOS hands the report over at the next launch and it lands here."
        }
        return "\(count) report\(count == 1 ? "" : "s") from the last 60 days. Attach them to a bug report."
    }
}

// MARK: - Settings primitives

private struct SettingsPageHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.Font.display(26))
                .tracking(-0.4)
                .foregroundStyle(Theme.Palette.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Font.body(13))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title.uppercased())
                .font(Theme.Font.label(10, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(Theme.Palette.textTertiary)
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
            Text(title)
                .font(Theme.Font.label(13, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            if let hint {
                Text(hint)
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
                    Text(option.1).tag(option.0)
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
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue) \(unit)")
                    .font(Theme.Font.label(12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
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
                    Text(codeLabel)
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
                    Text(instructions)
                        .font(Theme.Font.body(12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    HStack(spacing: Theme.Spacing.sm) {
                        FrameButton(title: "Open \(providerName)",
                                    icon: "arrow.up.right",
                                    color: Theme.Palette.accent,
                                    fill: Theme.Palette.accent) {
                            if let openURL { NSWorkspace.shared.open(openURL) }
                        }
                        FrameButton(title: copyLabel,
                                    icon: "doc.on.doc",
                                    color: Theme.Palette.textPrimary) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code, forType: .string)
                        }
                        ProgressView().controlSize(.small)
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
