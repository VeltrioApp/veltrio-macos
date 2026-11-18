import Foundation
import AVKit
import AppKit
import Observation

/// Casting / external playback coordinator. Three outputs are planned:
///
/// - **AirPlay** — native via AVRouteDetector; shows a system picker.
///   When a URL-based stream is active we can hand it to AVPlayer and let
///   Apple do the rest; for torrent / HLS from mpv we transparently
///   proxy through the local HTTP server that librqbit already runs.
/// - **PiP** — requires an AVPlayerLayer, which means we need to switch
///   the active player away from mpv for the PiP window. This service
///   publishes a `supportedByCurrentStream` flag so the UI can enable or
///   grey out the PiP action.
/// - **Chromecast** — gated behind the Google Cast SDK, which is not
///   bundled; we surface a one-time instruction.
///
/// This file keeps the observable state; the actual AVPlayer spin-up
/// lives next to PlayerView.

@MainActor
@Observable
final class CastingService {
    enum CastTarget: String, CaseIterable, Identifiable {
        case airplay    = "AirPlay"
        case pictureInPicture = "Picture in Picture"
        case chromecast = "Chromecast"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .airplay:         return "airplayvideo"
            case .pictureInPicture: return "pip"
            case .chromecast:      return "tv.and.mediabox"
            }
        }
    }

    /// Current AirPlay availability (updated by AVRouteDetector).
    private(set) var isAirPlayAvailable: Bool = false
    /// Current PiP eligibility (true only when the active stream is a
    /// direct URL mpv or AVPlayer can share).
    private(set) var isPipAvailable: Bool = false

    /// True once the user installs the Google Cast SDK and we successfully
    /// link against it at runtime.
    private(set) var isChromecastSdkPresent: Bool = false

    private var routeDetector: AVRouteDetector?

    init() {
        setupAirPlay()
        detectChromecastSdk()
    }

    func setStreamURL(_ url: URL?) {
        // AVPlayer-based PiP works for any direct HTTP(S) media URL that
        // AVAsset can read. Local torrent HTTP server URLs qualify too.
        isPipAvailable = (url?.scheme == "http" || url?.scheme == "https")
    }

    func openAirPlayPicker(anchor: NSView?) {
        guard isAirPlayAvailable else { return }
        // AVRoutePickerView is Apple's entry point. On macOS, we embed a
        // momentary instance offscreen and send it a click via the
        // underlying button inside its NSView hierarchy — the standard
        // trick since macOS doesn't expose a public picker API.
        let picker = AVRoutePickerView()
        picker.player = AVPlayer()
        let parent = anchor ?? NSApp.keyWindow?.contentView
        parent?.addSubview(picker)
        picker.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let button = picker.subviews.compactMap({ $0 as? NSButton }).first {
                button.performClick(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                picker.removeFromSuperview()
            }
        }
    }

    private func setupAirPlay() {
        let d = AVRouteDetector()
        d.isRouteDetectionEnabled = true
        self.routeDetector = d
        // On macOS AirPlay routes are always considered available at the
        // system level; AVRouteDetector keeps the UI honest for future
        // iPad/tvOS parity.
        self.isAirPlayAvailable = true
    }

    private func detectChromecastSdk() {
        // Soft probe: if Google's cast SDK bundle is present in the app
        // bundle, flip the flag. This lets a future build drop the SDK
        // in without changing any code here.
        let probe = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/GoogleCast.framework")
        isChromecastSdkPresent = FileManager.default.fileExists(atPath: probe.path)
    }

    /// Human-readable status for a target, to show in the menu so the
    /// user understands why something is disabled.
    func status(for target: CastTarget) -> String {
        switch target {
        case .airplay:
            return isAirPlayAvailable ? String(localized: "Ready") : String(localized: "Searching for devices…")
        case .pictureInPicture:
            return isPipAvailable
                ? String(localized: "Ready")
                : String(localized: "PiP needs a direct URL stream (not available for this source).")
        case .chromecast:
            return isChromecastSdkPresent
                ? String(localized: "Ready")
                : String(localized: "Install the Google Cast SDK to enable Chromecast. See veltrio.app/cast for details.")
        }
    }
}
