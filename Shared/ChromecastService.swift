import Foundation
import Network
import Observation

/// Chromecast, without Google's SDK (there is none for macOS).
///
/// Devices are found over Bonjour (`_googlecast._tcp`). Casting speaks the
/// Cast V2 protocol: a TLS connection to the device (port 8009, self-signed
/// certificate), length-prefixed protobuf `CastMessage`s carrying JSON.
/// The sender launches the Default Media Receiver (app `CC1AD845`) and
/// asks it to LOAD the stream URL, which the Chromecast then fetches
/// itself — so the URL has to be reachable from it: debrid, IPTV, media
/// servers and addon links are; the local torrent server (bound to
/// 127.0.0.1) isn't.
@MainActor
@Observable
final class ChromecastService {
    struct Device: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    enum State: Equatable {
        case idle
        case connecting(String)
        case casting(String)
        case failed(String)
    }

    private(set) var devices: [Device] = []
    private(set) var state: State = .idle

    private var browser: NWBrowser?
    private var session: CastSession?

    var isCasting: Bool {
        if case .casting = state { return true }
        if case .connecting = state { return true }
        return false
    }

    // MARK: - discovery

    func startDiscovery() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Device? in
                // The friendly name is the TXT record's "fn"; the service
                // name is an opaque id.
                var name: String?
                if case .bonjour(let txt) = result.metadata { name = txt["fn"] }
                if name == nil, case .service(let service, _, _, _) = result.endpoint { name = service }
                return name.map { Device(name: $0, endpoint: result.endpoint) }
            }
            Task { @MainActor in self?.devices = found.sorted { $0.name < $1.name } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }

    // MARK: - casting

    /// Whether a Chromecast could fetch this URL itself.
    nonisolated static func canCast(_ url: URL?) -> Bool {
        guard let url, url.scheme == "http" || url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return !(host == "localhost" || host == "127.0.0.1" || host == "::1")
    }

    func cast(_ url: URL, title: String, poster: String?, isLive: Bool, startAt: Double, to device: Device) {
        stop()
        state = .connecting(device.name)
        let media = CastSession.Media(url: url, title: title, poster: poster, isLive: isLive, startAt: startAt)
        let session = CastSession(endpoint: device.endpoint, media: media) { [weak self] event in
            Task { @MainActor in
                guard let self, self.session != nil else { return }
                switch event {
                case .playing:          self.state = .casting(device.name)
                case .failed(let why):  self.state = .failed(why); self.session = nil
                case .closed:           if case .connecting = self.state { self.state = .failed(String(localized: "The Chromecast closed the connection.")) } else { self.state = .idle }
                                        self.session = nil
                }
            }
        }
        self.session = session
        session.start()
    }

    func stop() {
        session?.stop()
        session = nil
        state = .idle
    }
}

// MARK: - Cast V2 session

/// One connection to one device, playing one media item.
final class CastSession: @unchecked Sendable {
    struct Media {
        let url: URL
        let title: String
        let poster: String?
        let isLive: Bool
        let startAt: Double
    }

    enum Event { case playing, failed(String), closed }

    private static let defaultMediaReceiver = "CC1AD845"
    private enum NS {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }

    private let connection: NWConnection
    private let media: Media
    private let onEvent: (Event) -> Void
    private let queue = DispatchQueue(label: "veltrio.cast")
    private var heartbeat: DispatchSourceTimer?
    private var requestId = 1
    private var transportId: String?
    private var sessionId: String?
    private var loaded = false

    init(endpoint: NWEndpoint, media: Media, onEvent: @escaping (Event) -> Void) {
        let tls = NWProtocolTLS.Options()
        // Chromecasts present a device certificate no CA signs.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .global())
        connection = NWConnection(to: endpoint, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        self.media = media
        self.onEvent = onEvent
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.send(NS.connection, to: "receiver-0", ["type": "CONNECT"])
                self.startHeartbeat()
                self.send(NS.receiver, to: "receiver-0", ["type": "LAUNCH", "appId": Self.defaultMediaReceiver, "requestId": self.nextId()])
                self.receive()
            case .failed(let error):
                self.onEvent(.failed(error.localizedDescription))
                self.teardown()
            case .cancelled:
                self.onEvent(.closed)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        queue.async {
            if let sessionId = self.sessionId {
                self.send(NS.receiver, to: "receiver-0", ["type": "STOP", "sessionId": sessionId, "requestId": self.nextId()])
            }
            self.teardown()
        }
    }

    private func teardown() {
        heartbeat?.cancel()
        heartbeat = nil
        connection.cancel()
    }

    private func nextId() -> Int {
        requestId += 1
        return requestId
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.send(NS.heartbeat, to: "receiver-0", ["type": "PING"]) }
        timer.resume()
        heartbeat = timer
    }

