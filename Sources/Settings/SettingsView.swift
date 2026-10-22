import SwiftUI

struct SettingsView: View {
    // Only the brand header and navigation title observe the scroll progress.
    @State private var header = SettingsHeaderScroll()
    @State private var shotOfflineAlerts = SettingsView.shotOfflineAlerts
    @State private var shotWebLink = SettingsView.shotWebLink

    private static var shotOfflineAlerts: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SHOT_OFFLINE_ALERTS"] == "1"
        #else
        return false
        #endif
    }

    @State private var shotSecurity = SettingsView.shotSecurity

    private static var shotSecurity: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SHOT_SECURITY"] == "1"
        #else
        return false
        #endif
    }

    private static var shotWebLink: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SHOT_WEB_LINK"] == "1"
        #else
        return false
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CollapsingLogoRow(header: header)
                        .listRowBackground(Color.clear)
                        #if os(iOS)
                        .background(ScrollOffsetReader { [header] y in
                            let p = min(max(y / 110, 0), 1)
                            if abs(p - header.progress) > 0.0005 { header.progress = p }
                        })
                        #endif
                }
                .listRowInsets(EdgeInsets())

                AccountSettingsSection()
                ProSettingsSection()
                NotificationSettingsSection()
                AppearanceSettingsSection()
                RegionalSettingsSection()
                GatewaySettingsSection()

                Section(Loc("安全与隐私")) {
                    NavigationLink {
                        SecurityInfoView()
                    } label: {
                        SettingsMenuLabel(Loc("安全性说明"), systemImage: "checkmark.shield")
                    }
                    .accessibilityIdentifier("settings-security")
                }
                .pearlListRowSurface()

                Section(Loc("帮助与关于")) {
                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        LabeledContent {
                            Text(appVersion)
                        } label: {
                            SettingsMenuLabel(Loc("关于"), systemImage: "info.circle")
                        }
                    }
                    .accessibilityIdentifier("settings-about")
                }
                .pearlListRowSurface()
            }
            .formStyle(.grouped)
            .pearlListBackground()
            .navigationTitle(Loc("设置"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    SettingsNavTitle(header: header)
                }
            }
            #endif
            .navigationDestination(isPresented: $shotOfflineAlerts) { OfflineAlertsView() }
            .navigationDestination(isPresented: $shotWebLink) { WebLinkView() }
            .navigationDestination(isPresented: $shotSecurity) { SecurityInfoView() }
        }
    }
}

private var appVersion: String {
    let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    return "\(v) (\(b))"
}

/// A settings row's leading icon. Bare glyph, no badge: in a 30pt badge the glyph is
/// 14pt and the rows all read as the same tile. The frame keeps titles on one column.
struct SettingsGlyph: View {
    let systemImage: String
    var tint: Color = Pearl.accent

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
    }
}

/// Shared menu treatment; controls and long explanations live on the destination pages.
private struct SettingsMenuLabel: View {
    let title: String
    let systemImage: String
    var detail: String? = nil

