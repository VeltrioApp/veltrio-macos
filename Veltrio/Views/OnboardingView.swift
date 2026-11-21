import SwiftUI

/// First-launch welcome flow: sets up preferred languages, installs Cinemeta
/// (the default movie & series catalog) in one click, and optionally lets the
/// user paste an addon URL right away. Always skippable.
struct OnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(WatchStore.self) private var watch
    @State private var prefs = UserPrefs.shared
    let onFinish: (_ goToTab: NavItem?) -> Void

    private enum Step: Int, CaseIterable {
        case welcome = 0
        case sources = 1
        case ready   = 2
    }

    @State private var step: Step = .welcome
    @State private var stremioEmail = ""
    @State private var stremioPassword = ""
    @State private var isImportingStremio = false
    @State private var stremioFeedback: String?
    @State private var installCinemeta = true
    @State private var customAddonURL = ""
    @State private var isInstallingAddon = false
    @State private var addonFeedback: String?
    @State private var addonError: String?
    @State private var isFinishing = false

    private static let cinemetaURL = "https://v3-cinemeta.strem.io/manifest.json"

    private var stremio: StremioAccountService { store.stremioAccount }

    private var hasCinemeta: Bool {
        store.addons.contains { $0.manifest.transportUrl.localizedCaseInsensitiveContains("cinemeta") }
    }

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Rule(color: Theme.Palette.hairline)

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        switch step {
                        case .welcome: welcomeStep
                        case .sources: sourcesStep
                        case .ready:   readyStep
                        }
                    }
                    .padding(Theme.Spacing.xxl)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }

                Rule(color: Theme.Palette.hairline)
                footer
            }
        }
        .tint(Theme.Palette.accent)
    }

    // MARK: - Header & Footer

    private var header: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Veltrio")
                    .font(Theme.Font.displaySerif(24, weight: .bold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(String(format: "%02d / %02d", step.rawValue + 1, Step.allCases.count))
                    .font(Theme.Font.mono(11, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accentText)
            }

            Spacer()

            Button {
                prefs.hasCompletedOnboarding = true
                onFinish(nil)
            } label: {
                Text("Skip")
                    .font(Theme.Font.eyebrow(10, weight: .bold))
                    .tracking(2.0)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, 18)
        .background(Theme.Palette.backgroundAlt)
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                FrameButton(title: "Back", icon: "chevron.left") {
                    withAnimation(.easeOut(duration: 0.18)) {
                        step = Step(rawValue: step.rawValue - 1) ?? .welcome
                    }
                }
            }

            Spacer()

            switch step {
            case .welcome:
                FrameButton(
                    title: "Continue",
                    icon: "arrow.right",
                    color: Theme.Palette.onAccent,
                    fill: Theme.Palette.accent
                ) {
                    withAnimation(.easeOut(duration: 0.18)) { step = .sources }
                }
            case .sources:
                FrameButton(
                    title: "Continue",
                    icon: "arrow.right",
                    color: Theme.Palette.onAccent,
                    fill: Theme.Palette.accent
                ) {
                    withAnimation(.easeOut(duration: 0.18)) { step = .ready }
                }
            case .ready:
                FrameButton(
                    title: "Start watching",
                    icon: "play.fill",
                    color: Theme.Palette.onAccent,
                    fill: Theme.Palette.accent,
                    isLoading: isFinishing
                ) {
                    Task { await completeOnboarding(goToTab: .home) }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, 18)
        .background(Theme.Palette.backgroundAlt)
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: 10) {
                Text("01 — WELCOME")
                    .eyebrow(Theme.Palette.accentText, tracking: 2.6)
                Text("Every source, one native player.")
                    .font(Theme.Font.displaySerif(38, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Sign in with your Stremio account to bring your addons and library over in one step, or start fresh.")
                    .font(Theme.Font.body(14))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            // Primary option: Stremio account sign-in + full import
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accentText)
                    Text("Sign in with Stremio")
                        .font(Theme.Font.label(15, weight: .bold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    if stremio.isConnected {
                        Text("CONNECTED")
                            .font(Theme.Font.mono(10, weight: .bold))
                            .foregroundStyle(Theme.Palette.success)
                    }
                }

                if stremio.isConnected {
                    Text(String(localized: "Signed in as \(stremio.email ?? "Stremio") — your addons and library can be imported in one click."))
                        .font(Theme.Font.caption(12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    HStack(spacing: Theme.Spacing.sm) {
                        FrameButton(
                            title: "Import addons & library",
                            icon: "square.and.arrow.down",
                            color: Theme.Palette.onAccent,
                            fill: Theme.Palette.accent,
                            isLoading: isImportingStremio
                        ) {
                            Task { await importFromStremio() }
                        }
                    }
                } else {
                    Text("Imports your installed addons, saved collection and watch history automatically.")
                        .font(Theme.Font.caption(12))
                        .foregroundStyle(Theme.Palette.textSecondary)

                    HStack(spacing: Theme.Spacing.sm) {
                        TextField("Email", text: $stremioEmail)
                            #if !os(tvOS)
                            .textFieldStyle(.plain)
                            #endif
                            .font(Theme.Font.body(13))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Theme.Palette.background)
                            .overlay(Rectangle().stroke(Theme.Palette.hairline, lineWidth: 1))

                        SecureField("Password", text: $stremioPassword)
                            #if !os(tvOS)
                            .textFieldStyle(.plain)
                            #endif
                            .font(Theme.Font.body(13))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Theme.Palette.background)
                            .overlay(Rectangle().stroke(Theme.Palette.hairline, lineWidth: 1))
                            .onSubmit { Task { await signInAndImportStremio() } }
                    }

                    FrameButton(
                        title: "Sign in & import",
                        icon: "arrow.right.circle",
                        color: Theme.Palette.onAccent,
                        fill: Theme.Palette.accent,
                        isLoading: isImportingStremio || stremio.isWorking,
                        isEnabled: !stremioEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !stremioPassword.isEmpty
                    ) {
                        Task { await signInAndImportStremio() }
                    }
                }

                if let feedback = stremioFeedback {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                        .font(Theme.Font.caption(12))
                        .foregroundStyle(Theme.Palette.success)
                }
                if let err = stremio.error {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.caption(12))
                        .foregroundStyle(Theme.Palette.danger)
                }
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.Palette.surface)
            .overlay(Rectangle().stroke(Theme.Palette.accent.opacity(0.45), lineWidth: 1))

            // Secondary option: Start fresh with Cinemeta + languages
            VStack(alignment: .leading, spacing: 14) {
                Text("Or start fresh")
                    .eyebrow(Theme.Palette.textTertiary, tracking: 2.0)

                Toggle(isOn: $installCinemeta) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Install Cinemeta catalog")
                            .font(Theme.Font.label(14, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Text("Populates Home and Search with popular movies, series, posters and ratings right away.")
                            .font(Theme.Font.caption(12))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                #if !os(tvOS)
                .toggleStyle(.switch)
                #endif

                Rule(color: Theme.Palette.border)

                HStack(spacing: Theme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Audio")
                            .font(Theme.Font.label(12, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Picker("Audio", selection: $prefs.preferredAudioLang) {
                            ForEach(UserPrefs.supportedLanguages, id: \.code) { lang in
                                Text(lang.name.localized).tag(lang.code)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Subtitles")
                            .font(Theme.Font.label(12, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Picker("Subtitles", selection: $prefs.preferredSubtitleLang) {
                            ForEach(UserPrefs.supportedLanguages, id: \.code) { lang in
                                Text(lang.name.localized).tag(lang.code)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.Palette.surface)
            .overlay(Rectangle().stroke(Theme.Palette.hairline, lineWidth: 1))
        }
    }

    // MARK: - Step 2: Sources

    private var sourcesStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: 10) {
                Text("02 — SOURCES")
                    .eyebrow(Theme.Palette.accentText, tracking: 2.6)
                Text("Connect what you already use.")
                    .font(Theme.Font.displaySerif(36, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Paste a Stremio addon link now, or skip and add your IPTV playlists, Plex / Jellyfin / Emby servers and debrid accounts later in Sources.")
                    .font(Theme.Font.body(14))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Add a Stremio addon")
                    .font(Theme.Font.label(14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)

                HStack(spacing: Theme.Spacing.sm) {
                    TextField("https://example.com/manifest.json", text: $customAddonURL)
                        #if !os(tvOS)
                        .textFieldStyle(.plain)
                        #endif
                        .font(Theme.Font.mono(12))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Theme.Palette.background)
                        .overlay(Rectangle().stroke(Theme.Palette.hairline, lineWidth: 1))
                        .onSubmit { Task { await installCustomAddon() } }

                    FrameButton(
                        title: "Install",
                        icon: "plus",
                        isLoading: isInstallingAddon,
                        isEnabled: !customAddonURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ) {
                        Task { await installCustomAddon() }
                    }
                }

                if let feedback = addonFeedback {
                    Label(feedback, systemImage: "checkmark.circle.fill")
                        .font(Theme.Font.caption(12))
                        .foregroundStyle(Theme.Palette.success)
                }
                if let error = addonError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.caption(12))
                        .foregroundStyle(Theme.Palette.danger)
                }
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.Palette.surface)
            .overlay(Rectangle().stroke(Theme.Palette.hairline, lineWidth: 1))

            HStack(spacing: Theme.Spacing.md) {
                onboardingHintCard(
                    icon: "dot.radiowaves.left.and.right",
                    title: "Live TV & IPTV",
                    detail: "M3U playlists, Xtream Codes, TV guide & catchup."
                )
                onboardingHintCard(
                    icon: "server.rack",
                    title: "Plex, Jellyfin & Emby",
                    detail: "Your personal libraries appear on every title page."
                )
                onboardingHintCard(
                    icon: "bolt.fill",
                    title: "Debrid & Sync",
                    detail: "AllDebrid, Real-Debrid, TorBox, Trakt & SIMKL."
                )
            }
        }
    }

    // MARK: - Step 3: Ready

    private var readyStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: 10) {
                Text("03 — READY")
                    .eyebrow(Theme.Palette.accentText, tracking: 2.6)
                Text("Lights down. You’re all set.")
                    .font(Theme.Font.displaySerif(38, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Everything can be adjusted later from Sources and Settings. You can also send your setup to an Apple TV or Android TV from Settings → Other devices.")
                    .font(Theme.Font.body(14))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                summaryRow(
                    label: "Catalog",
                    value: (installCinemeta || hasCinemeta) ? "Cinemeta enabled" : "None yet"
                )
                Rule(color: Theme.Palette.border)
                summaryRow(
                    label: "Installed addons",
                    value: "\(store.addons.count + (installCinemeta && !hasCinemeta ? 1 : 0))"
                )
                Rule(color: Theme.Palette.border)
                summaryRow(
                    label: "Audio / Subtitles",
                    value: "\(languageName(prefs.preferredAudioLang)) / \(languageName(prefs.preferredSubtitleLang))"
                )
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.Palette.surface)
            .overlay(Rectangle().stroke(Theme.Palette.hairline, lineWidth: 1))

            HStack(spacing: Theme.Spacing.md) {
                FrameButton(title: "Open Live TV setup", icon: "dot.radiowaves.left.and.right") {
                    Task { await completeOnboarding(goToTab: .iptv) }
                }
                FrameButton(title: "Open Sources", icon: "puzzlepiece.extension") {
                    Task { await completeOnboarding(goToTab: .addons) }
                }
            }
        }
    }

    // MARK: - Helpers

    private func onboardingHintCard(icon: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.accentText)
            Text(title.localized)
                .font(Theme.Font.label(13, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(detail.localized)
                .font(Theme.Font.caption(11))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Palette.surface)
        .overlay(Rectangle().stroke(Theme.Palette.hairline, lineWidth: 1))
    }

    private func summaryRow(label: String, value: String) -> some View {
        HStack {
            Text(label.localized)
                .font(Theme.Font.label(13, weight: .medium))
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Text(value.localized)
                .font(Theme.Font.mono(12, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
        }
    }

    private func languageName(_ code: String) -> String {
        UserPrefs.supportedLanguages.first(where: { $0.code == code })?.name ?? "Automatic"
    }

    private func signInAndImportStremio() async {
        let email = stremioEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !stremioPassword.isEmpty else { return }
        isImportingStremio = true
        stremioFeedback = nil
        await stremio.signIn(email: email, password: stremioPassword)
        guard stremio.isConnected else {
            isImportingStremio = false
            return
        }
        stremioPassword = ""
        await importFromStremio()
    }

    private func importFromStremio() async {
        isImportingStremio = true
        defer { isImportingStremio = false }
        let existing = Set(store.addons.map { $0.manifest.transportUrl })
        let urls = await stremio.addonURLs(excluding: existing)
        var added = 0
        for url in urls {
            let before = store.addons.count
            await store.installAddon(url: url)
            if store.addons.count > before { added += 1 }
        }
        await stremio.importLibrary(into: watch)
        let libSummary = stremio.lastResult ?? ""
        stremioFeedback = libSummary.isEmpty
            ? String(localized: "\(added) addons imported.")
            : String(localized: "\(added) addons imported · \(libSummary)")
    }

    private func installCustomAddon() async {
        let trimmed = customAddonURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isInstallingAddon = true
        addonError = nil
        addonFeedback = nil
        let before = store.addons.count
        await store.installAddon(url: trimmed)
        isInstallingAddon = false
        if store.addons.count > before {
            addonFeedback = String(localized: "Addon installed.")
            customAddonURL = ""
        } else if let err = store.lastError {
            addonError = err
        } else {
            addonFeedback = String(localized: "Addon already installed.")
            customAddonURL = ""
        }
    }

    private func completeOnboarding(goToTab: NavItem?) async {
        isFinishing = true
        if installCinemeta && !hasCinemeta {
            await store.installAddon(url: Self.cinemetaURL)
        }
        prefs.hasCompletedOnboarding = true
        isFinishing = false
        onFinish(goToTab)
    }
}
