import SwiftUI

// MARK: - Dashboard (unlocked)

struct DashboardView: View {
    @ObservedObject var store: WalletStore
    @StateObject private var price = PRLPriceManager.shared
    @EnvironmentObject private var currency: CurrencyManager
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var addingWallet = false
    @State private var managingWallets = false
    @State private var donating = false
    @State private var donationPromptPending = false
    /// False while a pushed screen (收款 / 转账 / 记录) or another tab covers the dashboard.
    @State private var dashboardVisible = false

    // 币价 chip text. macOS text styles run ~4pt smaller than iOS (body is 13pt there),
    // so the Mac gets the next sizes up to read at the same weight beside the balance.
    #if os(macOS)
    private static let chipLabelFont = Font.callout.weight(.bold)
    private static let chipPriceFont = Font.title2.weight(.bold)
    #else
    private static let chipLabelFont = Font.footnote.weight(.bold)
    private static let chipPriceFont = Font.body.weight(.bold)
    #endif

    private var isClassicNight: Bool {
        AppPalette.current == .classic && colorScheme == .dark
    }

    /// A brighter pearl-blue gradient shared by the balance and action badges.
    private var balanceGradient: LinearGradient {
        guard isClassicNight else {
            return Pearl.brandVivid
        }
        return ClassicNightBackground.gradient
    }

    private var chipPriceColor: Color {
        isClassicNight
            ? Color(red: 242 / 255, green: 209 / 255, blue: 134 / 255)
            : Pearl.heroChipPrice
    }

    private var cardSurface: Color? {
        isClassicNight ? Color(red: 43 / 255, green: 45 / 255, blue: 54 / 255) : nil
    }

    private var cardSecondary: Color {
        isClassicNight ? .white.opacity(0.70) : .secondary
    }

    /// Donations go to a mainnet address, so the entry only shows on mainnet — and never
    /// while the open wallet IS the donation wallet (that would just pay itself a fee).
    /// A fresh balance, or last session's while the fresh one loads.
    private var hasBalance: Bool { store.backendReady || store.balanceIsCached }

    private var canDonate: Bool {
        guard Donation.isConfigured, store.network == .mainnet else { return false }
        let mainAddress = store.activeRecord?.addresses[WalletNetwork.mainnet.rawValue]
        return mainAddress != Donation.address && store.address != Donation.address
    }

    /// The one-time donation ask (see `DonationPrompt`). Everything is re-checked right
    /// before presenting, and the ask is only recorded once the sheet is actually going up.
    private var donationPromptReady: Bool {
        canDonate && dashboardVisible && scenePhase == .active && store.backendReady
            && !donating && !addingWallet && !managingWallets
            // Right after the user's own send (pending/unconfirmed tx) is not the moment.
            && !store.hasUnconfirmedTx
            // Asking someone who can't give just spends the single ask.
            && store.balance.available >= Donation.minimum + WalletStore.sendFeeReserve
            && DonationPrompt.isEligible
    }

