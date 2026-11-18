import SwiftUI

// MARK: - Rule
//
// Hairline rules carry a lot of weight in this design system — they are
// the main structural device (no rounded cards everywhere). A Rule is 1pt
// tall, uses the hairline color, and spans its parent.

struct Rule: View {
    var color: Color = Theme.Palette.hairline
    var weight: CGFloat = 1
    var body: some View {
        Rectangle().fill(color).frame(height: weight)
    }
}

// MARK: - Numeral marker ("01", "02", …)
//
// Section counters double as part of the editorial grammar. The main
// view passes an incrementing index; the numeral is rendered mono, wide
// tracking, in a muted tone.

struct Numeral: View {
    let n: Int
    var body: some View {
        Text(String(format: "%02d", n))
            .font(Theme.Font.mono(10, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(Theme.Palette.textTertiary)
    }
}

// MARK: - PageHeader
//
// A page title in serif, with a long rule underneath that stretches across
// the full page. Optional eyebrow, optional trailing slot.

struct PageHeader<Trailing: View>: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(
        eyebrow: String? = nil,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .lastTextBaseline, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: 10) {
                    if let eyebrow {
                        Text(eyebrow.localized)
                            .eyebrow(Theme.Palette.accentText, tracking: 2.8)
                    }
                    Text(title.localized)
                        .font(Theme.Font.displaySerif(52, weight: .bold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .tracking(-1.2)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle.localized)
                            .font(Theme.Font.body(13))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                Spacer()
                trailing
            }
            Rule()
        }
    }
}

// MARK: - SectionHeader
//
// Numbered. Serif title. Rule extends to the right edge. Optional trailing
// slot sits above the rule.

struct SectionHeader<Trailing: View>: View {
    let number: Int?
    let title: String
    let subtitle: String?
    let trailing: Trailing

    init(_ title: String, number: Int? = nil, subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.number = number
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: Theme.Spacing.md) {
                if let n = number { Numeral(n: n) }
                Text(title.localized)
                    .font(Theme.Font.title(18))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle.localized)
                        .eyebrow(Theme.Palette.textTertiary, tracking: 1.8)
                }
                Spacer(minLength: Theme.Spacing.md)
                trailing
            }
            Rule()
        }
    }
}

// MARK: - TextLinkTab
//
// Nav items are text, not pills. A tracked-out label with a hairline that
// appears under the active one. Hover: label brightens.

struct TextLinkTab: View {
    let label: String
    let number: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(String(format: "%02d", number))
                    .font(Theme.Font.mono(10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(
                        isSelected ? Theme.Palette.accentText : Theme.Palette.textTertiary
                    )
                Text(label.localized)
                    .font(Theme.Font.label(12, weight: isSelected ? .bold : .medium))
                    .tracking(1.8)
                    .foregroundStyle(
                        isSelected
                            ? Theme.Palette.textPrimary
                            : (isHovering ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
                    )
                    .textCase(.uppercase)
            }
            .padding(.vertical, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? Theme.Palette.accent : .clear)
                    .frame(height: 1)
                    .offset(y: 6)
            }
            .animation(.easeOut(duration: 0.15), value: isSelected)
            .animation(.easeOut(duration: 0.1), value: isHovering)
        }
        .buttonStyle(.plainRect)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Chip (filter row)
//
// Same editorial language — text with a tiny underline when selected. No
// pill backgrounds anywhere.

struct Chip: View {
    let label: String
    var icon: String? = nil
    var count: Int? = nil
    var isSelected: Bool = false
    var filledUnselected: Bool = true // retained for API-compat, no-op
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(label.localized)
                    .font(Theme.Font.eyebrow(11, weight: isSelected ? .bold : .semibold))
                    .tracking(1.6)
                if let count {
                    Text("\(count)")
                        .font(Theme.Font.mono(9, weight: .regular))
                        .foregroundStyle(
                            isSelected ? Theme.Palette.accentText : Theme.Palette.textQuaternary
                        )
                }
            }
            .textCase(.uppercase)
            .foregroundStyle(
                isSelected
                    ? Theme.Palette.textPrimary
                    : (isHovering ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
            )
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? Theme.Palette.accent : .clear)
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plainRect)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isSelected)
    }
}

// MARK: - Buttons
//
// Three canonical shapes:
// - CTAButton  : solid amber block, primary action, one per screen
// - GhostButton: thick-border outlined button, secondary action
// - FrameButton: compact framed button for toolbars / nav / inline rows
//
// All share the same geometry rules: 2px hairline frame, 14×22 padding
// (10×16 for Frame), tracked-caps label, pointing-hand cursor on hover,
// a visible press state, and a subtle fill on hover.

