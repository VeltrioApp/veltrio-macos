import Foundation
#if os(macOS)
import AppKit
#endif
#if !os(tvOS)
import MetricKit

/// Keeps the crash, hang and exception reports macOS hands the app.
///
/// MetricKit delivers diagnostics for the previous sessions at launch
/// (and periodically after). There's no server to send them to, so each
/// payload is written to `~/Library/Application Support/Veltrio/
/// Diagnostics/` as JSON; Settings → About shows how many there are and
/// reveals the folder, so a user can attach them to a bug report.
final class CrashReports: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReports()

    static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Veltrio/Diagnostics", isDirectory: true)
    }()

    /// Reports older than this are pruned at launch so the folder can't
    /// grow without bound.
    private static let retention: TimeInterval = 60 * 24 * 3600

    func start() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        prune()
        MXMetricManager.shared.add(self)
        // Payloads that arrived while the app wasn't subscribed yet.
        save(MXMetricManager.shared.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        save(payloads)
    }

    /// Saved report files, newest first.
    static func reports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func revealInFinder() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([reports().first ?? directory])
        #endif
    }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        for payload in payloads {
            // Typed out: Xcode 16's type checker gives up on the literal.
            let counts: [(Int, String)] = [
                (payload.crashDiagnostics?.count ?? 0, "crash"),
                (payload.hangDiagnostics?.count ?? 0, "hang"),
                (payload.cpuExceptionDiagnostics?.count ?? 0, "cpu"),
                (payload.diskWriteExceptionDiagnostics?.count ?? 0, "disk"),
            ]
            let kinds = counts.filter { $0.0 > 0 }.map(\.1)
            guard !kinds.isEmpty else { continue }
            let name = "\(stamp.string(from: payload.timeStampEnd))-\(kinds.joined(separator: "+")).json"
                .replacingOccurrences(of: ":", with: "-")
            try? payload.jsonRepresentation().write(to: Self.directory.appendingPathComponent(name))
        }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        for url in Self.reports() {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}
#else
/// tvOS has no MetricKit diagnostics: nothing is collected there.
final class CrashReports {
    static let shared = CrashReports()
    func start() {}
    static func reports() -> [URL] { [] }
    static func revealInFinder() {}
}
#endif
