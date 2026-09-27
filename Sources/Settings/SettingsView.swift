import SwiftUI

struct SettingsView: View {
    @AppStorage("ui.appearance") private var appearance = "system"   // system | light | dark
    @AppStorage("ui.lockPortrait") private var lockPortrait = true   // iPhone 锁定竖屏 — same key as OrientationLock.key

    // Scroll-driven header morph. An @Observable held in @State: only the two views that
    // read `progress` (the logo row and the nav title) re-render per scroll frame, not
    // this whole Form.
    @State private var header = SettingsHeaderScroll()

    @EnvironmentObject private var loc: LocalizationManager
    @EnvironmentObject private var currency: CurrencyManager
    @ObservedObject private var alerts = PriceAlertStore.shared
    @ObservedObject private var pro = ProStore.shared
    @ObservedObject private var live = PriceLiveActivity.shared

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CollapsingLogoRow(header: header)
                        .listRowBackground(Color.clear)
                        #if os(iOS)
                        // KVO the enclosing scroll view → continuous collapse progress.
                        .background(ScrollOffsetReader { [header] y in
                            let p = min(max(y / 110, 0), 1)
                            if abs(p - header.progress) > 0.0005 { header.progress = p }
                        })
                        #endif
                }
                .listRowInsets(EdgeInsets())

                // Wallet-dependent rows live in their own views, so a WalletStore publish
                // (every chain poll) re-renders them rather than the whole Form.
                WalletSettingsSection()

                Section(Loc("通知")) {
                    NavigationLink {
                        PriceAlertsView()
                    } label: {
                        LabeledContent {
                            let on = alerts.rules.filter(\.enabled).count
                            if !pro.isPro {
                                PearlBadge(text: Loc("高级版"), tint: Pearl.accent)
                            } else if on > 0 {
                                Text("\(on)")
                            }
                        } label: {
                            Label(Loc("价格提醒"), systemImage: "bell.badge")
                        }
                    }
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
                                Label(Loc("锁屏盯盘"), systemImage: "lock.iphone")
                            }
                        }
                    }
                }

                NetworkSettingsSection()

                Section(Loc("外观")) {
                    Picker(Loc("主题"), selection: $appearance) {
                        Text(Loc("跟随系统")).tag("system")
                        Text(Loc("浅色")).tag("light")
                        Text(Loc("深色")).tag("dark")
                    }
                    #if os(iOS)
                    if UIDevice.current.userInterfaceIdiom == .phone {
                        Toggle(Loc("锁定竖屏"), isOn: $lockPortrait)
                    }
                    #endif
                }

                Section(Loc("语言")) {
                    Picker(Loc("界面语言"), selection: Binding(
                        get: { loc.language },
                        set: { loc.setLanguage($0) })) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                }

                Section(Loc("货币")) {
                    LabeledContent(Loc("主货币"), value: "USD · " + Loc("美元"))
                    Picker(Loc("副货币"), selection: Binding(
                        get: { currency.secondaryPref },
                        set: { currency.setSecondaryPref($0) })) {
                        Text(Loc("跟随语言")).tag(Fiat.auto)
                        Text(Loc("不显示")).tag(Fiat.none)
                        ForEach(Fiat.secondaries) { c in
                            Text("\(c.localizedName) · \(c.code)").tag(c.code)
                        }
                    }
                    if currency.secondaryPref == Fiat.auto, let s = currency.secondary {
                        LabeledContent(Loc("当前副货币"), value: "\(s.localizedName) · \(s.code)")
                    }
                    if let line = currency.rateLine() {
                        LabeledContent(Loc("当前汇率"), value: line)
                    }
                    if let at = currency.lastUpdated {
                        LabeledContent(Loc("汇率更新于"),
                                       value: at.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                                                            .locale(LocBundleHolder.shared.locale)))
                    }
                    Button(Loc("立即刷新汇率")) { Task { await currency.refresh() } }
                    Label(Loc("汇率以美元为基准，每天自动更新一次；离线时使用最近一次缓存。"),
                          systemImage: "clock.arrow.circlepath")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if AppFeatures.tradeEnabled {   // gated off for App Store: no in-app trading
                    SafeTradeSettingsSection()
                }

                Section(Loc("安全")) {
                    Label(Loc("助记词加密存于钥匙串；查看助记词与转账需 Face ID / Touch ID 验证。"), systemImage: "key.fill")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section(Loc("关于")) {
                    LabeledContent(Loc("应用"), value: Loc("$Pearl Hub"))
                    LabeledContent(Loc("版本"), value: appVersion)
                    // Opens the App Store review sheet directly. The in-app prompt (see
                    // ReviewPrompt) is rate-limited by the system and may show nothing at
                    // all, so an explicit "I want to rate this" needs a path that always works.
                    if let url = ReviewPrompt.writeReviewURL {
                        Link(destination: url) {
                            Label(Loc("为 Pearl Hub 评分"), systemImage: "star.fill")
                        }
                    }
                    LabeledContent(Loc("开发者"), value: "Cyber Corner")
                    Link(destination: AppLinks.telegram) {
                        Label(Loc("加入 Telegram 频道 @prl_hub，获取更新公告与帮助"), systemImage: "paperplane.fill")
                    }
                    Link(destination: AppLinks.github) {
                        Label(Loc("GitHub 开源代码"), systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    NavigationLink {
                        LicensesView()
                    } label: { Label(Loc("开源许可"), systemImage: "doc.text") }
                    Label(Loc("自托管 · 私钥与签名留在本机（钥匙串 / 安全隔区）"), systemImage: "shield.lefthalf.filled")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label(Loc("内置 PRL 挖矿监控"), systemImage: "chart.line.uptrend.xyaxis")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .pearlListBackground()
            .navigationTitle(Loc("设置"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // "设置" ↔ inline logo. The inline logo matches the content header's
                // fully-collapsed size, so the two icons stay horizontally aligned, and
                // it only fades in once the big header has scrolled away.
                ToolbarItem(placement: .principal) {
                    SettingsNavTitle(header: header)
                }
            }
            #endif
            .onChange(of: appearance) { _, _ in CloudSync.push("ui.appearance") }
            #if os(iOS)
            .onChange(of: lockPortrait) { _, _ in OrientationLock.apply() }
            #endif
        }
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
            Image("AppLogoMark")
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: mark, height: mark)
                .shadow(color: Pearl.indigo.opacity(0.30), radius: mark * 0.12, y: mark * 0.05)
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
                Image("AppLogoMark").resizable().interpolation(.high).scaledToFit()
                    .frame(width: 26, height: 26)
                    .shadow(color: Pearl.indigo.opacity(0.30), radius: 26 * 0.12, y: 26 * 0.05)
                PearlLogo.wordmark
                    .font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(1)
            }
            .opacity(fade(header.progress, 0.90, 1.0))
        }
    }
}

