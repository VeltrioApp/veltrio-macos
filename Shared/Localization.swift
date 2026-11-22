import Foundation

enum AppLocalization {
    nonisolated(unsafe) static var overrideCode: String = ""

    static func bundle() -> Bundle {
        let code = overrideCode
        guard !code.isEmpty,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let b = Bundle(path: path)
        else { return .main }
        return b
    }

    static var isFrench: Bool {
        switch overrideCode {
        case "fr": return true
        case "en": return false
        default: return Locale.preferredLanguages.first?.hasPrefix("fr") ?? false
        }
    }
}

extension String {
    /// This string looked up in the app's string catalog (respecting the
    /// user's in-app language override when set), or itself when absent.
    var localized: String {
        AppLocalization.bundle().localizedString(forKey: self, value: self, table: nil)
    }
}
