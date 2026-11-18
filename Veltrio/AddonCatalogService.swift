import Foundation
import Observation

/// One entry in the stremio-addons.net catalogue.
///
/// The site is a Next.js app, not a JSON API — its list pages embed the
/// addon manifests in a React Server Components payload. We scrape the
/// manifest objects out of that payload rather than depending on the
/// site's internal HTTP shape.
struct CatalogAddon: Identifiable, Hashable {
    let id: String
    let name: String
    let slug: String
    let description: String?
    let logo: String?
    let background: String?
    let version: String?
    let types: [String]
    let resources: [String]
    let catalogCount: Int
    /// The manifest URL to install from. Resolved from the addon's detail
    /// page, which lists every mirror the site knows about.
    var transportUrl: String?

    /// What the addon can do for the user, in the app's own words.
    var capabilities: [String] {
        var out: [String] = []
        if resources.contains("catalog") { out.append("Catalogs") }
        if resources.contains("stream") { out.append("Streams") }
        if resources.contains("meta")    { out.append("Metadata") }
        if resources.contains("subtitles") { out.append("Subtitles") }
        if resources.contains("addon_catalog") { out.append("Addon catalog") }
        return out
    }
}

/// Fetches the community addon catalogue from stremio-addons.net.
///
/// Two sources, in order of usefulness:
///   1. `api.strem.io/addonscollection.json` — a clean JSON list of the
///      official collection (97 addons) with a `transportUrl` on each. This
///      is the primary source: it gives installable manifests directly.
///   2. `stremio-addons.net/addons` — the community site's own list, far
///      larger (70 pages of 10). Its payloads don't carry a transport URL,
///      so each entry is resolved from the addon's detail page, which
///      lists its mirrors. Resolving is lazy and per-addon.
@MainActor
@Observable
final class AddonCatalogService {
    /// The official collection — every entry has a `transportUrl`.
    private(set) var officialAddons: [CatalogAddon] = []
    /// The community site — entries get their transport URL resolved lazily.
    private(set) var communityAddons: [CatalogAddon] = []
    /// Every addon from both sources, official first.
    var addons: [CatalogAddon] { officialAddons + communityAddons }
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var loadedFrom: Source = .none
    /// How many community pages have been fetched so far.
    private(set) var communityPagesLoaded: Int = 0

    enum Source: String {
        case none
        case officialCollection
        case communitySite
    }

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Loading

    /// Load the catalogue.
    ///
    /// Two independent lists are kept:
    ///
    ///   - `officialAddons` — the 97 addons of `api.strem.io/addonscollection.json`.
    ///     Every one of them carries a `transportUrl`, so they install with
    ///     a single request.
    ///   - `communityAddons` — the community site at stremio-addons.net.
    ///     Far larger (70 pages of 10), but the list pages don't carry a
    ///     transport URL, so each entry is resolved from its detail page
    ///     when the user hits Install.
    ///
    /// They're kept apart rather than merged so the picker in the sheet
    /// shows exactly what each source contains, and so paging the
    /// community list doesn't shuffle the official one.
    func load(includeCommunity: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        var lastError: String?

        if officialAddons.isEmpty {
            do {
                let official = try await fetchOfficialCollection()
                officialAddons = official
            } catch {
                lastError = error.localizedDescription
            }
        }

        if includeCommunity && communityAddons.isEmpty {
            do {
                let community = try await fetchCommunityPage(page: 1)
                communityAddons = community
                communityPagesLoaded = community.isEmpty ? 0 : 1
            } catch {
                if officialAddons.isEmpty {
                    lastError = lastError ?? error.localizedDescription
                }
            }
        }

        if officialAddons.isEmpty && communityAddons.isEmpty {
            if lastError == nil { lastError = "The addon catalogue came back empty." }
            error = lastError
        } else {
            error = nil
        }
    }

    /// The addons currently shown, for the given source.
    func addons(for source: Source) -> [CatalogAddon] {
        switch source {
        case .officialCollection: return officialAddons
        case .communitySite:      return communityAddons
        case .none:               return officialAddons + communityAddons
        }
    }

