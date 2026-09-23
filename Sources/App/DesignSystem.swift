import SwiftUI

// ============================================================
// Pearl Design System
// ------------------------------------------------------------
// One opinionated, cross-platform (iOS + macOS) visual language:
// brand colors, gradients, a generous spacing scale, frosted-glass
// cards, gradient buttons, section headers and small chips.
//
// Everything is resolution-independent and adapts to light/dark.
// Companion vector-graphics live in PearlGraphics.swift.
// ============================================================

enum Pearl {

    // MARK: Spacing — generous, for breathing room
    enum Space {
        static let xxs: CGFloat = 4
        static let xs:  CGFloat = 8
        static let sm:  CGFloat = 12
        static let md:  CGFloat = 16
        static let lg:  CGFloat = 22
        static let xl:  CGFloat = 28
        static let xxl: CGFloat = 36
        /// Default outer padding for a screen's scroll content.
        static let screen: CGFloat = 24
    }

    // MARK: Corner radii — continuous squircles everywhere
    enum Radius {
        static let xs:   CGFloat = 10
        static let sm:   CGFloat = 14
        static let md:   CGFloat = 20
        static let lg:   CGFloat = 26
        static let xl:   CGFloat = 32
        static let pill: CGFloat = 999
    }

    // MARK: Brand palette — the PEARL itself (iridescent blue with a hint of
    // violet) plus the miner's-hat GOLD as the accent. "indigo"/"violet" hold the
    // pearl blue/violet so every shadow, glow and gradient referencing them carries
    // the pearl tone. Cross-platform sRGB, looks right in both schemes.
    static let indigo = Color(red: 0.32, green: 0.48, blue: 0.95)   // pearl blue   #527AF2
    static let violet = Color(red: 0.53, green: 0.46, blue: 0.95)   // pearl violet #8775F2 (the hint of purple)
    static let teal   = Color(red: 0.36, green: 0.72, blue: 0.92)   // blue-aqua sheen #5CB8EB
    static let sky    = Color(red: 0.34, green: 0.62, blue: 0.99)   // sky blue     #579EFD
    static let gold   = Color(red: 1.00, green: 0.78, blue: 0.28)   // hard-hat gold #FFC747
    static let rose   = Color(red: 1.00, green: 0.45, blue: 0.62)   // #FF739E (warm accent)

    /// The primary brand accent — used for tint, links, key glyphs. Pearl blue-violet.
    static let accent = Color(red: 0.33, green: 0.47, blue: 0.93)   // #5478ED

