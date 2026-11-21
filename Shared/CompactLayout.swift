import SwiftUI

/// Pages laid out in columns on a Mac (the title page: info beside the
/// streams, each scrolling on its own) stack them on a phone, and the page
/// scrolls as one. Set by the page from its width.
private struct CompactPageKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var compactPage: Bool {
        get { self[CompactPageKey.self] }
        set { self[CompactPageKey.self] = newValue }
    }
}

/// Scrolls its content in a column of its own, unless the page is compact
/// (then the page's own scroll carries it).
struct ScrollUnlessCompact<Content: View>: View {
    @Environment(\.compactPage) private var compact
    @ViewBuilder let content: Content

    var body: some View {
        if compact { content } else { ScrollView { content } }
    }
}

extension View {
    /// On a Mac, pages run under the hidden title bar; on iOS the top
    /// edge belongs to the status bar.
    @ViewBuilder
    func ignoresTopSafeAreaOnMac() -> some View {
        #if os(macOS)
        ignoresSafeArea(edges: .top)
        #else
        self
        #endif
    }
}

extension View {
    /// An inline title in a phone's navigation bar; nothing on a Mac.
    @ViewBuilder
    func navigationBarTitleDisplayModeInlineOnPhone() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension View {
    /// No navigation bar on a phone page that draws its own header.
    @ViewBuilder
    func hidesNavigationBarOnPhone() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .navigationBar)
        #else
        self
        #endif
    }
}

extension View {
    /// A menu drawn as its label only (the Mac's borderless button style).
    @ViewBuilder
    func borderlessMenu() -> some View {
        #if os(macOS)
        menuStyle(.borderlessButton)
        #else
        menuStyle(.button).buttonStyle(.plain)
        #endif
    }
}

extension View {
    /// The Mac's window toolbar out of the way (the player is full bleed).
    @ViewBuilder
    func hidesWindowToolbarOnMac() -> some View {
        #if os(macOS)
        toolbar(.hidden, for: .windowToolbar)
        #else
        self
        #endif
    }
}

extension View {
    /// A sheet's size on a Mac. On an iPhone or iPad the system sizes the
    /// sheet to the screen; a Mac's minimum width would push it off.
    @ViewBuilder
    func macSheetFrame(minWidth: CGFloat? = nil, idealWidth: CGFloat? = nil, width: CGFloat? = nil,
                       minHeight: CGFloat? = nil, idealHeight: CGFloat? = nil, maxHeight: CGFloat? = nil) -> some View {
        #if os(macOS)
        if let width {
            frame(width: width).frame(minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight)
        } else {
            frame(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight, idealHeight: idealHeight, maxHeight: maxHeight)
        }
        #else
        self
        #endif
    }
}

extension View {
    /// A field for an address, a user name or a password: no capital
    /// letter or correction from the keyboard.
    func plainEntry() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}

extension View {
    /// A pointer's hover, where there is one. tvOS has no pointer: the
    /// remote's focus shows instead (see `PlainRectButtonStyle`).
    @ViewBuilder
    func pointerHover(_ action: @escaping (Bool) -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        onHover(perform: action)
        #endif
    }
}

extension View {
    /// Tracks a press from touch or click down to up, for a pressed look.
    /// The remote's buttons press through `ButtonStyle` instead (tvOS).
    @ViewBuilder
    func pressTracking(_ isPressed: Binding<Bool>) -> some View {
        #if os(tvOS)
        self
        #else
        simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed.wrappedValue = true }
                .onEnded { _ in isPressed.wrappedValue = false }
        )
        #endif
    }

    /// Escape triggers this button (a Mac's keyboard; Menu on a remote
    /// goes back through the navigation stack instead).
    @ViewBuilder
    func escapeShortcut() -> some View {
        #if os(tvOS)
        self
        #else
        keyboardShortcut(.escape, modifiers: [])
        #endif
    }
}

extension View {
    /// A focus section for the remote (tvOS) and the keyboard (macOS);
    /// iOS has none.
    @ViewBuilder
    func remoteFocusSection() -> some View {
        #if os(iOS)
        self
        #else
        focusSection()
        #endif
    }
}
