import SwiftUI

struct SettingsView: View {
    @AppStorage("ui.appearance") private var appearance = "system"   // system | light | dark
    @AppStorage("ui.lockPortrait") private var lockPortrait = true   // iPhone 锁定竖屏 — same key as OrientationLock.key
    @AppStorage("safetrade.market") private var market = "prlusdt"

    @State private var apiKeyInput = ""
    @State private var apiSecretInput = ""
    @State private var keyMsg: String?          // transient "已保存" / "已清除"
    @State private var keyMsgIsWarning = false   // green check vs. orange warning
    @State private var verifyingKey = false      // a save+verify request is in flight
    @State private var confirmingReset = false
    @State private var resetError: String?
    @State private var credTick = 0             // bump to re-read SafeTradeSecrets after an iCloud pull
    @State private var headerProgress: CGFloat = 0   // 0 = expanded vertical logo, 1 = inline (scroll-driven)
    @FocusState private var focusedField: Field?
    private enum Field { case market, apiKey, apiSecret }

    @EnvironmentObject private var wallet: WalletStore
    @EnvironmentObject private var loc: LocalizationManager
    @EnvironmentObject private var currency: CurrencyManager
    @ObservedObject private var alerts = PriceAlertStore.shared
    @ObservedObject private var pro = ProStore.shared
    @ObservedObject private var live = PriceLiveActivity.shared
    private var marketValid: Bool { SafeTradeMarket.isValid(market) }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    /// Brand header that morphs from a large vertical block to a small inline row as
    /// `headerProgress` goes 0 → 1 with scroll (see `MorphStack`).
    @ViewBuilder private var collapsingLogoRow: some View {
        let p = headerProgress
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

    /// Nav-bar inline logo — identical in mark size / font / spacing to the content
    /// header's fully-collapsed endpoint (mark 26, wordmark 17, spacing 7). Both are
    /// centered blocks of equal width, so their mascots land at the same x → the two
    /// stay horizontally aligned through the hand-off.
    private var inlineLogo: some View {
        HStack(spacing: 7) {
            Image("AppLogoMark").resizable().interpolation(.high).scaledToFit()
                .frame(width: 26, height: 26)
                .shadow(color: Pearl.indigo.opacity(0.30), radius: 26 * 0.12, y: 26 * 0.05)
            PearlLogo.wordmark
                .font(.system(size: 17, weight: .bold, design: .rounded)).lineLimit(1)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    collapsingLogoRow
                        .listRowBackground(Color.clear)
                        #if os(iOS)
                        // KVO the enclosing scroll view → continuous collapse progress.
                        .background(ScrollOffsetReader { y in
                            let p = min(max(y / 110, 0), 1)
                            if abs(p - headerProgress) > 0.0005 { headerProgress = p }
                        })
                        #endif
                }
                .listRowInsets(EdgeInsets())

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
                }

                Section(Loc("通知")) {
                    NavigationLink {
                        PriceAlertsView()
                    } label: {
                        LabeledContent {
                            let on = alerts.rules.filter(\.enabled).count
                            if !pro.isPro {
                                Text(Loc("高级版"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Pearl.accent)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Pearl.accent.opacity(0.12), in: Capsule())
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
                                    Text(Loc("高级版"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Pearl.accent)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(Pearl.accent.opacity(0.12), in: Capsule())
                                } else if live.running {
                                    Text(Loc("盯盘中")).foregroundStyle(.green)
                                }
                            } label: {
                                Label(Loc("锁屏盯盘"), systemImage: "lock.iphone")
                            }
                        }
                    }
                }

                Section(Loc("网络")) {
                    Picker(Loc("Pearl 网络"), selection: Binding(
                        get: { wallet.network },
                        set: { wallet.changeNetwork($0) })) {
                        ForEach(WalletNetwork.allCases) { Text($0.label).tag($0) }
                    }
                    LabeledContent(Loc("RPC 端口"), value: "\(wallet.network.rpcPort)")
                    LabeledContent(Loc("索引服务"), value: "blockbook.pearlresearch.ai")
                }

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
                                       value: at.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button(Loc("立即刷新汇率")) { Task { await currency.refresh() } }
                    Label(Loc("汇率以美元为基准，每天自动更新一次；离线时使用最近一次缓存。"),
                          systemImage: "clock.arrow.circlepath")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if AppFeatures.tradeEnabled {   // gated off for App Store: no in-app trading
                Section(Loc("交易（SafeTrade）")) {
                    LabeledContent(Loc("交易所"), value: "safetrade.com")
                    TextField(Loc("交易市场（例如 prlusdt）"), text: $market)
                        .focused($focusedField, equals: .market)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                    if !market.isEmpty && !marketValid {
                        Text(Loc("交易市场只能包含字母和数字，例如 prlusdt"))
                            .font(.caption).foregroundStyle(.red)
                    }
                    // Two mutually-exclusive modes: once keys are saved, show only
                    // their masked status + 清除密钥 (the input fields/保存密钥 would
                    // be redundant); clearing flips back to the input fields. credTick
                    // re-reads the Keychain so the mode switches after save/clear/sync.
                    let _ = credTick
                    if SafeTradeSecrets.hasCredentials {
                        LabeledContent(Loc("当前 Key"), value: SafeTradeSecrets.maskedKey)
                        LabeledContent(Loc("当前 Secret"), value: Loc("已设置 ✓"))
                        Button(Loc("清除密钥"), role: .destructive) {
                            SafeTradeSecrets.clear()
                            credTick += 1
                            flashKeyMsg(Loc("已清除"))
                        }
                    } else {
                        SecureField("API Key", text: $apiKeyInput)
                            .focused($focusedField, equals: .apiKey)
                            #if os(iOS)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            #endif
                            .accessibilityLabel("SafeTrade API Key")
                        SecureField("API Secret", text: $apiSecretInput)
                            .focused($focusedField, equals: .apiSecret)
                            #if os(iOS)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            #endif
                            .accessibilityLabel("SafeTrade API Secret")
                        Button {
                            let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            let secret = apiSecretInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await saveAndVerifyKeys(apiKey: key, apiSecret: secret) }
                        } label: {
                            HStack {
                                Text(verifyingKey ? Loc("验证中…") : Loc("保存密钥"))
                                if verifyingKey { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(apiKeyInput.isEmpty || apiSecretInput.isEmpty || verifyingKey)
                    }
                    if let keyMsg {
                        Label(keyMsg, systemImage: keyMsgIsWarning ? "exclamationmark.triangle" : "checkmark.seal")
                            .font(.footnote).foregroundStyle(keyMsgIsWarning ? .orange : .green)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(keyMsg)
                    }
                    Label(Loc("API 密钥存于 iCloud 钥匙串（端到端加密，仅你可见），在各设备间同步；助记词不同步，仅存于本机钥匙串。"), systemImage: "key.icloud")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                }   // AppFeatures.tradeEnabled

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
            // 文本/密钥输入键盘上方的「完成」按钮，点一下即可收起键盘。
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(Loc("完成")) { focusedField = nil }.fontWeight(.semibold)
                }
                // "设置" ↔ inline logo. The inline logo matches the content header's
                // fully-collapsed size, so the two icons stay horizontally aligned, and
                // it only fades in once the big header has scrolled away.
                ToolbarItem(placement: .principal) {
                    ZStack {
                        Text(Loc("设置")).font(.headline)
                            .opacity(1 - fade(headerProgress, 0.85, 0.95))
                        inlineLogo
                            .opacity(fade(headerProgress, 0.90, 1.0))
                    }
                }
            }
            #endif
            .onChange(of: market) { _, value in
                let cleaned = SafeTradeMarket.cleaned(value)
                if cleaned != value {
                    market = cleaned
                    return
                }
                if SafeTradeMarket.isValid(cleaned) { CloudSync.push("safetrade.market") }
            }
            .onChange(of: appearance) { _, _ in CloudSync.push("ui.appearance") }
            #if os(iOS)
            .onChange(of: lockPortrait) { _, _ in OrientationLock.apply() }
            #endif
            // Re-read SafeTradeSecrets when iCloud pulls keys in (the @State bump re-renders the body).
            .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidUpdate)) { _ in credTick += 1 }
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

