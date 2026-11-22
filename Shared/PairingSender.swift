import Foundation
import CryptoKit
#if os(iOS) || os(tvOS)
import UIKit
#endif

/// Sends this device's settings to a Veltrio TV on the same network (the
/// Android TV app's "Depuis un téléphone"), so it isn't set up again with a
/// remote. The protocol is the Android app's (see veltrio-android's README):
/// `GET /veltrio-pair` gives the TV's P-256 key; the AES-256-GCM key comes
/// from ECDH and HKDF-SHA256 with the TV's code as salt and
/// "veltrio-pair-v1" as info; `POST /veltrio-pair {publicKey, nonce, data}`
/// carries the settings, in the TV's format.
enum PairingSender {
    struct Target: Hashable, Identifiable {
        let name: String
        let host: String
        let port: Int
        var id: String { "\(host):\(port)" }
    }

    static let port = 8765

    /// "192.168.1.20" or "192.168.1.20:8765".
    static func manualTarget(_ address: String) -> Target? {
        let a = address.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return nil }
        if let colon = a.lastIndex(of: ":"), let p = Int(a[a.index(after: colon)...]) {
            return Target(name: a, host: String(a[..<colon]), port: p)
        }
        return Target(name: a, host: a, port: port)
    }

    enum Failure: LocalizedError {
        case wrongCode, unexpected, http(Int)
        var errorDescription: String? {
            switch self {
            case .wrongCode:   String(localized: "Wrong code: check the one shown on the TV.")
            case .unexpected:  String(localized: "Unexpected answer from the TV.")
            case .http(let c): String(localized: "The TV answered \(c).")
            }
        }
    }

    /// Sends and returns the TV's summary of what it took.
    static func send(_ bundle: [String: Any], to target: Target, code: String) async throws -> String {
        let host = target.host.contains(":") ? "[\(target.host)]" : target.host
        guard let url = URL(string: "http://\(host):\(target.port)/veltrio-pair") else { throw Failure.unexpected }

        let (helloData, _) = try await URLSession.shared.data(from: url)
        guard let hello = try JSONSerialization.jsonObject(with: helloData) as? [String: Any],
              let theirsB64 = hello["publicKey"] as? String, let theirsRaw = Data(base64Encoded: theirsB64) else {
            throw Failure.unexpected
        }
        let theirs = try P256.KeyAgreement.PublicKey(x963Representation: theirsRaw)
        let own = P256.KeyAgreement.PrivateKey()
        let key = try own.sharedSecretFromKeyAgreement(with: theirs).hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Data(code.trimmingCharacters(in: .whitespaces).utf8),
            sharedInfo: Data("veltrio-pair-v1".utf8), outputByteCount: 32)
        let plain = try JSONSerialization.data(withJSONObject: bundle)
        let sealed = try AES.GCM.seal(plain, using: key)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "publicKey": own.publicKey.x963Representation.base64EncodedString(),
            "nonce": Data(sealed.nonce).base64EncodedString(),
            "data": (sealed.ciphertext + sealed.tag).base64EncodedString(),
        ])
        request.timeoutInterval = 120
        let (answer, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 { throw Failure.wrongCode }
        guard status == 200 else { throw Failure.http(status) }
        return ((try? JSONSerialization.jsonObject(with: answer)) as? [String: Any])?["result"] as? String ?? ""
    }

    // MARK: - the bundle, in the TV's format

    @MainActor
    static func collect(store: AppStore, watch: WatchStore) -> [String: Any] {
        let defaults = UserDefaults.standard
        let addons = store.addons.map(\.manifest.transportUrl)
        let disabled = store.addons.filter { store.disabledAddonIds.contains($0.id) }.map(\.manifest.transportUrl)
        let playlists: [[String: Any]] = store.iptvPlaylists.compactMap { ref in
            if let x = ref.xtream {
                return ["name": ref.name, "url": "", "host": x.normalizedHost, "username": x.username, "password": x.password, "output": x.output]
            }
            // A file on this device means nothing to the TV.
            guard ref.url.hasPrefix("http") else { return nil }
            return ["name": ref.name, "url": ref.url, "output": "ts"]
        }

        // Keychain entries under the TV's names for them.
        var secrets: [String: String] = [:]
        let keychain: [(String, String)] = [
            ("debrid.realdebrid", "com.veltrio.debrid.realdebrid"), ("debrid.alldebrid", "com.veltrio.debrid.alldebrid"),
            ("debrid.premiumize", "com.veltrio.debrid.premiumize"), ("debrid.torbox", "com.veltrio.debrid.torbox"),
            ("stremio.authkey", "com.veltrio.stremio.authkey"), ("trakt.token", "com.veltrio.trakt.token"),
            ("simkl.token", "com.veltrio.simkl.token"), ("mediaserver.jellyfin", "com.veltrio.jellyfin.token"),
            ("mediaserver.emby", "com.veltrio.emby.token"), ("mediaserver.plex", "com.veltrio.plex.token"),
            ("tmdb.key", TmdbService.keyService), ("tmdb.lang", TmdbService.langService),
        ]
        for (name, service) in keychain { if let v = Keychain.get(service: service) { secrets[name] = v } }
        if secrets["stremio.authkey"] != nil, let email = defaults.string(forKey: "veltrio.stremio.email") { secrets["stremio.email"] = email }

        var servers: [String: Any] = [:]
        for kind in ["jellyfin", "emby"] where defaults.string(forKey: "veltrio.\(kind).userId") != nil {
            servers[kind] = [
                "url": defaults.string(forKey: "veltrio.\(kind).url") ?? "",
                "userId": defaults.string(forKey: "veltrio.\(kind).userId") ?? "",
                "userName": defaults.string(forKey: "veltrio.\(kind).userName") ?? "",
                // The server ties the token to this device id: the TV reuses it.
                "deviceId": defaults.string(forKey: "veltrio.\(kind).deviceId") ?? "",
            ]
        }
        if secrets["mediaserver.plex"] != nil {
            servers["plex"] = ["deviceId": defaults.string(forKey: "veltrio.plex.clientId") ?? ""]
        }

        func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
        let entries: [[String: Any]] = watch.entries.values.filter { $0.type != "iptv" }.map { e in
            var episodes: [String: Any] = [:]
            for (id, p) in e.episodes {
                var ep: [String: Any] = ["position": p.position, "duration": p.duration, "watched": p.watched, "updatedAt": ms(p.updatedAt)]
                if let s = p.season { ep["season"] = Int(s) }
                if let n = p.episode { ep["episode"] = Int(n) }
                episodes[id] = ep
            }
            var out: [String: Any] = [
                "type": e.type, "contentId": e.contentId, "name": e.name, "position": e.position, "duration": e.duration,
                "watched": e.watched, "episodes": episodes, "inLibrary": e.inLibrary,
                "addedAt": ms(e.addedAt), "lastWatchedAt": ms(e.lastWatchedAt),
            ]
            if let v = e.poster { out["poster"] = v }
            if let v = e.background { out["background"] = v }
            if let v = e.addonId { out["addonId"] = v }
            if let v = e.addonName { out["addonName"] = v }
            if let v = e.lastEpisodeId { out["lastEpisodeId"] = v }
            return out
        }

        return [
            "v": 1, "from": deviceName,
            "addons": addons, "disabledAddons": disabled, "playlists": playlists,
            "secrets": secrets, "mediaServers": servers, "watch": entries,
        ]
    }

    static var deviceName: String {
        #if os(iOS) || os(tvOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }
}

/// TVs waiting for settings, found over Bonjour.
@MainActor
@Observable
final class PairingBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private(set) var targets: [PairingSender.Target] = []
    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_veltrio-pair._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        resolving.forEach { $0.stop() }
        resolving = []
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            resolving.append(service)
            service.delegate = self
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let name = service.name
        MainActor.assumeIsolated { targets.removeAll { $0.name == name } }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let name = sender.name
        let port = sender.port
        // The first IPv4 address, else the host name.
        let host = sender.addresses?.compactMap(Self.ipv4).first ?? sender.hostName ?? ""
        MainActor.assumeIsolated {
            guard !host.isEmpty, !targets.contains(where: { $0.name == name }) else { return }
            targets.append(.init(name: name, host: host, port: port))
        }
    }

    nonisolated private static func ipv4(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let sa = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self), sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
            var addr = raw.load(as: sockaddr_in.self).sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            return inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)).map { String(cString: $0) }
        }
    }
}
