import SwiftUI

@main
struct VeltrioApp: App {
    @State private var store: AppStore
    @State private var watch = WatchStore()
    @State private var prefs = UserPrefs.shared

    init() {
        initLogging()
        CrashReports.shared.start()
        _ = AppUpdater.shared
        _store = State(initialValue: AppStore())
    }

    var body: some Scene {
        WindowGroup("Veltrio") {
            RootView()
                .environment(store)
                .environment(watch)
                .environment(\.locale, prefs.resolvedLocale)
                .frame(minWidth: 960, minHeight: 620)
                // The theme preference is applied by RootView, which is
                // deeper in the hierarchy and therefore wins. Forcing
                // `.dark` here as well would fight it.
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { AppUpdater.shared.checkForUpdates() }
            }
            CommandGroup(after: .appSettings) {
                Divider()
                Text("Veltrio") // category hint
            }
            CommandMenu("Go") {
                // Labels match the nav tabs exactly, so the menu and the
                // tab bar never disagree about what a section is called.
                Button("Home")      { NotificationCenter.default.post(name: .veltrioGoto, object: NavItem.home) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Collection") { NotificationCenter.default.post(name: .veltrioGoto, object: NavItem.library) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Live")      { NotificationCenter.default.post(name: .veltrioGoto, object: NavItem.iptv) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Sources")   { NotificationCenter.default.post(name: .veltrioGoto, object: NavItem.addons) }
                    .keyboardShortcut("4", modifiers: .command)
                Divider()
                Button("Search") { NotificationCenter.default.post(name: .veltrioOpenSearch, object: nil) }
                    .keyboardShortcut("k", modifiers: .command)
            }
            CommandMenu("Playback") {
                // These drive whichever player is on screen. They are
                // disabled when nothing is playing so the menu never
                // looks like it does something it can't.
                //
                // Deliberately no key equivalents on these items. A macOS
                // menu key equivalent is matched app-wide and *before* the
                // focused view sees the key, so a bare Space here would eat
                // the space key while typing in the Search field or in a
                // settings text field. The player binds Space and the
                // arrows itself with `onKeyPress`, which only fires while
                // the player is on screen and never steals from a field.
                Button("Play / Pause") {
                    ActivePlayback.shared.controller?.togglePause()
                }
                .disabled(ActivePlayback.shared.controller == nil)

                Button("Skip Back 10 s") {
                    ActivePlayback.shared.controller?.skip(by: -10)
                }
                .disabled(ActivePlayback.shared.controller == nil)

                Button("Skip Forward 10 s") {
                    ActivePlayback.shared.controller?.skip(by: 10)
                }
                .disabled(ActivePlayback.shared.controller == nil)
            }
        }
    }
}
