import Foundation
import Observation

/// Lightweight download manager for offline playback. Given a resolved
/// HTTP(S) URL for a stream + a display title, kicks off a `URLSession`
/// background-style download into Application Support, exposing progress
/// to the UI and letting the player open the local file when complete.
///
/// Scope for this pass:
/// - HTTP(S) sources only (direct URLs, debrid-unrestricted, or the local
///   librqbit HTTP server — all look like plain URLs from here).
/// - One tracked item per `id` (we use the Stremio content id).
/// - Resumable: we persist the metadata so a restart surfaces the file.
///
/// Not in scope:
/// - Background downloads surviving app quit (needs an app session with
///   Transfer Service — easy later).
/// - DASH / HLS segment merging — mpv already plays those URL-direct.

struct DownloadItem: Codable, Hashable, Identifiable {
    enum Status: String, Codable { case queued, downloading, completed, failed, paused }
    var id: String             // content id (e.g. tt28635800 or tt28635800:1:3)
    var title: String
    var sourceUrl: String
    var localPath: String
    var bytesExpected: Int64
    var bytesDownloaded: Int64
    var status: Status
    var errorMessage: String?
    var createdAt: Date

    var progress: Double {
        guard bytesExpected > 0 else { return 0 }
        return min(1, Double(bytesDownloaded) / Double(bytesExpected))
    }
}

@MainActor
@Observable
final class DownloadManager: NSObject {
    private(set) var items: [DownloadItem] = []
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var session: URLSession!

    private let fileURL: URL
    private let downloadsDir: URL

    override init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Veltrio", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let dl = support.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dl, withIntermediateDirectories: true)

        self.fileURL = support.appendingPathComponent("downloads.json")
        self.downloadsDir = dl

        super.init()

        let cfg = URLSessionConfiguration.default
        cfg.allowsConstrainedNetworkAccess = true
        cfg.waitsForConnectivity = true
        self.session = URLSession(
            configuration: cfg,
            delegate: self,
            delegateQueue: .main
        )

        load()
    }

    // MARK: - Public API

    /// Kick off a download. If this id is already queued/completed, no-op.
    func start(id: String, title: String, url: URL) {
        if let existing = items.first(where: { $0.id == id }) {
            if existing.status == .completed || existing.status == .downloading { return }
        }
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let safeId = id.replacingOccurrences(of: "/", with: "_")
        let dst = downloadsDir
            .appendingPathComponent("\(safeId).\(ext)")
        let item = DownloadItem(
            id: id, title: title,
            sourceUrl: url.absoluteString,
            localPath: dst.path,
            bytesExpected: 0, bytesDownloaded: 0,
            status: .downloading,
            errorMessage: nil,
            createdAt: Date()
        )
        upsert(item)

        var req = URLRequest(url: url)
        req.setValue("Veltrio/0.1", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: req)
        task.taskDescription = id
        tasks[id] = task
        task.resume()
        DebugLog.shared.info("downloads", "started \(id) from \(url.host ?? "?")")
    }

    func cancel(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if var e = items.first(where: { $0.id == id }) {
            e.status = .paused
            upsert(e)
        }
    }

    func remove(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if let e = items.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(atPath: e.localPath)
        }
        items.removeAll { $0.id == id }
        persist()
    }

    /// Returns the local file URL if this id is fully downloaded.
    func localURL(forId id: String) -> URL? {
        guard let e = items.first(where: { $0.id == id }), e.status == .completed
        else { return nil }
        let url = URL(fileURLWithPath: e.localPath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Internal

    private func upsert(_ item: DownloadItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
        } else {
            items.append(item)
        }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let list = try? dec.decode([DownloadItem].self, from: data) {
            // Surface downloading→paused on relaunch; the user can resume
            // manually later.
            self.items = list.map { e in
                guard e.status == .downloading else { return e }
                var p = e; p.status = .paused; return p
            }
        }
    }
}

// MARK: - URLSession delegates

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskDescription ?? ""
        let data = try? Data(contentsOf: location)
        Task { @MainActor in
            guard var e = self.items.first(where: { $0.id == id }) else { return }
            let dst = URL(fileURLWithPath: e.localPath)
            try? FileManager.default.removeItem(at: dst)
            if let data {
                try? data.write(to: dst)
                e.bytesDownloaded = Int64(data.count)
            }
            e.status = .completed
            self.tasks[id] = nil
            self.upsert(e)
            DebugLog.shared.info("downloads", "completed \(id)")
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskDescription ?? ""
        Task { @MainActor in
            guard var e = self.items.first(where: { $0.id == id }) else { return }
            e.bytesDownloaded = totalBytesWritten
            e.bytesExpected = max(e.bytesExpected, totalBytesExpectedToWrite)
            self.upsert(e)
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let error else { return }
        let id = task.taskDescription ?? ""
        let msg = "\(error)"
        Task { @MainActor in
            guard var e = self.items.first(where: { $0.id == id }) else { return }
            if e.status == .completed { return }
            e.status = .failed
            e.errorMessage = msg
            self.tasks[id] = nil
            self.upsert(e)
            DebugLog.shared.error("downloads", "failed \(id): \(msg)")
        }
    }
}
