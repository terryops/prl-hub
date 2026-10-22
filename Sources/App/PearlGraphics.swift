import SwiftUI
import Foundation

// ============================================================
// Pearl Graphics
// ------------------------------------------------------------
// A library of resolution-independent vector graphics (the native
// equivalent of SVG): the pearlescent brand mark, glow orbs, an
// aurora hero banner, a decorative sparkle shape
// and illustrated empty states. All pure SwiftUI — scale crisply
// at any size and adapt to light/dark.
// ============================================================

// MARK: - Brand mark (a luminous pearl)

/// The Pearl brand mark: a glossy sphere with an iridescent sheen,
/// a specular highlight and a soft rim — drawn entirely with gradients.
struct PearlMark: View {
    var size: CGFloat = 64
    var body: some View {
        let modern = AppPalette.current == .modern
        ZStack {
            // The modern mark is pearl-white with a soft blue sheen.
            Circle()
                .fill(
                    RadialGradient(
                        colors: modern
                            ? [.white,
                               Color(red: 0.96, green: 0.98, blue: 1.00),
                               Color(red: 0.79, green: 0.85, blue: 0.93),
                               Color(red: 0.51, green: 0.63, blue: 0.77)]
                            : [.white,
                               Pearl.teal.opacity(0.55),
                               Pearl.violet.opacity(0.85),
                               Pearl.indigo],
                        center: UnitPoint(x: 0.36, y: 0.30),
                        startRadius: size * 0.02,
                        endRadius: size * 0.78)
                )
            // Iridescent sheen sweep
            Circle()
                .fill(Pearl.sheen)
                .opacity(modern ? 0 : 0.35)
                .blendMode(.plusLighter)
            // Specular highlight
            Ellipse()
                .fill(.white.opacity(0.92))
                .frame(width: size * 0.28, height: size * 0.19)
                .blur(radius: size * 0.025)
                .offset(x: -size * 0.15, y: -size * 0.21)
            // Bottom inner shadow for volume
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.clear, Pearl.indigo.opacity(modern ? 0.16 : 0.45)],
                        center: UnitPoint(x: 0.65, y: 0.78),
                        startRadius: size * 0.30,
                        endRadius: size * 0.62)
                )
                .blendMode(.multiply)
            // Rim light
            Circle().strokeBorder(.white.opacity(0.28), lineWidth: max(0.8, size * 0.014))
        }
        .frame(width: size, height: size)
        .shadow(color: Pearl.shadow.opacity(0.35), radius: size * 0.16, x: 0, y: size * 0.07)
        .accessibilityHidden(true)
    }
}

/// Brand mark + "Pearl Hub" wordmark, laid out horizontally.
struct PearlLogo: View {
    var size: CGFloat = 56
    var showsWordmark = true
    /// Use the background-removed mascot mark (transparent PNG) instead of the
    /// opaque rounded app-icon tile — for surfaces that read cleaner without a tile
    /// (e.g. the Settings header over a Form background).
    var transparentMark = false
    /// Stack the mark ABOVE the wordmark (centered) instead of side-by-side — for a
    /// tall header (e.g. the Settings top). The mark then dominates and the wordmark
    /// sits under it at a smaller size.
    var vertical = false
    @AppStorage(AppIconChoice.key) var iconChoice: String?
    var body: some View {
        if vertical {
            VStack(spacing: size * 0.16) {
                mark
                wordmarkLabel(scale: 0.34)
            }
        } else {
            HStack(spacing: size * 0.22) {
                mark
                wordmarkLabel(scale: 0.5)
            }
        }
    }

