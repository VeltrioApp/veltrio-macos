import Foundation

/// Where we store installed addons. For MVP: JSON file in Application Support.
/// Later this moves into the Rust core (SQLite) so it syncs across devices.
struct AddonPersistence {
    private let fileURL: URL
    private let disabledURL: URL

    init(fileURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Veltrio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = fileURL ?? dir.appendingPathComponent("addons.json")
        self.disabledURL = dir.appendingPathComponent("addons-disabled.json")
    }

    func load() -> [InstalledAddon] {
        guard let data = try? Data(contentsOf: fileURL) else {
            return Self.defaultAddons()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dtos = (try? decoder.decode([InstalledAddonDTO].self, from: data)) ?? []
        return dtos.map { $0.toModel() }
    }

    func save(_ addons: [InstalledAddon]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dtos = addons.map(InstalledAddonDTO.init)
        guard let data = try? encoder.encode(dtos) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func loadDisabled() -> Set<String> {
        guard let data = try? Data(contentsOf: disabledURL),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(list)
    }

    func saveDisabled(_ ids: Set<String>) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(ids).sorted()) else { return }
        try? data.write(to: disabledURL, options: .atomic)
    }

    /// Nothing is installed by default; the empty state in SourcesView walks
    /// the user through adding Cinemeta (the canonical Stremio catalog) in
    /// one tap.
    static func defaultAddons() -> [InstalledAddon] { [] }

    static let suggestedAddons: [SuggestedAddon] = [
        .init(name: "Cinemeta", url: "https://v3-cinemeta.strem.io/manifest.json",
              blurb: "Official catalogs for movies and series (TMDB-powered)."),
        .init(name: "OpenSubtitles v3", url: "https://opensubtitles-v3.strem.io/manifest.json",
              blurb: "Subtitles in 50+ languages."),
        .init(name: "WatchHub", url: "https://watchhub.strem.io/manifest.json",
              blurb: "Legal streaming links from Apple TV, Prime, etc.")
    ]
}

struct SuggestedAddon: Identifiable, Hashable {
    let name: String
    let url: String
    let blurb: String
    var id: String { url }
}
