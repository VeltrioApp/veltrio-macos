import Foundation

extension String {
    /// This string looked up in the app's string catalog, or itself when
    /// it isn't there.
    ///
    /// For text that reaches a view as a `String` — component titles, enum
    /// labels — rather than as a literal SwiftUI can localize on its own.
    /// Names from outside the app (addons, catalogs, servers) have no
    /// entry and come back unchanged. Unlike `LocalizedStringKey`, this
    /// never reads `%` in the text as a format specifier.
    var localized: String {
        Bundle.main.localizedString(forKey: self, value: self, table: nil)
    }
}