/// Primary CTA. Solid block, strong presence. Reserve for hero + main
/// "Add / Install" actions.
struct CTAButton: View {
    let title: String
    var icon: String? = "play.fill"
    var tint: Color = Theme.Palette.accent
    var textColor: Color = Theme.Palette.onAccent
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if isLoading {
                    ProgressView().controlSize(.small).tint(textColor)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .black))
                }
                Text(title.localized)
                    .font(Theme.Font.eyebrow(11, weight: .heavy))
                    .tracking(2.6)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                Rectangle().fill(tint)
                    .brightness(isHovering && isEnabled ? 0.06 : 0)
                    .brightness(isPressed ? -0.1 : 0)
            )
            .overlay(Rectangle().stroke(tint, lineWidth: 2))
            .foregroundStyle(textColor)
            .opacity(isEnabled ? 1 : 0.4)
            .shadow(color: tint.opacity(isHovering && isEnabled ? 0.45 : 0.25),
                    radius: isHovering ? 22 : 14, y: isHovering ? 10 : 6)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: isPressed)
        }
        .buttonStyle(.plainRect)
        .disabled(!isEnabled)
        .onHover { h in
            isHovering = h
            if h, isEnabled { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}

/// Outlined secondary button. Real border (1.5pt), solid fill on hover.
struct GhostButton: View {
    let title: String
    var icon: String? = nil
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 11, weight: .bold))
                }
                Text(title.localized)
                    .font(Theme.Font.eyebrow(11, weight: .bold))
                    .tracking(2.4)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .background(
                Rectangle().fill(
                    isHovering
                        ? Theme.Palette.textPrimary.opacity(isPressed ? 0.14 : 0.08)
                        : Color.clear
                )
            )
            .overlay(
                Rectangle().stroke(
                    isHovering ? Theme.Palette.textPrimary : Theme.Palette.borderStrong,
                    lineWidth: 1.5
                )
            )
            .foregroundStyle(
                isHovering ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
            )
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.08), value: isPressed)
        }
        .buttonStyle(.plainRect)
        .disabled(!isEnabled)
        .onHover { h in
            isHovering = h
            if h, isEnabled { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }
}

/// Compact outlined button for toolbars, inline rows, menus. Smaller than
/// GhostButton. Replaces the old "TextLinkButton" everywhere.
struct FrameButton: View {
    let title: String
    var icon: String? = nil
    var color: Color = Theme.Palette.textPrimary
    var fill: Color? = nil   // when set, button reads as solid (strong CTA)
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().controlSize(.small).tint(labelColor)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 10, weight: .bold))
                }
                // Icon-only buttons (guide arrows) pass an empty title.
                if !title.isEmpty {
                    Text(title.localized)
                        .font(Theme.Font.eyebrow(10, weight: .bold))
                        .tracking(2.2)
                        .textCase(.uppercase)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(backgroundLayer)
            .overlay(Rectangle().stroke(borderColor, lineWidth: 1.5))
            .foregroundStyle(labelColor)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plainRect)
        .disabled(!isEnabled)
        .onHover { h in
            isHovering = h
            if h, isEnabled { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
    }

    @ViewBuilder private var backgroundLayer: some View {
        if let fill {
            Rectangle().fill(fill)
                .brightness(isHovering ? 0.05 : 0)
                .brightness(isPressed ? -0.08 : 0)
        } else {
            Rectangle().fill(
                isHovering
                    ? color.opacity(isPressed ? 0.18 : 0.10)
                    : Color.clear
            )
        }
    }

    private var borderColor: Color {
        if fill != nil { return fill ?? color }
        return isHovering ? color : color.opacity(0.4)
    }

    private var labelColor: Color {
        if fill != nil { return Theme.Palette.onAccent }
        return isHovering ? color : color.opacity(0.78)
    }
}

/// API-compat shim — old callers kept building TextLinkButton(…).
/// Routes to FrameButton so every "link" now reads as a real button.
struct TextLinkButton: View {
    enum Weight { case bold, regular }
    let title: String
    var icon: String? = "arrow.right"
    var weight: Weight = .bold
    var color: Color = Theme.Palette.textPrimary
    var isLoading: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        FrameButton(
            title: title,
            icon: icon,
            color: color,
            fill: nil,
            isLoading: isLoading,
            isEnabled: isEnabled,
            action: action
        )
    }
}

/// Square icon-only button — toolbar / nav glyphs.
struct IconButton: View {
    let system: String
    var tooltip: String? = nil
    var size: CGFloat = 38
    let action: () -> Void

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(
                    isHovering ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
                )
                .frame(width: size, height: size)
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
            if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
        .if(tooltip != nil) { $0.help(tooltip!) }
        // `.help()` only sets the hover tooltip; it does not give the
        // button an accessible name. Without this, VoiceOver announces
        // the settings gear as "button" with no label, and the button is
        // invisible to an AX-driven test.
        .accessibilityLabel(tooltip ?? "")
    }
}

// MARK: - MetaRow (hero / detail metadata)
//
// Horizontal mono-style facts separated by center-dot rules. Replaces the
// ultraThinMaterial pill badges.

