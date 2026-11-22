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
        static let onboardingDone = "veltrio.pref.onboardingDone"
        static let autoCheckUpdates = "veltrio.pref.autoCheckUpdates"
        static let appLanguage = "veltrio.pref.appLanguage"
        static let subtitleScale = "veltrio.pref.subtitleScale"
        static let subtitleColor = "veltrio.pref.subtitleColor"
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
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboardingDone) }
    }
    var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) }
    }
    /// "" = follow system, "fr" = Français, "en" = English.
    var appLanguage: String {
        didSet {
            defaults.set(appLanguage, forKey: Keys.appLanguage)
            AppLocalization.overrideCode = appLanguage
        }
    }
    var subtitleScale: Double {
        didSet { defaults.set(subtitleScale, forKey: Keys.subtitleScale) }
    }
    var subtitleColor: String {
        didSet { defaults.set(subtitleColor, forKey: Keys.subtitleColor) }
    }
    var resolvedLocale: Locale {
        appLanguage.isEmpty ? .autoupdatingCurrent : Locale(identifier: appLanguage)
    }

    static let appLanguages: [(code: String, label: String)] = [
        ("", "Automatic"),
        ("fr", "Français"),
        ("en", "English"),
        ("es", "Español"),
        ("de", "Deutsch"),
        ("it", "Italiano"),
    ]

    static let subtitleScales: [(value: Double, label: String)] = [
        (0.75, "Small"),
        (1.0, "Normal"),
        (1.25, "Large"),
        (1.5, "Extra large"),
    ]

    static let subtitleColors: [(value: String, label: String)] = [
        ("#FFFFFFFF", "White"),
        ("#FFFFE066", "Yellow"),
        ("#FFD0D0D0", "Light gray"),
    ]

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
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboardingDone)
        autoCheckUpdates       = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        let savedLang          = defaults.string(forKey: Keys.appLanguage) ?? ""
        appLanguage            = savedLang
        AppLocalization.overrideCode = savedLang
        subtitleScale          = (defaults.object(forKey: Keys.subtitleScale) as? Double) ?? 1.0
        subtitleColor          = defaults.string(forKey: Keys.subtitleColor) ?? "#FFFFFFFF"
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
