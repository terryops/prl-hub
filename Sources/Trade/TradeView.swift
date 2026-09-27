import SwiftUI
import Combine

struct TradeView: View {
    @StateObject private var store = SafeTradeStore()
    @ObservedObject private var upsell = UpsellPrompt.shared
    @EnvironmentObject private var contacts: ContactsStore
    @State private var openAlerts = false      // after buying Pro from the upsell, land on 价格提醒
    @Environment(\.horizontalSizeClass) private var hsc
    @Environment(\.scenePhase) private var scenePhase

    @State private var orderToCancel: STOrder?
    @State private var withdrawing: WithdrawCurrency? = TradeView.shotWithdraw
    @State private var sideColumnWidth: CGFloat = 20   // measured width of the 买/卖 column

    /// Which balance the withdraw sheet is for (`.sheet(item:)` needs Identifiable).
    struct WithdrawCurrency: Identifiable { let id: String }

    /// DEBUG-only: SHOT_WITHDRAW=prl|usdt opens that withdraw sheet on launch (with
    /// SHOT_TAB=1) so a verification run can reach it without API keys.
    private static var shotWithdraw: WithdrawCurrency? {
        #if DEBUG
        if let c = ProcessInfo.processInfo.environment["SHOT_WITHDRAW"], ["prl", "usdt"].contains(c) {
            return WithdrawCurrency(id: c)
        }
        #endif
        return nil
    }

    /// 现价 poll interval: every 5 s in front; every 30 s while visible but not
    /// frontmost (a Mac window behind another app); not at all in the background.
    private static func pollSeconds(_ phase: ScenePhase) -> Int? {
        switch phase {
        case .active: return 5
        case .inactive: return 30
        default: return nil
        }
    }

    private var usdt: STBalance? { store.balance("usdt") }
    private var prl: STBalance? { store.balance("prl") }
    private var wide: Bool { hsc != .compact }