    /// The "Pearl Hub" wordmark sized relative to the mark (`scale` × `size`).
    @ViewBuilder private func wordmarkLabel(scale: CGFloat) -> some View {
        if showsWordmark {
            Self.wordmark
                .font(.system(size: size * scale, weight: .bold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }

    @ViewBuilder private var mark: some View {
        if transparentMark || AppIconChoice(stored: iconChoice) == .pearl {
            // Free-floating, background-removed mark (no tile/border) — just a soft shadow.
            // Pearl and classic choices have cut-outs; see BrandMark.
            BrandMark(size: size)
        } else {
            // The app icon this install is on, as a rounded app-style mark.
            AppIconTile(choice: AppIconChoice(stored: iconChoice), size: size)
        }
    }

    /// The app's name as the home screen shows it (no "$"), in the palette's blue accent.
    static var wordmark: Text {
        Text(verbatim: "Pearl Hub").foregroundColor(Pearl.accent)
    }
}

/// The original pearl miner lives on as a small decorative companion, independent
/// of the selected app icon. Its transparent artwork stays clear of the main branding.
struct PearlMascot: View {
    var size: CGFloat = 44
    var body: some View {
        Image("AppLogoMark")
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: Pearl.shadow.opacity(0.18), radius: size * 0.10, y: size * 0.04)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

// MARK: - Glow orb (soft radial light)

/// A soft circular glow — the building block for ambient backgrounds.
struct GlowOrb: View {
    var color: Color
    var diameter: CGFloat
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.08)
            .allowsHitTesting(false)
    }
}

// MARK: - Ambient screen background

/// A faint, premium wash placed behind a tab's content (orbs + tint).
/// Apply once at the root so every screen shares the same atmosphere.
struct PearlBackground: View {
    var body: some View {
        // Kept deliberately plain: a barely-there diagonal tint, no floating orbs,
        // so screens read clean and content stays the focus.
        Pearl.canvas.overlay(Pearl.wash)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

// MARK: - Decorative shapes (pure vector paths)

/// A four-pointed sparkle / star.
struct SparkleShape: Shape {
    var points: Int = 4
    var innerRatio: CGFloat = 0.34
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let total = points * 2
        for i in 0..<total {
            let angle = (Double(i) / Double(total)) * 2 * .pi - .pi / 2
            let r = i.isMultiple(of: 2) ? outer : inner
            let pt = CGPoint(x: c.x + CGFloat(cos(angle)) * r,
                             y: c.y + CGFloat(sin(angle)) * r)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Aurora hero banner

/// A rounded brand-gradient banner with floating orbs and sparkles —
/// a flexible header surface. The modern palette uses a bright pearl-blue gradient.
struct PearlHero<Content: View>: View {
    var gradient: LinearGradient = Pearl.brandVivid
    var minHeight: CGFloat = 0
    var cornerRadius: CGFloat = Pearl.Radius.lg
    var padding: CGFloat = Pearl.Space.xl
    /// The decorative top-right sparkle. Turn OFF when the banner places its own
    /// content there (e.g. the wallet dashboard's gold price chip) to avoid overlap.
    var showSparkle: Bool = true
    /// A complete backdrop, including its highlights, in place of the default fill.
    var backdrop: AnyView? = nil
    @ViewBuilder var content: () -> Content

    init(gradient: LinearGradient = Pearl.brandVivid,
         minHeight: CGFloat = 0,
         cornerRadius: CGFloat = Pearl.Radius.lg,
         padding: CGFloat = Pearl.Space.xl,
         showSparkle: Bool = true,
         backdrop: AnyView? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.gradient = gradient
        self.minHeight = minHeight
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.showSparkle = showSparkle
        self.backdrop = backdrop
        self.content = content
    }

    var body: some View {
        // The content drives the size; the gradient + orbs sit in the BACKGROUND
        // so the banner hugs its content vertically instead of greedily filling
        // the whole scroll height (a bare LinearGradient has no intrinsic size).
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background {
                ZStack {
                    if let backdrop {
                        backdrop
                    } else {
                        gradient
                        if AppPalette.current == .classic {
                            GlowOrb(color: .white.opacity(0.18), diameter: 150).offset(x: -90, y: -60)
                            GlowOrb(color: Pearl.teal.opacity(0.30), diameter: 130).offset(x: 120, y: 60)
                        }
                    }
                    if showSparkle && AppPalette.current == .classic {
                        SparkleShape().fill(Pearl.gold.opacity(0.9)).frame(width: 12, height: 12).offset(x: 122, y: -40)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Pearl.heroEdge, lineWidth: 1)
            )
            .shadow(color: Pearl.shadow.opacity(AppPalette.current == .modern ? 0.08 : 0.12), radius: 10, x: 0, y: 5)
    }
}

// MARK: - Illustrated empty state

/// A friendlier replacement for ContentUnavailableView: an SF Symbol set
/// in an orbiting glow with sparkles, plus title / message / optional action.
struct PearlEmptyState<Action: View>: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var gradient: LinearGradient = Pearl.brand
    var showsMascot = false
    @ViewBuilder var action: () -> Action

    init(systemImage: String, title: String, message: String? = nil,
         gradient: LinearGradient = Pearl.brand,
         showsMascot: Bool = false,
         @ViewBuilder action: @escaping () -> Action = { EmptyView() }) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.gradient = gradient
        self.showsMascot = showsMascot
        self.action = action
    }

    var body: some View {
        VStack(spacing: Pearl.Space.lg) {
            ZStack {
                Circle().fill(gradient.opacity(0.12)).frame(width: 132, height: 132)
                Circle().strokeBorder(gradient.opacity(0.22), lineWidth: 1).frame(width: 132, height: 132)
                SparkleShape().fill(Pearl.gold.opacity(0.85)).frame(width: 14, height: 14).offset(x: 54, y: -44)
                Image(systemName: systemImage)
                    .font(.system(size: 50, weight: .semibold))
                    .foregroundStyle(gradient)
                if showsMascot {
                    PearlMascot(size: 48).offset(x: 50, y: 40)
                }
            }
            VStack(spacing: 6) {
                Text(title).font(.title3.weight(.semibold))
                if let message {
                    Text(message)
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            action()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Pearl.Space.xl)
        .padding(.horizontal, Pearl.Space.lg)
    }
}

// MARK: - Previews

#Preview("Graphics") {
    ScrollView {
        VStack(spacing: 28) {
            PearlLogo(size: 64)
            PearlHero(minHeight: 180) {
                VStack(spacing: 8) {
                    PearlMark(size: 56)
                    Text(Loc("$Pearl Hub")).font(.title.bold()).foregroundStyle(.white)
                }
            }
            PearlEmptyState(systemImage: "tray", title: Loc("暂无内容"), message: Loc("这里会显示你的数据"))
        }
        .padding()
    }
    .background(PearlBackground())
}