    /// Fetch more community pages and append them.
    ///
    /// The site paginates 10 addons per page and has roughly 70 pages.
    /// We walk forward from the page after the last one loaded, so
    /// repeated calls keep growing the list.
    func loadMoreCommunityPages(count: Int = 3) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let start = communityPagesLoaded + 1
        for p in start..<(start + count) {
            guard let more = try? await fetchCommunityPage(page: p), !more.isEmpty else { continue }
            let existing = Set(communityAddons.map(\.id))
            let fresh = more.filter { !existing.contains($0.id) }
            guard !fresh.isEmpty else { continue }
            communityAddons.append(contentsOf: fresh)
            communityPagesLoaded = p
        }
    }

    /// Whether the community site still has pages left to fetch.
    var hasMoreCommunityPages: Bool {
        communityPagesLoaded > 0 && communityPagesLoaded < 70
    }

    // MARK: - Official collection

    private struct CollectionEntry: Decodable {
        let transportUrl: String
        let manifest: CollectionManifest?
    }

    private struct CollectionManifest: Decodable {
        let id: String
        let name: String
        let description: String?
        let logo: String?
        let background: String?
        let version: String?
        let types: [String]?
        let resources: [CommunityResource]?
        let catalogs: [CollectionCatalog]?
    }

    /// The manifest's `resources` is either a list of strings or a list of
    /// objects with a `name`. The official collection mixes both.

    private struct CollectionCatalog: Decodable {
        let id: String
        /// Some catalogues in the official collection omit `name`
        /// entirely, so it falls back to the id.
        let name: String
        let type: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            id = try c.decode(String.self, forKey: .id)
            type = try c.decode(String.self, forKey: .type)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        }

        private enum K: String, CodingKey { case id, name, type }
    }

    private func fetchOfficialCollection() async throws -> [CatalogAddon] {
        let url = URL(string: "https://api.strem.io/addonscollection.json")!
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let entries = try JSONDecoder().decode([CollectionEntry].self, from: data)

        return entries.compactMap { entry in
            guard let m = entry.manifest else { return nil }
            let resources = (m.resources ?? []).map(\.name)
            let slug = Self.slugify(m.id)
            return CatalogAddon(
                id: m.id,
                name: m.name,
                slug: slug,
                description: m.description,
                logo: m.logo,
                background: m.background,
                version: m.version,
                types: m.types ?? [],
                resources: resources,
                catalogCount: m.catalogs?.count ?? 0,
                transportUrl: entry.transportUrl
            )
        }
    }

    // MARK: - Community site

    /// Fetch one page of the community site and parse the embedded manifests.
    ///
    /// The list page embeds each addon as a React Server Components node:
    ///
    ///     "href":"/addons/torrentio" ... "manifest":{"id":"com.stremio..."}
    ///
    /// inside a JS string, so every `"` is backslash-escaped. We unescape
    /// the whole payload first, then balance braces to extract each
    /// manifest object.
    private func fetchCommunityPage(page: Int) async throws -> [CatalogAddon] {
        var url = URL(string: "https://stremio-addons.net/addons")!
        if page > 1 {
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "page", value: String(page))]
            url = c.url!
        }
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let html = String(decoding: data, as: UTF8.self)
        return Self.parseCommunityPage(html)
    }

    /// Exposed for tests: parse the addon list out of a community page.
    static func parseCommunityPage(_ html: String) -> [CatalogAddon] {
        var out: [CatalogAddon] = []

        for body in rscPayloadBodies(html) {
            // A payload body can contain several addons. Each one is a
            // `"href":"/addons/<slug>"` followed by a `"manifest":{…}`
            // object, in that order.
            var searchFrom = body.startIndex

            while let hrefRange = body.range(of: "\"href\":\"/addons/", range: searchFrom..<body.endIndex) {
                let slug = Self.slugAfterHref(in: body, from: hrefRange.upperBound)
                guard let slug else {
                    searchFrom = hrefRange.upperBound
                    continue
                }

                // The manifest for this addon is the next one in the body.
                guard let keyRange = body.range(of: "\"manifest\":", range: hrefRange.upperBound..<body.endIndex),
                      let objRange = balancedObjectRange(in: body, from: keyRange.upperBound),
                      let data = String(body[objRange]).data(using: .utf8),
                      let manifest = try? JSONDecoder().decode(CommunityManifest.self, from: data) else {
                    searchFrom = hrefRange.upperBound
                    continue
                }

                out.append(manifest.toCatalogAddon(slug: slug))
                searchFrom = keyRange.upperBound
            }
        }
        return out
    }

    /// Read the slug that follows a `/addons/` href.
    private static func slugAfterHref(in text: String, from index: String.Index) -> String? {
        let slug = text[index...].prefix {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
        }
        return slug.isEmpty ? nil : String(slug)
    }

    /// Extract the transport URL for a community addon.
    ///
    /// The detail page lists every mirror the site knows about, as plain
    /// `https://host/path/manifest.json` strings. We take the first.
    func resolveTransportUrl(slug: String) async -> String? {
        guard let url = URL(string: "https://stremio-addons.net/addons/\(slug)") else { return nil }
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else { return nil }
        let html = String(decoding: data, as: UTF8.self)

        // Manifest URLs appear in the page as plain absolute links.
        let pattern = "https://[A-Za-z0-9._-]+[A-Za-z0-9._/-]*manifest\\.json"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let r = Range(match.range, in: html) else { return nil }
        return String(html[r])
    }

    // MARK: - Parsing helpers

    private struct CommunityManifest: Decodable {
        let id: String
        let name: String
        let description: String?
        let logo: String?
        let background: String?
        let version: String?
        let types: [String]?
        let resources: [CommunityResource]?
        let catalogs: [CommunityCatalog]?

        func toCatalogAddon(slug: String) -> CatalogAddon {
            let resources = (self.resources ?? []).map(\.name)
            return CatalogAddon(
                id: id,
                name: name,
                slug: slug,
                description: description,
                logo: logo,
                background: background,
                version: version,
                types: types ?? [],
                resources: resources,
                catalogCount: catalogs?.count ?? 0,
                transportUrl: nil
            )
        }
    }

    /// A `resources` entry: either a bare string (`"catalog"`) or an
    /// object (`{"name": "stream", "types": [...], "idPrefixes": [...]}`).
    ///
    /// Only `name` is read. The object form carries arrays alongside it,
    /// so it must not be decoded as a flat string dictionary.
    private enum CommunityResource: Decodable {
        case name(String)
        case object(String)

        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                self = .name(s)
                return
            }
            let c = try decoder.container(keyedBy: NameKey.self)
            self = .object(try c.decodeIfPresent(String.self, forKey: .name) ?? "")
        }

        private enum NameKey: String, CodingKey { case name }

        var name: String {
            switch self {
            case .name(let s): return s
            case .object(let s): return s
            }
        }
    }

    private struct CommunityCatalog: Decodable {
        let id: String
        /// Some addons omit `name` on their catalogues.
        let name: String
        let type: String

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: K.self)
            id = try c.decode(String.self, forKey: .id)
            type = try c.decode(String.self, forKey: .type)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        }

        private enum K: String, CodingKey { case id, name, type }
    }

    /// Extract and unescape the payload bodies the Next.js page pushes.
    ///
    /// The page calls `self.__next_f.push([1,"…"])` several times. Each
    /// argument is a JS string literal: `\"` for a quote, `\\` for a
    /// backslash, `\n` for a newline, `\/` for a slash, `\uXXXX` for a
    /// unicode escape.
    ///
    /// The bodies are returned separately rather than concatenated. That
    /// matters: a manifest object can straddle a push boundary, and
    /// unescaping the whole document at once would let a `"` inside one
    /// push corrupt the quote-tracking of the next.
    static func rscPayloadBodies(_ html: String) -> [String] {
        let marker = "self.__next_f.push([1,\""
        var bodies: [String] = []
        var searchFrom = html.startIndex

        while let pushRange = html.range(of: marker, range: searchFrom..<html.endIndex) {
            var index = pushRange.upperBound
            var out = ""

            // Walk the JS string literal to its closing quote.
            while index < html.endIndex {
                let ch = html[index]
                if ch == "\\" {
                    let next = html.index(after: index)
                    guard next < html.endIndex else { break }
                    let esc = html[next]
                    switch esc {
                    case "n":  out.append("\n")
                    case "t":  out.append("\t")
                    case "r":  out.append("\r")
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/":  out.append("/")
                    case "u":
                        let hexStart = html.index(after: next)
                        let hexEnd = html.index(hexStart, offsetBy: 4, limitedBy: html.endIndex) ?? hexStart
                        if let value = UInt32(html[hexStart..<hexEnd], radix: 16),
                           let scalar = Unicode.Scalar(value) {
                            out.append(Character(scalar))
                        }
                        index = hexEnd
                        continue
                    default:
                        out.append(esc)
                    }
                    index = html.index(after: next)
                    continue
                }
                if ch == "\"" { break }   // end of this string literal
                out.append(ch)
                index = html.index(after: index)
            }

            bodies.append(out)
            searchFrom = index
        }
        return bodies
    }

    /// Find the range of a balanced `{...}` object starting at `from`.
    static func balancedObjectRange(in text: String, from: String.Index) -> Range<String.Index>? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = from
        while i < text.endIndex {
            let ch = text[i]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else {
                if ch == "\"" { inString = true }
                else if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return from..<text.index(after: i)
                    }
                }
            }
            i = text.index(after: i)
        }
        return nil
    }

    /// The last `/addons/<slug>` href appearing before the current manifest.
    private static func lastSlug(in prefix: String) -> String? {
        guard let r = prefix.range(of: "\"/addons/", options: .backwards) else { return nil }
        let after = prefix[r.upperBound...]
        let slug = after.prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        return slug.isEmpty ? nil : String(slug)
    }

    /// Turn an addon id into a plausible slug, for the ones that don't
    /// carry one in the payload.
    static func slugify(_ id: String) -> String {
        id.lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }
}
