import SwiftUI

// MARK: - Media server connection cards
//
// Jellyfin, Emby and Plex are *sources* — catalogues the app searches
// and plays from, exactly like a Stremio addon or an IPTV playlist.
// They used to live in Settings > Accounts, which buried them: the user
// could not tell that connecting a Jellyfin server was what put their
// personal library into search.
//
// They now live in the Sources tab, next to the other kinds of source.

// MARK: - Jellyfin connect card

struct JellyfinCard: View {
    @Environment(AppStore.self) private var store
    @State private var showSheet = false

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Rectangle().fill(Color(hex: 0x00A4DC)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Jellyfin").font(Theme.Font.heading(15))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        statusLabel
                    }
                    Spacer()
                    actionButton
                }
                Text(store.jellyfin.isConnected
                     ? "Your Jellyfin library is available in this session. Items appear in a future Library tab integration."
                     : "Point Veltrio at your Jellyfin server to stream your personal library through the same player.")
                    .font(Theme.Font.caption(11))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .sheet(isPresented: $showSheet) {
            JellyfinConnectSheet(isPresented: $showSheet)
                .macSheetFrame(minWidth: 480, idealWidth: 540, minHeight: 320)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        if store.jellyfin.isConnected {
            HStack(spacing: 4) {
                Text(store.jellyfin.username ?? "Connected")
                    .foregroundStyle(Theme.Palette.success)
                if !store.jellyfin.serverUrl.isEmpty {
                    Text("·").foregroundStyle(Theme.Palette.textTertiary)
                    Text(URL(string: store.jellyfin.serverUrl)?.host ?? "")
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .font(Theme.Font.body(12))
        } else {
            Text("Not connected")
                .font(Theme.Font.body(12))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if store.jellyfin.isConnected {
            FrameButton(title: "Disconnect",
                        icon: "arrow.right",
                        color: Theme.Palette.danger) {
                store.jellyfin.disconnect()
            }
        } else {
            FrameButton(title: "Connect",
                        icon: "arrow.right",
                        color: Theme.Palette.accent,
                        fill: Theme.Palette.accent) {
                showSheet = true
            }
        }
    }
}

struct JellyfinConnectSheet: View {
    @Binding var isPresented: Bool
    @Environment(AppStore.self) private var store
    @State private var host = ""
    @State private var user = ""
    @State private var pass = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Connect to Jellyfin")
                .font(Theme.Font.display(22, weight: .bold))
                .foregroundStyle(Theme.Palette.textPrimary)
            field("Server URL", text: $host, placeholder: "http://jellyfin.local:8096")
            field("Username", text: $user, placeholder: "")
            field("Password", text: $pass, placeholder: "", secure: true)
            if let err = store.jellyfin.connectionError {
                Text(err.localized).font(Theme.Font.caption(12))
                    .foregroundStyle(Theme.Palette.danger)
            }
            HStack {
                Spacer()
                FrameButton(title: "Cancel", icon: "xmark",
                            color: Theme.Palette.textPrimary) {
                    isPresented = false
                }
                FrameButton(title: "Connect",
                            icon: "arrow.right",
                            color: Theme.Palette.accent,
                            fill: Theme.Palette.accent,
                            isLoading: store.jellyfin.isConnecting,
                            isEnabled: !store.jellyfin.isConnecting && !host.isEmpty && !user.isEmpty) {
                    Task {
                        await store.jellyfin.connect(host: host, user: user, password: pass)
                        if store.jellyfin.isConnected { isPresented = false }
                    }
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .background(Theme.Palette.background)
    }

    @ViewBuilder
    private func field(_ label: String, text: Binding<String>, placeholder: String = "", secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.localized).eyebrow(Theme.Palette.textTertiary, tracking: 1.8)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(Theme.Font.body(14))
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1))
        }
    }
}

// MARK: - Emby card

