import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 设置 → 外观 → 应用图标. The bundle's blue pearl, the P icon, and the classic miner
/// pearl. New installs use the pearl; recognized preferences remain unchanged.
///
/// iOS swaps the home-screen icon through the alternate-icon API, and the system always
/// tells the user it happened (an alert it puts up itself; there is no quiet way). macOS
/// gives a sandboxed app no such thing: only the Dock icon of the running app can be
/// replaced, so Finder and Launchpad always show the bundle's icon.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case pearl, modern, classic

    /// Per device, not synced: it is this device's home screen.
    static let key = "ui.appIcon"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modern: Loc("P 图标")
        case .pearl: Loc("珍珠图标")
        case .classic: Loc("经典图标")
        }
    }

    /// The picture of this icon for use inside the app: a square the caller rounds.
    var imageName: String {
        switch self {
        case .modern: "AppLogoModern"
        case .pearl: "AppLogoPearl"
        case .classic: "AppLogo"
        }
    }

    /// The asset-catalog name iOS knows this icon by; nil is the bundle's own.
    var alternateIconName: String? {
        switch self {
        case .modern: "AppIconModern"
        case .pearl: nil
        case .classic: "AppIconClassic"
        }
    }

    init(stored: String?) {
        self = stored.flatMap(AppIconChoice.init(rawValue:)) ?? .pearl
    }

    /// What this install shows. Unset only until `adoptDefault()` has run.
    static var current: AppIconChoice { AppIconChoice(stored: UserDefaults.standard.string(forKey: key)) }

    /// Old installs without an icon preference predate the picker and used the miner.
    static func initial(launchedBefore: Bool) -> AppIconChoice { launchedBefore ? .classic : .pearl }

    /// Keep the former pearl alternate registered so its existing users need no icon alert.
    func isApplied(alternateName: String?) -> Bool {
        alternateName == alternateIconName || (self == .pearl && alternateName == "AppIconPearl")
    }

    /// First run of a build that has the choice: record which icon this install gets. Has
    /// to run before `ReviewPrompt.registerLaunch()` counts the launch being decided on —
    /// a count above zero is what says the app was here before.
    static func adoptDefault(in defaults: UserDefaults = .standard, launches: Int = ReviewPrompt.launchCount) {
        guard defaults.string(forKey: key) == nil else { return }
        defaults.set(initial(launchedBefore: launches > 0).rawValue, forKey: key)
    }

    /// Make the home screen (iOS) or the Dock (macOS) show `choice`.
    @MainActor static func apply(_ choice: AppIconChoice) async {
        #if os(iOS)
        let app = UIApplication.shared
        guard app.supportsAlternateIcons, !choice.isApplied(alternateName: app.alternateIconName) else { return }
        try? await app.setAlternateIconName(choice.alternateIconName)
        #else
        // nil hands the Dock back the bundle's icon.
        NSApp.applicationIconImage = choice == .pearl ? nil : NSImage(named: choice.imageName)
        #endif
    }

    /// At launch: bring the icon in line with the stored choice. On iOS that is a no-op
    /// except the once an existing install is moved back to its old icon, and the system
    /// refuses the swap until the app is active — a matter of a few frames. On macOS it is
    /// every launch: the Dock forgets.
    @MainActor static func applyAtLaunch() async {
        #if os(iOS)
        for _ in 0..<40 where UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(100))
        }
        #endif
        await apply(current)
    }
}

/// An app icon as a rounded tile, the way the home screen shows it.
struct AppIconTile: View {
    var choice: AppIconChoice
    var size: CGFloat

    var body: some View {
        Image(choice.imageName)
            .resizable().interpolation(.high).scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
            )
            .shadow(color: Pearl.shadow.opacity(0.25), radius: size * 0.12, y: size * 0.05)
    }
}

/// The pearl and classic marks float on the current surface; the P icon uses its tile.
struct BrandMark: View {
    var size: CGFloat
    /// The cut-out's shadow: its opacity, then radius and drop as fractions of `size`.
    var shadow: (opacity: Double, radius: CGFloat, drop: CGFloat) = (0.30, 0.12, 0.05)
    @AppStorage(AppIconChoice.key) var stored: String?

    var body: some View {
        let choice = AppIconChoice(stored: stored)
        if choice != .modern {
            Image(choice == .pearl ? "AppLogoPearlMark" : "AppLogoMark")
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                .shadow(color: Pearl.shadow.opacity(shadow.opacity), radius: size * shadow.radius, y: size * shadow.drop)
        } else {
            // The cut-out fills about four fifths of its box; the tile matches that weight.
            AppIconTile(choice: choice, size: size * 0.82)
                .frame(width: size, height: size)
        }
    }
}

/// 设置 → 外观 → 应用图标: tapping an icon switches to it.
struct AppIconPicker: View {
    @AppStorage(AppIconChoice.key) private var stored: String?

    var body: some View {
        let current = AppIconChoice(stored: stored)
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            Text(Loc("应用图标"))
            HStack(alignment: .top, spacing: Pearl.Space.xs) {
                ForEach(AppIconChoice.allCases) { choice in
                    Button {
                        stored = choice.rawValue
                        Task { await AppIconChoice.apply(choice) }
                    } label: {
                        VStack(spacing: Pearl.Space.xxs) {
                            AppIconTile(choice: choice, size: 52)
                                .padding(3)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 58 * 0.225 + 1.5, style: .continuous)
                                        .strokeBorder(Pearl.accent, lineWidth: 2)
                                        .opacity(choice == current ? 1 : 0)
                                )
                            Text(choice.title)
                                .font(.caption2)
                                .foregroundStyle(choice == current ? Color.primary : Color.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(choice == current ? .isSelected : [])
                    .accessibilityIdentifier("app-icon-" + choice.rawValue)
                }
            }
        }
        .padding(.vertical, Pearl.Space.xxs)
        #if os(macOS)
        PearlInfoRow(Loc("在 Mac 上只更换程序坞里运行中的图标，访达和启动台仍显示默认图标。"), systemImage: "dock.rectangle")
        #endif
    }
}