    /// Save the entered keys, then immediately verify them against SafeTrade so we
    /// can tell the user *why* if a trade-authed request fails — wrong key/secret,
    /// IP not whitelisted, or a network problem — instead of silently storing a key
    /// that won't work. We still save on a failed check (the keys may be correct but
    /// the IP simply isn't whitelisted yet, which the user fixes exchange-side), and
    /// surface a warning rather than a hard failure.
    @MainActor
    private func saveAndVerifyKeys(apiKey: String, apiSecret: String) async {
        verifyingKey = true
        withAnimation { keyMsg = nil }
        // Check what the user typed *before* committing it (signs with these keys).
        let check = await SafeTradeClient().verifyCredentials(apiKey: apiKey, apiSecret: apiSecret)
        // Stored in the iCloud Keychain — syncs to your other devices end-to-end
        // encrypted, so no manual (plaintext) KVS push.
        let saved = SafeTradeSecrets.save(apiKey: apiKey, apiSecret: apiSecret)
        apiKeyInput = ""; apiSecretInput = ""
        credTick += 1
        verifyingKey = false
        guard saved else {
            flashKeyMsg(Loc("无法写入钥匙串（Keychain）"), warning: true)
            return
        }
        switch check {
        case .ok:
            flashKeyMsg(Loc("已保存并通过验证（会经 iCloud 同步到其他设备）"))
        case .rejected:
            flashKeyMsg(Loc("已保存，但验证未通过：API Key/Secret 可能不正确，或当前 IP 未加入白名单。请在 SafeTrade 后台核对密钥，并为此网络的 IP 开通访问权限。"), warning: true, sticky: true)
        case .serverError(let code, _):
            flashKeyMsg(Loc("已保存，但交易所返回错误（HTTP %@）。请稍后在交易页重试。", String(code)), warning: true, sticky: true)
        case .network:
            flashKeyMsg(Loc("已保存，但暂时无法连接 SafeTrade（网络问题）。请检查网络后在交易页确认。"), warning: true, sticky: true)
        }
    }

