import Foundation

enum AppLocalization {
    nonisolated(unsafe) static var overrideCode: String = ""

    static var resolvedCode: String {
        if !overrideCode.isEmpty { return overrideCode }
        let sys = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if sys.hasPrefix("fr") { return "fr" }
        if sys.hasPrefix("es") { return "es" }
        if sys.hasPrefix("de") { return "de" }
        if sys.hasPrefix("it") { return "it" }
        return "en"
    }

    static var isFrench: Bool { resolvedCode == "fr" }

    static func tmdbLanguage(for code: String) -> String {
        switch code {
        case "fr": return "fr-FR"
        case "en": return "en-US"
        case "es": return "es-ES"
        case "de": return "de-DE"
        case "it": return "it-IT"
        default: return tmdbLanguage(for: resolvedCode)
        }
    }

    static func bundle() -> Bundle {
        let code = overrideCode
        guard !code.isEmpty,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let b = Bundle(path: path)
        else { return .main }
        return b
    }

    /// Lightweight built-in translations for ES / DE / IT on core UI strings
    /// (FR & EN come from Localizable.xcstrings).
    static let extra: [String: [String: String]] = [
        "es": [
            "Home": "Inicio", "Collection": "Colección", "Live": "En directo", "Sources": "Fuentes",
            "Search": "Buscar", "Settings": "Ajustes", "Appearance": "Apariencia", "Language": "Idioma",
            "Playback": "Reproducción", "Storage": "Almacenamiento", "About": "Acerca de",
            "Continue Watching": "Seguir viendo", "Watch now": "Ver ahora", "Resume": "Reanudar",
            "Details": "Detalles", "Save": "Guardar", "In library": "En biblioteca",
            "Trailer": "Tráiler", "More like this": "Títulos similares", "Subtitles": "Subtítulos",
            "Audio": "Audio", "Off": "Desactivado", "Automatic": "Automático",
            "Small": "Pequeño", "Normal": "Normal", "Large": "Grande", "Extra large": "Muy grande",
            "White": "Blanco", "Yellow": "Amarillo", "Light gray": "Gris claro",
            "Subtitle size": "Tamaño de subtítulos", "Subtitle color": "Color de subtítulos",
            "Search OpenSubtitles": "Buscar en OpenSubtitles", "Skip intro": "Saltar intro",
            "Favorites": "Favoritos", "Movies": "Películas", "Series": "Series", "Back": "Atrás",
        ],
        "de": [
            "Home": "Startseite", "Collection": "Sammlung", "Live": "Live-TV", "Sources": "Quellen",
            "Search": "Suchen", "Settings": "Einstellungen", "Appearance": "Erscheinungsbild", "Language": "Sprache",
            "Playback": "Wiedergabe", "Storage": "Speicher", "About": "Über",
            "Continue Watching": "Weiterschauen", "Watch now": "Jetzt ansehen", "Resume": "Fortsetzen",
            "Details": "Details", "Save": "Speichern", "In library": "Gespeichert",
            "Trailer": "Trailer", "More like this": "Ähnliche Titel", "Subtitles": "Untertitel",
            "Audio": "Audio", "Off": "Aus", "Automatic": "Automatisch",
            "Small": "Klein", "Normal": "Normal", "Large": "Groß", "Extra large": "Sehr groß",
            "White": "Weiß", "Yellow": "Gelb", "Light gray": "Hellgrau",
            "Subtitle size": "Untertitelgröße", "Subtitle color": "Untertitelfarbe",
            "Search OpenSubtitles": "OpenSubtitles durchsuchen", "Skip intro": "Intro überspringen",
            "Favorites": "Favoriten", "Movies": "Filme", "Series": "Serien", "Back": "Zurück",
        ],
        "it": [
            "Home": "Home", "Collection": "Collezione", "Live": "Diretta", "Sources": "Sorgenti",
            "Search": "Cerca", "Settings": "Impostazioni", "Appearance": "Aspetto", "Language": "Lingua",
            "Playback": "Riproduzione", "Storage": "Archiviazione", "About": "Info",
            "Continue Watching": "Continua a guardare", "Watch now": "Guarda ora", "Resume": "Riprendi",
            "Details": "Dettagli", "Save": "Salva", "In library": "Salvato",
            "Trailer": "Trailer", "More like this": "Titoli simili", "Subtitles": "Sottotitoli",
            "Audio": "Audio", "Off": "Disattivati", "Automatic": "Automatico",
            "Small": "Piccolo", "Normal": "Normale", "Large": "Grande", "Extra large": "Molto grande",
            "White": "Bianco", "Yellow": "Giallo", "Light gray": "Grigio chiaro",
            "Subtitle size": "Dimensione sottotitoli", "Subtitle color": "Colore sottotitoli",
            "Search OpenSubtitles": "Cerca su OpenSubtitles", "Skip intro": "Salta sigla",
            "Favorites": "Preferiti", "Movies": "Film", "Series": "Serie", "Back": "Indietro",
        ],
    ]
}

extension String {
    /// This string looked up in the app's string catalog (respecting the
    /// user's in-app language override when set), or itself when absent.
    var localized: String {
        let code = AppLocalization.resolvedCode
        if let mapped = AppLocalization.extra[code]?[self] {
            return mapped
        }
        return AppLocalization.bundle().localizedString(forKey: self, value: self, table: nil)
    }
}
