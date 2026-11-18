import Foundation
import AppKit
import Observation

/// Lightweight ring-buffer of recent log entries. Any service that wants
/// to help the user debug a weird state posts into `DebugLog.shared`;
/// the Settings → Storage pane renders it.
///
/// Keeping this in Swift (not NSLog) means the user sees context without
/// opening Console.app. Entries are capped so the buffer never leaks.
@MainActor
@Observable
final class DebugLog {
    static let shared = DebugLog()

    enum Level: String { case info, warn, error }

    struct Entry: Identifiable, Hashable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let source: String
        let message: String
    }

    private(set) var entries: [Entry] = []
    private let capacity = 400

    func info(_ source: String, _ message: String) { add(.info, source, message) }
    func warn(_ source: String, _ message: String) { add(.warn, source, message) }
    func error(_ source: String, _ message: String) { add(.error, source, message) }

    func clear() { entries.removeAll() }

    private func add(_ level: Level, _ source: String, _ rawMessage: String) {
        let message = Self.redact(rawMessage)
        entries.append(Entry(timestamp: Date(), level: level, source: source, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        // Mirror to NSLog so native log readers still see the stream.
        NSLog("[%@] %@ · %@", level.rawValue.uppercased(), source, message)
    }

    /// Mask credentials that ride inside URLs before anything is logged:
    /// Xtream paths (`/movie/<user>/<pass>/123.mkv`), and token or
    /// password query items (Jellyfin `api_key`, Plex `X-Plex-Token`,
    /// Xtream `password`). The log is meant to be pasted into bug reports.
    nonisolated static func redact(_ text: String) -> String {
        var out = text
        let rules: [(String, String)] = [
            (#"/(live|movie|series|timeshift)/[^/\s]+/[^/\s]+/"#, "/$1/***/***/"),
            (#"(?i)\b(api_?key|x-plex-token|password|token|access_token)=[^&\s"']+"#, "$1=***"),
        ]
        for (pattern, template) in rules {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    /// Copy the current log to the clipboard as plain text — makes it
    /// trivial to paste into a bug report.
    func copyToPasteboard() {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let text = entries.map { e in
            "\(fmt.string(from: e.timestamp)) \(e.level.rawValue.uppercased()) \(e.source): \(e.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