    init(_ title: String, systemImage: String, detail: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: Pearl.Space.sm) {
            SettingsGlyph(systemImage: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AccountSettingsSection: View {
    @ObservedObject private var web = WebLinkStore.shared

    var body: some View {
        Section(Loc("账号与钱包")) {
            NavigationLink {
                WebLinkView()
            } label: {
                LabeledContent {
                    if web.isLinked { Text(Loc("已连接")) }
                } label: {
                    SettingsMenuLabel(Loc("邮箱账号"), systemImage: "person.crop.circle")
                }
            }
            .accessibilityIdentifier("settings-account")
            WalletSettingsEntry()
        }
        .pearlListRowSurface()
    }
}

/// Wallet polling only refreshes its own entry, rather than the settings directory.
private struct WalletSettingsEntry: View {
    @EnvironmentObject private var wallet: WalletStore

    var body: some View {
        NavigationLink {
            WalletSecuritySettingsView()
        } label: {
            LabeledContent {
                if wallet.phase == .unlocked { Text("\(wallet.wallets.count)") }
            } label: {
                SettingsMenuLabel(Loc("钱包与安全"), systemImage: "lock.shield")
            }
        }
        .accessibilityIdentifier("settings-wallet")
    }
}

private struct ProSettingsSection: View {
    @ObservedObject private var pro = ProStore.shared

    var body: some View {
        Section(Loc("Pro 会员")) {
            NavigationLink {
                ProSettingsView()
            } label: {
                LabeledContent {
                    Text(pro.isPro ? Loc("已开通") : Loc("未开通"))
                } label: {
                    SettingsMenuLabel(Loc("会员权益"), systemImage: "sparkles",
                                      detail: Loc("跨设备数据同步"))
                }
            }
            .accessibilityIdentifier("settings-pro")
        }
        .pearlListRowSurface()
    }
}

private struct AppearanceSettingsSection: View {
    @AppStorage("ui.appearance") private var appearance = "system"
    @AppStorage(AppIconChoice.key) private var iconStored: String?

    private var theme: String {
        appearance == "light" ? Loc("浅色") : appearance == "dark" ? Loc("深色") : Loc("跟随系统")
    }

    var body: some View {
        Section(Loc("外观设置")) {
            NavigationLink {
                AppearanceSettingsView()
            } label: {
                LabeledContent {
                    Text(theme)
                } label: {
                    SettingsMenuLabel(Loc("主题与配色"), systemImage: "paintpalette")
                }
            }
            .accessibilityIdentifier("settings-appearance")
            NavigationLink {
                AppIconSettingsView()
            } label: {
                LabeledContent {
                    Text(AppIconChoice(stored: iconStored).title)
                } label: {
                    SettingsMenuLabel(Loc("应用图标"), systemImage: "app.badge")
                }
            }
            .accessibilityIdentifier("settings-app-icon")
        }
        .pearlListRowSurface()
    }
}

private struct RegionalSettingsSection: View {
    @EnvironmentObject private var loc: LocalizationManager
    @EnvironmentObject private var currency: CurrencyManager

    var body: some View {
        Section(Loc("语言与货币")) {
            NavigationLink {
                LanguageSettingsView()
            } label: {
                LabeledContent {
                    Text(loc.language.displayName)
                } label: {
                    SettingsMenuLabel(Loc("界面语言"), systemImage: "globe")
                }
            }
            .accessibilityIdentifier("settings-language")
            NavigationLink {
                CurrencySettingsView()
            } label: {
                LabeledContent {
                    Text(currency.secondary.map { "USD · " + $0.code } ?? "USD")
                } label: {
                    SettingsMenuLabel(Loc("货币"), systemImage: "dollarsign.circle")
                }
            }
            .accessibilityIdentifier("settings-currency")
        }
        .pearlListRowSurface()
    }
}

private struct GatewaySettingsSection: View {
    @EnvironmentObject private var wallet: WalletStore

    var body: some View {
        Section(Loc("网关设置")) {
            NavigationLink {
                NetworkSettingsView()
            } label: {
                LabeledContent {
                    Text(wallet.network.label)
                } label: {
                    SettingsMenuLabel(Loc("Pearl 网络"), systemImage: "network")
                }
            }
            .accessibilityIdentifier("settings-network")
            if AppFeatures.tradeEnabled {
                NavigationLink {
                    TradeSettingsView()
                } label: {
                    SettingsMenuLabel(Loc("交易（SafeTrade）"), systemImage: "arrow.left.arrow.right")
                }
                .accessibilityIdentifier("settings-trade")
            }
        }
        .pearlListRowSurface()
    }
}

private struct NotificationSettingsSection: View {
    @ObservedObject private var alerts = PriceAlertStore.shared
    @ObservedObject private var offline = OfflineAlertStore.shared
    @ObservedObject private var pro = ProStore.shared
    @ObservedObject private var live = PriceLiveActivity.shared

    var body: some View {
        Section(Loc("通知设置")) {
            NavigationLink {
                PriceAlertsView()
            } label: {
                LabeledContent {
                    let on = alerts.rules.filter(\.isOn).count
                    if !pro.isPro {
                        PearlBadge(text: Loc("高级版"), tint: Pearl.accent)
                    } else if on > 0 {
                        Text("\(on)")
                    }
                } label: {
                    SettingsMenuLabel(Loc("价格提醒"), systemImage: "bell.badge")
                }
            }
            .accessibilityIdentifier("settings-price-alerts")
            NavigationLink {
                OfflineAlertsView()
            } label: {
                LabeledContent {
                    let on = offline.activeCount
                    if !pro.isPro {
                        PearlBadge(text: Loc("高级版"), tint: Pearl.accent)
                    } else if on > 0 {
                        Text("\(on)")
                    }
                } label: {
                    SettingsMenuLabel(Loc("掉线提醒"), systemImage: "wifi.exclamationmark")
                }
            }
            .accessibilityIdentifier("settings-offline-alerts")
            if PriceLiveActivity.supported {
                NavigationLink {
                    LiveActivitySettingsView()
                } label: {
                    LabeledContent {
                        if !pro.isPro {
                            PearlBadge(text: Loc("高级版"), tint: Pearl.accent)
                        } else if live.running {
                            Text(Loc("盯盘中")).foregroundStyle(.green)
                        }
                    } label: {
                        SettingsMenuLabel(Loc("锁屏盯盘"), systemImage: "lock.iphone")
                    }
                }
                .accessibilityIdentifier("settings-live-activity")
            }
        }
        .pearlListRowSurface()
    }
}

/// Scroll progress of the settings header: 0 = expanded vertical logo, 1 = inline.
@Observable
final class SettingsHeaderScroll {
    var progress: CGFloat = 0
}

/// Brand header that morphs from a large vertical block to a small inline row as
/// `progress` goes 0 → 1 with scroll (see `MorphStack`).
private struct CollapsingLogoRow: View {
    let header: SettingsHeaderScroll

    var body: some View {
        let p = header.progress
        let sp = min(1, p / 0.5)            // size finishes collapsing by progress 0.5
        let mark = lerp(96, 26, sp)
        MorphStack(progress: p, spacing: lerp(8, 7, sp)) {
            PearlLogo(size: mark * 0.82, showsWordmark: false)
                .frame(width: mark, height: mark)
            PearlLogo.wordmark
                .font(.system(size: lerp(30, 17, sp), weight: .bold, design: .rounded))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, lerp(Pearl.Space.xs, 2, p))
    }
}

/// "设置" ↔ inline logo in the nav bar. The inline logo is identical in mark size /
/// font / spacing to the content header's fully-collapsed endpoint (mark 26, wordmark
/// 17, spacing 7), so the two stay horizontally aligned through the hand-off, and it
/// only fades in once the big header has scrolled away.
private struct SettingsNavTitle: View {
    let header: SettingsHeaderScroll

    var body: some View {
        ZStack {
            Text(Loc("设置")).font(.headline)
                .opacity(1 - fade(header.progress, 0.85, 0.95))
            HStack(spacing: 7) {
                PearlLogo(size: 26 * 0.82, showsWordmark: false)
                    .frame(width: 26, height: 26)
                PearlLogo.wordmark
                    .font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(1)
            }
            .opacity(fade(header.progress, 0.90, 1.0))
        }
    }
}

/// Linear interpolation for the collapsing-header morph.
private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

/// Smooth 0→1 ramp of `p` between thresholds `a`…`b` — used to cross-fade the nav title.
private func fade(_ p: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Double {
    Double(min(max((p - a) / (b - a), 0), 1))
}

/// Two-subview layout that morphs between a vertical stack (`progress` 0) and a
/// horizontal stack (`progress` 1), interpolating each subview's center so the brand
/// header shrinks smoothly from a tall block into an inline row as the user scrolls.
private struct MorphStack: Layout {
    var progress: CGFloat
    var spacing: CGFloat

    /// Offset of subview 1 (wordmark) from subview 0 (mascot) center. Follows an
    /// L-path — slides right over 0→0.5, then up over 0.5→1 — so the two never pass
    /// through each other (a straight vertical→horizontal lerp overlaps mid-morph).
    private func offset(_ a: CGSize, _ b: CGSize) -> CGPoint {
        let rv = a.height / 2 + spacing + b.height / 2   // straight-below separation
        let rh = a.width / 2 + spacing + b.width / 2     // straight-right separation
        // Snap onto a single row EARLY: slide right over 0→0.12 (clearing the mascot),
        // then up onto the same line over 0.12→0.28. After ~0.28 they're inline and just
        // shrink — so the staggered below-right phase is brief instead of lasting all scroll.
        let x = rh * min(1, progress / 0.12)
        let y = rv * (1 - min(1, max(0, (progress - 0.12) / 0.16)))
        return CGPoint(x: x, y: y)
    }

    /// Union bounds (size + center) of mascot @origin and wordmark @offset.
    private func union(_ a: CGSize, _ b: CGSize, _ o: CGPoint) -> (size: CGSize, center: CGPoint) {
        let minX = min(-a.width / 2, o.x - b.width / 2),  maxX = max(a.width / 2, o.x + b.width / 2)
        let minY = min(-a.height / 2, o.y - b.height / 2), maxY = max(a.height / 2, o.y + b.height / 2)
        return (CGSize(width: maxX - minX, height: maxY - minY),
                CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let a = subviews[0].sizeThatFits(.unspecified)
        let b = subviews[1].sizeThatFits(.unspecified)
        return union(a, b, offset(a, b)).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let a = subviews[0].sizeThatFits(.unspecified)
        let b = subviews[1].sizeThatFits(.unspecified)
        let o = offset(a, b)
        let center = union(a, b, o).center
        // Position so the union of both subviews is centered in bounds.
        let c = CGPoint(x: bounds.midX - center.x, y: bounds.midY - center.y)
        subviews[0].place(at: c, anchor: .center, proposal: .unspecified)
        subviews[1].place(at: CGPoint(x: c.x + o.x, y: c.y + o.y), anchor: .center, proposal: .unspecified)
    }
}

#if os(iOS)
import UIKit

/// Reports the enclosing `UIScrollView`'s scroll distance from the top (0 at rest)
/// via KVO. Needed inside a `Form`/`List` because SwiftUI preference-based offset
/// tracking does not propagate through UIKit cells during scroll.
private struct ScrollOffsetReader: UIViewRepresentable {
    var onChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        context.coordinator.onChange = onChange
        DispatchQueue.main.async { context.coordinator.attach(from: v) }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChange = onChange
        if !context.coordinator.isAttached {
            DispatchQueue.main.async { context.coordinator.attach(from: uiView) }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Observes `contentOffset` with string-keyed KVO: a Swift key path to that
    /// main-actor property can't be formed from the (nonisolated) KVO callback.
    @MainActor final class Coordinator: NSObject {
        var onChange: (CGFloat) -> Void = { _ in }
        private weak var scrollView: UIScrollView?
        var isAttached: Bool { scrollView != nil }

        func attach(from view: UIView) {
            guard scrollView == nil else { return }
            var v: UIView? = view.superview
            while let cur = v {
                if let sv = cur as? UIScrollView {
                    scrollView = sv
                    sv.addObserver(self, forKeyPath: "contentOffset", options: [.initial, .new], context: nil)
                    return
                }
                v = cur.superview
            }
        }

        func detach() {
            scrollView?.removeObserver(self, forKeyPath: "contentOffset")
            scrollView = nil
        }

        // UIKit changes contentOffset — and so sends this — on the main thread only.
        nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                               change: [NSKeyValueChangeKey: Any]?,
                                               context: UnsafeMutableRawPointer?) {
            MainActor.assumeIsolated {
                guard let sv = scrollView else { return }
                onChange(sv.contentOffset.y + sv.adjustedContentInset.top)
            }
        }
    }
}
#endif
