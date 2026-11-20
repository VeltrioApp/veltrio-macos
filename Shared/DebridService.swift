import Foundation
import Observation

/// Debrid orchestration: owns every provider client, caches availability
/// checks, knows whether each account is configured. The app store
/// delegates every debrid decision through here so the UI stays simple.
///
/// Pinned to the main actor because every published property is observed
/// directly by SwiftUI views — writing to them off-main is a data race
/// that SwiftUI flags at runtime.
@MainActor
@Observable
final class DebridService {
    // ---------- state exposed to views ----------

    // AllDebrid
    private(set) var allDebridKey: String?
    private(set) var allDebridUser: AdUserInfo?

    // Real-Debrid
    private(set) var realDebridKey: String?
    private(set) var realDebridUser: RdUser?

    // TorBox and Premiumize: API key pasted from the account page.
    private(set) var torBoxKey: String?
    private(set) var torBoxUser: TorBoxClient.User?
    private(set) var premiumizeKey: String?
    private(set) var premiumizeAccount: PremiumizeClient.Account?
    private(set) var isConnectingTorBox = false
    private(set) var isConnectingPremiumize = false
    private(set) var torBoxError: String?
    private(set) var premiumizeError: String?

    /// Last availability snapshot across all providers:
    ///   `(provider, info_hash_lower) -> cached?`
    /// Views read the ⚡ badges from here.
    private(set) var cachedHashes: [CacheKey: Bool] = [:]

    // Auth flow state (shared across providers so at most one PIN panel
    // shows up at a time in Settings).
    private(set) var pendingPin: AdPinStart?       // AllDebrid
    private(set) var pendingRdDevice: RdDeviceCode? // Real-Debrid
    /// Per-provider flags and errors.
    ///
    /// These used to be a single shared `isConnecting` and a single
    /// shared `connectionError`. Two bugs came out of that: a failed
    /// Real-Debrid attempt stored its message in the one field the
    /// *AllDebrid* card was the only one rendering, and one provider's
    /// Connect button showed a spinner while the other was connecting.
    private(set) var isConnectingAllDebrid = false
    private(set) var isConnectingRealDebrid = false
    private(set) var allDebridError: String?
    private(set) var realDebridError: String?

    // ---------- deps ----------
    private let ad: AllDebridClient
    private let rd: RealDebridClient
    private let torBox = TorBoxClient()
    private let premiumize = PremiumizeClient()
    private var adPollTask: Task<Void, Never>?
    private var rdPollTask: Task<Void, Never>?

    var isAllDebridConnected: Bool { allDebridKey != nil }
    var isRealDebridConnected: Bool { realDebridKey != nil }
    var isTorBoxConnected: Bool { torBoxKey != nil }
    var isPremiumizeConnected: Bool { premiumizeKey != nil }

    /// Any premium provider configured? Drives UI "⚡ cached" filter
    /// visibility and the "no debrid" empty states.
    var anyProviderConnected: Bool {
        isAllDebridConnected || isRealDebridConnected || isTorBoxConnected || isPremiumizeConnected
    }

    init(ad: AllDebridClient? = nil, rd: RealDebridClient? = nil) {
        let ad = ad ?? AllDebridClient()
        let rd = rd ?? RealDebridClient()
        self.ad = ad
        self.rd = rd
        self.allDebridKey = Keychain.get(service: DebridProvider.allDebrid.keychainService)
        self.realDebridKey = Keychain.get(service: DebridProvider.realDebrid.keychainService)
        if let key = allDebridKey {
            Task { [weak self] in
                let user = try? await ad.userInfo(apiKey: key)
                await MainActor.run { self?.allDebridUser = user }
            }
        }
        if let tok = realDebridKey {
            Task { [weak self, rd] in
                let user = try? await rd.userInfo(token: tok)
                await MainActor.run { self?.realDebridUser = user }
            }
        }
        torBoxKey = Keychain.get(service: DebridProvider.torbox.keychainService)
        premiumizeKey = Keychain.get(service: DebridProvider.premiumize.keychainService)
        if let key = torBoxKey {
            Task { [weak self, torBox] in
                let user = try? await torBox.user(apiKey: key)
                await MainActor.run { self?.torBoxUser = user }
            }
        }
        if let key = premiumizeKey {
            Task { [weak self, premiumize] in
                let account = try? await premiumize.account(apiKey: key)
                await MainActor.run { self?.premiumizeAccount = account }
            }
        }
    }

