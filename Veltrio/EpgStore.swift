import Foundation
import Observation
import Compression

/// One programme from an XMLTV guide.
struct EpgProgramme: Identifiable, Hashable {
    let channelId: String
    let start: Date
    let end: Date
    let title: String
    let description: String?
    let category: String?

    var id: String { "\(channelId)|\(start.timeIntervalSince1970)" }

    func progress(at date: Date = Date()) -> Double {
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / span))
    }
}

/// The XMLTV guide for the selected playlist.
///
/// Where the guide comes from: an Xtream provider serves it at
/// `xmltv.php`; an M3U playlist names it in its header (`url-tvg` /
/// `x-tvg-url`). Guides are often tens of megabytes and gzipped, so only
/// the playlist's own channels and the next day are kept.
@MainActor
@Observable
final class EpgStore {
    /// Programmes per XMLTV channel id (lower-cased), sorted by start.
    private(set) var programmes: [String: [EpgProgramme]] = [:]
    /// Playlist channel id → XMLTV channel id, for channels matched by name.
    private var channelMap: [String: String] = [:]
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var sourceURL: URL?

    private var loadedFor: UUID?
    private var loadedAt: Date?
    private var task: Task<Void, Never>?

    /// Guides change slowly; refetch at most this often per playlist.
    private let maxAge: TimeInterval = 6 * 3600
    /// What's kept: an hour back (catch-up of the current slot) to a day ahead.
    private let window: (back: TimeInterval, ahead: TimeInterval) = (3600, 24 * 3600)

    var hasGuide: Bool { !programmes.isEmpty }

    func load(for ref: IptvPlaylistRef, channels: [IptvChannel], force: Bool = false) {
        if !force, loadedFor == ref.id, let loadedAt, Date().timeIntervalSince(loadedAt) < maxAge { return }
        task?.cancel()
        let id = ref.id
        isLoading = true
        error = nil
        task = Task {
            guard let url = await Self.guideURL(for: ref) else {
                guard self.loadedFor != id || force else { return }
                self.finish(id: id, url: nil, result: nil, error: nil)
                return
            }
            let wantedIds = Set(channels.compactMap { $0.tvgId?.lowercased() })
            let wantedNames = Dictionary(channels.map { (Self.nameKey($0.tvgName ?? $0.name), $0.id) },
                                         uniquingKeysWith: { a, _ in a })
            let now = Date()
            let range = now.addingTimeInterval(-window.back)...now.addingTimeInterval(window.ahead)
            do {
                let parsed = try await Task.detached(priority: .utility) {
                    try await Self.fetchAndParse(url: url, wantedIds: wantedIds, wantedNames: wantedNames, range: range)
                }.value
                guard !Task.isCancelled else { return }
                self.finish(id: id, url: url, result: parsed, error: nil)
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.finish(id: id, url: url, result: nil, error: error.localizedDescription)
            }
        }
    }

    private func finish(id: UUID, url: URL?, result: EpgParser.Result?, error: String?) {
        programmes = result?.programmes ?? [:]
        channelMap = result?.nameMatches ?? [:]
        sourceURL = url
        self.error = error
        loadedFor = id
        loadedAt = Date()
        isLoading = false
    }

    func clear() {
        task?.cancel()
        programmes = [:]
        channelMap = [:]
        loadedFor = nil
        isLoading = false
    }

    // MARK: - queries

    func schedule(for channel: IptvChannel) -> [EpgProgramme] {
        if let tvg = channel.tvgId?.lowercased(), let list = programmes[tvg] { return list }
        if let mapped = channelMap[channel.id], let list = programmes[mapped] { return list }
        return []
    }

    func current(for channel: IptvChannel, at date: Date = Date()) -> EpgProgramme? {
        schedule(for: channel).first { $0.start <= date && date < $0.end }
    }

    func next(for channel: IptvChannel, at date: Date = Date()) -> EpgProgramme? {
        schedule(for: channel).first { $0.start > date }
    }

    // MARK: - fetching

    /// Xtream: the provider's `xmltv.php`. M3U: the `url-tvg` attribute of
    /// the playlist's first line, read without downloading the playlist.
    nonisolated static func guideURL(for ref: IptvPlaylistRef) async -> URL? {
        if let creds = ref.xtream {
            var comps = URLComponents(string: "\(creds.normalizedHost)/xmltv.php")
            comps?.queryItems = [URLQueryItem(name: "username", value: creds.username),
                                 URLQueryItem(name: "password", value: creds.password)]
            return comps?.url
        }
        guard let url = URL(string: ref.url), url.scheme?.hasPrefix("http") == true,
              let (bytes, _) = try? await URLSession.shared.bytes(from: url) else {
            // Local files: read the header line from disk.
            if let url = URL(string: ref.url), url.isFileURL,
               let handle = try? FileHandle(forReadingFrom: url),
               let head = try? handle.read(upToCount: 8192) {
                return headerGuideURL(String(decoding: head, as: UTF8.self))
            }
            return nil
        }
        var firstLine = ""
        do {
            for try await line in bytes.lines {
                firstLine = line
                break
            }
        } catch {
            return nil
        }
        return headerGuideURL(firstLine)
    }

