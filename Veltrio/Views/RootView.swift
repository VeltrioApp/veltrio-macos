import SwiftUI

enum NavItem: String, CaseIterable, Identifiable {
    case home     = "Home"
    case library  = "Collection"
    case iptv     = "Live"
    case addons   = "Sources"

    var id: String { rawValue }

    /// Index used by the editorial nav bar ("01 — HOME").
    var index: Int {
        switch self {
        case .home: return 1
        case .library: return 2
        case .iptv: return 3
        case .addons: return 4
        }
    }

    var icon: String {
        switch self {
        case .home:    return "house.fill"
        case .library: return "square.stack.fill"
        case .iptv:    return "dot.radiowaves.left.and.right"
        case .addons:  return "puzzlepiece.extension.fill"
        }
    }
}

struct SearchDestination: Hashable {}

struct RootView: View {
    @State private var selection: NavItem = .home
    @State private var path = NavigationPath()
    @State private var showSettings = false
    private let prefs = UserPrefs.shared

    private var preferredScheme: ColorScheme? {
        switch prefs.colorScheme {
        case .system: return nil
        case .dark:   return .dark
        case .light:  return .light
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .top) {
                Theme.Palette.background.ignoresSafeArea()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                TopNavBar(
                    selection: $selection,
                    onSearch:   { path.append(SearchDestination()) },
                    onSettings: { showSettings.toggle() }
                )
            }
            .navigationDestination(for: DetailDestination.self) { dest in
                DetailView(destination: dest)
            }
            .navigationDestination(for: PlayerDestination.self) { dest in
                PlayerView(destination: dest)
            }
            .navigationDestination(for: MediaServerSeriesDestination.self) { dest in
                MediaServerSeriesView(destination: dest)
            }
            .navigationDestination(for: IptvSeriesDestination.self) { dest in
                IptvSeriesView(destination: dest)
            }
            .navigationDestination(for: SearchDestination.self) { _ in
                SearchView()
            }
            .navigationDestination(for: CatalogDestination.self) { dest in
                CatalogGridView(destination: dest)
            }
        }
        .tint(Theme.Palette.accent)
        .preferredColorScheme(preferredScheme)
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
                .frame(minWidth: 860, idealWidth: 920, minHeight: 580, idealHeight: 680)
                // Sheets don't inherit the stack's tint: switches and
                // pickers would fall back to the system blue.
                .tint(Theme.Palette.accent)
        }
        .onChange(of: selection) { _, _ in path = NavigationPath() }
        .onReceive(NotificationCenter.default.publisher(for: .veltrioGoto)) { note in
            if let item = note.object as? NavItem { selection = item }
        }
        .onReceive(NotificationCenter.default.publisher(for: .veltrioPlay)) { note in
            if let destination = note.object as? PlayerDestination { path.append(destination) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .veltrioZap)) { note in
            guard let destination = note.object as? PlayerDestination else { return }
            if !path.isEmpty { path.removeLast() }
            path.append(destination)
        }
        .onReceive(NotificationCenter.default.publisher(for: .veltrioOpenSearch)) { _ in
            path.append(SearchDestination())
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .home:
            HomeView()
        case .library:
            LibraryView()
                .padding(.top, Theme.navBarInset)
        case .iptv:
            IPTVView()
                .padding(.top, Theme.navBarInset)
        case .addons:
            SourcesView()
                .padding(.top, Theme.navBarInset)
        }
    }}

// MARK: - Top nav bar
//
// Editorial, not a navigation chrome. A thin black-washed bar, wordmark
// left in serif, numbered text-link tabs center, and a tracked "SEARCH ⌘K"
// link on the right. One pixel of amber under the active tab.

private struct TopNavBar: View {
    @Binding var selection: NavItem
    let onSearch: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Theme.Spacing.xl) {
                wordmark
                    .padding(.leading, Theme.trafficLightInset)
                Spacer(minLength: Theme.Spacing.xl)
                navItems
                Spacer(minLength: Theme.Spacing.xl)
                trailingActions
            }
            .padding(.horizontal, Theme.Layout.contentInset)
            .padding(.vertical, 20)
            .frame(height: Theme.navBarInset - 1)
            Rule(color: Theme.Palette.border, weight: 1)
        }
        .background(
            Theme.Palette.background.opacity(0.92)
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var wordmark: some View {
        Text("Veltrio")
            .font(Theme.Font.displaySerif(26, weight: .bold))
            .tracking(-0.4)
            .foregroundStyle(Theme.Palette.textPrimary)
            .accessibilityLabel("Veltrio")
    }

    private var navItems: some View {
        HStack(spacing: 32) {
            ForEach(NavItem.allCases) { item in
                TextLinkTab(
                    label: item.rawValue,
                    number: item.index,
                    isSelected: selection == item
                ) { selection = item }
            }
        }
    }

    private var trailingActions: some View {
        HStack(spacing: Theme.Spacing.md) {
            SearchBarTrigger(action: onSearch)
                .accessibilityIdentifier("nav.search")
            IconButton(system: "gearshape.fill", tooltip: "Settings", action: onSettings)
                .accessibilityIdentifier("nav.settings")
        }
    }
}

/// Fat, framed "Search ⌘K" trigger that looks like an actual button /
/// search bar at rest — the nav's second CTA after the tabs.
private struct SearchBarTrigger: View {
    let action: () -> Void
    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                Text("Search")
                    .font(Theme.Font.eyebrow(11, weight: .bold))
                    .tracking(2.2)
                    .textCase(.uppercase)
                Spacer(minLength: 16)
                Text("⌘K")
                    .font(Theme.Font.mono(10, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textQuaternary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
            }
            .foregroundStyle(
                isHovering ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(width: 220)
            .background(
                Rectangle().fill(
                    isHovering
                        ? Theme.Palette.textPrimary.opacity(isPressed ? 0.14 : 0.08)
                        : Color.clear
                )
            )
            .overlay(Rectangle().stroke(
                isHovering ? Theme.Palette.textPrimary : Theme.Palette.borderStrong,
                lineWidth: 1.5
            ))
        }
        .buttonStyle(.plainRect)
        .onHover { h in
            isHovering = h
            Platform.pointingCursor(h)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}


// MARK: - Settings sheet

private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preferences")
                        .eyebrow(Theme.Palette.accentText, tracking: 2.8)
                    Text("Settings")
                        .font(Theme.Font.displaySerif(32, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Text("Close")
                            .eyebrow(Theme.Palette.textTertiary, tracking: 2.2)
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                }
                .buttonStyle(.plainRect)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.md)
            Rule()
            SettingsView()
        }
        .background(Theme.Palette.background)
    }
}
