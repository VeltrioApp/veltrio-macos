import Foundation
import Security

/// Minimal Keychain wrapper for storing provider API keys and other
/// per-account secrets. Items are written with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so they're never synced
/// to another device via iCloud backups.
///
/// In macOS Debug builds (ad-hoc signed), every rebuild changes the binary's
/// cdhash and triggers a macOS Keychain password prompt for every stored key.
/// Debug macOS builds therefore store secrets in a user-only (0600) JSON file
/// under Application Support instead; Release macOS and all iOS/tvOS builds
/// always use the system Keychain.
enum Keychain {
    private static let accessGroup: String? = nil

    @discardableResult
    static func set(_ value: String, service: String, account: String = "default") -> Bool {
        #if os(macOS) && DEBUG
        return DebugSecretFile.set(value, service: service, account: account)
        #else
        let data = Data(value.utf8)
        // Try an update first; fall back to add. This keeps the write
        // atomic — a crash between delete+add would otherwise lose the key.
        let lookup: [String: Any] = baseQuery(service: service, account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(lookup as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var add = lookup
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
        #endif
    }

    static func get(service: String, account: String = "default") -> String? {
        #if os(macOS) && DEBUG
        return DebugSecretFile.get(service: service, account: account)
        #else
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
        #endif
    }

    static func delete(service: String, account: String = "default") {
        #if os(macOS) && DEBUG
        DebugSecretFile.delete(service: service, account: account)
        #else
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        #endif
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = accessGroup { q[kSecAttrAccessGroup as String] = group }
        return q
    }
}

#if os(macOS) && DEBUG
private enum DebugSecretFile {
    private static let lock = NSLock()

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Veltrio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug-secrets.json")
    }

    private static func key(_ service: String, _ account: String) -> String {
        "\(service)::\(account)"
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func save(_ dict: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(dict) else { return false }
        let target = url
        do {
            try data.write(to: target, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return true
        } catch {
            return false
        }
    }

    static func get(service: String, account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return load()[key(service, account)]
    }

    static func set(_ value: String, service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var dict = load()
        dict[key(service, account)] = value
        return save(dict)
    }

    static func delete(service: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        var dict = load()
        dict.removeValue(forKey: key(service, account))
        _ = save(dict)
    }
}
#endif

enum DebridProvider: String, CaseIterable, Identifiable {
    case realDebrid
    case allDebrid
    case premiumize
    case torbox
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .realDebrid: "Real-Debrid"
        case .allDebrid:  "AllDebrid"
        case .premiumize: "Premiumize"
        case .torbox:     "TorBox"
        }
    }
    var keychainService: String {
        switch self {
        case .realDebrid: "com.veltrio.debrid.realdebrid"
        case .allDebrid:  "com.veltrio.debrid.alldebrid"
        case .premiumize: "com.veltrio.debrid.premiumize"
        case .torbox:     "com.veltrio.debrid.torbox"
        }
    }
    var brandColorHex: UInt32 {
        switch self {
        case .realDebrid: 0x6CAD3E
        case .allDebrid:  0x16A34A
        case .premiumize: 0xFFA200
        case .torbox:     0x4EA2FF
        }
    }
    var shortTagline: String {
        switch self {
        case .realDebrid: "The classic — EU + US servers, deep catalog."
        case .allDebrid:  "European service with a generous cache window."
        case .premiumize: "Cloud downloads and reader-mode torrent indexer."
        case .torbox:     "Newer service, Usenet + torrents, fast mirrors."
        }
    }
}
