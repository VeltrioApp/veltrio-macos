import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Design tokens, cinema-editorial direction.
///
/// Reference points: Mubi, The Criterion Channel, Letterboxd.
/// - True-black canvas, no near-black cheating; posters sit on #000.
/// - One warm accent: a tungsten amber. Reserved for the eye to rest on
///   (an active tab underline, a rating star, the Watch link).
/// - Hairline rules instead of rounded surfaces everywhere.
/// - Serif display for titles, geometric sans for metadata, mono for counts
///   and timecodes. Three faces = a voice, not a slop of SF variants.
/// - Section numerals ("01 —") used as a structural element, not decoration.
enum Theme {
    /// Palette tokens are adaptive: the same name returns the right value
    /// for the current NSAppearance. The dark side keeps the pitch-black
    /// theater look; the light side is a warm paper tone with amber
    /// accent kept intact (it works on both).
    enum Palette {
        // Backgrounds / surfaces.
        static let background      = Color.adaptive(dark: Color.black,
                                                    light: Color(hex: 0xF7F3EC))
        static let backgroundAlt   = Color.adaptive(dark: Color(hex: 0x0A0A0A),
                                                    light: Color(hex: 0xEFE9DF))
        static let surface         = Color.adaptive(dark: Color(hex: 0x111111),
                                                    light: Color(hex: 0xFFFFFF))
        static let surfaceHover    = Color.adaptive(dark: Color(hex: 0x1A1A1A),
                                                    light: Color(hex: 0xECE6DB))
        static let surfaceElevated = Color.adaptive(dark: Color(hex: 0x1F1F1F),
                                                    light: Color(hex: 0xE4DDCF))

        static let border          = Color.adaptive(dark:  Color.white.opacity(0.08),
                                                    light: Color.black.opacity(0.10))
        static let borderStrong    = Color.adaptive(dark:  Color.white.opacity(0.22),
                                                    light: Color.black.opacity(0.28))
        static let hairline        = Color.adaptive(dark:  Color.white.opacity(0.12),
                                                    light: Color.black.opacity(0.14))

        static let textPrimary     = Color.adaptive(dark:  Color(hex: 0xFAF7F2),
                                                    light: Color(hex: 0x0E0E12))
        static let textSecondary   = Color.adaptive(dark:  Color.white.opacity(0.68),
                                                    light: Color.black.opacity(0.70))
        static let textTertiary    = Color.adaptive(dark:  Color.white.opacity(0.42),
                                                    light: Color.black.opacity(0.46))
        static let textQuaternary  = Color.adaptive(dark:  Color.white.opacity(0.26),
                                                    light: Color.black.opacity(0.30))

        // Tungsten amber — accent is the same in both themes. One-color
        // discipline: no inversion, no vendor swap.
        static let accent          = Color(hex: 0xE6A84B)
        static let accentHover     = Color(hex: 0xF2BB64)
        static let accentSoft      = Color(hex: 0xE6A84B).opacity(0.14)
        static let accentSoftHover = Color(hex: 0xE6A84B).opacity(0.22)
        static let accentGlow      = Color(hex: 0xE6A84B).opacity(0.35)

        /// The accent *as text or a thin icon*, not as a fill.
        ///
        /// The fill colour is a bright amber that reads as a shape on
        /// any background. As text it does not: on the light theme's
        /// paper surface it measures 1.89:1 — well under the 4.5:1
        /// minimum. So accent-coloured *text* uses a darker amber in
        /// light mode (4.72:1) and the bright one in dark mode
        /// (9.05:1 on a surface).
        ///
        /// Use `accent` for fills, `accentText` for type and glyphs.
        static let accentText      = Color.adaptive(dark: Color(hex: 0xE6A84B),
                                                    light: Color(hex: 0x9C5E0C))

        /// The bright accent, for content sitting on a *dark* chip in
        /// either theme.
        ///
        /// Several chips — the poster rating badge, the library bookmark
        /// badge, the player's chapter list, the "catchup" / "media
        /// info" headings — sit on a fixed dark scrim painted over
        /// artwork. Their content has to stay bright in both themes.
        /// `accentText` would go dark amber in the light theme, which is
        /// unreadable on those chips.
        static let accentOnDark     = accent

        static let danger          = Color(hex: 0xE5484D)
        static let success         = Color(hex: 0x4F9E5F)
        static let warning         = Color(hex: 0xE6A84B)
        static let rating          = Color(hex: 0xE6A84B)