struct MetaRow: View {
    struct Fact: Identifiable {
        /// Stable identity derived from the content, not a fresh UUID.
        /// A UUID would change on every parent re-render, making SwiftUI
        /// tear down and rebuild every fact row each time.
        ///
        /// Labels within a row are unique by construction (a rating, a
        /// runtime, a release year, …), so label + icon is enough.
        var id: String { "\(label)|\(icon ?? "")" }
        let label: String
        var icon: String?
        var color: Color = Theme.Palette.textSecondary
    }
    let facts: [Fact]

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ForEach(Array(facts.enumerated()), id: \.element.id) { idx, fact in
                HStack(spacing: 5) {
                    if let icon = fact.icon {
                        Image(systemName: icon)
                            .font(.system(size: 9, weight: .bold))
                    }
                    Text(fact.label)
                        .font(Theme.Font.eyebrow(10, weight: .bold))
                        .tracking(2.0)
                        .textCase(.uppercase)
                }
                .foregroundStyle(fact.color)
                if idx != facts.count - 1 {
                    Rectangle()
                        .fill(Theme.Palette.textQuaternary)
                        .frame(width: 10, height: 1)
                }
            }
        }
        // Fixed-size so the row never wraps or clips mid-fact.
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Legacy MetaBadge (kept so other views still compile — maps to MetaRow)

struct MetaBadge: View {
    let text: String
    var icon: String?
    var color: Color = Theme.Palette.textSecondary

    var body: some View {
        MetaRow(facts: [.init(label: text, icon: icon, color: color)])
    }
}

// MARK: - SurfaceCard
//
// A rectangle with a hairline — the only "card". No rounded corners, just
// a 1pt border.

struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.lg
    var radius:  CGFloat = Theme.Radius.sm
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Rectangle().fill(Theme.Palette.surface)
                    .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
            )
    }
}

// MARK: - PosterCard
//
// Movie posters aren't rounded in real life. Tight corners, a single
// hairline frame, a slim progress line hidden in the bottom edge. The
// hover state is a contained zoom (within the frame) + a small amber dot
// — no translucent "play" pill.

struct PosterCard: View {
    let title: String
    let posterURL: String?
    let subtitle: String?
    let rating: String?

    init(title: String, posterURL: String?, subtitle: String?, rating: String? = nil) {
        self.title = title
        self.posterURL = posterURL
        self.subtitle = subtitle
        self.rating = rating
    }

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.Palette.surface)
                posterImage
                    .scaleEffect(isHovering ? 1.04 : 1.0)
                    .animation(.easeOut(duration: 0.3), value: isHovering)
                    .clipped()

                // Permanent subtle vignette so the title and rating read.
                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.45)],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)

                // Rating in the top-right corner, tracked, no pill.
                if let rating {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text(rating)
                            .font(Theme.Font.mono(10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.Palette.accentOnDark)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Rectangle().fill(.black.opacity(0.55)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay(
                Rectangle().stroke(
                    isHovering ? Theme.Palette.accent : Theme.Palette.border,
                    lineWidth: 1
                )
            )
            .overlay(alignment: .bottomLeading) {
                // Amber tick when hovered — a quieter affordance than
                // the translucent play pill every clone uses.
                if isHovering {
                    HStack(spacing: 6) {
                        Rectangle().fill(Theme.Palette.accent).frame(width: 14, height: 1)
                        Text("View")
                            .font(Theme.Font.eyebrow(10, weight: .bold))
                            .tracking(2.0)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.Palette.accentOnDark)
                    }
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .shadow(isHovering ? Theme.Shadow.hero : Theme.Shadow.card)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.Font.title(13))
                    .tracking(-0.1)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Font.mono(10))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var posterImage: some View {
        if let urlString = posterURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty: placeholder
                @unknown default: placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Theme.Palette.backgroundAlt
            VStack(spacing: 8) {
                Text(String(title.prefix(2)).uppercased())
                    .font(Theme.Font.displaySerif(36, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textQuaternary)
                Text(title)
                    .font(Theme.Font.caption(10))
                    .foregroundStyle(Theme.Palette.textQuaternary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
        }
    }
}

// MARK: - Loading / shimmer

struct LoadingRow: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    Rectangle().fill(Theme.Palette.surface)
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .frame(width: 180)
                        .shimmer()
                        .overlay(Rectangle().stroke(Theme.Palette.border, lineWidth: 1))
                    Rectangle().fill(Theme.Palette.surface)
                        .frame(width: 120, height: 11).shimmer()
                }
            }
        }
    }
}

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content.overlay(
            LinearGradient(
                colors: [.white.opacity(0), .white.opacity(0.06), .white.opacity(0)],
                startPoint: .leading, endPoint: .trailing
            )
            .rotationEffect(.degrees(18))
            .offset(x: phase * 320)
            .blendMode(.plusLighter)
            .mask(content)
        )
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                phase = 1.5
            }
        }
    }
}

extension View {
    func shimmer() -> some View { modifier(ShimmerModifier()) }

    @ViewBuilder
    func `if`<C: View>(_ condition: Bool, transform: (Self) -> C) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Button style
//
// SwiftUI's `.plain` style only reacts to what the label draws: on a
// framed button that's the text and icon, not the padding around them,
// so clicking inside the rectangle but beside the word did nothing. This
// style is `.plain` with the whole label rectangle clickable. Use it for
// every borderless button and navigation link in the app.

struct PlainRectButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

extension ButtonStyle where Self == PlainRectButtonStyle {
    static var plainRect: PlainRectButtonStyle { PlainRectButtonStyle() }
}
