import SwiftUI

/// 设置 → 外观 → 配色. Classic pearl blue and modern silver with blue accents.
/// A separate choice from the home-screen icon (AppIcon.swift).
///
/// The colours themselves are `PearlTones` in DesignSystem.swift; the `Pearl` tokens read
/// `current` each time a view is built, and RootView rebuilds the tree when it changes.
enum AppPalette: String, CaseIterable, Identifiable {
    // Retain the former monochrome setting so existing selections receive the new style.
    case modern = "mono"
    case classic

    /// Per device, like the icon.
    static let key = "ui.palette"

    var id: String { rawValue }

    var title: String { self == .modern ? Loc("现代银") : Loc("经典蓝") }

    var tones: PearlTones { self == .modern ? .modern : .classic }

    /// New installs use modern silver; a recognized stored choice always wins.
    init(stored: String?) {
        self = stored.flatMap(AppPalette.init(rawValue:)) ?? .modern
    }

    /// Old installs without a palette preference predate the picker and were classic blue.
    static func initial(launchedBefore: Bool) -> AppPalette { launchedBefore ? .classic : .modern }

    /// First run of a build that has the choice: record which palette this install gets,
    /// the way the icon does (`AppIconChoice.adoptDefault`) — an update must not repaint
    /// an app its user never touched. Runs with the first colour lookup, which is ahead of
    /// `ReviewPrompt.registerLaunch()` counting the launch being decided on.
    static func adoptDefault(in defaults: UserDefaults = .standard, launches: Int = ReviewPrompt.launchCount) -> AppPalette {
        if let stored = defaults.string(forKey: key).flatMap(AppPalette.init(rawValue:)) { return stored }
        let palette = initial(launchedBefore: launches > 0)
        defaults.set(palette.rawValue, forKey: key)
        return palette
    }

    /// The palette in use. Cached: every colour lookup asks. Only ever written on the main
    /// thread, by `select`.
    nonisolated(unsafe) private(set) static var current = adoptDefault()

    /// Switch palettes. The stored value is what RootView watches to rebuild.
    @MainActor static func select(_ palette: AppPalette) {
        current = palette
        UserDefaults.standard.set(palette.rawValue, forKey: key)
    }
}

/// 设置 → 外观 → 配色: a swatch of each palette side by side; tapping one switches to it.
struct AppPalettePicker: View {
    @AppStorage(AppPalette.key) private var stored: String?

    var body: some View {
        let current = AppPalette(stored: stored)
        HStack(spacing: Pearl.Space.md) {
            Text(Loc("配色"))
            Spacer(minLength: Pearl.Space.xs)
            ForEach(AppPalette.allCases) { palette in
                Button {
                    AppPalette.select(palette)
                } label: {
                    VStack(spacing: Pearl.Space.xxs) {
                        swatch(palette)
                            .padding(3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 58 * 0.225 + 1.5, style: .continuous)
                                    .strokeBorder(Pearl.accent, lineWidth: 2)
                                    .opacity(palette == current ? 1 : 0)
                            )
                        Text(palette.title)
                            .font(.caption2)
                            .foregroundStyle(palette == current ? Color.primary : Color.secondary)
                    }
                    // Match the app-icon columns regardless of caption length.
                    .frame(width: 80)
                    .multilineTextAlignment(.center)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(palette == current ? .isSelected : [])
            }
        }
        .padding(.vertical, Pearl.Space.xxs)
    }

    /// The palette in miniature, the size of an icon tile: its hero fill, a line of what
    /// stands on it, and its accent.
    private func swatch(_ palette: AppPalette) -> some View {
        let shape = RoundedRectangle(cornerRadius: 52 * 0.225, style: .continuous)
        return shape.fill(palette.tones.brandVivid)
            .frame(width: 52, height: 52)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(palette.tones.onHero.opacity(0.92)).frame(width: 24, height: 5)
                    Capsule().fill(palette.tones.onHero.opacity(0.45)).frame(width: 15, height: 4)
                }
                .padding(9)
            }
            .overlay(alignment: .topTrailing) {
                Circle().fill(palette == .modern ? palette.tones.accent : palette.tones.gold)
                    .frame(width: 10, height: 10).padding(9)
            }
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}