    // MARK: Gradients
    // Pearl blue → violet (the hint of purple) — buttons, badges, glyphs.
    static let brand = LinearGradient(
        colors: [indigo, violet],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    // Sky-blue → pearl blue → violet — the iridescent pearl, for hero banners.
    static let brandVivid = LinearGradient(
        colors: [sky, indigo, violet],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let mint = LinearGradient(
        colors: [teal, sky],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let sunrise = LinearGradient(
        colors: [gold, rose],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let positive = LinearGradient(
        colors: [Color(red: 0.20, green: 0.80, blue: 0.55), teal],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let negative = LinearGradient(
        colors: [rose, Color(red: 0.95, green: 0.32, blue: 0.40)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// The 卖出 button: a real red, not the pink-rose of `negative`, so it pairs
    /// with the red candles instead of reading as candy.
    static let sell = LinearGradient(
        colors: [Color(red: 0.93, green: 0.33, blue: 0.36), Color(red: 0.82, green: 0.22, blue: 0.30)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Iridescent pearl sheen, for the brand mark + accents.
    static let sheen = AngularGradient(
        colors: [teal, sky, violet, rose, gold, teal],
        center: .center)

    /// A faint full-screen wash for tab backgrounds.
    static let wash = LinearGradient(
        colors: [indigo.opacity(0.05), teal.opacity(0.04)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Card surface: a translucent flat fill standing in for `.regularMaterial`.
    /// A material is a live backdrop blur — every card on screen re-samples and
    /// blurs what's behind it on each scroll frame, which is what made long pages
    /// stutter. Behind the cards there's only the faint `wash`, so a fixed tint
    /// looks the same at a fraction of the GPU cost.
    static let surface: Color = {
        #if os(iOS)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 0.13, alpha: 0.94) : UIColor(white: 0.96, alpha: 0.94) })
        #else
        return Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? NSColor(white: 0.17, alpha: 0.94) : NSColor(white: 1.0, alpha: 0.82) })
        #endif
    }()

    /// Gradient for a card's hairline edge highlight (glass rim).
    static let glassEdge = LinearGradient(
        colors: [.white.opacity(0.55), .white.opacity(0.04)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - Frosted glass card

private struct PearlCardModifier: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat
    var elevated: Bool
    var frosted: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            // Default cards are flat; only "elevated" gets a subtle, single soft shadow —
            // cast by the background SHAPE, not the whole card, so it's rendered from the
            // shape's path instead of an offscreen pass over every piece of content.
            .background {
                if frosted {
                    shape.fill(.regularMaterial)
                        .shadow(color: .black.opacity(elevated ? 0.08 : 0),
                                radius: elevated ? 10 : 0, x: 0, y: elevated ? 4 : 0)
                } else {
                    shape.fill(Pearl.surface)
                        .shadow(color: .black.opacity(elevated ? 0.08 : 0),
                                radius: elevated ? 10 : 0, x: 0, y: elevated ? 4 : 0)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)   // clean hairline, not glossy
            )
    }
}

// MARK: - Gradient-stroked accent card (for hero / highlighted blocks)

private struct PearlAccentCardModifier: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat
    var gradient: LinearGradient
    func body(content: Content) -> some View {
        content
            .padding(padding)
            // Solid, readable surface with only a hint of color + a colored hairline.
            // Keep text in normal .primary/.secondary so it stays legible.
            .background(Pearl.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(gradient.opacity(0.10), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(gradient.opacity(0.35), lineWidth: 1)
            )
    }
}

extension View {
    /// Standard card surface with a hairline rim (+ optional soft shadow).
    /// `frosted` swaps the flat fill for a live `.regularMaterial` blur — kept for the
    /// short wallet screen, where the look matters and there's little to scroll.
    func pearlCard(padding: CGFloat = Pearl.Space.lg,
                   radius: CGFloat = Pearl.Radius.md,
                   elevated: Bool = false,
                   frosted: Bool = false) -> some View {
        modifier(PearlCardModifier(padding: padding, radius: radius, elevated: elevated, frosted: frosted))
    }

    /// A card tinted by a brand gradient — for hero blocks and callouts.
    func pearlAccentCard(padding: CGFloat = Pearl.Space.lg,
                         radius: CGFloat = Pearl.Radius.md,
                         gradient: LinearGradient = Pearl.brand) -> some View {
        modifier(PearlAccentCardModifier(padding: padding, radius: radius, gradient: gradient))
    }
}

// MARK: - Icon badge (SF Symbol in a gradient squircle)

struct PearlIconBadge: View {
    let systemImage: String
    var gradient: LinearGradient = Pearl.brand
    var size: CGFloat = 38
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(gradient)
            // Shadow on the filled shape only (not the composited badge + glyph) — no
            // offscreen pass per badge while scrolling.
            .shadow(color: Pearl.indigo.opacity(0.18), radius: size * 0.14, x: 0, y: size * 0.06)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.8)
            )
    }
}

// MARK: - Section header (icon chip + title + optional subtitle)

struct PearlSectionHeader: View {
    let title: String
    var systemImage: String? = nil
    var subtitle: String? = nil
    var gradient: LinearGradient = Pearl.brand
    var trailing: AnyView? = nil

    init(_ title: String, systemImage: String? = nil, subtitle: String? = nil,
         gradient: LinearGradient = Pearl.brand) {
        self.title = title; self.systemImage = systemImage
        self.subtitle = subtitle; self.gradient = gradient
    }

    var body: some View {
        HStack(spacing: Pearl.Space.sm) {
            if let systemImage {
                PearlIconBadge(systemImage: systemImage, gradient: gradient, size: 30)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
    }
}

// MARK: - Pill badge

struct PearlBadge: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = Pearl.indigo
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.caption2.bold()) }
            Text(text).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(tint.opacity(0.13), in: Capsule())
        // Never let a squeezed parent wrap the label (e.g. "%" dropping to a 2nd
        // line in the price-change pill) — the pill keeps its natural width.
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Gradient prominent button

struct PearlButtonStyle: ButtonStyle {
    var gradient: LinearGradient = Pearl.brand
    var shape: AnyShape = AnyShape(Capsule())
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.vertical, 15)
            .padding(.horizontal, Pearl.Space.lg)
            .frame(maxWidth: .infinity)
            .background(gradient, in: shape)
            .overlay(shape.stroke(.white.opacity(0.22), lineWidth: 0.8))
            .shadow(color: Pearl.indigo.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.10 : 0.16),
                    radius: configuration.isPressed ? 4 : 8, x: 0, y: configuration.isPressed ? 2 : 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            // A custom ButtonStyle gets no automatic disabled look — dim it ourselves
            // so a greyed-out 发送 / 确认 reads as unavailable instead of just unresponsive.
            .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
            .contentShape(shape)
    }
}

extension ButtonStyle where Self == PearlButtonStyle {
    static var pearl: PearlButtonStyle { PearlButtonStyle() }
    static func pearl(_ gradient: LinearGradient) -> PearlButtonStyle { PearlButtonStyle(gradient: gradient) }
}

// MARK: - Screen helpers

extension View {
    /// Reveal the ambient pearl wash behind a List/Form by hiding its opaque
    /// scroll background. (Plain ScrollViews are already transparent.)
    func pearlListBackground() -> some View {
        self.scrollContentBackground(.hidden)
            .background { PearlBackground() }
    }
}

// MARK: - No glass on toolbar items

extension ToolbarContent {
    /// Opts a toolbar item out of the automatic Liquid Glass capsule that the
    /// iOS/macOS 26+ SDK draws behind toolbar buttons — the user doesn't want the
    /// glass look (reverted 2026-09-17). Earlier systems never drew one.
    @ToolbarContentBuilder
    func noGlassBackground() -> some ToolbarContent {
        if #available(iOS 26.0, macOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