/// 设置 → 钱包 (only while unlocked) plus the remove-wallet confirmation.
private struct WalletSettingsSection: View {
    @EnvironmentObject private var wallet: WalletStore
    @State private var confirmingReset = false
    @State private var resetError: String?

    var body: some View {
        if wallet.phase == .unlocked {
            Section(Loc("钱包")) {
                NavigationLink {
                    ManageWalletsView(store: wallet)
                } label: {
                    LabeledContent {
                        Text("\(wallet.wallets.count)")
                    } label: {
                        Label(Loc("管理钱包"), systemImage: "wallet.pass")
                    }
                }
                NavigationLink {
                    ContactsView()
                } label: { Label(Loc("地址簿"), systemImage: "person.crop.circle") }
                NavigationLink {
                    RevealSeedView(store: wallet)
                } label: { Label(Loc("查看助记词"), systemImage: "key.horizontal") }
                NavigationLink {
                    RecoverChangeView(store: wallet)
                } label: { Label(Loc("找回搁浅的找零"), systemImage: "arrow.uturn.down.circle") }
                Button { wallet.lock() } label: {
                    Label(Loc("锁定钱包"), systemImage: "lock").foregroundStyle(.primary)
                }
                Button(role: .destructive) { confirmingReset = true } label: {
                    Label(Loc("移除钱包（需助记词恢复）"), systemImage: "trash")
                }
            }
            // .alert (not .confirmationDialog) — centered on every platform; a
            // confirmationDialog mis-anchors as a popover over the nav bar on iPad/Mac.
            .alert(Loc("确定要移除钱包「%@」吗？", wallet.walletName), isPresented: $confirmingReset) {
                Button(Loc("移除钱包"), role: .destructive) {
                    let ok = withAnimation { wallet.reset() }
                    if !ok { resetError = wallet.lastError ?? Loc("移除失败"); wallet.lastError = nil }
                }
                Button(Loc("取消"), role: .cancel) {}
            } message: {
                Text(Loc("助记词将从本机删除且无法恢复。请确认你已安全备份助记词，否则资产将永久丢失。"))
            }
            .alert(Loc("移除失败"), isPresented: Binding(
                get: { resetError != nil }, set: { if !$0 { resetError = nil } })) {
                Button(Loc("知道了"), role: .cancel) { resetError = nil }
            } message: {
                Text(resetError ?? "")
            }
        }
    }
}

/// 设置 → 网络.
private struct NetworkSettingsSection: View {
    @EnvironmentObject private var wallet: WalletStore

    var body: some View {
        Section(Loc("网络")) {
            Picker(Loc("Pearl 网络"), selection: Binding(
                get: { wallet.network },
                set: { wallet.changeNetwork($0) })) {
                ForEach(WalletNetwork.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent(Loc("索引服务"), value: "blockbook.pearlresearch.ai")
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