    /// Show a transient status line under the key fields. Warnings are orange and
    /// linger longer (they're actionable); successes auto-dismiss quickly.
    private func flashKeyMsg(_ msg: String, warning: Bool = false, sticky: Bool = false) {
        withAnimation { keyMsg = msg; keyMsgIsWarning = warning }
        let seconds = sticky ? 10 : 3
        Task { try? await Task.sleep(for: .seconds(seconds)); withAnimation { keyMsg = nil } }
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
        if context.coordinator.observation == nil {
            DispatchQueue.main.async { context.coordinator.attach(from: uiView) }
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.observation?.invalidate()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var onChange: (CGFloat) -> Void = { _ in }
        var observation: NSKeyValueObservation?

        func attach(from view: UIView) {
            guard observation == nil else { return }
            var v: UIView? = view.superview
            while let cur = v {
                if let sv = cur as? UIScrollView {
                    observation = sv.observe(\.contentOffset, options: [.initial, .new]) { [weak self] sv, _ in
                        self?.onChange(sv.contentOffset.y + sv.adjustedContentInset.top)
                    }
                    return
                }
                v = cur.superview
            }
        }
    }
}
#endif

/// Recovers "stranded change": funds the wallet sent to its own change addresses
/// that the xpub balance scan doesn't cover, so they vanish from the in-app balance.
/// Rediscovers them on-chain, proves ownership by trial-signing, and sweeps them
/// back to a destination you choose (your own address by default).
struct RecoverChangeView: View {
    @ObservedObject var store: WalletStore
    @State private var toMyWallet = true
    @State private var customDestination = ""
    @State private var working = false
    @State private var result: String?
    @State private var done = false