    /// A refresh the user asked for (pull-to-refresh or the toolbar button). Only these
    /// count toward the Pro upsell — automatic loads and iCloud-sync refreshes must not
    /// (see UpsellPrompt).
    private func manualRefresh() async {
        await store.refresh()
        upsell.tradeRefreshed()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(Pearl.Space.screen)
                    .frame(maxWidth: wide ? 1100 : 560)
                    .frame(maxWidth: .infinity)
                    // Natural height, top-aligned. The trade screen's content (market +
                    // order form + chart + open orders) is usually TALLER than the viewport,
                    // so it must NOT be clamped to viewport height: containerRelativeFrame /
                    // minHeight: geo.size.height force an exact height that compresses tall
                    // content and wrecks the layout (and also breaks pull-to-refresh).
            }
            // 下拉滚动即可收起数字键盘（decimalPad 没有回车键）。
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #endif
            .navigationTitle(Loc("交易 · SafeTrade"))
            .navigationDestination(isPresented: $openAlerts) { PriceAlertsView() }
            .sheet(item: $withdrawing) { WithdrawView(trade: store, currency: $0.id).environmentObject(contacts) }
            .sheet(isPresented: $upsell.showing, onDismiss: {
                if ProStore.shared.isPro { openAlerts = true }
            }) { ProUpsellSheet() }
            .toolbar {
                ToolbarItem {
                    Button { Task { await manualRefresh() } } label: {
                        if store.refreshing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(store.refreshing)
                }
                .noGlassBackground()
            }
            .refreshable { await manualRefresh() }
            // The chart period may have synced in. (API keys sync through the iCloud
            // Keychain, which posts nothing here — refresh() re-reads them instead.)
            .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidUpdate)) { _ in
                store.adoptSyncedPeriod()
            }
            // The blocking overlay: an order in flight, or a first load with nothing
            // on screen yet. Later refreshes run quietly (toolbar spinner).
            .processingOverlay(store.placing || (store.refreshing && store.balances.isEmpty && store.ticker == nil))
            // Catch up once on appearing / returning to the foreground, then keep 现价
            // fresh — only while the scene is visible.
            .task(id: scenePhase) {
                guard let seconds = Self.pollSeconds(scenePhase) else { return }
                await store.refreshIfStale()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(seconds))
                    if Task.isCancelled { break }
                    await store.refreshTickerOnly()
                }
            }
            // One-time, order-triggered Pro offer: a limit order fills around the moment
            // PRL touches its price, which is exactly what a price alert reports.
            .alert(Loc("成交时通知你？"),
                   isPresented: Binding(get: { upsell.orderPrompt != nil },
                                        set: { if !$0 { upsell.orderPrompt = nil } }),
                   presenting: upsell.orderPrompt) { _ in
                Button(Loc("解锁高级版")) { upsell.openFromOrderPrompt() }
                Button(Loc("暂不"), role: .cancel) { upsell.orderPrompt = nil }
            } message: { p in
                Text(Loc("PRL 到达 %@ USDT 时给你推送通知，也就是这笔限价单大概率成交的时候。价格提醒是高级版功能。", p))
            }
            .alert(Loc("撤销订单"),
                   isPresented: Binding(get: { orderToCancel != nil },
                                        set: { if !$0 { orderToCancel = nil } }),
                   presenting: orderToCancel) { o in
                Button(Loc("确认撤单"), role: .destructive) {
                    Task { await store.cancelOrder(o) }
                    orderToCancel = nil
                }
                Button(Loc("取消"), role: .cancel) { orderToCancel = nil }
            } message: { o in
                Text(Loc("确认撤销此订单？%@ %@ PRL @ %@",
                         o.side == "buy" ? Loc("买入") : Loc("卖出"),
                         o.origin_amount ?? "", o.displayPrice ?? "—"))
            }
        }
    }

    // MARK: layout

    @ViewBuilder private var content: some View {
        if wide {
            VStack(spacing: Pearl.Space.lg) {
                notices
                HStack(alignment: .top, spacing: Pearl.Space.lg) {
                    VStack(spacing: Pearl.Space.lg) { balancesRow; MarketSection(store: store); PriceAlertPromoCard() }
                        .frame(maxWidth: .infinity)
                    VStack(spacing: Pearl.Space.lg) { orderSection; statusMessages; ordersList }
                        .frame(width: 360)
                }
            }
        } else {
            VStack(spacing: Pearl.Space.lg) {
                notices
                balancesRow
                MarketSection(store: store)
                PriceAlertPromoCard()
                orderSection
                statusMessages
                ordersList
            }
        }
    }

    // MARK: pieces

    /// Why the account can't be used right now: no keys, or the key refused for this IP.
    @ViewBuilder private var notices: some View {
        if !store.hasCredentials { credWarning }
        if let issue = store.ipIssue { UntrustedIPCard(issue: issue) }
    }

    private var credWarning: some View {
        HStack(alignment: .top, spacing: Pearl.Space.md) {
            PearlIconBadge(systemImage: "exclamationmark.triangle.fill", gradient: Pearl.sunrise, size: 40)
            VStack(alignment: .leading, spacing: Pearl.Space.xs) {
                Label(Loc("未配置 SafeTrade API 密钥"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .labelStyle(.titleOnly).font(.subheadline.weight(.semibold))
                Text(Loc("前往「设置 → 交易（SafeTrade）」填入 API Key / Secret 后即可下单。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
    }

    /// The order form, or — while an order's outcome is unknown — the form plus the
    /// banner that explains why its button is locked.
    @ViewBuilder private var orderSection: some View {
        if store.unverifiedOrder != nil {
            UnverifiedBanner(text: Loc("上一笔订单的结果还没确认，核对清楚前暂停下单。"),
                             checking: store.verifyingOrder,
                             recheck: { Task { await store.verifyUnverifiedOrder() } },
                             dismiss: { store.dismissUnverifiedOrder() })
        }
        OrderFormView(store: store)
    }

    /// Both exchange balances in ONE card, side by side — two half-empty cards with
    /// a coloured dot each read as filler; one quiet row reads as a ledger line.
    private var balancesRow: some View {
        let canWithdraw = store.hasCredentials && !SafeTradeStore.shotDemo
        // Both columns reserve the locked line or neither, so they line up.
        let footer = (usdt?.lockedValue ?? 0) > 0 || (prl?.lockedValue ?? 0) > 0
        // "余额" once, as the card's title; each column is then just the coin.
        return VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            HStack {
                Text(Loc("余额")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                // A failed refresh keeps the last balances — say they may be old.
                if store.accountStale && !store.balances.isEmpty {
                    Label(Loc("刷新失败，显示的是上次的数据"), systemImage: "clock.arrow.circlepath")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                balanceColumn("USDT", usdt, withdraw: canWithdraw, footer: footer)
                Divider().padding(.horizontal, Pearl.Space.lg)
                balanceColumn("PRL", prl, withdraw: canWithdraw, footer: footer)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
    }

    private var statusMessages: some View {
        TradeStatusLines(notice: store.lastOrder, errors: [store.error, store.accountError])
    }

    /// Every open (cancellable) order pinned to the top — they're the actionable ones
    /// — then recent finished ones up to 10 rows in all. Each group keeps the API's
    /// own recency order.
    private var displayOrders: [STOrder] {
        let open = store.orders.filter { $0.isOpen }
        let rest = store.orders.filter { !$0.isOpen }
        return open + rest.prefix(max(0, 10 - open.count))
    }

    @ViewBuilder private var ordersList: some View {
        if !store.orders.isEmpty {
            let rows = displayOrders
            VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                HStack {
                    Text(Loc("我的订单")).font(.headline)
                    Spacer()
                    let open = store.orders.filter(\.isOpen).count
                    if open > 0 {
                        Text(Loc("%@ 笔挂单", "\(open)")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.id) { o in
                        HStack(spacing: Pearl.Space.sm) {
                            sideWord(o)
                            orderSummary(o)
                            // Fixed-width state column so the dates line up down the list.
                            orderTrailing(o).frame(minWidth: 44, alignment: .trailing)
                        }
                        .padding(.vertical, Pearl.Space.xs + 2)
                        if o.id != rows.last?.id {
                            Divider().padding(.leading, sideColumnWidth + Pearl.Space.sm)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pearlCard()
        }
    }

    /// Side as a small coloured word, not a pill — the pills stacked down the list were
    /// the loudest thing on the page. Both localized words sit hidden underneath so every
    /// row's column is as wide as the wider one: a fixed 20pt fit 买/卖 but clipped
    /// "Sell" (21.7pt at iOS caption) and "Продать" (52pt). The width feeds the divider inset.
    private func sideWord(_ o: STOrder) -> some View {
        ZStack(alignment: .leading) {
            Text(Loc("买")).hidden()
            Text(Loc("卖")).hidden()
            Text(o.side == "buy" ? Loc("买") : Loc("卖"))
                .foregroundStyle(o.side == "buy" ? Color.green : Color.red)
        }
        .font(.caption.weight(.semibold))
        .frame(minWidth: 20, alignment: .leading)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { sideColumnWidth = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(o.side == "buy" ? Loc("买入") : Loc("卖出"))
    }

    /// Amount @ price with the order's date beneath — always two lines, so every row
    /// in the list has the same shape (a per-row "fit on one line if you can" made
    /// neighbouring rows alternate between one and two lines and read as a mess).
    @ViewBuilder private func orderSummary(_ o: STOrder) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Loc("%@ PRL @ %@", o.origin_amount ?? "", o.displayPrice ?? "—"))
                .font(.callout.monospacedDigit())
            if let at = o.placedAt {
                // Text(date, format:) follows the app's chosen language (environment
                // locale); Date.formatted() follows the SYSTEM locale, which is how an
                // English UI was showing "晚上8:00".
                Text(at, format: .dateTime.month(.defaultDigits).day().hour().minute())
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Trailing accessory for an order row: a spinner while this order is being
    /// canceled, a 撤单 button for open orders, or the plain state for terminal ones.
    @ViewBuilder private func orderTrailing(_ o: STOrder) -> some View {
        if store.cancelingOrderID == o.id {
            ProgressView().controlSize(.small)
        } else if o.isOpen {
            Button { orderToCancel = o } label: {
                Text(Loc("撤单")).font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .tint(.red)
            .disabled(store.cancelingOrderID != nil)
        } else {
            Text(stateLabel(o.state)).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The exchange's order state as a word, not its API token ("done" → 已成交).
    private func stateLabel(_ state: String?) -> String {
        switch state?.lowercased() {
        case "done":   return Loc("已成交")
        case "cancel": return Loc("已撤销")
        case "reject": return Loc("已拒绝")
        case "wait", "pending": return Loc("挂单中")
        default: return state ?? ""
        }
    }

    @ViewBuilder private func balanceColumn(_ name: String, _ b: STBalance?, withdraw: Bool, footer: Bool) -> some View {
        let locked = b?.lockedValue ?? 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                CoinBadge(symbol: name)
                Text(verbatim: name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(b.map { String(format: "%.4f", $0.balanceValue) } ?? "—")
                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
            // Locked amount on its own line (reserved in both columns when either has
            // one, so they line up), then 提现 as a soft full-width button — off the
            // coin line, where it crowded the name and the divider.
            if footer {
                Text(Loc("锁定 %@", String(format: "%.4f", locked)))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .opacity(locked > 0 ? 1 : 0)
                    .accessibilityHidden(locked <= 0)
            }
            if withdraw {
                Button { withdrawing = WithdrawCurrency(id: name.lowercased()) } label: {
                    Text(Loc("提现"))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Pearl.accent.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Pearl.accent)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// Small coin mark shown before a balance label: USDT as a Tether-green disc
/// with ₮; PRL as the widgets' pearl symbol (custom SF Symbol "pearl", shared
/// with the lock-screen widget) in the brand gradient. Vector, so it stays crisp
/// at caption size and follows Dynamic Type.
struct CoinBadge: View {
    let symbol: String
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 15

    var body: some View {
        Group {
            if symbol.uppercased() == "USDT" {
                ZStack {
                    Circle().fill(Color(red: 0.149, green: 0.631, blue: 0.482))   // #26A17B
                    Text(verbatim: "₮")
                        .font(.system(size: size * 0.62, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            } else {
                Image("pearl")
                    .resizable().scaledToFit()
                    .foregroundStyle(Pearl.brand)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
