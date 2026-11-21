import Foundation

/// The last channel list of each playlist (one per Xtream section), kept
/// on disk: a launch shows it at once instead of asking the provider again.
/// Providers limit requests and connections, and fetching 20,000 channels
/// at every launch got users blocked (HTTP 511). The list is refreshed in
/// the background once it's older than `maxAge`, or on demand.
///
/// Xtream passwords stay in the Keychain: stream URLs carry the password
/// in their path, so it's stored as a placeholder and put back on load.
enum IptvChannelCache {
    static let maxAge: TimeInterval = 12 * 3600

    struct Entry {
        let channels: [IptvChannel]
        let savedAt: Date
        var isFresh: Bool { Date().timeIntervalSince(savedAt) < IptvChannelCache.maxAge }
    }

    private struct Stored: Codable {
        let savedAt: Date
        let channels: [Channel]
    }

    private struct Channel: Codable {
        let id: String
        let name: String
        let streamUrl: String
        let logoUrl: String?
        let group: String?
        let tvgId: String?
        let tvgName: String?
        let tvgCountry: String?
        let tvgLanguage: String?
    }

    private static let passwordToken = "{veltrio-password}"

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Veltrio/IptvChannels", isDirectory: true)
    }

    static func file(for playlistId: UUID, section: String) -> URL {
        directory.appendingPathComponent("\(playlistId.uuidString)-\(section).json")
    }

    /// The `/user/password/` segment of an Xtream stream URL.
    private static func secretSegment(_ ref: IptvPlaylistRef) -> (plain: String, masked: String)? {
        guard let creds = ref.xtream, !creds.password.isEmpty else { return nil }
        return ("/\(creds.username)/\(creds.password)/", "/\(creds.username)/\(passwordToken)/")
    }

    static func load(_ ref: IptvPlaylistRef, section: String) async -> Entry? {
        let url = file(for: ref.id, section: section)
        let secret = secretSegment(ref)
        return await Task.detached(priority: .userInitiated) { () -> Entry? in
            guard let data = try? Data(contentsOf: url),
                  let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
            let channels = stored.channels.map { c in
                IptvChannel(id: c.id, name: c.name,
                            streamUrl: secret.map { c.streamUrl.replacingOccurrences(of: $0.masked, with: $0.plain) } ?? c.streamUrl,
                            logoUrl: c.logoUrl, group: c.group, tvgId: c.tvgId, tvgName: c.tvgName,
                            tvgCountry: c.tvgCountry, tvgLanguage: c.tvgLanguage)
            }
            return Entry(channels: channels, savedAt: stored.savedAt)
        }.value
    }

    @discardableResult
    static func save(_ channels: [IptvChannel], for ref: IptvPlaylistRef, section: String) -> Task<Void, Never> {
        let url = file(for: ref.id, section: section)
        let secret = secretSegment(ref)
        return Task.detached(priority: .utility) {
            let stored = Stored(savedAt: Date(), channels: channels.map { c in
                Channel(id: c.id, name: c.name,
                        streamUrl: secret.map { c.streamUrl.replacingOccurrences(of: $0.plain, with: $0.masked) } ?? c.streamUrl,
                        logoUrl: c.logoUrl, group: c.group, tvgId: c.tvgId, tvgName: c.tvgName,
                        tvgCountry: c.tvgCountry, tvgLanguage: c.tvgLanguage)
            })
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Every cached list of a playlist (all sections), with its guide.
    static func remove(playlistId: UUID) {
        let prefix = playlistId.uuidString
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
