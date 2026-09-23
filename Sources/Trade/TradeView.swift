import SwiftUI
import Charts
import Combine

struct TradeView: View {
    @StateObject private var store = SafeTradeStore()
    @ObservedObject private var upsell = UpsellPrompt.shared
    @EnvironmentObject private var contacts: ContactsStore
    @State private var openAlerts = false      // after buying Pro from the upsell, land on 价格提醒
    @Environment(\.horizontalSizeClass) private var hsc

    @State private var side = "sell"         // buy | sell — default to 卖出
    @State private var ordType = "limit"     // limit | market
    @State private var price = ""
    @State private var volume = ""
    @State private var confirming = false
    @State private var orderToCancel: STOrder?
    @State private var withdrawing: WithdrawCurrency? = TradeView.shotWithdraw
    @State private var sideColumnWidth: CGFloat = 20   // measured width of the 买/卖 column
    @FocusState private var focusedField: Field?
    private enum Field { case price, volume }

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

    private var usdt: STBalance? { store.balance("usdt") }
    private var prl: STBalance? { store.balance("prl") }
    private var total: Double { (parseAmt(price) ?? 0) * (parseAmt(volume) ?? 0) }
    private var wide: Bool { hsc != .compact }

    /// Parse a user-typed number tolerating the locale's comma decimal separator —
    /// the .decimalPad shows a comma key in ru/vi (and other comma regions) but
    /// Double() and the API only accept a period.
    private func parseAmt(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        if let v = Double(s) { return v }
        return Double(s.replacingOccurrences(of: ",", with: "."))
    }

    /// MAX fillable PRL amount: sell → all PRL held; buy → USDT ÷ price (ask for market).
    private var maxAmount: Double {
        if side == "sell" { return prl?.balanceValue ?? 0 }
        let p = parseAmt(price) ?? parseAmt(store.ticker?.sell) ?? parseAmt(store.ticker?.last) ?? 0
        guard p > 0 else { return 0 }
        return (usdt?.balanceValue ?? 0) / p
    }
    /// Display rounding (nearest) — fine for labels/estimates.
    private func amt(_ x: Double) -> String { String(format: "%.4f", x) }
    /// MAX-fill rounding: truncate DOWN to 4dp so the prefilled amount can never
    /// exceed the real balance and trip the insufficient-funds guard.
    private func amtFloor(_ x: Double) -> String {
        String(format: "%.4f", (x * 10000).rounded(.down) / 10000)
    }

    /// A refresh the user asked for (pull-to-refresh or the toolbar button). Only these
    /// count toward the Pro upsell — automatic loads and iCloud-sync refreshes must not
    /// (see UpsellPrompt).
    private func manualRefresh() async {
        await store.refresh()
        upsell.tradeRefreshed()
    }

