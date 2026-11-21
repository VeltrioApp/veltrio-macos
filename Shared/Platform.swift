import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few things the shared views do differently on a Mac and on an
/// iPhone or iPad: opening a link, the clipboard, the pointer.
enum Platform {
    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    @MainActor
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
        // tvOS has no pasteboard.
    }

    /// The pointing hand over something clickable (a Mac's pointer only).
    static func pointingCursor(_ on: Bool) {
        #if os(macOS)
        if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        #endif
    }
}
