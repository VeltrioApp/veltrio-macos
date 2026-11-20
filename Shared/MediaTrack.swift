import Foundation

/// One audio or subtitle track reported by mpv.
struct MediaTrack: Hashable, Identifiable {
    let id: Int64        // mpv track id (≥ 1); 0 means "none"
    let lang: String?
    let title: String?
    let codec: String?
    let isDefault: Bool
    let isForced: Bool

    /// Best-effort human name shown in the picker.
    var displayName: String {
        if let title, !title.isEmpty { return title }
        if let lang, !lang.isEmpty { return Self.languageName(for: lang) }
        return String(localized: "Track \(id)")
    }

    /// Side caption below the main label (codec / lang code fallback).
    var secondaryLabel: String? {
        var parts: [String] = []
        if let lang, !lang.isEmpty, title != nil { parts.append(lang.uppercased()) }
        if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        if isDefault { parts.append("Default") }
        if isForced   { parts.append("Forced") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Maps the most common ISO 639-2 codes to readable names. mpv tends
    /// to emit 3-letter codes (eng, fra, spa, …) — the two-letter cases
    /// are kept as a safety net.
    static func languageName(for code: String) -> String {
        let normalized = code.lowercased()
        let map: [String: String] = [
            "eng": "English",  "en": "English",
            "fre": "French",   "fra": "French",   "fr": "French",
            "spa": "Spanish",  "es": "Spanish",
            "ger": "German",   "deu": "German",   "de": "German",
            "ita": "Italian",  "it": "Italian",
            "por": "Portuguese","pt": "Portuguese",
            "rus": "Russian",  "ru": "Russian",
            "jpn": "Japanese", "ja": "Japanese",
            "kor": "Korean",   "ko": "Korean",
            "chi": "Chinese",  "zho": "Chinese",  "zh": "Chinese",
            "ara": "Arabic",   "ar": "Arabic",
            "dut": "Dutch",    "nld": "Dutch",    "nl": "Dutch",
            "swe": "Swedish",  "sv": "Swedish",
            "pol": "Polish",   "pl": "Polish",
            "tur": "Turkish",  "tr": "Turkish",
            "hin": "Hindi",    "hi": "Hindi",
        ]
        return map[normalized] ?? normalized.uppercased()
    }
}