        /// Text/icon colour meant to sit ON the accent fill.
        ///
        /// The accent is a light tungsten amber, so white on it measures
        /// 2.09:1 — unreadable. Near-black on amber measures 10:1.
        ///
        /// This used to be `Palette.background`, which is *adaptive*: it
        /// flipped to cream in the light theme and dropped the contrast
        /// to 1.89:1. The on-accent colour is deliberately fixed, not
        /// adaptive — amber is bright in both themes.
        static let onAccent        = Color(hex: 0x1A1206)
        /// Same idea for the success green fill (a light green).
        static let onSuccess       = Color(hex: 0x06180C)

        /// Text over a full-bleed movie still.
        ///
        /// The hero and the detail backdrop paint a `scrim` over the
        /// artwork so overlaid text reads. Because the scrim flips with
        /// the theme (black over artwork in dark mode, white over
        /// artwork in light mode), the text on top has to flip with it.
        ///
        /// In dark mode the scrim is black, so the text stays near-white.
        /// In light mode the scrim is white, so the text goes near-black
        /// — otherwise the light theme would put near-black text on a
        /// black rectangle.
        static let heroText        = Color.adaptive(dark: Color(hex: 0xFAF7F2),
                                                    light: Color(hex: 0x0E0E12))
        static let heroTextSecondary = Color.adaptive(dark: Color.white.opacity(0.75),
                                                      light: Color.black.opacity(0.72))

        /// The wash painted over movie artwork so overlaid text reads.
        ///
        /// In the dark theme the canvas is black, so the artwork is
        /// washed toward black. In the light theme the canvas is paper,
        /// so the artwork must be washed toward the page background
        /// instead — a black wash would leave the theme's dark text on a
        /// black rectangle.
        ///
        /// It deliberately matches `background` so a scrimmed panel
        /// dissolves seamlessly into the page.
        static let scrim           = Color.adaptive(dark: .black, light: Color(hex: 0xF7F3EC))

        // Compatibility shims.
        static let accentStrong    = accentHover
        static let accentWarm      = accent
        static let gold            = rating
    }

    enum Radius {
        // Editorial design uses almost-sharp corners. Poster = movie poster
        // (not a 12pt pill). Keeping the enum so callers don't break, but
        // the values collapse to "sharp" and "pill only when you really
        // mean it".
        static let xs:   CGFloat = 2
        static let sm:   CGFloat = 3
        static let md:   CGFloat = 4
        static let lg:   CGFloat = 6
        static let xl:   CGFloat = 10
        static let pill: CGFloat = 999
    }

    // A phone's width is a third of a Mac window's: the outer spacings and
    // the page inset shrink on iOS; the small ones stay.
    #if os(iOS)
    enum Spacing {
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 12
        static let lg:  CGFloat = 18
        static let xl:  CGFloat = 24
        static let xxl: CGFloat = 36
    }

    enum Layout {
        static let contentInset: CGFloat = 18
        static let sectionGap:   CGFloat = 34
        static let pageMaxWidth: CGFloat = 1560
    }
    #else
    enum Spacing {
        static let xs:  CGFloat = 4
        static let sm:  CGFloat = 8
        static let md:  CGFloat = 14
        static let lg:  CGFloat = 22
        static let xl:  CGFloat = 36
        static let xxl: CGFloat = 60
    }

    enum Layout {
        static let contentInset: CGFloat = 48
        static let sectionGap:   CGFloat = 52
        static let pageMaxWidth: CGFloat = 1560
    }
    #endif