    private func promptDonationIfDue() {
        guard !donationPromptPending, donationPromptReady else { return }
        donationPromptPending = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))   // let the balance settle in first
            donationPromptPending = false
            guard donationPromptReady else { return }
            DonationPrompt.markShown()
            donating = true
        }
    }

    /// Spot price of 1 PRL in USD, formatted like the mining monitor's "PRL 币价"
    /// card (adaptive precision for a sub-dollar coin) so the number matches
    /// app-wide. nil until the first price load (cached on disk, so usually
    /// present immediately on launch).
    private var unitPriceText: String? {
        guard let usd = price.usd, usd > 0, usd.isFinite else { return nil }
        return "$" + usd.formatted(.number.precision(.fractionLength(2)).locale(LocBundleHolder.shared.locale))
    }

    /// Split the balance for display: a big grouped "1,234.56" head (integer + the
    /// first 2 decimals, TRUNCATED not rounded so the tail stays exact) and the
    /// remaining fraction digits (3rd–8th, trailing zeros trimmed) to render tiny.
    /// PRL has 8 decimals.
    private static let sliceFormatter: NumberFormatter = {
        let slice = NumberFormatter()
        slice.locale = Locale(identifier: "en_US_POSIX")
        slice.numberStyle = .decimal
        slice.usesGroupingSeparator = false
        slice.minimumFractionDigits = 8
        slice.maximumFractionDigits = 8
        slice.roundingMode = .down                 // truncate toward zero (balances ≥ 0)
        return slice
    }()
    private static let groupFormatter: NumberFormatter = {
        let grp = NumberFormatter()
        grp.locale = .autoupdatingCurrent
        grp.numberStyle = .decimal
        grp.usesGroupingSeparator = true
        grp.maximumFractionDigits = 0
        return grp
    }()

    private func balanceParts(_ v: Decimal) -> (head: String, tail: String) {
        let full = Self.sliceFormatter.string(from: NSDecimalNumber(decimal: v)) ?? "0.00000000"
        let comps = full.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let intRaw = comps.first ?? "0"
        let frac = comps.count > 1 ? comps[1] : "00000000"
        let head2 = String(frac.prefix(2))
        var tail = String(frac.dropFirst(2))
        while tail.hasSuffix("0") { tail.removeLast() }
        // Group the integer with the user's locale, then the locale's decimal mark.
        let intGrouped = Self.groupFormatter.string(from: NSDecimalNumber(string: intRaw)) ?? intRaw
        let dec = Locale.current.decimalSeparator ?? "."
        return (intGrouped + dec + head2, tail)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Pearl.Space.lg) {
                // Balance card → brand hero banner (compact)
                // Every row keeps a FIXED slot (placeholder until its data loads) so
                // the hero never changes height — the layout settles first, then the
                // real balance / fiat / address fade in without shoving anything.
                PearlHero(gradient: balanceGradient, minHeight: 0, padding: Pearl.Space.md,
                          showSparkle: false, backdrop: isClassicNight ? AnyView(ClassicNightBackground()) : nil) {
                    VStack(spacing: Pearl.Space.xs) {
                        // Top row: the 币价 chip on the right (the wallet name lives in the
                        // toolbar switcher). The chip always holds its slot — "—" until the first
                        // price loads — so the hero never changes height.
                        HStack(spacing: Pearl.Space.sm) {
                            Spacer(minLength: Pearl.Space.xs)
                            HStack(spacing: 6) {
                                Text(verbatim: "PRL").font(Self.chipLabelFont)
                                    .foregroundStyle(Pearl.onHeroChip.opacity(0.75))
                                Text(unitPriceText ?? "—").font(Self.chipPriceFont).monospacedDigit()
                                    .foregroundStyle(unitPriceText == nil ? Pearl.onHeroChip.opacity(0.55) : chipPriceColor)
                                    .contentTransition(.numericText())
                            }
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Pearl.heroChip, in: Capsule())
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(Loc("PRL 币价 %@", unitPriceText ?? "—"))
                            .animation(.snappy, value: unitPriceText)
                        }

                        // Balance — always-present slot; dimmed dashes until the chain syncs,
                        // or last session's figure (slightly dimmed) until the fresh one lands.
                        // Big grouped "1,234.56" head (2 dp), the remaining fraction digits
                        // tiny & trailing, then the PRL unit.
                        Group {
                            if hasBalance {
                                let p = balanceParts(store.balance.total)
                                (
                                    Text(p.head)
                                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                                    + Text(p.tail)
                                        .font(.system(.footnote, design: .rounded).weight(.bold))
                                        .foregroundStyle(Pearl.onHero.opacity(0.6))
                                    + Text(verbatim: " PRL")
                                        .font(.system(.callout, design: .rounded).weight(.semibold))
                                        .foregroundStyle(Pearl.onHero.opacity(0.85))
                                )
                                .foregroundStyle(Pearl.onHero)
                                .opacity(store.balanceIsCached ? 0.7 : 1)
                                .contentTransition(.numericText())
                            } else {
                                Text(verbatim: "—— PRL")
                                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                                    .foregroundStyle(Pearl.onHero.opacity(0.45))
                            }
                        }
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .accessibilityLabel(hasBalance ? Loc("余额 %@ PRL", store.balance.total.formatted(.number.locale(LocBundleHolder.shared.locale))) : Loc("同步余额…"))
                        // Tuck the balance up under the chip row: with only a right-aligned chip
                        // above it, the full row gap made the number read as sitting low.
                        .padding(.top, -6)

                        // Fiat — slot reserved; shows the sync hint until balance+price are in.
                        Group {
                            if hasBalance, let usd = price.value(of: store.balance.total) {
                                Text(verbatim: "≈ " + currency.dual(usd))
                                    .foregroundStyle(Pearl.onHero.opacity(store.balanceIsCached ? 0.6 : 0.85))
                                    .contentTransition(.numericText())
                                    .accessibilityLabel(Loc("约合 %@", currency.dual(usd)))
                            } else {
                                Text(Loc("同步余额…")).foregroundStyle(Pearl.onHero.opacity(0.7))
                            }
                        }
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity)
                    .animation(.snappy, value: store.backendReady)
                    .animation(.snappy, value: store.balanceIsCached)
                }

                // Backend unreachable: the figures above are the last good snapshot — say so
                // rather than let them pass for live.
                if let problem = store.syncError {
                    Label(store.lastSyncedAt.map { Loc("%@，显示的是 %@ 的数据", problem, $0.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(LocBundleHolder.shared.locale))) }
                          ?? Loc("%@，稍后自动重试", problem),
                          systemImage: "exclamationmark.icloud")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }

                // Actions
                HStack(spacing: Pearl.Space.md) {
                    action(Loc("收款"), "qrcode") { ReceiveView(store: store) }
                    action(Loc("转账"), "paperplane") { SendView(store: store) }
                    action(Loc("记录"), "clock.arrow.circlepath") { ActivityView(store: store) }
                }

                // 最近交易：金额为 0 的交易不显示。卡片始终保留 3 个等高行槽——同步时为骨架
                // 占位，加载后填入真实交易、空槽留白——所以高度恒定（居中布局不跳动），且
                // 满 3 笔时没有多余空白。
                let recent = Array(store.txs.filter { $0.amount > 0 }.sorted { $0.time > $1.time }.prefix(3))
                let rowH: CGFloat = 24
                VStack(alignment: .leading, spacing: Pearl.Space.xs) {
                    HStack {
                        Text(Loc("最近交易")).font(.caption.weight(.semibold)).foregroundStyle(cardSecondary)
                        Spacer()
                        if store.historyReady && !recent.isEmpty {
                            NavigationLink { ActivityView(store: store) } label: {
                                Text(Loc("全部")).font(.caption2).foregroundStyle(Pearl.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    VStack(alignment: .leading, spacing: Pearl.Space.xxs) {
                        if !store.historyReady {
                            // 历史还没拉回来：3 行骨架占位（不要先显示"暂无交易记录"）。
                            ForEach(0..<3, id: \.self) { _ in txSkeletonRow().frame(height: rowH) }
                        } else if recent.isEmpty {
                            Text(Loc("暂无交易记录")).font(.caption).foregroundStyle(cardSecondary)
                                .frame(maxWidth: .infinity, minHeight: rowH * 3 + Pearl.Space.xxs * 2, alignment: .center)
                        } else {
                            // 始终 3 个等高槽：有交易填真实行，没有的留等高空槽（高度恒定）。
                            ForEach(0..<3, id: \.self) { i in
                                if i < recent.count {
                                    NavigationLink { TxDetailView(store: store, txid: recent[i].txid) } label: {
                                        txRow(recent[i]).frame(height: rowH).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                else { Color.clear.frame(height: rowH) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md, frosted: true, surface: cardSurface)
                .animation(.snappy, value: store.backendReady)

                PriceAlertInlineLink()
                WidgetInlineLink()
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .animation(.snappy, value: store.syncError)
            // Top-aligned on iOS: keep the content its NATURAL height so the refreshable
            // ScrollView has a real scroll range and pull-to-refresh snaps back. Forcing
            // height == viewport (geo.size.height OR containerRelativeFrame) leaves no
            // scroll range, so the pull stuck at the pulled-down position. macOS keeps the
            // centered look — it has no touch pull-to-refresh to fight, and tall windows
            // look better centered.
            #if os(macOS)
            .containerRelativeFrame(.vertical, alignment: .center)
            #endif
        }
        .background {
            if isClassicNight {
                Color(red: 17 / 255, green: 18 / 255, blue: 22 / 255).ignoresSafeArea()
            }
        }
        .navigationTitle(Loc("钱包"))
        .toolbar {
            // Both items opt out of the system's glass capsule (user preference).
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                WalletSwitcherMenu(store: store, addingWallet: $addingWallet, managingWallets: $managingWallets)
            }
            .noGlassBackground()
            #else
            ToolbarItem(placement: .navigation) {
                WalletSwitcherMenu(store: store, addingWallet: $addingWallet, managingWallets: $managingWallets)
            }
            .noGlassBackground()
            #endif
            if canDonate {
                ToolbarItem(placement: .primaryAction) {
                    Button { donating = true } label: {
                        Image(systemName: "heart.fill").foregroundStyle(Pearl.rose)
                    }
                    .accessibilityLabel(Loc("支持开发者"))
                }
                .noGlassBackground()
            }
        }
        .sheet(isPresented: $addingWallet) { AddWalletView(store: store) }
        .sheet(isPresented: $donating) { DonateView(store: store) }
        .onChange(of: store.backendReady) { _, _ in promptDonationIfDue() }
        .onChange(of: store.balance) { _, _ in promptDonationIfDue() }
        .onAppear { dashboardVisible = true; promptDonationIfDue() }
        .onDisappear { dashboardVisible = false }
        .navigationDestination(isPresented: $managingWallets) { ManageWalletsView(store: store) }
        .task { await store.refreshIfStale(); await price.refreshIfStale() }
        .refreshable { await store.loadChain(); await price.refresh() }
        // 自适应自动轮询：App 在前台时按 store.pollInterval 周期重拉链上数据——有未确认
        // 交易时快轮询（~15s，让「待确认」尽快翻成已确认），全部确认后退回 60s keep-warm。
        // scenePhase 作 task id：切后台即取消（省电/省流量），回前台自动重启。loadChain
        // 已单飞+幂等，与下拉刷新/发送后对账并发也安全。
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Refresh immediately on (re)activation: returning from the background should
            // update the wallet right away, not only after the first poll interval. (Joins
            // the appear-load above instead of running a second one.)
            await store.refreshIfStale()
            await price.refreshIfStale()
            while !Task.isCancelled {
                try? await Task.sleep(for: store.pollInterval)
                if Task.isCancelled { break }
                await store.loadChain()
            }
        }
        // Transient success toast (e.g. after a send returns here from 转账).
        .overlay(alignment: .top) {
            if let toast = store.toast {
                Label(toast, systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, Pearl.Space.md).padding(.vertical, Pearl.Space.sm)
                    .background(.green.gradient, in: Capsule())
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                    .padding(.top, Pearl.Space.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: store.toast)
    }

    /// One placeholder transaction row (固定占位) shown while the chain syncs — same
    /// layout as a real row (icon · amount · time) so the 最近交易 area looks
    /// identical before and after data loads in.
    private func txSkeletonRow() -> some View {
        HStack(spacing: Pearl.Space.sm) {
            Circle().fill(Color.secondary.opacity(0.12)).frame(width: 18, height: 18)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.12)).frame(width: 112, height: 11)
            Spacer(minLength: Pearl.Space.xs)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.secondary.opacity(0.12)).frame(width: 40, height: 10)
        }
    }

    /// One recent-transaction row: direction glyph · signed amount · optional
    /// confirmation badge · relative time. The host fixes the row height so the
    /// card stays compact and the slots line up.
    @ViewBuilder private func txRow(_ tx: WalletTx) -> some View {
        let received = tx.direction == .received
        HStack(spacing: Pearl.Space.sm) {
            Image(systemName: received ? "arrow.down" : "arrow.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(received ? .green : .orange)
                .frame(width: 16, height: 16)
                .background((received ? Color.green : Color.orange).opacity(0.14), in: Circle())
            Text((received ? "+" : "-") + tx.amount.formatted(.number.precision(.fractionLength(0...8)).locale(LocBundleHolder.shared.locale)) + " PRL")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(received ? .green : .primary).lineLimit(1).minimumScaleFactor(0.6)
            // 未满 100 确认时显示确认数（满 100 视为稳定，不再显示）
            if tx.confirmations < 100 {
                Text(tx.confirmations == 0 ? Loc("待确认") : Loc("%@ 确认", "\(tx.confirmations)"))
                    .font(.caption2)
                    .foregroundStyle(tx.confirmations == 0 ? .orange : .secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background((tx.confirmations == 0 ? Color.orange : Color.secondary).opacity(0.12), in: Capsule())
            }
            Spacer(minLength: Pearl.Space.xs)
            Text(RelTime(tx.time)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func action<Dest: View>(_ title: String, _ icon: String, @ViewBuilder dest: () -> Dest) -> some View {
        NavigationLink(destination: dest()) {
            VStack(spacing: Pearl.Space.sm) {
                PearlIconBadge(systemImage: icon, gradient: isClassicNight ? balanceGradient : nil)
                // One line, shrunk to fit: "Empfangen" is a few points wider than a third of
                // a phone, and wrapped as "Empfan-gen" in a tile taller than its neighbours.
                Text(title).font(.callout.weight(.medium))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md, frosted: true, surface: cardSurface)
        }
        .buttonStyle(.plain)
    }

}

// MARK: - Receive

struct ReceiveView: View {
    @ObservedObject var store: WalletStore
    @State private var copied = false
    var body: some View {
        ScrollView {
            VStack(spacing: Pearl.Space.lg) {
                if let addr = store.address {
                    if let qr = QRCode.cgImage(from: addr) {
                        Image(decorative: qr, scale: 1)
                            .interpolation(.none).resizable().scaledToFit()
                            .frame(width: 220, height: 220)
                            .padding(Pearl.Space.md).background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Pearl.Radius.md, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Pearl.Radius.md, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.06), radius: 6, x: 0, y: 2)
                            .id(addr)
                            .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                    PearlSectionHeader(store.receiveIndex == 0
                                       ? Loc("收款地址 · %@", store.network.label)
                                       : Loc("收款地址 · %@ · 第 %@ 个", store.network.label, "\(store.receiveIndex + 1)"),
                                       systemImage: "qrcode")
                    Text(addr).font(.callout.monospaced()).multilineTextAlignment(.center).textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.sm)
                        .id(addr)
                        .transition(.opacity)
                    Button {
                        copyToPasteboard(addr)
                        withAnimation { copied = true }
                        Task { try? await Task.sleep(for: .seconds(2)); withAnimation { copied = false } }
                    } label: {
                        Label(copied ? Loc("已复制") : Loc("复制地址"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.pearl)
                    .accessibilityLabel(Loc("复制收款地址"))

                    // 换地址：点按派生下一个收款地址（0…9 轮换），每个都可正常收款，换地址更利于隐私。
                    HStack(spacing: Pearl.Space.lg) {
                        Button {
                            copied = false
                            store.nextReceiveAddress()
                        } label: {
                            Label(Loc("换一个地址"), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .accessibilityLabel(Loc("换一个收款地址"))
                        if store.receiveIndex > 0 {
                            Button {
                                copied = false
                                Task { await store.setReceiveIndex(0) }
                            } label: {
                                Label(Loc("回到主地址"), systemImage: "house")
                            }
                        }
                    }
                    .font(.callout.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(Pearl.accent)

                    Text(Loc("把这个地址发给对方即可收到 PRL。点按「换一个地址」可生成新地址，更好地保护隐私。"))
                        .pearlExplanation().multilineTextAlignment(.center)
                } else {
                    ProgressView(Loc("派生地址…")).frame(maxHeight: 240)
                }
            }
            .padding(Pearl.Space.screen).frame(maxWidth: 460).frame(maxWidth: .infinity)
            .animation(.snappy, value: store.address)
        }
        .pearlScreenBackground()
        .navigationTitle(Loc("收款"))
        .task { await store.refreshIfStale() }
    }
}

// MARK: - Send

struct SendView: View {
    @ObservedObject var store: WalletStore
    @EnvironmentObject private var contacts: ContactsStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var amount = ""
    @State private var preparing = false
    @State private var sending = false
    /// The signed tx awaiting the final confirmation (shows the real fee); nil = no alert.
    @State private var prepared: PreparedSend?
    @State private var result: String?          // error banner (cleared by field onChange)
    /// The banner reports a send of unknown outcome, not a failure.
    @State private var resultIsWarning = false
    @State private var savingContact = false
    /// The exact string the MAX button last filled in. A send is treated as a full
    /// sweep ONLY when `amount` still equals this — i.e. the user explicitly chose MAX
    /// and hasn't edited it — never inferred from the (racy) live balance.
    @State private var maxString: String?
    /// Wallet + network the MAX was computed for; a switch voids it (see onChange below).
    @State private var maxSession: String?
    /// The input total the MAX quote came from — handed to `prepareSend` as the sweep intent.
    @State private var maxTotalSat: Int64?
    /// MAX is fetching the UTXOs and fee rate it needs.
    @State private var quotingMax = false
    private var session: String { "\(store.activeWalletID ?? "")|\(store.network.rawValue)" }

    /// `prefillAddress`: 交易 → 充值 PRL opens this with the SafeTrade deposit address
    /// filled in; the amount, fee and device check stay the user's as usual.
    init(store: WalletStore, prefillAddress: String? = nil) {
        self.store = store
        _address = State(initialValue: prefillAddress ?? "")
    }

    // Reserved for the network fee; any unused part returns as change (nothing is lost).
    private let feeReserve = WalletStore.sendFeeReserve
    private var feeReserveText: String { NSDecimalNumber(decimal: feeReserve).stringValue }
    private var amountText: String { amount.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedAmount: Decimal? { PRLAmount.parse(amountText) }
    private var amountDec: Decimal { parsedAmount ?? 0 }
    private var addr: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var amountPrecisionOK: Bool { parsedAmount != nil }
    /// The user tapped MAX, didn't edit it, and is still on the wallet/network it was tapped for.
    private var isMaxArmed: Bool { maxString != nil && amount == maxString && maxSession == session && maxTotalSat != nil }
    /// A MAX amount already has the real fee taken off, so the fixed reserve doesn't apply.
    private var overBalance: Bool { !isMaxArmed && amountDec > 0 && amountDec + feeReserve > store.balance.available }
    private var addressValid: Bool { PRLAddress.isValid(addr, network: store.network) }
    private var canSend: Bool { !preparing && !sending && amountDec > 0 && amountPrecisionOK && !overBalance && addressValid }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                Text(Loc("可用余额 %@ PRL", store.balance.available.formatted(.number.precision(.fractionLength(0...8)).locale(LocBundleHolder.shared.locale))))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.sm)

                // Recipient block
                VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                    HStack {
                        Text(Loc("收款地址")).font(.headline)
                        Spacer()
                        // Always available — even with no saved contacts you can add a
                        // new address right here (opens the contact editor).
                        Menu {
                            ForEach(contacts.contacts) { c in
                                Button { address = c.address; result = nil } label: {
                                    Text("\(c.name) · \(shortAddr(c.address))")
                                }
                            }
                            if !contacts.contacts.isEmpty { Divider() }
                            Button { savingContact = true } label: {
                                Label(Loc("添加新地址"), systemImage: "person.badge.plus")
                            }
                        } label: { Label(Loc("地址簿"), systemImage: "person.crop.circle") }
                        .font(.callout)
                    }
                    TextField("\(store.network.addressPrefix)…", text: $address)
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                        .onChange(of: address) { _, _ in result = nil }
                    if !addr.isEmpty && !addressValid {
                        Text(Loc("地址格式不正确（需为 %@ 开头的 Taproot 地址）", store.network.addressPrefix)).font(.caption).foregroundStyle(.red)
                    } else if let name = contacts.name(for: addr) {
                        Label(Loc("联系人：%@", name), systemImage: "person.crop.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    } else if addressValid {
                        Button { savingContact = true } label: {
                            Label(Loc("保存到地址簿"), systemImage: "person.badge.plus")
                        }.font(.caption).buttonStyle(.borderless)
                    }
                }
                .pearlCard()

                // Amount block
                VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                    HStack {
                        Text(Loc("金额 (PRL)")).font(.headline)
                        Spacer()
                        Button { quoteMax() } label: {
                            if quotingMax { ProgressView().controlSize(.mini) } else { Text("MAX") }
                        }
                        .font(.caption)
                        .disabled(quotingMax || preparing || sending)
                    }
                    TextField("0.0", text: $amount).textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .onChange(of: amount) { _, _ in result = nil }
                    if overBalance {
                        Text(Loc("超过可用余额（需预留至少 %@ PRL 手续费）", feeReserveText)).font(.caption).foregroundStyle(.red)
                    } else if !amountText.isEmpty && !amountPrecisionOK {
                        Text(Loc("金额最多支持 %@ 位小数", "\(BlockbookClient.decimals)")).font(.caption).foregroundStyle(.red)
                    }
                }
                .pearlCard()

                Button { prepare() } label: {
                    HStack(spacing: Pearl.Space.xs) {
                        if preparing || sending { ProgressView().controlSize(.small).tint(Pearl.onAccent) }
                        Text(sending ? Loc("签名并广播…") : preparing ? Loc("正在构建交易…") : Loc("发送"))
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.pearl)
                .disabled(!canSend)

                if let result {
                    Label(result, systemImage: resultIsWarning ? "exclamationmark.triangle" : "xmark.octagon")
                        .font(.callout).foregroundStyle(resultIsWarning ? .orange : .red).textSelection(.enabled)
                }
                PearlInfoRow(Loc("交易在本机签名（私钥不离开设备），经 Blockbook 广播。"), systemImage: "lock.shield")
            }
            .padding(Pearl.Space.screen).frame(maxWidth: 520).frame(maxWidth: .infinity)
            .animation(.snappy, value: sending)
            .animation(.snappy, value: result)
        }
        .pearlScreenBackground()
        .navigationTitle(Loc("转账"))
        // The tx is built and signed first, so the receipt shows what it really costs; an
        // unusually high fee gets its own warning. Dismissing it (取消 / swipe) clears `prepared`.
        .sheet(item: $prepared) { p in
            SendConfirmSheet(send: p, contactName: contacts.name(for: p.recipient),
                             network: store.network) { broadcast(p) }
        }
        .sheet(isPresented: $savingContact) { ContactEditor(draft: ContactDraft(prefillAddress: addr)) }
        // Working out the fee rate takes a few requests; start them now (cached ~2 min) so
        // MAX and 发送 don't wait on them.
        .task(id: store.network) { _ = await BlockbookClient(network: store.network).pinned(to: store.chainReadBase, strict: false).estimateFeePerKB() }
        // This screen can stay pushed while the wallet or network is switched from Settings:
        // an amount (and above all a MAX) computed for the old one must not carry over.
        .onChange(of: session) { _, _ in
            amount = ""; maxString = nil; maxSession = nil; maxTotalSat = nil; result = nil; prepared = nil
        }
    }

    /// Fill in everything spendable minus the real fee for sending it all, and arm the
    /// explicit sweep intent.
    private func quoteMax() {
        let tappedFor = session
        quotingMax = true; result = nil
        Task {
            defer { quotingMax = false }
            do {
                let q = try await store.maxSendQuote()
                guard session == tappedFor else { return }   // switched wallet/network meanwhile
                let s = NSDecimalNumber(decimal: q.amount).stringValue
                amount = s; maxString = s; maxSession = tappedFor; maxTotalSat = q.totalSat
            } catch {
                resultIsWarning = false
                result = error.localizedDescription
            }
        }
    }

    /// Build + sign on-device (no broadcast yet), then confirm with the real fee.
    private func prepare() {
        guard let amt = parsedAmount else { return }
        let sweepTotal = isMaxArmed ? maxTotalSat : nil
        preparing = true; result = nil
        Task {
            do {
                prepared = try await store.prepareSend(to: addr, amountPRL: amt, sweepTotalSat: sweepTotal)
            } catch {
                resultIsWarning = false
                result = error.localizedDescription
            }
            preparing = false
        }
    }

    private func broadcast(_ p: PreparedSend) {
        guard !sending else { return }   // one send at a time, however the confirm got tapped
        prepared = nil
        sending = true; result = nil
        Task {
            let outcome = await store.broadcast(p)
            sending = false
            switch outcome {
            case .sent:
                // Success → toast + return to the home dashboard, then refresh the
                // on-chain balance so the home shows the new total.
                amount = ""; address = ""
                store.flashToast(Loc("已发送 ✓"))
                dismiss()
                await store.loadChain()
            case .failed(let m):
                resultIsWarning = false
                result = m
            case .unverified(let m):
                // Possibly sent: keep the form (nothing to redo yet) and say why not to resend.
                resultIsWarning = true
                result = m
            }
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @ObservedObject var store: WalletStore
    @State private var opened: WalletTx?
    @State private var lookingUp = false
    var body: some View {
        Group {
            if !store.historyReady && store.txs.isEmpty {
                VStack(spacing: Pearl.Space.md) {
                    ProgressView()
                    Text(Loc("同步中…")).font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.txs.isEmpty {
                PearlEmptyState(systemImage: "clock.arrow.circlepath",
                                title: Loc("暂无交易记录"),
                                message: Loc("你的收发记录会显示在这里"))
            } else {
                // Capped-width list so it doesn't stretch across a wide Mac window.
                // One card with hairline-separated rows, not a stack of small cards.
                ScrollView {
                    VStack(spacing: Pearl.Space.md) {
                        LazyVStack(spacing: 0) {
                            ForEach(store.txs) { tx in
                                ActivityRow(tx: tx) { opened = tx }
                                    .padding(.vertical, Pearl.Space.xs)
                                if tx.id != store.txs.last?.id {
                                    Divider().padding(.leading, 36 + Pearl.Space.sm)
                                }
                            }
                        }
                        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
                        // History arrives a page (25 txs) at a time; older pages on request.
                        if store.historyHasMore {
                            Button { Task { await store.loadMoreHistory() } } label: {
                                HStack(spacing: Pearl.Space.xs) {
                                    if store.loadingMoreHistory { ProgressView().controlSize(.small) }
                                    Text(Loc("加载更多"))
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.callout.weight(.medium))
                            .disabled(store.loadingMoreHistory)
                        }
                    }
                    .padding(Pearl.Space.screen)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(Loc("交易记录"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { lookingUp = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel(Loc("交易查询"))
                    .help(Loc("交易查询"))
            }
            .noGlassBackground()
        }
        .navigationDestination(item: $opened) { TxDetailView(store: store, txid: $0.txid) }
        .navigationDestination(isPresented: $lookingUp) { TxLookupView(store: store) }
        .task { await store.refreshIfStale() }
        .refreshable { await store.loadChain() }
    }
}

private struct ActivityRow: View {
    let tx: WalletTx
    /// Opens 交易详情 (a tap anywhere but the copy buttons).
    let onOpen: () -> Void
    @EnvironmentObject private var contacts: ContactsStore
    @State private var copiedTxid = false
    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.xs) {
            HStack(alignment: .top, spacing: Pearl.Space.sm) {
                ZStack {
                    Circle()
                        .fill((tx.direction == .received ? Color.green : Color.orange).opacity(0.16))
                        .frame(width: 36, height: 36)
                    Image(systemName: tx.direction == .received ? "arrow.down" : "arrow.up")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(tx.direction == .received ? .green : .orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tx.direction == .received ? Loc("收到") : Loc("发出")).font(.body)
                    // 紧凑单行日期（去掉年份，省出宽度，避免与右侧金额互挤换行）。
                    Text(tx.time.formatted(.dateTime.month().day().hour().minute().locale(LocBundleHolder.shared.locale)))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Pearl.Space.sm)
                VStack(alignment: .trailing, spacing: 2) {
                    // 数字与单位拆开：单位 PRL 弱化为小灰字，整体单行、必要时等比缩小而不换行。
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text((tx.direction == .received ? "+" : "-")
                             + tx.amount.formatted(.number.precision(.fractionLength(0...8)).locale(LocBundleHolder.shared.locale)))
                            .font(.callout.monospacedDigit().bold())
                            .foregroundStyle(tx.direction == .received ? .green : .primary)
                        Text(verbatim: "PRL").font(.caption2).foregroundStyle(.secondary)
                    }
                    .lineLimit(1).minimumScaleFactor(0.6)
                    if tx.confirmations < 100 {
                        Text(tx.confirmations == 0 ? Loc("待确认") : Loc("%@ 确认", "\(tx.confirmations)"))
                            .font(.caption2).foregroundStyle(tx.confirmations == 0 ? .orange : .secondary)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            if !tx.address.isEmpty {
                HStack(spacing: Pearl.Space.xs) {
                    Text(tx.direction == .received ? Loc("收款地址") : Loc("发送至")).font(.caption2).foregroundStyle(.secondary)
                    if let name = contacts.name(for: tx.address) {
                        Text(name).font(.caption2.bold()).foregroundStyle(.primary).lineLimit(1)
                    }
                    Text(tx.address).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityLabel(tx.direction == .received ? Loc("收款地址 %@", tx.address) : Loc("发送至 %@", tx.address))
                    Button { copyToPasteboard(tx.address) } label: {
                        Image(systemName: "doc.on.doc").font(.caption2)
                    }
                    .buttonStyle(.borderless).padding(4).contentShape(Rectangle())
                    .accessibilityLabel(Loc("复制地址"))
                }
            }
            HStack(spacing: Pearl.Space.xs) {
                Text(Loc("交易 ID")).font(.caption2).foregroundStyle(.secondary)
                Text(verbatim: tx.txid).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityLabel(Loc("交易 ID") + " " + tx.txid)
                Button {
                    copyToPasteboard(tx.txid)
                    copiedTxid = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copiedTxid = false }
                } label: {
                    Image(systemName: copiedTxid ? "checkmark" : "doc.on.doc").font(.caption2)
                }
                .buttonStyle(.borderless).padding(4).contentShape(Rectangle())
                .accessibilityLabel(copiedTxid ? Loc("已复制") : Loc("复制交易 ID"))
            }
        }
        .padding(.vertical, Pearl.Space.xxs)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button(action: onOpen) { Label(Loc("交易详情"), systemImage: "info.circle") }
            Button { copyToPasteboard(tx.txid) } label: { Label(Loc("复制交易 ID"), systemImage: "doc.on.doc") }
            if !tx.address.isEmpty {
                Button { copyToPasteboard(tx.address) } label: { Label(Loc("复制地址"), systemImage: "doc.on.doc") }
            }
        }
        .accessibilityAction(named: Loc("交易详情"), onOpen)
    }
}

// MARK: - Reveal seed

struct RevealSeedView: View {
    @ObservedObject var store: WalletStore
    @State private var revealed = false
    @State private var authing = false
    @State private var screenshotWarning = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: Pearl.Space.lg) {
            if revealed, let m = store.mnemonic {
                let words = m.split(separator: " ").map(String.init)
                #if os(iOS)
                // Host the seed in a secure-text-entry canvas → iOS blanks it in
                // screenshots & screen recordings (a real block, not a post-hoc hide).
                CaptureProtected { SeedGrid(words: words) }
                    .fixedSize(horizontal: false, vertical: true)
                #else
                SeedGrid(words: words)   // macOS: the window is hard-excluded from capture
                #endif
                Label(Loc("切勿截图、拍照或发给任何人。"), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                Button { withAnimation { revealed = false } } label: {
                    Label(Loc("隐藏"), systemImage: "eye.slash")
                }.font(.callout)
            } else {
                ZStack {
                    GlowOrb(color: Pearl.indigo.opacity(0.18), diameter: 140)
                    Image(systemName: "eye.slash")
                        .font(.system(size: 54))
                        .foregroundStyle(Pearl.brand)
                }
                if screenshotWarning {
                    Label(Loc("检测到截图，已立即隐藏助记词。请勿截图保存，改为离线手抄。"),
                          systemImage: "exclamationmark.octagon.fill")
                        .font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Text(Loc("助记词是你资产的唯一凭证")).font(.headline)
                Text(Loc("需通过 Face ID / Touch ID 验证后才会显示")).pearlExplanation()
                Button {
                    authing = true
                    Task { let ok = await store.authenticate(reason: Loc("查看助记词")); authing = false; if ok { withAnimation { revealed = true } } }
                } label: {
                    Label(authing ? Loc("验证中…") : Loc("验证并显示"), systemImage: "faceid")
                }
                .buttonStyle(.pearl).frame(maxWidth: 320).disabled(authing)
            }
        }
        .padding(Pearl.Space.screen).navigationTitle(Loc("助记词"))
        .animation(.snappy, value: revealed)
        .animation(.snappy, value: screenshotWarning)
        // Hard-block capture on macOS; redact while recording + re-hide on
        // screenshot on iOS — only while the seed is actually revealed.
        .screenCaptureProtected(active: revealed) {
            withAnimation { revealed = false; screenshotWarning = true }
        }
        .onChange(of: scenePhase) { _, p in if p != .active { revealed = false } }   // re-hide when backgrounded
        .onDisappear { revealed = false }
    }
}
