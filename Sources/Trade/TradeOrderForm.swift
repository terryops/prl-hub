import SwiftUI

/// 下单 card. Owns the typed fields, so a keystroke re-renders only this card — not
/// the chart and order list around it.
struct OrderFormView: View {
    @ObservedObject var store: SafeTradeStore
    @ObservedObject private var upsell = UpsellPrompt.shared

    @State private var side = "sell"         // buy | sell — default to 卖出
    @State private var ordType = "limit"     // limit | market
    @State private var price = ""
    @State private var volume = ""
    @State private var confirming = false
    @FocusState private var focusedField: Field?
    private enum Field { case price, volume }

    private var usdt: STBalance? { store.balance("usdt") }
    private var prl: STBalance? { store.balance("prl") }
    private var rules: SafeTradeMarketRules { store.rules }

    /// Typed number → Double (a ru/vi decimalPad types a comma; PRLAmount.parse takes both).
    private func num(_ s: String) -> Double {
        PRLAmount.parse(s).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0
    }
    private var volNum: Double { num(volume) }
    private var priceNum: Double { num(price) }
    private var total: Double { priceNum * volNum }
    private var tick: Double { pow(10, -Double(rules.pricePrecision)) }

    /// Market-order average fill price from the live book: walking the asks for a buy,
    /// the bids for a sell. nil = no book yet, or it can't fill this amount.
    private var marketAvg: Double? {
        guard let d = store.depth else { return nil }
        return SafeTradeBook.averagePrice(for: volNum, levels: side == "buy" ? d.asks : d.bids)
    }
    private var marketEstimate: Double { (marketAvg ?? 0) * volNum }

    /// MAX fillable PRL: sell → all PRL held; limit buy → USDT ÷ price (the best ask
    /// until a price is typed); market buy → what the USDT buys walking the asks,
    /// with a tick + fee margin.
    private var maxAmount: Double {
        if side == "sell" { return prl?.balanceValue ?? 0 }
        let quote = usdt?.balanceValue ?? 0
        if ordType == "market" {
            guard let d = store.depth else { return 0 }
            return SafeTradeBook.affordableAmount(quote: quote, asks: d.asks, tick: tick)
        }
        let p = priceNum > 0 ? priceNum : (store.ticker?.buy).flatMap(Double.init) ?? 0   // `buy` = best ask
        guard p > 0 else { return 0 }
        return quote / p
    }
    /// Rounded DOWN to the market's amount precision, so the prefilled amount can never
    /// exceed the real balance or trip the exchange's precision check.
    private var maxText: String {
        String(format: "%.\(rules.amountPrecision)f", SafeTradeMarketRules.floor(maxAmount, places: rules.amountPrecision))
    }

    private var ruleProblem: SafeTradeMarketRules.Problem? {
        rules.problem(amountText: volume, priceText: ordType == "limit" ? price : nil)
    }
    private var insufficient: Bool {
        if side == "sell" { return volNum > (prl?.balanceValue ?? 0) }
        let cost = ordType == "limit" ? total : marketEstimate
        return cost > (usdt?.balanceValue ?? 0)
    }
    private var parsed: Bool {
        PRLAmount.parse(volume) != nil && (ordType == "market" || PRLAmount.parse(price) != nil)
    }
    private var canOrder: Bool {
        store.hasCredentials && !store.placing && store.unverifiedOrder == nil && parsed && volNum > 0
            && (ordType == "market" || priceNum > 0) && ruleProblem == nil && !insufficient
            && (ordType == "limit" || marketAvg != nil)
    }
    private var confirmMessage: String {
        let head = (side == "buy" ? Loc("买入") : Loc("卖出")) + Loc(" %@ PRL", volume)
        if ordType == "limit" { return head + Loc(" @ %@ USDT（约 %@ USDT）", price, amt(total)) }
        return head + Loc("（市价，约 %@ USDT）", amt(marketEstimate))
    }
    private func amt(_ x: Double) -> String { String(format: "%.4f", x) }

    var body: some View {
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
                        Button(Loc("MAX %@", maxText)) { volume = maxText }
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

            if ordType == "limit" || marketAvg != nil {
                HStack {
                    Text(Loc("预计成交额")).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%@%.4f USDT", ordType == "market" ? "≈ " : "",
                                ordType == "limit" ? total : marketEstimate)).monospacedDigit()
                }.font(.subheadline)
            }

            if volNum > 0 { formNote }

            Button { focusedField = nil; confirming = true } label: {
                Text(side == "buy" ? Loc("买入") : Loc("卖出"))
            }
            .buttonStyle(.pearl(side == "buy" ? Pearl.positive : Pearl.sell))
            .disabled(!canOrder)
        }
        .pearlCard()
        .animation(.snappy, value: ordType)
        .animation(.snappy, value: side)
        .onAppear { store.wantsDepth = ordType == "market" }
        .onDisappear { store.wantsDepth = false }
        .onChange(of: ordType) { _, t in store.wantsDepth = t == "market" }
        #if os(iOS)
        .toolbar {
            // 数字键盘上方的「完成」按钮，点一下即可收起键盘。
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(Loc("完成")) { focusedField = nil }.fontWeight(.semibold)
            }
        }
        #endif
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
    }

    /// Why the order can't go yet — the exchange's own rules first, then funds, then the book.
    @ViewBuilder private var formNote: some View {
        Group {
            if let p = ruleProblem {
                Text(p.message).foregroundStyle(.red)
            } else if insufficient {
                Text(side == "sell" ? Loc("PRL 余额不足") : Loc("USDT 余额不足")).foregroundStyle(.red)
            } else if ordType == "market" && store.depth == nil {
                Text(Loc("等待盘口数据后才能下市价单")).foregroundStyle(.orange)
            } else if ordType == "market" && marketAvg == nil {
                Text(Loc("盘口深度不够，市价单成交不了这么多，请减少数量或改用限价单")).foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
