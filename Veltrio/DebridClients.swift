import Foundation

/// TorBox and Premiumize. Both authenticate with the API key the user
/// copies from their account page (neither offers a device or PIN flow to
/// third-party apps), check a batch of info hashes for cached torrents,
/// and turn a cached torrent into a direct HTTPS link.

enum DebridAPIError: LocalizedError {
    case http(Int)
    case rejected(String)
    case notCached
    case noPlayableFile

    var errorDescription: String? {
        switch self {
        case .http(let code):   return String(localized: "The service answered HTTP \(code).")
        case .rejected(let m):  return m
        case .notCached:        return String(localized: "This torrent isn't cached on the service.")
        case .noPlayableFile:   return String(localized: "No video file in this torrent.")
        }
    }
}

/// Which file of a torrent to play: the one named after the episode when
/// a season and episode are given, else the biggest video. Keeps a
/// "Sample.mkv" or a season pack's first episode from being picked.
enum DebridFilePicker {
    static let videoExtensions: Set<String> = ["mkv", "mp4", "avi", "mov", "ts", "m4v", "webm"]

    static func pick<File>(_ files: [File], path: (File) -> String, size: (File) -> Int64,
                           season: Int32?, episode: Int32?) -> File? {
        let videos = files.filter { videoExtensions.contains((path($0) as NSString).pathExtension.lowercased()) }
        if let s = season, let e = episode {
            let patterns = [String(format: "S%02dE%02d", s, e), String(format: "%dx%02d", s, e),
                            "S\(s)E\(e)", " \(s)x\(e)"]
            if let match = videos.first(where: { f in
                let upper = path(f).uppercased()
                return patterns.contains { upper.contains($0) }
            }) {
                return match
            }
        }
        return videos.max { size($0) < size($1) }
    }
}

// MARK: - TorBox

/// https://api.torbox.app/v1/api — bearer API key.
struct TorBoxClient {
    struct User: Decodable, Hashable {
        let email: String?
        let plan: Int?
        /// TorBox plans: 0 free, 1 essential, 2 pro, 3 standard.
        var isPaid: Bool { (plan ?? 0) > 0 }
    }

    private let base = URL(string: "https://api.torbox.app/v1/api")!
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    private struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let detail: String?
        let data: T?
    }

    func user(apiKey: String) async throws -> User {
        try await get("user/me", apiKey: apiKey)
    }

    /// Hash → cached. Hashes missing from the answer aren't cached.
    func checkCached(hashes: [String], apiKey: String) async throws -> [String: Bool] {
        var result: [String: Bool] = [:]
        // The endpoint takes a comma-separated list; keep requests short.
        for chunk in stride(from: 0, to: hashes.count, by: 50).map({ Array(hashes[$0..<min($0 + 50, hashes.count)]) }) {
            let found: [String: CachedEntry] = (try? await get(
                "torrents/checkcached",
                query: ["hash": chunk.joined(separator: ","), "format": "object"],
                apiKey: apiKey
            )) ?? [:]
            let cached = Set(found.keys.map { $0.lowercased() })
            for h in chunk { result[h.lowercased()] = cached.contains(h.lowercased()) }
        }
        return result
    }

    private struct CachedEntry: Decodable { let name: String? }

    /// Adds the magnet (instant when cached), picks the file, returns its
    /// direct link.
    func resolveStream(infoHash: String, season: Int32?, episode: Int32?, apiKey: String) async throws -> String {
        struct Created: Decodable { let torrent_id: Int }
        let magnet = "magnet:?xt=urn:btih:\(infoHash)"
        let created: Created = try await postForm("torrents/createtorrent", fields: ["magnet": magnet], apiKey: apiKey)

        struct Torrent: Decodable {
            let download_present: Bool?
            let files: [File]?
            struct File: Decodable { let id: Int; let name: String; let size: Int64 }
        }
        let torrent: Torrent = try await get(
            "torrents/mylist", query: ["id": String(created.torrent_id), "bypass_cache": "true"], apiKey: apiKey
        )
        guard torrent.download_present == true else { throw DebridAPIError.notCached }
        guard let file = DebridFilePicker.pick(torrent.files ?? [], path: \.name, size: \.size,
                                               season: season, episode: episode) else {
            throw DebridAPIError.noPlayableFile
        }
        let link: String = try await get(
            "torrents/requestdl",
            query: ["token": apiKey, "torrent_id": String(created.torrent_id), "file_id": String(file.id)],
            apiKey: apiKey
        )
        return link
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], apiKey: String) async throws -> T {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return try await send(req)
    }

    private func postForm<T: Decodable>(_ path: String, fields: [String: String], apiKey: String) async throws -> T {
        let boundary = "veltrio-\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await send(req)
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        let env = try? JSONDecoder().decode(Envelope<T>.self, from: data)
        if let env, env.success, let value = env.data { return value }
        if let detail = env?.detail { throw DebridAPIError.rejected(detail) }
        throw DebridAPIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

// MARK: - Premiumize

/// https://www.premiumize.me/api — `apikey` query parameter.
struct PremiumizeClient {
    struct Account: Decodable, Hashable {
        let customer_id: FlexibleId?
        let premium_until: Double?
        var isPremium: Bool { (premium_until ?? 0) > Date().timeIntervalSince1970 }
    }

    private let base = "https://www.premiumize.me/api"
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    private struct Status: Decodable { let status: String; let message: String? }

    func account(apiKey: String) async throws -> Account {
        try await call("account/info", query: [("apikey", apiKey)])
    }

    func checkCached(hashes: [String], apiKey: String) async throws -> [String: Bool] {
        struct Answer: Decodable { let response: [Bool] }
        var result: [String: Bool] = [:]
        for chunk in stride(from: 0, to: hashes.count, by: 50).map({ Array(hashes[$0..<min($0 + 50, hashes.count)]) }) {
            let query = [("apikey", apiKey)] + chunk.map { ("items[]", $0) }
            guard let answer: Answer = try? await call("cache/check", query: query) else { continue }
            for (h, cached) in zip(chunk, answer.response) { result[h.lowercased()] = cached }
        }
        return result
    }

    /// `transfer/directdl` answers a cached torrent with its files' links
    /// straight away.
    func resolveStream(infoHash: String, season: Int32?, episode: Int32?, apiKey: String) async throws -> String {
        struct Answer: Decodable {
            let content: [File]?
            struct File: Decodable { let path: String; let size: Int64; let link: String? }
        }
        let answer: Answer = try await call("transfer/directdl", query: [("apikey", apiKey)],
                                            form: ["src": "magnet:?xt=urn:btih:\(infoHash)"])
        guard let file = DebridFilePicker.pick(answer.content ?? [], path: \.path, size: \.size,
                                               season: season, episode: episode),
              let link = file.link else {
            throw DebridAPIError.noPlayableFile
        }
        return link
    }

    private func call<T: Decodable>(_ path: String, query: [(String, String)], form: [String: String]? = nil) async throws -> T {
        var comps = URLComponents(string: "\(base)/\(path)")!
        comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        var req = URLRequest(url: comps.url!)
        if let form {
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            req.httpBody = Data(form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
                .joined(separator: "&").utf8)
        }
        let (data, resp) = try await session.data(for: req)
        if let status = try? JSONDecoder().decode(Status.self, from: data), status.status != "success" {
            throw DebridAPIError.rejected(status.message ?? String(localized: "The service refused the request."))
        }
        guard (resp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? false else {
            throw DebridAPIError.http((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