struct EmbyCard: View {
    @Environment(AppStore.self) private var store
    @State private var showSheet = false
    @State private var host = ""
    @State private var user = ""
    @State private var pass = ""

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Rectangle().fill(Color(hex: 0x52B54B)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Emby").font(Theme.Font.heading(15))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        if store.emby.isConnected {
                            Text(store.emby.username ?? "Connected")
                                .font(Theme.Font.body(12))
                                .foregroundStyle(Theme.Palette.success)
                        } else {
                            Text("Not connected")
                                .font(Theme.Font.body(12))
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                    Spacer()
                    if store.emby.isConnected {
                        FrameButton(title: "Disconnect",
                                    icon: "arrow.right",
                                    color: Theme.Palette.danger) {
                            store.emby.disconnect()
                        }
                    } else {
                        FrameButton(title: "Connect",
                                    icon: "arrow.right",
                                    color: Theme.Palette.accent,
                                    fill: Theme.Palette.accent) {
                            showSheet = true
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showSheet) {
            sheet
                .macSheetFrame(minWidth: 480, idealWidth: 540, minHeight: 320)
        }
    }

    @ViewBuilder
    private var sheet: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Connect to Emby")
                .font(Theme.Font.display(22, weight: .bold))
                .foregroundStyle(Theme.Palette.textPrimary)
            textField("Server URL", $host, placeholder: "http://emby.local:8096")
            textField("Username",   $user)
            textField("Password",   $pass, secure: true)
            if let err = store.emby.connectionError {
                Text(err.localized).font(Theme.Font.caption(12))
                    .foregroundStyle(Theme.Palette.danger)
            }
            HStack {
                Spacer()
                FrameButton(title: "Cancel", icon: "xmark",
                            color: Theme.Palette.textPrimary) { showSheet = false }
                FrameButton(title: "Connect",
                            icon: "arrow.right",
                            color: Theme.Palette.accent,
                            fill: Theme.Palette.accent,
                            isLoading: store.emby.isConnecting,
                            isEnabled: !store.emby.isConnecting && !host.isEmpty && !user.isEmpty) {
                    Task {
                        await store.emby.connect(host: host, user: user, password: pass)
                        if store.emby.isConnected { showSheet = false }
                    }
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .background(Theme.Palette.background)
    }

    @ViewBuilder
    private func textField(_ label: String, _ text: Binding<String>, placeholder: String = "", secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.localized).eyebrow(Theme.Palette.textTertiary, tracking: 1.8)
            Group {
                if secure { SecureField(placeholder, text: text) }
                else { TextField(placeholder, text: text) }
            }
            .textFieldStyle(.plain)
            .font(Theme.Font.body(14))
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(Rectangle().stroke(Theme.Palette.borderStrong, lineWidth: 1))
        }
    }
}

// MARK: - Plex card

struct PlexCard: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Rectangle().fill(Color(hex: 0xE5A00D)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plex").font(Theme.Font.heading(15))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        if let u = store.plex.user {
                            Text(u.username)
                                .font(Theme.Font.body(12))
                                .foregroundStyle(Theme.Palette.success)
                        } else if store.plex.isConnected {
                            Text("Connected")
                                .font(Theme.Font.body(12))
                                .foregroundStyle(Theme.Palette.success)
                        } else {
                            Text("Not connected")
                                .font(Theme.Font.body(12))
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                    Spacer()
                    actionButton
                }
                if let pin = store.plex.pendingPin {
                    PlexPinView(pin: pin)
                }
                if let err = store.plex.connectionError {
                    Text(err.localized).font(Theme.Font.caption(12))
                        .foregroundStyle(Theme.Palette.danger)
                }
            }
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if store.plex.isConnected {
            FrameButton(title: "Disconnect",
                        icon: "arrow.right",
                        color: Theme.Palette.danger) { store.plex.disconnect() }
        } else if store.plex.pendingPin != nil {
            FrameButton(title: "Cancel", icon: "xmark",
                        color: Theme.Palette.textSecondary) { store.plex.cancelPinFlow() }
        } else {
            FrameButton(title: "Connect",
                        icon: "arrow.right",
                        color: Theme.Palette.accent,
                        fill: Theme.Palette.accent,
                        isLoading: store.plex.isConnecting,
                        isEnabled: !store.plex.isConnecting) {
                Task { await store.plex.startPinFlow() }
            }
        }
    }
}

struct PlexPinView: View {
    let pin: PlexPin

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Rule()
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                VStack(spacing: 4) {
                    Text("Code").eyebrow(Theme.Palette.textTertiary, tracking: 1.6)
                    Text(pin.code)
                        .font(Theme.Font.mono(22, weight: .heavy))
                        .foregroundStyle(Theme.Palette.accentText)
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .overlay(Rectangle().stroke(Theme.Palette.accent.opacity(0.4), lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Link your Plex account")
                        .font(Theme.Font.heading(14))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Visit plex.tv/link, enter the code. Veltrio is polling and will connect automatically.")
                        .font(Theme.Font.body(12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    HStack(spacing: Theme.Spacing.sm) {
                        FrameButton(title: "Open plex.tv/link",
                                    icon: "arrow.up.right",
                                    color: Theme.Palette.accent,
                                    fill: Theme.Palette.accent) {
                            if let u = URL(string: "https://plex.tv/link?code=\(pin.code)") {
                                Platform.open(u)
                            }
                        }
                        FrameButton(title: "Copy code",
                                    icon: "doc.on.doc",
                                    color: Theme.Palette.textPrimary) {
                            Platform.copy(pin.code)
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
