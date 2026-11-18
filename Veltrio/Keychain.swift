import Foundation
import Security

/// Minimal Keychain wrapper for storing provider API keys and other
/// per-account secrets. Items are written with
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so they're never synced
/// to another device via iCloud backups.
enum Keychain {
    private static let accessGroup: String? = nil

    @discardableResult
    static func set(_ value: String, service: String, account: String = "default") -> Bool {
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
    }

    static func get(service: String, account: String = "default") -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func delete(service: String, account: String = "default") {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
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