    nonisolated static func headerGuideURL(_ header: String) -> URL? {
        guard header.hasPrefix("#EXTM3U") else { return nil }
        for attr in ["url-tvg", "x-tvg-url"] {
            guard let r = header.range(of: "\(attr)=\"") else { continue }
            let rest = header[r.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            // Some headers list several guides, comma-separated: take the first.
            let first = rest[..<end].split(separator: ",").first.map(String.init) ?? ""
            if let url = URL(string: first.trimmingCharacters(in: .whitespaces)) { return url }
        }
        return nil
    }

    nonisolated static func fetchAndParse(url: URL, wantedIds: Set<String>, wantedNames: [String: String],
                                          range: ClosedRange<Date>) async throws -> EpgParser.Result {
        let (file, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        var xml = file
        if Gzip.isGzipped(file) {
            xml = file.appendingPathExtension("xml")
            try Gzip.decompress(file, to: xml)
        }
        defer { if xml != file { try? FileManager.default.removeItem(at: xml) } }
        guard let parser = XMLParser(contentsOf: xml) else { throw URLError(.cannotParseResponse) }
        let delegate = EpgParser(wantedIds: wantedIds, wantedNames: wantedNames, range: range)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() || !delegate.programmes.isEmpty else {
            throw parser.parserError ?? URLError(.cannotParseResponse)
        }
        return delegate.result
    }

    nonisolated static func nameKey(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - XMLTV parser

/// SAX parser for XMLTV: `<channel id><display-name>` then
/// `<programme start stop channel><title><desc><category>`. Keeps only the
/// wanted channels and the given time range.
final class EpgParser: NSObject, XMLParserDelegate {
    struct Result {
        let programmes: [String: [EpgProgramme]]
        /// Playlist channel id → XMLTV channel id, matched by display name.
        let nameMatches: [String: String]
    }

    private var wantedIds: Set<String>
    private let wantedNames: [String: String]
    private let range: ClosedRange<Date>

    private(set) var programmes: [String: [EpgProgramme]] = [:]
    private var nameMatches: [String: String] = [:]

    private var channelId: String?
    private var current: (channel: String, start: Date, end: Date)?
    private var title = "", desc = "", category = ""
    private var text = ""
    private var inProgrammeField: String?

    init(wantedIds: Set<String>, wantedNames: [String: String], range: ClosedRange<Date>) {
        self.wantedIds = wantedIds
        self.wantedNames = wantedNames
        self.range = range
    }

    var result: Result {
        Result(programmes: programmes.mapValues { $0.sorted { $0.start < $1.start } }, nameMatches: nameMatches)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMddHHmmss Z"
        return f
    }()

    private static let dateFormatterNoZone: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    static func parseDate(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), s.count >= 14 else { return nil }
        return dateFormatter.date(from: s) ?? dateFormatterNoZone.date(from: String(s.prefix(14)))
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "channel":
            channelId = attributes["id"]?.lowercased()
        case "programme":
            guard let ch = attributes["channel"]?.lowercased(), wantedIds.contains(ch),
                  let start = Self.parseDate(attributes["start"]),
                  let end = Self.parseDate(attributes["stop"]) ?? Self.parseDate(attributes["start"])?.addingTimeInterval(1800),
                  end >= range.lowerBound, start <= range.upperBound else {
                current = nil
                return
            }
            current = (ch, start, end)
            title = ""; desc = ""; category = ""
        case "title", "desc", "category":
            inProgrammeField = current == nil ? nil : name
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "display-name":
            // A playlist channel without a matching tvg-id can still be
            // matched by name; the channel's programmes are then kept too.
            if let id = channelId, let playlistId = wantedNames[EpgStore.nameKey(text)], nameMatches[playlistId] == nil {
                nameMatches[playlistId] = id
                wantedIds.insert(id)
            }
        case "channel":
            channelId = nil
        case "title" where inProgrammeField == "title" && title.isEmpty:
            title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "desc" where inProgrammeField == "desc" && desc.isEmpty:
            desc = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "category" where inProgrammeField == "category" && category.isEmpty:
            category = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "programme":
            if let c = current, !title.isEmpty {
                programmes[c.channel, default: []].append(EpgProgramme(
                    channelId: c.channel, start: c.start, end: c.end, title: title,
                    description: desc.isEmpty ? nil : desc, category: category.isEmpty ? nil : category
                ))
            }
            current = nil
        default:
            break
        }
        if ["title", "desc", "category"].contains(name) { inProgrammeField = nil }
        text = ""
    }
}

// MARK: - gzip

/// Guides are commonly served as `.xml.gz`. The Compression framework
/// inflates raw DEFLATE, so the gzip header is skipped by hand.
enum Gzip {
    static func isGzipped(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url), let head = try? h.read(upToCount: 2) else { return false }
        return head.count == 2 && head[head.startIndex] == 0x1f && head[head.startIndex + 1] == 0x8b
    }

    static func decompress(_ source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source, options: .alwaysMapped)
        let offset = try headerLength(data)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
            if let chunk { out.write(chunk) }
        }
        let body = data[(data.startIndex + offset)...]
        var index = body.startIndex
        let step = 1 << 20
        while index < body.endIndex {
            let end = min(index + step, body.endIndex)
            try filter.write(body[index..<end])
            index = end
        }
        try filter.finalize()
    }

    /// RFC 1952: 10 fixed bytes, then optional extra field, file name,
    /// comment and header CRC depending on the flags byte.
    static func headerLength(_ d: Data) throws -> Int {
        let b = [UInt8](d.prefix(10))
        guard b.count == 10, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw CocoaError(.fileReadCorruptFile) }
        let flags = b[3]
        var i = 10
        let bytes = d.startIndex
        if flags & 0x04 != 0 {
            guard d.count >= i + 2 else { throw CocoaError(.fileReadCorruptFile) }
            i += 2 + Int(d[bytes + i]) + Int(d[bytes + i + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while i < d.count, d[bytes + i] != 0 { i += 1 }
            i += 1
        }
        if flags & 0x02 != 0 { i += 2 }
        guard i < d.count else { throw CocoaError(.fileReadCorruptFile) }
        return i
    }
}
