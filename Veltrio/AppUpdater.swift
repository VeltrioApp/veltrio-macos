import AppKit
import Foundation
import Observation
import Sparkle

/// macOS auto-updater: uses Sparkle when the build carries a feed URL and
/// EdDSA public key, and falls back to checking GitHub Releases otherwise
/// (e.g. ad-hoc signed releases or local builds) so users always get update
/// notifications and one-click downloads.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    struct AvailableUpdate: Equatable {
        let version: String
        let downloadURL: URL
        let releaseURL: URL
    }

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case failed(String)
    }

    private let controller: SPUStandardUpdaterController?
    private let lastCheckKey = "veltrio.updater.lastCheck"
    private let releasesAPI = URL(string: "https://api.github.com/repos/VeltrioApp/veltrio-macos/releases?per_page=1")!

    private(set) var status: Status = .idle
    var bannerDismissed = false

    var usesSparkle: Bool { controller != nil }

    var availableUpdate: AvailableUpdate? {
        if case .available(let u) = status { return u }
        return nil
    }

    var automaticallyChecks: Bool {
        get {
            if let updater = controller?.updater {
                return updater.automaticallyChecksForUpdates
            }
            return UserPrefs.shared.autoCheckUpdates
        }
        set {
            UserPrefs.shared.autoCheckUpdates = newValue
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String) ?? ""
        let key = (info["SUPublicEDKey"] as? String) ?? ""
        if !feed.isEmpty && !key.isEmpty {
            let ctrl = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
            ctrl.updater.automaticallyChecksForUpdates = UserPrefs.shared.autoCheckUpdates
            controller = ctrl
        } else {
            controller = nil
        }
    }

    /// Runs a quiet background check on launch (throttled to once every 12h)
    /// when Sparkle is not handling it.
    func checkOnLaunchIfNeeded() {
        guard !usesSparkle, UserPrefs.shared.autoCheckUpdates else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        let twelveHours: TimeInterval = 12 * 3600
        if Date().timeIntervalSince1970 - last < twelveHours { return }
        Task { await checkGitHubRelease(silent: true) }
    }

    /// Triggered by the menu bar item or Settings → About.
    func checkForUpdates() {
        if let controller {
            controller.checkForUpdates(nil)
            return
        }
        bannerDismissed = false
        Task { await checkGitHubRelease(silent: false) }
    }

    func openDownload() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.downloadURL)
    }

    private func checkGitHubRelease(silent: Bool) async {
        if !silent { status = .checking }
        var req = URLRequest(url: releasesAPI)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Veltrio/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                if !silent { status = .failed(String(localized: "Could not reach GitHub Releases.")) }
                return
            }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
            struct Release: Decodable {
                let tag_name: String
                let html_url: String
                let draft: Bool
                let assets: [Asset]
            }

            let releases = try JSONDecoder().decode([Release].self, from: data)
            guard let latest = releases.first(where: { !$0.draft }) else {
                if !silent { status = .upToDate }
                return
            }

            let latestTag = latest.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if Self.isNewer(latestTag, than: currentVersion),
               let releaseURL = URL(string: latest.html_url) {
                let dmgURL = latest.assets
                    .first(where: { $0.name.hasSuffix(".dmg") })
                    .flatMap { URL(string: $0.browser_download_url) } ?? releaseURL
                status = .available(AvailableUpdate(
                    version: latestTag,
                    downloadURL: dmgURL,
                    releaseURL: releaseURL
                ))
            } else if !silent {
                status = .upToDate
            }
        } catch {
            if !silent {
                status = .failed(error.localizedDescription)
            }
        }
    }

    /// Compares dotted numeric version strings (e.g. "0.2.1" > "0.2.0").
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let core = s.split(separator: "-").first.map(String.init) ?? s
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate)
        let b = parts(current)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}