    private var volNum: Double { parseAmt(volume) ?? 0 }
    private var priceNum: Double { parseAmt(price) ?? 0 }
    /// Estimated USDT cost of a market buy — a market buy fills at the ASK (sell),
    /// so use that (falling back to last); upper-bound estimate.
    private var marketEstimate: Double { (parseAmt(store.ticker?.sell) ?? parseAmt(store.ticker?.last) ?? 0) * volNum }
    private var marketBuyNeedsQuote: Bool { side == "buy" && ordType == "market" && marketEstimate <= 0 }
    private var insufficient: Bool {
        if side == "sell" { return volNum > (prl?.balanceValue ?? 0) }
        let cost = ordType == "limit" ? total : marketEstimate
        return cost > (usdt?.balanceValue ?? 0)
    }
    private var canOrder: Bool {
        store.hasCredentials && !store.loading && !store.placing && volNum > 0
            && (ordType == "market" || priceNum > 0) && !insufficient && !marketBuyNeedsQuote
    }
    private var confirmMessage: String {
        let head = (side == "buy" ? Loc("买入") : Loc("卖出")) + Loc(" %@ PRL", volume)
        if ordType == "limit" { return head + Loc(" @ %@ USDT（约 %@ USDT）", price, amt(total)) }
        return head + Loc("（市价，约 %@ USDT）", amt(marketEstimate))
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
                    Button { Task { await manualRefresh() } } label: { Image(systemName: "arrow.clockwise") }
                }
                #if os(iOS)
                // 数字键盘上方的「完成」按钮，点一下即可收起键盘。
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(Loc("完成")) { focusedField = nil }.fontWeight(.semibold)
                }
                #endif
            }
            .refreshable { await manualRefresh() }
            .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidUpdate)) { _ in
                store.adoptSyncedPeriod()        // chart period may have synced in
                Task { await store.refresh() }   // API keys may have synced in from another device
            }
            .overlay {
                if store.loading || store.placing {
                    ZStack {
                        Color.black.opacity(0.12).ignoresSafeArea()
                        ProgressView(Loc("处理中…")).controlSize(.large)
                            .pearlCard(padding: Pearl.Space.lg, radius: Pearl.Radius.sm, elevated: true)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.snappy, value: store.loading)
            .animation(.snappy, value: store.placing)
            .task {
                await store.loadPublic(); await store.refresh()
                while !Task.isCancelled {               // keep 现价 fresh
                    try? await Task.sleep(for: .seconds(5))
                    await store.refreshTickerOnly()
                }
            }
            // .alert (not .confirmationDialog): a confirmationDialog renders as a popover
            // anchored to this view on regular-width iPad/Mac, floating it over the form.
            // An alert is centered on every platform.
            .alert(Loc("确认下单"), isPresented: $confirming) {
                Button(side == "buy" ? Loc("确认买入") : Loc("确认卖出"), role: side == "buy" ? .none : .destructive) {
                    let limitPrice = ordType == "limit" ? price : ""   // captured: the fields are cleared on success
                    Task {
                        let ok = await store.placeOrder(side: side, ordType: ordType, volume: volume, price: ordType == "limit" ? price : nil)
                        if ok {
                            price = ""; volume = ""
                            // Market orders fill immediately — nothing to be notified about.
                            upsell.limitOrderPlaced(price: limitPrice)
                        }
                    }
                }
                Button(Loc("取消"), role: .cancel) {}
            } message: {
                Text(confirmMessage)
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
                if !store.hasCredentials { credWarning }
                HStack(alignment: .top, spacing: Pearl.Space.lg) {
                    VStack(spacing: Pearl.Space.lg) { balancesRow; MarketSection(store: store); PriceAlertPromoCard() }
                        .frame(maxWidth: .infinity)
                    VStack(spacing: Pearl.Space.lg) { orderForm; statusMessages; ordersList }
                        .frame(width: 360)
                }
            }
        } else {
            VStack(spacing: Pearl.Space.lg) {
                if !store.hasCredentials { credWarning }
                balancesRow
                MarketSection(store: store)
                PriceAlertPromoCard()
                orderForm
                statusMessages
                ordersList
            }
        }
    }

    // MARK: pieces

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

    /// Both exchange balances in ONE card, side by side — two half-empty cards with
    /// a coloured dot each read as filler; one quiet row reads as a ledger line.
    private var balancesRow: some View {
        // "余额" once, as the card's title; each column is then just the coin.
        VStack(alignment: .leading, spacing: Pearl.Space.xs) {
            Text(Loc("余额")).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 0) {
                balanceColumn("USDT", usdt, withdraw: store.hasCredentials && !SafeTradeStore.shotDemo)
                Divider().frame(height: 44).padding(.horizontal, Pearl.Space.md)
                balanceColumn("PRL", prl, withdraw: store.hasCredentials && !SafeTradeStore.shotDemo)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
    }

    @ViewBuilder private var orderForm: some View {
        VStack(spacing: Pearl.Space.md) {
            HStack {
                Text(Loc("下单")).font(.headline)
                Spacer()
                Text("PRL/USDT").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            // Full-width, label-less segments: the pickers' own titles ("方向" /
            // "类型") crowded the row on the Mac and said nothing the segments don't.
            Picker(Loc("方向"), selection: $side) {
                Text(Loc("买入 PRL")).tag("buy"); Text(Loc("卖出 PRL")).tag("sell")
            }.pickerStyle(.segmented).labelsHidden()

            Picker(Loc("类型"), selection: $ordType) {
                Text(Loc("限价")).tag("limit"); Text(Loc("市价")).tag("market")
            }.pickerStyle(.segmented).labelsHidden()

            if ordType == "limit" {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(Loc("价格 (USDT)")).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        if let last = store.ticker?.last {
                            Button(Loc("现价 %@", last)) { price = last }
                                .buttonStyle(.borderless).font(.caption.weight(.medium)).tint(Pearl.accent)
                        }
                    }
                    TextField("0.0", text: $price).textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .focused($focusedField, equals: .price)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        .submitLabel(.done)
                        #endif
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Loc("数量 (PRL)")).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if maxAmount > 0 {
                        Button(Loc("MAX %@", amtFloor(maxAmount))) { volume = amtFloor(maxAmount) }
                            .buttonStyle(.borderless).font(.caption.weight(.medium)).tint(Pearl.accent)
                    }
                }
                TextField("0.0", text: $volume).textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
                    .focused($focusedField, equals: .volume)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    .submitLabel(.done)
                    #endif
            }

            if ordType == "limit" {
                HStack {
                    Text(Loc("预计成交额")).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.4f USDT", total)).monospacedDigit()
                }.font(.subheadline)
            }

            if insufficient && volNum > 0 {
                Text(side == "sell" ? Loc("PRL 余额不足") : Loc("USDT 余额不足"))
                    .font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if marketBuyNeedsQuote && volNum > 0 {
                Text(Loc("等待现价后才能市价买入"))
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { confirming = true } label: {
                Text(side == "buy" ? Loc("买入") : Loc("卖出"))
            }
            .buttonStyle(.pearl(side == "buy" ? Pearl.positive : Pearl.sell))
            .disabled(!canOrder)
        }
        .pearlCard()
        .animation(.snappy, value: ordType)
        .animation(.snappy, value: side)
    }

    @ViewBuilder private var statusMessages: some View {
        if let msg = store.lastOrder {
            Label(msg, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
        if let e = store.error {
            Label(e, systemImage: "xmark.octagon").foregroundStyle(.red)
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Open (cancellable) orders pinned to the top — they're the actionable ones,
    /// and pinning also keeps them from being dropped by the 10-row cap below
    /// terminal (done/cancel) orders. Each group keeps the API's own recency order.
    private var displayOrders: [STOrder] {
        let open = store.orders.filter { $0.isOpen }
        let rest = store.orders.filter { !$0.isOpen }
        return Array((open + rest).prefix(10))
    }

    @ViewBuilder private var ordersList: some View {
        if !store.orders.isEmpty {
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
                    ForEach(displayOrders, id: \.id) { o in
                        HStack(spacing: Pearl.Space.sm) {
                            sideWord(o)
                            orderSummary(o)
                            // Fixed-width state column so the dates line up down the list.
                            orderTrailing(o).frame(minWidth: 44, alignment: .trailing)
                        }
                        .padding(.vertical, Pearl.Space.xs + 2)
                        if o.id != displayOrders.last?.id {
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

    @ViewBuilder private func balanceColumn(_ name: String, _ b: STBalance?, withdraw: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // One line always; 提现 keeps its full width.
            HStack(spacing: 5) {
                CoinBadge(symbol: name)
                Text(verbatim: name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .lineLimit(1)
                if withdraw {
                    Spacer(minLength: 4)
                    Button(Loc("提现")) { withdrawing = WithdrawCurrency(id: name.lowercased()) }
                        .buttonStyle(.borderless).font(.caption.weight(.semibold)).tint(Pearl.accent)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            Text(b.map { String(format: "%.4f", $0.balanceValue) } ?? "—")
                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
            // Always reserve the locked-amount line so both columns keep one height.
            Text(Loc("锁定 %@", String(format: "%.4f", b?.lockedValue ?? 0)))
                .font(.caption2).foregroundStyle(.secondary)
                .opacity((b?.lockedValue ?? 0) > 0 ? 1 : 0)
                .accessibilityHidden((b?.lockedValue ?? 0) <= 0)
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

// MARK: - Market price + candlestick K-line

struct MarketSection: View {
    @ObservedObject var store: SafeTradeStore
    @ObservedObject private var live = PriceLiveActivity.shared
    @ObservedObject private var pro = ProStore.shared

    /// Change shown next to the price, following the chart's period picker: the
    /// rolling change over the last 5 min / 15 min / 1 h / 4 h (from 1-minute
    /// candles), and the exchange's own rolling 24h change for 1日.
    private var periodChange: String? {
        if store.period == 1440 { return store.ticker?.price_change_percent }
        guard let now = store.ticker?.last.flatMap(Double.init) ?? store.minuteCandles.last?.close,
              let pct = store.rollingChange(minutes: store.period, price: now) else { return nil }
        return String(format: "%+.2f%%", pct)
    }

    var body: some View {
        let t = store.ticker
        let chg = periodChange
        let down = (chg ?? "").hasPrefix("-")
        VStack(alignment: .leading, spacing: Pearl.Space.md) {
            HStack {
                Text("PRL/USDT").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if PriceLiveActivity.supported { liveButton }
            }
            .padding(.bottom, -Pearl.Space.sm)
            HStack(alignment: .top, spacing: Pearl.Space.md) {
                VStack(alignment: .leading, spacing: Pearl.Space.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Pearl.Space.xs) {
                        Text(t?.last ?? "—")
                            .font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .contentTransition(.numericText())
                        // 24h change in the same green/red the candles use — a third
                        // colour pair (teal/rose) next to the chart just looked wrong.
                        if let chg {
                            Text(chg).font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(down ? Color.red : Color.green)
                                .contentTransition(.numericText())
                                .animation(.snappy, value: chg)
                        }
                    }
                }
                Spacer(minLength: Pearl.Space.sm)
                // 2×2 label/value grid instead of two run-on caption lines.
                Grid(alignment: .trailing, horizontalSpacing: Pearl.Space.sm, verticalSpacing: 3) {
                    GridRow { tickerCell(Loc("高"), t?.high); tickerCell(Loc("买"), t?.buy) }
                    GridRow { tickerCell(Loc("低"), t?.low);  tickerCell(Loc("卖"), t?.sell) }
                }
                .fixedSize()
            }

            // Full card width on its own row: sharing the row with the 锁屏盯盘 button
            // (both fixed-size) made it wider than a phone and pushed the whole
            // screen past its margins.
            Picker(Loc("周期"), selection: Binding(get: { store.period }, set: { store.setPeriod($0) })) {
                Text(Loc("5分")).tag(5); Text(Loc("15分")).tag(15); Text(Loc("1时")).tag(60); Text(Loc("4时")).tag(240); Text(Loc("1日")).tag(1440)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)

            if let e = live.error {
                Text(e).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CandleChart(candles: store.candles)
        }
        .pearlCard()
    }

    /// 锁屏盯盘 toggle (Pro). Without Pro it opens the upgrade sheet instead.
    private var liveButton: some View {
        Button {
            guard pro.isPro else { UpsellPrompt.shared.showing = true; return }
            Task { if live.running { await live.stop() } else { await live.start() } }
        } label: {
            HStack(spacing: 4) {
                if live.running {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text(Loc("盯盘中"))
                } else {
                    Image(systemName: "lock.iphone")
                    Text(Loc("锁屏盯盘"))
                }
            }
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.borderless)
        .tint(live.running ? .green : Pearl.accent)
        .fixedSize()
    }

    @ViewBuilder private func tickerCell(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value ?? "—").foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
        .gridColumnAlignment(.trailing)
    }
}

#if os(iOS)
/// UIKit long-press → scrub for the K-line crosshair. A SwiftUI gesture on the chart
/// (a zero-distance drag, and even a LongPress→Drag sequence) swallowed every swipe that
/// began on the chart, so the page wouldn't scroll there. UILongPressGestureRecognizer
/// fails as soon as the finger moves before 0.2 s, handing the touch to the enclosing
/// scroll view; once it has begun, the drag moves only the crosshair.
private struct HoldToScrub: UIViewRepresentable {
    var onChange: (CGPoint?) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let g = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        g.minimumPressDuration = 0.2
        v.addGestureRecognizer(g)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.onChange = onChange }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    final class Coordinator: NSObject {
        var onChange: (CGPoint?) -> Void
        init(onChange: @escaping (CGPoint?) -> Void) { self.onChange = onChange }

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began, .changed: onChange(g.location(in: g.view))
            default: onChange(nil)
            }
        }
    }
}
#endif

struct CandleChart: View {
    let candles: [STCandle]
    @State private var selected: STCandle?
    @Environment(\.colorScheme) private var scheme

    /// Minutes between candles, read from the data itself so the axis always matches what
    /// is drawn (the period picker can change a beat before the new candles arrive).
    private var candleMinutes: Double {
        guard candles.count >= 2 else { return 1440 }
        return abs(candles[1].time.timeIntervalSince(candles[0].time)) / 60
    }

    /// Time labels fine enough that the ~4 ticks differ: 5-min candles span ~10 h and
    /// 15-min ~30 h (times),
    /// hourly ~5 days (one tick per day, date only), 4-hour / daily candles weeks to months
    /// (dates).
    private var timeAxisFormat: Date.FormatStyle {
        switch candleMinutes {
        case ..<30:  return .dateTime.hour().minute()
        case ..<120: return .dateTime.month(.defaultDigits).day()
        default:     return .dateTime.month(.abbreviated).day()
        }
    }

    /// Hourly candles get a fixed midnight tick per day. The automatic ticks landed on
    /// midnight anyway, and "9/14, 12 AM" ×5 overflowed an iPhone-width axis and overlapped.
    private var dailyTicks: Bool { (30..<120).contains(candleMinutes) }

    /// Enough decimals that neighbouring price ticks (~¼ of the visible range apart) never
    /// print the same label — a sub-dollar coin can move less than a cent in a window.
    private func priceFractionDigits(lo: Double, hi: Double) -> Int {
        let step = max(hi - lo, 0.0001) / 4
        return min(6, max(2, Int(ceil(-log10(step)))))
    }

    var body: some View {
        if candles.isEmpty {
            Text(Loc("加载 K 线…")).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 260)
        } else {
            let lo = candles.map(\.low).min() ?? 0
            let hi = candles.map(\.high).max() ?? 1
            let pad = max((hi - lo) * 0.08, 0.0001)
            let priceDigits = priceFractionDigits(lo: lo, hi: hi)
            Chart {
                ForEach(candles) { c in
                    RuleMark(x: .value("时间", c.time),
                             yStart: .value("低", c.low), yEnd: .value("高", c.high))
                        .foregroundStyle(c.up ? Color.green : Color.red)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    // A doji (open == close) still needs a visible body: pad it to a hairline.
                    RectangleMark(x: .value("时间", c.time),
                                  yStart: .value("开", c.open),
                                  yEnd: .value("收", c.close == c.open ? c.close + (hi - lo) * 0.002 : c.close),
                                  width: .fixed(4))
                        .foregroundStyle(c.up ? Color.green : Color.red)
                        .cornerRadius(1)
                }
                // Crosshair + OHLC tooltip following the cursor.
                if let sel = selected {
                    RuleMark(x: .value("时间", sel.time))
                        .foregroundStyle(Color.gray.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .center,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(sel)
                        }
                    PointMark(x: .value("时间", sel.time), y: .value("收", sel.close))
                        .symbolSize(45).foregroundStyle(sel.up ? Color.green : Color.red)
                }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            // Quiet axes: faint horizontal guides only, no vertical dashed lattice.
            // Labels are built explicitly so they can't inherit the app tint (a bare
            // AxisValueLabel picked up the accent blue on the date axis).
            .chartXAxis {
                if dailyTicks {
                    AxisMarks(values: .stride(by: .day)) { v in
                        AxisValueLabel {
                            if let d = v.as(Date.self) {
                                Text(d, format: timeAxisFormat)
                                    .font(.caption2).foregroundStyle(Color.secondary)
                            }
                        }
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 4)) { v in
                        AxisValueLabel {
                            if let d = v.as(Date.self) {
                                Text(d, format: timeAxisFormat)
                                    .font(.caption2).foregroundStyle(Color.secondary)
                            }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let y = v.as(Double.self) {
                            // Text(_:format:) formats with the app's locale from the environment.
                            // A concrete gray, not .secondary: inside these AxisMarks the hierarchical
                            // style resolves against the 6%-opacity grid line and the labels vanish.
                            Text(y, format: .number.precision(.fractionLength(priceDigits)))
                                .font(.caption2).foregroundStyle(Color.gray)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    #if os(macOS)
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc): select(candle(at: loc, proxy, geo))
                            case .ended: select(nil)
                            }
                        }
                    #else
                    // Press-and-hold (0.2 s) arms the crosshair, then drag to scrub; a plain
                    // swipe that starts on the chart scrolls the page. See HoldToScrub.
                    HoldToScrub { p in select(p.flatMap { candle(at: $0, proxy, geo) }) }
                    #endif
                }
            }
            .frame(height: 260)   // fixed so the chart doesn't stretch to fill the column
        }
    }

    /// Only touch `selected` when the candle under the cursor actually changes, so a drag
    /// doesn't re-render all 120 candles on every point it moves.
    private func select(_ c: STCandle?) {
        if c?.id != selected?.id { selected = c }
    }

    /// Nearest candle to the cursor's x-position.
    private func candle(at loc: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) -> STCandle? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = loc.x - geo[plot].origin.x
        guard x >= 0, x <= geo[plot].width, let date: Date = proxy.value(atX: x) else { return nil }
        return candles.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }

    @ViewBuilder private func tooltip(_ c: STCandle) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(c.time.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.weight(.semibold)).foregroundStyle(.primary)
            // 对齐成 2×2 网格，标签弱化、数值加粗，避免挤在一起看不清。
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    // Own keys: the bare "开"/"收" keys are the On-toggle and Receive
                    // strings elsewhere ("On" / "Receive" in English).
                    ohlc(Loc("开盘价"), pf(c.open), .primary)
                    ohlc(Loc("高"), pf(c.high), .green)
                }
                GridRow {
                    ohlc(Loc("低"), pf(c.low), .red)
                    ohlc(Loc("收盘价"), pf(c.close), c.up ? .green : .red)
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        // Opaque, scheme-matched surface so the tooltip always has strong contrast.
        // A translucent material let the (light) chart backdrop show through in 白天
        // mode and washed the OHLC labels out — use solid white in light / charcoal
        // in dark so .primary/.secondary text reads cleanly either way.
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(scheme == .dark ? Color(white: 0.16) : .white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .fixedSize()
    }

    @ViewBuilder private func ohlc(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(color)
        }
    }

    private func pf(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(2...6))) }
}
