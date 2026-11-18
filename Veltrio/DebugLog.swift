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

    private func add(_ level: Level, _ source: String, _ message: String) {
        entries.append(Entry(timestamp: Date(), level: level, source: source, message: message))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        // Mirror to NSLog so native log readers still see the stream.
        NSLog("[%@] %@ · %@", level.rawValue.uppercased(), source, message)
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