    private func amount(_ d: Decimal) -> String { d.formatted(.number.precision(.fractionLength(0...8))) }
    private func short(_ a: String) -> String { a.count > 18 ? "\(a.prefix(11))…\(a.suffix(6))" : a }
    private var destination: String {
        toMyWallet ? (store.address ?? "") : customDestination.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var destValid: Bool { PRLAddress.isValid(destination, network: store.network) }

    var body: some View {
        Form {
            Section {
                Text(Loc("转账产生的“找零”会退回到钱包自动生成的找零地址。这些余额已计入你的总额、也能正常花费；如需把它们归集到一个地址，可在这里一键扫回。"))
                    .font(.callout).foregroundStyle(.secondary)
            }

            if done {
                // Recovery succeeded: `recoverable` is now empty and `recoveryScanned` was
                // reset, which would otherwise flip the view to "没有发现搁浅的找零 🎉" and hide
                // the broadcast txid. Pin the success + txid here instead.
                Section {
                    if let result {
                        Text(result).font(.callout).foregroundStyle(.green).textSelection(.enabled)
                    } else {
                        Label(Loc("找回成功 ✓"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    Text(Loc("交易已广播，待网络确认后即并入「钱包」余额与最近交易。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if store.recoveryScanning {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(Loc("正在扫描搁浅的找零…"))
                    }
                }
            } else if store.recoverable.isEmpty {
                Section {
                    Label(Loc("没有发现搁浅的找零 🎉"), systemImage: "checkmark.seal")
                }
                Section {
                    Button(Loc("重新扫描")) { Task { await store.scanRecoverableChange() } }
                }
            } else {
                Section(Loc("可找回 %@ PRL", amount(store.recoverableTotal))) {
                    ForEach(store.recoverable) { s in
                        HStack {
                            Text(short(s.address)).font(.footnote.monospaced())
                            Spacer()
                            Text(amount(s.valuePRL) + " PRL").foregroundStyle(.secondary)
                        }
                    }
                }

                Section(Loc("找回到")) {
                    Toggle(Loc("我的主地址"), isOn: $toMyWallet)
                    if toMyWallet {
                        if let a = store.address {
                            Text(short(a)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("\(store.network.addressPrefix)…", text: $customDestination)
                            .font(.body.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            #endif
                        if !customDestination.isEmpty && !destValid {
                            Text(Loc("地址格式不正确（需为 %@ 开头的 Taproot 地址）", store.network.addressPrefix))
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    Button {
                        Task {
                            working = true; result = nil
                            let r = await store.recoverChange(to: destination)
                            working = false
                            done = r.ok
                            result = r.ok ? Loc("已找回，交易已广播 ✓\n%@", r.message) : r.message
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if working { ProgressView().controlSize(.small) }
                            Text(working ? Loc("签名并广播…") : Loc("找回 %@ PRL", amount(store.recoverableTotal)))
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(working || done || !destValid)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(Loc("交易在本机签名（私钥不离开设备），合并到一笔扫回，剩余不再搁浅。"))
                }

                if let result {
                    Section {
                        Text(result)
                            .font(.callout)
                            .foregroundStyle(done ? .green : .red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        // Same chrome as the main settings Form — without .grouped, macOS renders
        // a bare left-aligned text stack instead of inset card sections.
        .formStyle(.grouped)
        .pearlListBackground()
        .navigationTitle(Loc("找回搁浅的找零"))
        .task { if !done && !store.recoveryScanned { await store.scanRecoverableChange() } }
    }
}