    // MARK: messages

    private func handle(_ message: CastMessage) {
        guard let data = message.payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }
        switch type {
        case "PING":
            send(NS.heartbeat, to: message.source, ["type": "PONG"])
        case "RECEIVER_STATUS":
            let apps = ((json["status"] as? [String: Any])?["applications"] as? [[String: Any]]) ?? []
            guard !loaded, let app = apps.first(where: { $0["appId"] as? String == Self.defaultMediaReceiver }),
                  let transport = app["transportId"] as? String else { return }
            loaded = true
            transportId = transport
            sessionId = app["sessionId"] as? String
            send(NS.connection, to: transport, ["type": "CONNECT"])
            send(NS.media, to: transport, loadRequest())
        case "MEDIA_STATUS":
            let statuses = (json["status"] as? [[String: Any]]) ?? []
            if let state = statuses.first?["playerState"] as? String, state == "PLAYING" || state == "BUFFERING" {
                onEvent(.playing)
            }
        case "LOAD_FAILED", "LOAD_CANCELLED", "INVALID_REQUEST", "LAUNCH_ERROR":
            onEvent(.failed(String(localized: "The Chromecast couldn't play this stream.")))
            teardown()
        case "CLOSE":
            teardown()
        default:
            break
        }
    }

    private func loadRequest() -> [String: Any] {
        var metadata: [String: Any] = ["metadataType": 0, "title": media.title]
        if let poster = media.poster { metadata["images"] = [["url": poster]] }
        return [
            "type": "LOAD",
            "requestId": nextId(),
            "autoplay": true,
            "currentTime": media.isLive ? 0 : media.startAt,
            "media": [
                "contentId": media.url.absoluteString,
                "contentType": Self.contentType(for: media.url),
                "streamType": media.isLive ? "LIVE" : "BUFFERED",
                "metadata": metadata,
            ] as [String: Any],
        ]
    }

    static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m3u8": return "application/x-mpegURL"
        case "mkv":  return "video/x-matroska"
        case "webm": return "video/webm"
        case "ts":   return "video/mp2t"
        default:     return "video/mp4"
        }
    }

    private func send(_ namespace: String, to destination: String, _ payload: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        let body = CastMessage(source: "sender-0", destination: destination, namespace: namespace, payload: text).encoded()
        var frame = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
        frame.append(body)
        connection.send(content: frame, completion: .idempotent)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] header, _, _, error in
            guard let self, let header, header.count == 4, error == nil else { return }
            let length = header.reduce(0) { $0 << 8 | Int($1) }
            self.connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error in
                guard let body, error == nil else { return }
                if let message = CastMessage(decoding: body) { self.handle(message) }
                self.receive()
            }
        }
    }
}

// MARK: - CastMessage protobuf

/// The six fields of `CastMessage` (cast_channel.proto), encoded by hand:
/// 1 protocol_version (enum, always CASTV2_1_0 = 0), 2 source_id,
/// 3 destination_id, 4 namespace, 5 payload_type (enum, STRING = 0),
/// 6 payload_utf8.
struct CastMessage: Equatable {
    let source: String
    let destination: String
    let namespace: String
    let payload: String

    init(source: String, destination: String, namespace: String, payload: String) {
        self.source = source
        self.destination = destination
        self.namespace = namespace
        self.payload = payload
    }

    func encoded() -> Data {
        var d = Data()
        func varint(_ value: Int) {
            var v = UInt64(value)
            while v >= 0x80 {
                d.append(UInt8(v & 0x7F) | 0x80)
                v >>= 7
            }
            d.append(UInt8(v))
        }
        func string(_ field: Int, _ s: String) {
            let bytes = Data(s.utf8)
            varint(field << 3 | 2)
            varint(bytes.count)
            d.append(bytes)
        }
        varint(1 << 3); varint(0)
        string(2, source)
        string(3, destination)
        string(4, namespace)
        varint(5 << 3); varint(0)
        string(6, payload)
        return d
    }

    init?(decoding data: Data) {
        var fields: [Int: String] = [:]
        let bytes = [UInt8](data)
        var i = 0
        func varint() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                result |= Int(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < bytes.count {
            guard let tag = varint() else { return nil }
            switch tag & 7 {
            case 0:
                guard varint() != nil else { return nil }
            case 2:
                guard let length = varint(), length >= 0, i + length <= bytes.count else { return nil }
                fields[tag >> 3] = String(decoding: bytes[i..<(i + length)], as: UTF8.self)
                i += length
            default:
                return nil
            }
        }
        guard let ns = fields[4] else { return nil }
        self.init(source: fields[2] ?? "", destination: fields[3] ?? "", namespace: ns, payload: fields[6] ?? "")
    }
}
