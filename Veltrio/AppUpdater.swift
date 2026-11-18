import Foundation
import Sparkle

/// Sparkle updates, when the build carries a feed and a signing key.
///
/// A build without them (local and debug builds) never starts the
/// updater: Sparkle would otherwise refuse to run, or check a feed that
/// doesn't exist. The "Check for Updates…" menu item is disabled then.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController?

    var isConfigured: Bool { controller != nil }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        controller = feed.isEmpty || key.isEmpty
            ? nil
            : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