    /// Typography.
    /// - `displaySerif`: New York (Apple's built-in serif) — for marquee
    ///   titles, hero names, page titles. A different face from the UI
    ///   font is what makes the app stop looking like every other SwiftUI
    ///   app.
    /// - `displaySans`: large sans for cinematic numerals and wordmark.
    /// - `body`: standard SF body text.
    /// - `caption` / `mono` / `eyebrow`: metadata and markers.
    enum Font {
        /// Display sizes are set for a Mac window; on a phone the big ones
        /// come down (a 72 pt title is three words a line there).
        static func displayScaled(_ size: CGFloat) -> CGFloat {
            #if os(iOS)
            size > 26 ? max(26, (size * 0.6).rounded()) : size
            #else
            size
            #endif
        }
        static func displaySerif(_ size: CGFloat = 56, weight: SwiftUI.Font.Weight = .bold) -> SwiftUI.Font {
            .system(size: displayScaled(size), weight: weight, design: .serif)
        }
        static func display(_ size: CGFloat = 40, weight: SwiftUI.Font.Weight = .heavy) -> SwiftUI.Font {
            .system(size: displayScaled(size), weight: weight, design: .default)
        }
        static func title(_ size: CGFloat = 20) -> SwiftUI.Font {
            .system(size: size, weight: .semibold, design: .serif)
        }
        static func heading(_ size: CGFloat = 16) -> SwiftUI.Font {
            .system(size: size, weight: .semibold, design: .default)
        }
        static func body(_ size: CGFloat = 13) -> SwiftUI.Font {
            .system(size: size, weight: .regular, design: .default)
        }
        static func label(_ size: CGFloat = 12, weight: SwiftUI.Font.Weight = .semibold) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .default)
        }
        static func caption(_ size: CGFloat = 11) -> SwiftUI.Font {
            .system(size: size, weight: .medium, design: .default)
        }
        /// Tracked-out all-caps marker — the house voice for eyebrows,
        /// counts, metadata rows, section numerals.
        static func eyebrow(_ size: CGFloat = 10, weight: SwiftUI.Font.Weight = .bold) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .default)
        }
        static func mono(_ size: CGFloat = 11, weight: SwiftUI.Font.Weight = .regular) -> SwiftUI.Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
    }

    enum Shadow {
        static let subtle = ShadowSpec(color: .black.opacity(0.4), radius: 8,  y: 3)
        static let card   = ShadowSpec(color: .black.opacity(0.65), radius: 24, y: 14)
        static let hero   = ShadowSpec(color: .black.opacity(0.78), radius: 42, y: 24)
        static let glow   = ShadowSpec(color: Palette.accentGlow, radius: 20, y: 0)
    }

    /// Room for the editorial top bar on a Mac; iOS has its own bars.
    #if os(iOS)
    static let navBarInset: CGFloat = 0
    static let trafficLightInset: CGFloat = 0
    static let pushedTopInset: CGFloat = 0
    #else
    static let navBarInset: CGFloat = 72
    #endif

    /// Leading room reserved for the macOS traffic lights.
    ///
    /// The window uses `.hiddenTitleBar`, so the close/minimise/zoom
    /// buttons float over the app's own chrome at the very top-left.
    /// Measured on this layout they occupy x=8…70 relative to the
    /// window's left edge, and y=8…24 relative to its top.
    ///
    /// Two rules follow:
    ///   - anything in the top-left *row* (wordmark, back buttons) needs
    ///     `trafficLightInset` of leading room;
    ///   - anything below the first ~30pt vertically is already clear.
    #if os(macOS)
    static let trafficLightInset: CGFloat = 30
    #endif

    /// Top inset for views pushed onto the navigation stack.
    ///
    /// The editorial top nav only exists on the root tabs — pushing a
    /// destination covers it. Pushed views therefore have no nav bar to
    /// clear, so they use this small inset instead of `navBarInset`
    /// (which left 72pt of dead space at the top of every pushed page).
    ///
    /// 34pt also puts the first row clear of the traffic lights.
    #if os(macOS)
    static let pushedTopInset: CGFloat = 34
    #endif
}

struct ShadowSpec { let color: Color; let radius: CGFloat; let y: CGFloat }

extension View {
    func shadow(_ spec: ShadowSpec) -> some View {
        self.shadow(color: spec.color, radius: spec.radius, x: 0, y: spec.y)
    }

    func pageContainer() -> some View {
        self
            .frame(maxWidth: Theme.Layout.pageMaxWidth)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, Theme.Layout.contentInset)
    }

    /// Tracked-out all-caps eyebrow treatment. Used so often it earns a
    /// one-shot modifier.
    func eyebrow(_ color: Color = Theme.Palette.textTertiary, tracking: CGFloat = 2.4) -> some View {
        self.font(Theme.Font.eyebrow(10, weight: .bold))
            .tracking(tracking)
            .foregroundStyle(color)
            .textCase(.uppercase)
    }

    /// Eyebrow in the accent colour, using the text-safe variant so it
    /// stays legible on the light theme's paper surface.
    func accentEyebrow(tracking: CGFloat = 2.8) -> some View {
        self.eyebrow(Theme.Palette.accentText, tracking: tracking)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Builds a color that picks the dark or light side based on the
    /// current NSAppearance. SwiftUI reads it through NSColor's dynamic
    /// resolve, so switching the app's appearance flips every surface
    /// at once — no manual env wiring per view.
    static func adaptive(dark: Color, light: Color) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let aqua = appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            return aqua ? NSColor(light) : NSColor(dark)
        }))
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .light ? UIColor(light) : UIColor(dark)
        })
        #endif
    }
}
