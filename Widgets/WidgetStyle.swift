import SwiftUI

/// Silver surfaces and classic blue, each with a quieter palette for night.
struct WidgetColors {
    let primary, secondary, muted, accent, price, gold, divider, panel, positive, negative: Color
    let background: LinearGradient

    init(_ appearance: WidgetAppearance, scheme: ColorScheme) {
        func color(_ light: UInt32, _ dark: UInt32? = nil) -> Color {
            let h = scheme == .dark ? (dark ?? light) : light
            return Color(red: Double((h >> 16) & 255) / 255,
                         green: Double((h >> 8) & 255) / 255, blue: Double(h & 255) / 255)
        }
        if appearance.isModern {
            primary = color(0x21384F, 0xF3F7FC)
            secondary = color(0x536C87, 0xBCD0E5)
            muted = color(0x6C8096, 0x99ADC4)
            accent = color(0x3F6EBA, 0xADC8EF)
            price = color(0x355F93, 0xD4E5F7)
            gold = color(0xB77914, 0xF5CE72)
            divider = color(0xCEDCE9, 0x51565E)
            panel = color(0xEAF2FA, 0x30343C)
            positive = color(0x16805F, 0x67D6AA)
            negative = color(0xC84255, 0xFF8CA7)
            background = LinearGradient(colors: [color(0xFCFEFF, 0x2C2F35), color(0xF0F8FB, 0x292C31), color(0xE4EFFB, 0x26282E)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            let night = scheme == .dark
            primary = .white
            secondary = .white.opacity(night ? 0.88 : 0.8)
            muted = .white.opacity(night ? 0.75 : 0.6)
            accent = night ? color(0xA6BEDF) : .pearlSky
            price = night ? color(0xF2D186) : .pearlGold; gold = price
            divider = .white.opacity(night ? 0.14 : 0.16)
            panel = .white.opacity(night ? 0.06 : 0.08)
            positive = night ? color(0x9DE4C8) : .green
            negative = night ? color(0xF6CAA1) : .orange
            // Match the wallet's brighter pearl-blue night gradient.
            background = night
                ? ClassicNightBackground.gradient
                : pearlGradient
        }
    }
}

private struct WidgetColorsKey: EnvironmentKey {
    static let defaultValue = WidgetColors(WidgetAppearance(), scheme: .light)
}
extension EnvironmentValues {
    var widgetColors: WidgetColors {
        get { self[WidgetColorsKey.self] }
        set { self[WidgetColorsKey.self] = newValue }
    }
}

extension WidgetAppearance {
    var colorScheme: ColorScheme? { mode == "light" ? .light : mode == "dark" ? .dark : nil }

    #if os(iOS)
    var activityBackground: Color {
        guard isModern else { return .black.opacity(0.55) }
        return Color(uiColor: UIColor { traits in
            let dark = mode == "dark" || (mode == "system" && traits.userInterfaceStyle == .dark)
            return dark ? UIColor(red: 41 / 255, green: 44 / 255, blue: 49 / 255, alpha: 1)
                : UIColor(red: 0.941, green: 0.973, blue: 0.984, alpha: 1)
        })
    }
    #endif
}

struct WidgetPresentation<Content: View>: View {
    let appearance: WidgetAppearance
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var systemScheme
    var body: some View {
        let scheme = appearance.colorScheme ?? systemScheme
        content.environment(\.widgetColors, WidgetColors(appearance, scheme: scheme))
            .environment(\.colorScheme, scheme)
            .foregroundStyle(WidgetColors(appearance, scheme: scheme).primary)
    }
}

struct WidgetBackground: View {
    let appearance: WidgetAppearance
    @Environment(\.colorScheme) private var systemScheme
    @ViewBuilder
    var body: some View {
        let scheme = appearance.colorScheme ?? systemScheme
        if !appearance.isModern && scheme == .dark {
            ClassicNightBackground()
        } else {
            WidgetColors(appearance, scheme: scheme).background
        }
    }
}

/// A physical pixel rather than a point, so dividers stay delicate on Retina screens.
struct WidgetDivider: View {
    var vertical = false
    @Environment(\.displayScale) private var scale
    @Environment(\.widgetColors) private var colors
    var body: some View {
        Rectangle().fill(colors.divider)
            .frame(width: vertical ? 1 / max(scale, 1) : nil,
                   height: vertical ? nil : 1 / max(scale, 1))
            .accessibilityHidden(true)
    }
}
