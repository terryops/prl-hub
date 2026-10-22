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

    // MARK: Brand palette — two of them (设置 → 外观 → 配色; see AppPalette.swift). Every
    // colour below is the one of the palette this install is on, looked up when a view is
    // built: switching rebuilds the tree (RootView), so nothing may keep one in a `static let`.
    static var tones: PearlTones { AppPalette.current.tones }

    /// The pearl-blue palette whichever one the install is on — for colours that are an
    /// identity rather than the app's look (a pool's badge, its slice of the donut).
    static let classic = PearlTones.classic

    static var indigo: Color { tones.indigo }
    static var violet: Color { tones.violet }
    static var teal:   Color { tones.teal }
    static var sky:    Color { tones.sky }
    static var gold:   Color { tones.gold }
    static var rose:   Color { tones.rose }

    /// `gold` and `rose` deep enough to read as text on a card (classic's gold is a fill
    /// colour, too light for words on white). The same in both palettes.
    static var goldInk: Color { PearlTones.tone(0xB77914, 0xF5CE72) }
    static var roseInk: Color { PearlTones.tone(0xD64A6C, 0xFF8CA7) }

    /// The primary brand accent — used for tint, links, key glyphs.
    static var accent: Color { tones.accent }
    /// Text and glyphs set on a fill of `accent` or `brand`.
    static var onAccent: Color { tones.onAccent }
    /// A solid the system sets its own white label on (prominent buttons, swipe actions).
    static var plate: Color { tones.plate }
    /// An icon badge's own fill and the glyph on it (PearlIconBadge).
    static var badge: LinearGradient { tones.badge }
    static var onBadge: Color { tones.onBadge }
    /// What stands on a hero banner, and the chip set into one.
    static var onHero: Color { tones.onHero }
    static var heroChip: Color { tones.heroChip }
    static var onHeroChip: Color { tones.onHeroChip }
    static var heroChipPrice: Color { tones.heroChipPrice }
    /// A switch that is on.
    static var switchOn: Color { tones.switchOn }
    /// The shadow brand-coloured things cast.
    static var shadow: Color { tones.shadow }

    // MARK: Gradients
    /// Buttons, badges, glyphs.
    static var brand: LinearGradient { tones.brand }
    /// Hero banners; what stands on one is `onHero`.
    static var brandVivid: LinearGradient { tones.brandVivid }
    static var mint: LinearGradient { tones.mint }
    static var sunrise: LinearGradient { tones.sunrise }
    static var positive: LinearGradient { tones.positive }
    static var negative: LinearGradient { tones.negative }
    /// The 卖出 button: a real red, not the pink-rose of `negative`, so it pairs
    /// with the red candles instead of reading as candy.
    static var sell: LinearGradient { tones.sell }
    /// Iridescent pearl sheen, for the brand mark + accents.
    static var sheen: AngularGradient { tones.sheen }
    /// A faint full-screen wash for tab backgrounds.
    static var wash: LinearGradient { tones.wash }

    /// Card surface: a translucent flat fill standing in for `.regularMaterial`.
    /// A material is a live backdrop blur — every card on screen re-samples and
    /// blurs what's behind it on each scroll frame, which is what made long pages
    /// stutter. Behind the cards there's only the faint `wash`, so a fixed tint
    /// looks the same at a fraction of the GPU cost.
    static var surface: Color { tones.surface }
    static var canvas: Color { tones.canvas }
    static var surfaceEdge: Color { tones.surfaceEdge }
    static var heroEdge: Color { tones.heroEdge }

    /// Gradient for a card's hairline edge highlight (glass rim).
    static let glassEdge = LinearGradient(
        colors: [.white.opacity(0.55), .white.opacity(0.04)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

// MARK: - The two palettes

/// One palette: the colours the `Pearl` tokens hand out.
struct PearlTones {
    let indigo, violet, teal, sky, gold, rose: Color
    let accent, onAccent, plate, switchOn, shadow: Color
    let onBadge, onHero, heroChip, onHeroChip, heroChipPrice: Color
    let brand, brandVivid, mint, wash, badge: LinearGradient
    let surface, canvas, surfaceEdge, heroEdge: Color

    var sunrise: LinearGradient {
        LinearGradient(colors: [gold, rose], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var positive: LinearGradient {
        LinearGradient(colors: [Color(red: 0.20, green: 0.80, blue: 0.55), teal],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var negative: LinearGradient {
        LinearGradient(colors: [rose, Color(red: 0.95, green: 0.32, blue: 0.40)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var sell: LinearGradient {
        LinearGradient(colors: [Color(red: 0.93, green: 0.33, blue: 0.36), Color(red: 0.82, green: 0.22, blue: 0.30)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var sheen: AngularGradient {
        AngularGradient(colors: [teal, sky, violet, rose, gold, teal], center: .center)
    }

    /// The PEARL itself — iridescent blue with a hint of violet — plus the miner's-hat GOLD
    /// as the accent. "indigo"/"violet" hold the pearl blue/violet so every shadow, glow and
    /// gradient referencing them carries the pearl tone. Cross-platform sRGB, the same in
    /// both appearances.
    static let classic: PearlTones = {
        let indigo = Color(red: 0.32, green: 0.48, blue: 0.95)   // pearl blue   #527AF2
        let violet = Color(red: 0.53, green: 0.46, blue: 0.95)   // pearl violet #8775F2 (the hint of purple)
        let teal   = Color(red: 0.36, green: 0.72, blue: 0.92)   // blue-aqua sheen #5CB8EB
        let sky    = Color(red: 0.34, green: 0.62, blue: 0.99)   // sky blue     #579EFD
        let accent = Color(red: 0.33, green: 0.47, blue: 0.93)   // pearl blue-violet #5478ED
        // Pearl blue → violet (the hint of purple).
        let brand = LinearGradient(colors: [indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
        return PearlTones(
            indigo: indigo, violet: violet, teal: teal, sky: sky,
            gold: Color(red: 1.00, green: 0.78, blue: 0.28),     // hard-hat gold #FFC747
            rose: Color(red: 1.00, green: 0.45, blue: 0.62),     // #FF739E (warm accent)
            accent: accent, onAccent: .white, plate: accent, switchOn: accent, shadow: indigo,
            onBadge: .white, onHero: .white, heroChip: .white.opacity(0.12),
            onHeroChip: .white, heroChipPrice: Color(red: 1.00, green: 0.78, blue: 0.28),
            brand: brand,
            // Sky-blue → pearl blue → violet — the iridescent pearl.
            brandVivid: LinearGradient(colors: [sky, indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing),
            mint: LinearGradient(colors: [teal, sky], startPoint: .topLeading, endPoint: .bottomTrailing),
            wash: LinearGradient(colors: [indigo.opacity(0.05), teal.opacity(0.04)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing),
            badge: brand,
            surface: gray(light: 0.96, 0.94, dark: 0.13, 0.94, macLight: 1.0, 0.82, macDark: 0.17, 0.94),
            canvas: .clear, surfaceEdge: Color.primary.opacity(0.06), heroEdge: .white.opacity(0.15))
    }()

    /// Bright pearl-white surfaces with a restrained blue sheen and softly tinted icons.
    /// Dark appearance uses graphite surfaces with blue reserved for accents.
    /// Status colours still communicate gains, losses and warnings independently.
    static let modern: PearlTones = {
        let accent = tone(0x3F6EBA, 0xADC8EF)
        let blue = tone(0x386BD3, 0x416ED0)
        let sky = tone(0x6388C7, 0x91ACD8)
        let brand = LinearGradient(colors: [blue, tone(0x3260BE, 0x3863BD)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
        return PearlTones(
            indigo: accent, violet: tone(0x657EB4, 0xB5C6E5),
            teal: tone(0x1685A0, 0x68C4D8), sky: sky,
            gold: tone(0xB77914, 0xF5CE72), rose: tone(0xDF5274, 0xFF8CA7),
            accent: accent, onAccent: .white, plate: blue, switchOn: blue,
            shadow: tone(0x5A728D, 0x141416),
            onBadge: tone(0x4372AE, 0xB5CFEE), onHero: tone(0x21384F, 0xF3F7FC),
            heroChip: tone(0xFFFFFF, 0xD7DCE3, alpha: 0.90, 0.10),
            onHeroChip: tone(0x536C87, 0xBCD0E5), heroChipPrice: tone(0x355F93, 0xD4E5F7),
            brand: brand,
            brandVivid: LinearGradient(colors: [tone(0xFCFEFF, 0x2C2F35), tone(0xF0F8FB, 0x292C31), tone(0xE4EFFB, 0x26282E)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
            mint: LinearGradient(colors: [tone(0x1685A0, 0x238CA8), blue],
                                 startPoint: .topLeading, endPoint: .bottomTrailing),
            wash: LinearGradient(colors: [tone(0xE1EFFA, 0x8B8F98, alpha: 0.10, 0.025), .clear],
                                 startPoint: .topLeading, endPoint: .bottomTrailing),
            badge: LinearGradient(colors: [tone(0xF0F6FD, 0x30343C), tone(0xEAF2FC, 0x2C3037)],
                                  startPoint: .topLeading, endPoint: .bottomTrailing),
            surface: tone(0xFFFFFF, 0x24262B), canvas: tone(0xFAFBFD, 0x18191D),
            surfaceEdge: tone(0xE0E7F0, 0x43474E, alpha: 0.75, 0.70),
            heroEdge: tone(0xDAE6F2, 0x51565E, alpha: 0.75, 0.70))
    }()

    /// An sRGB colour that is `light` in the light appearance and `dark` in the dark one.
    static func tone(_ light: UInt32, _ dark: UInt32, alpha: Double...) -> Color {
        func parts(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
        }
        let (l, d) = (parts(light), parts(dark))
        let la = CGFloat(alpha.first ?? 1), da = CGFloat(alpha.count > 1 ? alpha[1] : 1)
        #if os(iOS)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(red: d.0, green: d.1, blue: d.2, alpha: da) : UIColor(red: l.0, green: l.1, blue: l.2, alpha: la) })
        #else
        return Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? NSColor(srgbRed: d.0, green: d.1, blue: d.2, alpha: da) : NSColor(srgbRed: l.0, green: l.1, blue: l.2, alpha: la) })
        #endif
    }

    /// A card surface: a white level and an alpha for each appearance, per platform.
    private static func gray(light: CGFloat, _ lightAlpha: CGFloat, dark: CGFloat, _ darkAlpha: CGFloat,
                             macLight: CGFloat, _ macLightAlpha: CGFloat,
                             macDark: CGFloat, _ macDarkAlpha: CGFloat) -> Color {
        #if os(iOS)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: dark, alpha: darkAlpha) : UIColor(white: light, alpha: lightAlpha) })
        #else
        return Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? NSColor(white: macDark, alpha: macDarkAlpha) : NSColor(white: macLight, alpha: macLightAlpha) })
        #endif
    }
}

// MARK: - Frosted glass card

private struct PearlCardModifier: ViewModifier {
    var padding: CGFloat
    var radius: CGFloat
    var elevated: Bool
    var frosted: Bool
    var surface: Color?
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            // Default cards are flat; only "elevated" gets a subtle, single soft shadow —
            // cast by the background SHAPE, not the whole card, so it's rendered from the
            // shape's path instead of an offscreen pass over every piece of content.
            .background {
                if frosted && AppPalette.current == .classic && surface == nil {
                    shape.fill(.regularMaterial)
                        .shadow(color: .black.opacity(elevated ? 0.08 : 0),
                                radius: elevated ? 10 : 0, x: 0, y: elevated ? 4 : 0)
                } else {
                    shape.fill(surface ?? Pearl.surface)
                        .shadow(color: .black.opacity(elevated ? 0.08 : 0),
                                radius: elevated ? 10 : 0, x: 0, y: elevated ? 4 : 0)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Pearl.surfaceEdge, lineWidth: 1)
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
    /// `surface` supplies an explicit flat fill instead of the palette or material.
    func pearlCard(padding: CGFloat = Pearl.Space.lg,
                   radius: CGFloat = Pearl.Radius.md,
                   elevated: Bool = false,
                   frosted: Bool = false,
                   surface: Color? = nil) -> some View {
        modifier(PearlCardModifier(padding: padding, radius: radius, elevated: elevated,
                                   frosted: frosted, surface: surface))
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
    /// nil is the palette's own badge fill and glyph; any other fill is one that carries
    /// white, unless `glyph` says otherwise.
    var gradient: LinearGradient? = nil
    var glyph: Color? = nil
    var size: CGFloat = 38
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(gradient ?? Pearl.badge)
            // Shadow on the filled shape only (not the composited badge + glyph) — no
            // offscreen pass per badge while scrolling.
            .shadow(color: Pearl.shadow.opacity(AppPalette.current == .modern ? 0 : 0.18),
                    radius: size * 0.14, x: 0, y: size * 0.06)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(glyph ?? (gradient == nil ? Pearl.onBadge : .white))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .strokeBorder(AppPalette.current == .modern ? Pearl.surfaceEdge : .white.opacity(0.25), lineWidth: 0.8)
            )
    }
}

// MARK: - Info row (a statement worth reading, on its own line)

/// Something the reader should not miss — what is stored, what never leaves the device,
/// what a feature needs — as its own row: accent glyph on the settings rows' column, then
/// the sentence in the body colour. Small grey print is for what accompanies something
/// else (a subtitle, a timestamp); a sentence standing alone in it goes unread.
///
/// `title` is the point itself in a few bold words, for a row whose sentence takes a
/// moment to read: the eye gets the point from the title and the rest from the sentence.
struct PearlInfoRow: View {
    let text: String
    var title: String? = nil
    let systemImage: String
    var tint: Color = Pearl.accent

    init(_ text: String, title: String? = nil, systemImage: String = "info.circle", tint: Color = Pearl.accent) {
        self.text = text; self.title = title; self.systemImage = systemImage; self.tint = tint
    }

    var body: some View {
        HStack(alignment: title == nil ? .center : .firstTextBaseline, spacing: Pearl.Space.sm) {
            Image(systemName: systemImage)
                .font(.system(size: title == nil ? 17 : 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(text).font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, title == nil ? 0 : 2)
    }
}

extension View {
    /// A sentence that explains — under a title, beside a control, beneath a card — set
    /// like `PearlInfoRow`'s: grey `.caption` made these the least readable text on the
    /// page. Labels, values and timestamps keep the small grey; whole sentences do not.
    func pearlExplanation(_ font: Font = .subheadline) -> some View {
        self.font(font).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Section header (icon chip + title + optional subtitle)

struct PearlSectionHeader: View {
    let title: String
    var systemImage: String? = nil
    var subtitle: String? = nil
    var gradient: LinearGradient? = nil   // nil: the palette's badge (see PearlIconBadge)
    var trailing: AnyView? = nil

    init(_ title: String, systemImage: String? = nil, subtitle: String? = nil,
         gradient: LinearGradient? = nil) {
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
    /// nil is the brand fill, and its label the palette's `onAccent`; any other fill is one
    /// that carries white.
    var gradient: LinearGradient? = nil
    var shape: AnyShape? = nil
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = shape ?? (AppPalette.current == .modern
            ? AnyShape(RoundedRectangle(cornerRadius: Pearl.Radius.sm, style: .continuous))
            : AnyShape(Capsule()))
        return configuration.label
            .font(.headline)
            .foregroundStyle(gradient == nil ? Pearl.onAccent : .white)
            .padding(.vertical, 15)
            .padding(.horizontal, Pearl.Space.lg)
            .frame(maxWidth: .infinity)
            .background(gradient ?? Pearl.brand, in: shape)
            .overlay(shape.stroke(.white.opacity(0.22), lineWidth: 0.8))
            .shadow(color: Pearl.shadow.opacity(!isEnabled ? 0 : configuration.isPressed ? 0.10 : 0.16),
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

// MARK: - Switches

/// The system's switch, on in the palette's `switchOn` instead of the tint every other
/// control takes. The active fill must remain distinct from its white knob.
struct PearlSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).tint(Pearl.switchOn)
    }
}

// MARK: - Screen helpers

extension View {
    /// Apply on a Form section so its rows share the same surface as the dashboard cards.
    @ViewBuilder
    func pearlListRowSurface() -> some View {
        if AppPalette.current == .modern {
            self.listRowBackground(Pearl.surface)
        } else {
            self
        }
    }

    /// NavigationStack supplies an opaque system canvas, so plain scroll screens need
    /// the modern canvas inside the stack as well as behind the root TabView.
    @ViewBuilder
    func pearlScreenBackground() -> some View {
        if AppPalette.current == .modern {
            self.background { PearlBackground() }
        } else {
            self
        }
    }

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
