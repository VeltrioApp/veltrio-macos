import Foundation
import Observation

/// Lightweight user preferences backed by UserDefaults. Observed by views
/// so changing a preference in Settings reflects immediately everywhere.
///
/// Scope is narrow: things the player and downloader need to know about
/// per-user defaults. Anything bigger (library, addons) lives in its own
/// store.
@MainActor
@Observable
final class UserPrefs {
    static let shared = UserPrefs()

    private let defaults = UserDefaults.standard
    private struct Keys {
        static let preferredAudioLang = "veltrio.pref.audioLang"
        static let preferredSubtitleLang = "veltrio.pref.subLang"
        static let autoplayNext = "veltrio.pref.autoplayNext"
        static let hwdec = "veltrio.pref.hwdec"
        static let cacheMiB = "veltrio.pref.cacheMiB"
        static let reduceMotion = "veltrio.pref.reduceMotion"
        static let colorScheme  = "veltrio.pref.colorScheme"
    }

    enum ColorSchemePreference: String, CaseIterable, Identifiable {
        case system, dark, light
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: "Match system"
            case .dark:   "Nightfall (dark)"
            case .light:  "Daybreak (light)"
            }
        }
    }

    /// ISO-639 language code. Empty = no preference.
    var preferredAudioLang: String {
        didSet { defaults.set(preferredAudioLang, forKey: Keys.preferredAudioLang) }
    }
    var preferredSubtitleLang: String {
        didSet { defaults.set(preferredSubtitleLang, forKey: Keys.preferredSubtitleLang) }
    }
    var autoplayNextEpisode: Bool {
        didSet { defaults.set(autoplayNextEpisode, forKey: Keys.autoplayNext) }
    }
    var hwdec: String {
        didSet { defaults.set(hwdec, forKey: Keys.hwdec) }
    }
    var cacheMiB: Int {
        didSet { defaults.set(cacheMiB, forKey: Keys.cacheMiB) }
    }
    var reduceMotion: Bool {
        didSet { defaults.set(reduceMotion, forKey: Keys.reduceMotion) }
    }
    var colorScheme: ColorSchemePreference {
        didSet { defaults.set(colorScheme.rawValue, forKey: Keys.colorScheme) }
    }

    private init() {
        preferredAudioLang   = defaults.string(forKey: Keys.preferredAudioLang) ?? ""
        preferredSubtitleLang = defaults.string(forKey: Keys.preferredSubtitleLang) ?? ""
        autoplayNextEpisode  = defaults.object(forKey: Keys.autoplayNext) as? Bool ?? true
        hwdec                = defaults.string(forKey: Keys.hwdec) ?? "auto-safe"
        cacheMiB             = (defaults.object(forKey: Keys.cacheMiB) as? Int) ?? 150
        reduceMotion         = defaults.object(forKey: Keys.reduceMotion) as? Bool ?? false
        colorScheme          = ColorSchemePreference(
            // A Mac follows the system; a phone starts in the dark theme,
            // the reference experience (as on Android).
            rawValue: defaults.string(forKey: Keys.colorScheme) ?? (Platform.isMac ? "system" : "dark")
        ) ?? .system
    }

    /// Readable list of language options for the Settings picker.
    static let supportedLanguages: [(code: String, name: String)] = [
        ("", "Automatic"),
        ("eng", "English"),
        ("fre", "French"),
        ("spa", "Spanish"),
        ("ger", "German"),
        ("ita", "Italian"),
        ("por", "Portuguese"),
        ("rus", "Russian"),
        ("jpn", "Japanese"),
        ("kor", "Korean"),
        ("chi", "Chinese"),
        ("ara", "Arabic"),
        ("dut", "Dutch"),
        ("swe", "Swedish"),
        ("pol", "Polish"),
        ("tur", "Turkish"),
        ("hin", "Hindi"),
    ]
}