    // MARK: - TorBox / Premiumize (API key)

    /// Checks the key against the account endpoint before keeping it, so a
    /// typo shows up here rather than as streams that never resolve.
    func connectTorBox(apiKey raw: String) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        torBoxError = nil
        isConnectingTorBox = true
        defer { isConnectingTorBox = false }
        do {
            torBoxUser = try await torBox.user(apiKey: key)
            Keychain.set(key, service: DebridProvider.torbox.keychainService)
            torBoxKey = key
        } catch {
            torBoxError = String(localized: "TorBox rejected this API key.") + " " + error.localizedDescription
        }
    }

    func disconnectTorBox() {
        Keychain.delete(service: DebridProvider.torbox.keychainService)
        torBoxKey = nil
        torBoxUser = nil
        torBoxError = nil
        pruneCache(for: .torbox)
    }

    func connectPremiumize(apiKey raw: String) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        premiumizeError = nil
        isConnectingPremiumize = true
        defer { isConnectingPremiumize = false }
        do {
            premiumizeAccount = try await premiumize.account(apiKey: key)
            Keychain.set(key, service: DebridProvider.premiumize.keychainService)
            premiumizeKey = key
        } catch {
            premiumizeError = String(localized: "Premiumize rejected this API key.") + " " + error.localizedDescription
        }
    }

    func disconnectPremiumize() {
        Keychain.delete(service: DebridProvider.premiumize.keychainService)
        premiumizeKey = nil
        premiumizeAccount = nil
        premiumizeError = nil
        pruneCache(for: .premiumize)
    }

    // MARK: - AllDebrid PIN flow

    @MainActor
    func startAllDebridPinFlow() async {
        allDebridError = nil
        adPollTask?.cancel()
        // Only one provider may have an auth panel open at a time, so
        // starting this flow cancels the other provider's flow.
        rdPollTask?.cancel()
        pendingRdDevice = nil
        isConnectingAllDebrid = true
        defer { isConnectingAllDebrid = false }
        do {
            let pin = try await ad.startPinAuth()
            pendingPin = pin
            adPollTask = Task { [weak self] in await self?.pollAllDebridPin(pin: pin) }
        } catch {
            allDebridError = humanize(error)
        }
    }

    @MainActor
    func cancelAllDebridPinFlow() {
        adPollTask?.cancel()
        adPollTask = nil
        pendingPin = nil
        allDebridError = nil
    }

    private nonisolated func pollAllDebridPin(pin: AdPinStart) async {
        let deadline = Date().addingTimeInterval(TimeInterval(pin.expiresInSeconds))
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if Task.isCancelled { return }
            do {
                if let key = try await ad.pollPin(pin: pin.pin, checkToken: pin.checkToken) {
                    let user = try? await ad.userInfo(apiKey: key)
                    if Task.isCancelled { return }
                    await MainActor.run {
                        guard self.pendingPin?.checkToken == pin.checkToken else { return }
                        Keychain.set(key, service: DebridProvider.allDebrid.keychainService)
                        self.allDebridKey = key
                        self.pendingPin = nil
                        self.allDebridUser = user
                    }
                    return
                }
            } catch {
                continue
            }
        }
        await MainActor.run {
            guard self.pendingPin?.checkToken == pin.checkToken else { return }
            self.pendingPin = nil
            self.allDebridError = String(localized: "The AllDebrid PIN expired. Please try again.")
        }
    }

    @MainActor
    func disconnectAllDebrid() {
        Keychain.delete(service: DebridProvider.allDebrid.keychainService)
        allDebridKey = nil
        allDebridUser = nil
        allDebridError = nil
        pruneCache(for: .allDebrid)
    }

    // MARK: - Real-Debrid device flow

    @MainActor
    func startRealDebridDeviceFlow() async {
        realDebridError = nil
        rdPollTask?.cancel()
        // Same rule as the AllDebrid flow: one open auth panel at a time.
        adPollTask?.cancel()
        pendingPin = nil
        isConnectingRealDebrid = true
        defer { isConnectingRealDebrid = false }
        do {
            let code = try await rd.startDeviceAuth()
            pendingRdDevice = code
            rdPollTask = Task { [weak self] in await self?.pollRealDebrid(code: code) }
        } catch {
            realDebridError = humanize(error)
        }
    }

    @MainActor
    func cancelRealDebridDeviceFlow() {
        rdPollTask?.cancel()
        rdPollTask = nil
        pendingRdDevice = nil
        realDebridError = nil
    }

    private func pollRealDebrid(code: RdDeviceCode) async {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresInSeconds))
        let interval = UInt64(code.interval) * 1_000_000_000
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: interval)
            if Task.isCancelled { return }
            do {
                let token = try await rd.pollDeviceAuth(deviceCode: code.deviceCode)
                let user = try? await rd.userInfo(token: token)
                guard self.pendingRdDevice?.deviceCode == code.deviceCode else { return }
                Keychain.set(token, service: DebridProvider.realDebrid.keychainService)
                self.realDebridKey = token
                self.realDebridUser = user
                self.pendingRdDevice = nil
                return
            } catch RdError.authPending, RdError.authSlowDown {
                continue
            } catch {
                // Hard failure — keep retrying until the code expires;
                // most non-200s during the device flow are transient.
                continue
            }
        }
        guard self.pendingRdDevice?.deviceCode == code.deviceCode else { return }
        self.pendingRdDevice = nil
        self.realDebridError = String(localized: "The Real-Debrid code expired. Please try again.")
    }

    @MainActor
    func disconnectRealDebrid() {
        Keychain.delete(service: DebridProvider.realDebrid.keychainService)
        realDebridKey = nil
        realDebridUser = nil
        realDebridError = nil
        pruneCache(for: .realDebrid)
    }

    // MARK: - Availability prefetch

    func prefetchAvailability(for streams: [LabeledStream]) async {
        let hashes: [String] = streams.compactMap { s in
            if case .torrent(let hash, _, _) = s.stream.source { return hash.lowercased() }
            return nil
        }
        guard !hashes.isEmpty else { return }
        let unique = Array(Set(hashes))

        // AllDebrid
        if let key = allDebridKey {
            let missing = unique.filter { cachedHashes[.init(provider: .allDebrid, hash: $0)] == nil }
            if !missing.isEmpty {
                if let result = try? await ad.checkAvailability(apiKey: key, hashes: missing) {
                    guard allDebridKey == key else { return }
                    for (h, ready) in result {
                        cachedHashes[.init(provider: .allDebrid, hash: h.lowercased())] = ready
                    }
                }
            }
        }

        // Real-Debrid
        if let tok = realDebridKey {
            let missing = unique.filter { cachedHashes[.init(provider: .realDebrid, hash: $0)] == nil }
            if !missing.isEmpty {
                if let result = try? await rd.checkAvailability(hashes: missing, token: tok) {
                    guard realDebridKey == tok else { return }
                    for (h, ready) in result {
                        cachedHashes[.init(provider: .realDebrid, hash: h.lowercased())] = ready
                    }
                }
            }
        }

        await prefetch(.torbox, key: torBoxKey, hashes: unique) { [torBox] key, hashes in
            try await torBox.checkCached(hashes: hashes, apiKey: key)
        }
        await prefetch(.premiumize, key: premiumizeKey, hashes: unique) { [premiumize] key, hashes in
            try await premiumize.checkCached(hashes: hashes, apiKey: key)
        }
    }

    private func prefetch(_ provider: DebridProvider, key: String?, hashes: [String],
                          check: (String, [String]) async throws -> [String: Bool]) async {
        guard let key else { return }
        let missing = hashes.filter { cachedHashes[.init(provider: provider, hash: $0)] == nil }
        guard !missing.isEmpty, let result = try? await check(key, missing) else { return }
        for (h, ready) in result {
            cachedHashes[.init(provider: provider, hash: h.lowercased())] = ready
        }
    }

    /// Any provider that has this hash cached. Used for the badge on the
    /// stream rows (we show one amber ⚡ regardless of which provider
    /// cached it — the user doesn't care).
    func isCached(_ infoHash: String) -> Bool {
        let lower = infoHash.lowercased()
        for p in DebridProvider.allCases where cachedHashes[.init(provider: p, hash: lower)] == true {
            return true
        }
        return false
    }

    /// Which provider cached it? Used for the per-row provider tag.
    func cachingProvider(for infoHash: String) -> DebridProvider? {
        let lower = infoHash.lowercased()
        for p in DebridProvider.allCases where cachedHashes[.init(provider: p, hash: lower)] == true {
            return p
        }
        return nil
    }

    // MARK: - Stream resolution

    /// Resolve an infohash via the first provider that can serve it.
    /// Priority: Real-Debrid, TorBox, Premiumize (each only when it has the
    /// torrent cached) → AllDebrid → nil (caller falls back to the local
    /// torrent engine). AllDebrid is tried without a cache hit because it
    /// still resolves non-cached items; the others return nothing useful
    /// for a torrent they haven't cached.
    func resolveStream(
        infoHash: String,
        season: Int32? = nil,
        episode: Int32? = nil
    ) async -> String? {
        // Real-Debrid first — fastest when cached.
        if let tok = realDebridKey, isCachedOn(.realDebrid, hash: infoHash) {
            do {
                return try await rd.resolveStream(
                    infoHash: infoHash, season: season, episode: episode, token: tok
                )
            } catch {
                DebugLog.shared.error("real-debrid", "resolve \(infoHash): \(error)")
            }
        }
        if let key = torBoxKey, isCachedOn(.torbox, hash: infoHash) {
            do {
                return try await torBox.resolveStream(infoHash: infoHash, season: season, episode: episode, apiKey: key)
            } catch {
                DebugLog.shared.error("torbox", "resolve \(infoHash): \(error)")
            }
        }
        if let key = premiumizeKey, isCachedOn(.premiumize, hash: infoHash) {
            do {
                return try await premiumize.resolveStream(infoHash: infoHash, season: season, episode: episode, apiKey: key)
            } catch {
                DebugLog.shared.error("premiumize", "resolve \(infoHash): \(error)")
            }
        }
        // AllDebrid fallback (also handles non-cached because AD will
        // download on their side).
        if let key = allDebridKey {
            do {
                return try await ad.resolveStream(
                    apiKey: key, infoHash: infoHash,
                    season: season, episode: episode
                )
            } catch {
                DebugLog.shared.error("alldebrid", "resolve \(infoHash): \(error)")
            }
        }
        return nil
    }

    /// Legacy name — kept so existing call sites compile. Routes to the
    /// provider-agnostic resolver.
    func resolveViaAllDebrid(
        infoHash: String,
        season: Int32? = nil,
        episode: Int32? = nil
    ) async -> String? {
        await resolveStream(infoHash: infoHash, season: season, episode: episode)
    }

    private func isCachedOn(_ p: DebridProvider, hash: String) -> Bool {
        cachedHashes[.init(provider: p, hash: hash.lowercased())] == true
    }

    private func pruneCache(for provider: DebridProvider) {
        cachedHashes = cachedHashes.filter { $0.key.provider != provider }
    }

    // MARK: - helpers

    private func humanize(_ error: Error) -> String {
        if let v = error as? VeltrioError {
            switch v {
            case .Network(let m), .Parse(let m), .InvalidUrl(let m),
                 .NotFound(let m), .Unsupported(let m), .Internal(let m):
                return m
            }
        }
        if let rd = error as? RdError {
            switch rd {
            case .network(let m):      return "Network: \(m)"
            case .decode(let m):       return "Parse: \(m)"
            case .authPending:         return "Waiting on Real-Debrid confirmation…"
            case .authSlowDown:        return "Slow down, retrying…"
            case .tokenRejected(let m):return String(localized: "Token rejected: \(m)")
            case .notReady:            return "Content not ready on Real-Debrid."
            case .apiError(let c, let m): return "Real-Debrid \(c): \(m)"
            }
        }
        return error.localizedDescription
    }
}

/// Composite key for the cached-hash map so one hash can be tracked per
/// provider independently.
struct CacheKey: Hashable {
    let provider: DebridProvider
    let hash: String
}
