import Foundation
import Combine
import CryptoKit
import SwiftUI

/// SafeTrade refused the key for this network's IP: the key has a Trusted IPs list
/// and SafeTrade sees an address that isn't on it.
struct SafeTradeIPIssue: Equatable {
    /// The public IP SafeTrade sees — nil while it's being looked up (or if that failed).
    var ip: String?
    var isIPv6: Bool { ip?.contains(":") == true }
}

/// An order POST whose outcome is unknown (timeout, 5xx, unreadable reply). The order
/// button stays locked until the order list shows it or, after a few clean looks,
/// provably doesn't — a blind re-tap could book it twice.
struct PendingOrderCheck: Equatable {
    let side: String
    let knownIDs: Set<Int>
    /// `knownIDs` is the full recent list from before the POST (not a partial / failed read),
    /// so "no new id" really means "not booked".
    let knownComplete: Bool

    /// A new order on the same side. Deliberately loose (no amount match): mistaking
    /// some other new order for this one only keeps the user from re-ordering; the
    /// reverse would book a duplicate.
    func isNew(_ o: STOrder) -> Bool {
        guard let id = o.id, !knownIDs.contains(id) else { return false }
        return o.side == nil || o.side == side
    }
}

@MainActor
final class SafeTradeStore: ObservableObject {
    @Published var balances: [STBalance] = []
    /// `balances` is last session's (shown dimmed) until the first fresh read lands.
    @Published private(set) var balancesAreCached = false
    @Published var ticker: STTicker?
    /// Every open order (newest first), then the recent finished ones.
    @Published var orders: [STOrder] = []
    @Published var candles: [STCandle] = []
    /// 1-minute candles for the last ~4 h — only used to work out the rolling
    /// "last 5 min / 15 min / 1 h / 4 h" change shown next to the price.
    @Published var minuteCandles: [STCandle] = []
    private var minutesFetchedAt: Date?
    @Published var period = 60          // minutes: 15 / 60 / 240 / 1440
    /// The order book — polled only while the order form is on 市价 (`wantsDepth`) or
    /// the Pro depth chart is on screen (`wantsDepthChart`).
    @Published private(set) var depth: STDepth?
    /// The last book read failed: `depth` is from before (the chart says so, but keeps it).
    @Published private(set) var depthStale = false
    private var depthFetchedAt: Date?
    /// The market's order rules (precisions, minimum); the built-in values until they load.
    @Published private(set) var rules = SafeTradeMarketRules.prlusdt
    private var rulesLoaded = false
    /// Some refresh is in flight (toolbar spinner). The blocking overlay only covers a
    /// first load that has nothing on screen yet.
    @Published private(set) var refreshing = false
    private var lastRefreshAt: Date?
    /// The last account refresh failed: balances / orders on screen are from before.
    @Published private(set) var accountStale = false
    /// An order POST is in flight. SEPARATE from `refreshing` so a stray refresh
    /// completing mid-order can never drop the order overlay or re-enable the order
    /// button and invite a duplicate.
    @Published var placing = false
    /// The id of the order currently being canceled, so the row can show a
    /// spinner in place of its 撤单 button. nil when no cancel is in flight.
    @Published var cancelingOrderID: Int?
    /// Outcome of the user's last action (order / cancel).
    @Published var error: String?
    /// Why the account couldn't be read (kept separate so a successful refresh clears
    /// it without wiping an order error).
    @Published private(set) var accountError: String?
    @Published var lastOrder: String?
    /// SafeTrade refused the API key for this network's IP — see UntrustedIPCard.
    @Published private(set) var ipIssue: SafeTradeIPIssue?
    @Published private(set) var unverifiedOrder: PendingOrderCheck?
    @Published private(set) var verifyingOrder = false
    /// Withdrawals whose POST outcome is unknown, per currency. Held here rather than
    /// in the withdraw sheet, so closing and reopening the sheet can't unlock a re-submit.
    @Published var unverifiedWithdraws: [String: PendingWithdrawCheck] = [:]
    /// The order form is on 市价 — poll the book with the ticker.
    var wantsDepth = false {
        didSet { if wantsDepth, !oldValue { Task { await refreshDepth() } } }
    }
    /// The 买卖深度图 card is showing its live (Pro) chart — poll the book every ~10 s.
    /// Mid-refresh the book waits for the balances and candles: the second phase picks
    /// it up (see refresh()).
    var wantsDepthChart = false {
        didSet {
            if wantsDepthChart, !oldValue, !refreshing, depthDue(every: Self.depthChartInterval) {
                Task { await refreshDepth() }
            }
        }
    }
    /// The chart only needs a gentle refresh; the 市价 estimate keeps its per-tick poll.
    private static let depthChartInterval: TimeInterval = 9

    private let client = SafeTradeClient()
    private var candleRequestID = 0
    let market = SafeTradeMarket.defaultValue

    #if DEBUG
    /// Screenshot-only (App Store captures): when SHOT_TRADE_DEMO=1, present a
    /// fully-populated Trade tab — believable demo balances & open orders plus the
    /// REAL public price / candlestick K-line, and no "configure API key" warning —
    /// so the promo shot shows the feature in use. Mirrors the pool-monitor
    /// SHOT_WATCH seam; never compiled into Release.
    static let shotDemo = ProcessInfo.processInfo.environment["SHOT_TRADE_DEMO"] == "1"
    #else
    static let shotDemo = false
    #endif
    var hasCredentials: Bool { Self.shotDemo || SafeTradeSecrets.hasCredentials }

    /// K-line periods offered by the chart picker, in minutes.
    static let periods = [5, 15, 60, 240, 1440]

    init() {
        // Restore the last-used chart period (persisted + iCloud-synced).
        let stored = UserDefaults.standard.integer(forKey: "safetrade.period")
        if SafeTradeStore.periods.contains(stored) { period = stored }
        #if DEBUG
        if Self.shotDemo { seedDemo() }
        #endif
    }

    func balance(_ currency: String) -> STBalance? {
        balances.first { $0.currency.lowercased() == currency.lowercased() }
    }

    /// A full refresh unless one ran within `seconds` — for re-entering the tab or the
    /// foreground, which can flip several times in a row (Control Center, app switcher).
    func refreshIfStale(olderThan seconds: TimeInterval = 30) async {
        if let t = lastRefreshAt, Date().timeIntervalSince(t) < seconds { return }
        await refresh()
    }

    /// Market data always; the account (balances, orders) when keys are set. What's
    /// on screen stays when a part fails — nothing is blanked by a bad read.
    ///
    /// Two phases, so the top of the tab isn't held up by what's below it: first the
    /// balances, price and candles (each shown the moment it lands), then the order
    /// lists, 1-minute candles, order rules and — only if its card is on screen — the book.
    func refresh() async {
        #if DEBUG
        if Self.shotDemo { seedDemo(); await loadPublic(); return }   // demo account + real public market
        #endif
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; lastRefreshAt = Date() }
        // Keys may have synced in from another device since the last look.
        SafeTradeSecrets.invalidateCache()
        guard hasCredentials else {
            balances = []
            balancesAreCached = false
            orders = []
            lastOrder = nil
            ipIssue = nil
            accountStale = false
            accountError = Loc("未配置 API 密钥")
            await loadPublic()
            return
        }
        // Last session's balances for this key, until the fresh read replaces them — no
        // blank card (and no full-screen overlay) on opening the tab.
        if balances.isEmpty, let cached = Self.cachedBalances() {
            balances = cached
            balancesAreCached = true
        }
        async let balanceError = loadBalances()
        await loadPrimaryMarket()
        if let error = await balanceError {
            await settleAccount(error)   // the order lists would fail the same way
            await loadSecondaryMarket()
            return
        }
        async let orderError = loadOrders()
        await loadSecondaryMarket()
        await settleAccount(await orderError)
    }

    func setPeriod(_ p: Int) {
        period = p
        UserDefaults.standard.set(p, forKey: "safetrade.period")
        CloudSync.push("safetrade.period")
        let currentMarket = market
        let requestID = nextCandleRequestID()
        Task {
            if let next = try? await client.kline(market: currentMarket, period: p) {
                applyCandles(next, requestID: requestID, period: p)
            }
        }
    }

    /// Adopt a chart period synced in from another device (re-fetches candles).
    func adoptSyncedPeriod() {
        let stored = UserDefaults.standard.integer(forKey: "safetrade.period")
        guard SafeTradeStore.periods.contains(stored), stored != period else { return }
        setPeriod(stored)
    }

    /// Public market data — ticker, candles, rules, book — needs no keys.
    func loadPublic() async {
        await loadPrimaryMarket()
        await loadSecondaryMarket()
    }

    /// The price and the candles, each put on screen as soon as it arrives.
    private func loadPrimaryMarket() async {
        let candlePeriod = period
        let requestID = nextCandleRequestID()
        async let t: Void = setTicker(try? await client.ticker(market: market))
        async let k: Void = loadCandles(period: candlePeriod, requestID: requestID)
        await t; await k
    }

    private func loadCandles(period p: Int, requestID: Int) async {
        if let next = try? await client.kline(market: market, period: p) {
            applyCandles(next, requestID: requestID, period: p)
        }
    }

    /// What can wait for the top of the tab: 1-minute candles (the rolling change),
    /// order rules, and the book when the 市价 form or the depth card wants it.
    private func loadSecondaryMarket() async {
        async let m: Void = refreshMinutesIfDue(force: true)
        async let r: Void = loadRulesIfNeeded()
        let bookWanted = wantsDepth || wantsDepthChart
        async let d: Void = bookWanted ? refreshDepth() : ()
        await m; await r; await d
    }

    /// The periodic 现价 poll (plus the book: every tick on 市价, every ~10 s for the
    /// depth chart). The 1-minute candles only gain a row per minute, so they're
    /// re-fetched at most every 30 s.
    func refreshTickerOnly() async {
        async let m: Void = refreshMinutesIfDue(force: false)
        let bookDue = wantsDepth || (wantsDepthChart && depthDue(every: Self.depthChartInterval))
        async let d: Void = bookDue ? refreshDepth() : ()
        setTicker(try? await client.ticker(market: market))
        await m; await d
    }

    /// Publish only a quote that actually changed: an identical tick every 5 s would
    /// otherwise re-render the whole Trade tab (K-line included) for nothing. A failed
    /// read (nil) keeps the last quote rather than flashing "—".
    private func setTicker(_ t: STTicker?) {
        guard let t else { return }
        if t != ticker { ticker = t }
        if let last = t.last.flatMap(Double.init) { PRLPriceManager.shared.adopt(last) }
    }

    /// The 1-minute candles only feed the rolling change of the shorter periods — the
    /// 1日 view shows the exchange's own 24 h change instead.
    private func refreshMinutesIfDue(force: Bool) async {
        guard period != 1440 else { return }
        if !force, let t = minutesFetchedAt, Date().timeIntervalSince(t) < 30 { return }
        if let m = try? await client.kline(market: market, period: 1, limit: 250), !m.isEmpty {
            if m != minuteCandles { minuteCandles = m }
            minutesFetchedAt = Date()
        }
    }

    /// 100 levels: enough for the chart's ±15 % window and for walking a market order.
    /// A failed read keeps the last book, flagged stale, so one bad poll can't blank it.
    private func refreshDepth() async {
        do {
            let d = try await client.depth(market: market, limit: 100)
            depthFetchedAt = Date()
            if d != depth { depth = d }
            if depthStale { depthStale = false }
        } catch {
            if depth != nil, !depthStale { depthStale = true }
        }
    }

    private func depthDue(every seconds: TimeInterval) -> Bool {
        guard let t = depthFetchedAt else { return true }
        return Date().timeIntervalSince(t) >= seconds
    }

    private func loadRulesIfNeeded() async {
        guard !rulesLoaded, let r = try? await client.marketRules(market: market) else { return }
        rulesLoaded = true
        if r != rules { rules = r }
    }

    /// % change of `price` against the price `minutes` ago, from the 1-minute
    /// candles (the close of the minute that ended at or just before then).
    /// nil when the history doesn't reach back that far.
    func rollingChange(minutes: Int, price: Double) -> Double? {
        let target = Date().addingTimeInterval(-Double(minutes * 60))
        guard let first = minuteCandles.first, first.time <= target,
              let ref = minuteCandles.last(where: { $0.time.addingTimeInterval(60) <= target }),
              ref.close > 0, price > 0 else { return nil }
        return (price - ref.close) / ref.close * 100
    }

    /// Returns true on success so the view can clear its inputs.
    ///
    /// The blocking overlay is dropped the instant the order POST returns — the
    /// trade is already in at that point. Balances + open orders are then
    /// reconciled in the background (no overlay), so the user isn't held on the
    /// "处理中…" screen waiting out the slower account refresh that used to run
    /// inline. The returned order is inserted optimistically so the list updates
    /// immediately while the background reconcile catches up.
    @discardableResult
    func placeOrder(side: String, ordType: String, volume: String, price: String?) async -> Bool {
        // Never start a second order while one is in flight or unaccounted for.
        guard !placing, unverifiedOrder == nil, let amount = PRLAmount.parse(volume) else { return false }
        // The API takes "1.5": a ru/vi decimalPad types "1,5", which PRLAmount.parse accepts.
        let priceValue = price.flatMap(PRLAmount.parse)
        let amountText = SafeTradeMarketRules.plain(amount)
        let priceText = priceValue.map(SafeTradeMarketRules.plain)
        let before = PendingOrderCheck(side: side, knownIDs: Set(orders.compactMap(\.id)), knownComplete: !accountStale)
        placing = true; error = nil; lastOrder = nil
        do {
            let o = try await client.placeOrder(market: market, side: side, amount: amountText, price: priceText, type: ordType)
            placing = false   // order accepted — stop blocking the screen right away
            lastOrder = Loc("已下单 #%@ · %@ %@ @ %@ · %@", o.id.map(String.init) ?? "?", o.side ?? side, o.origin_amount ?? amountText, o.displayPrice ?? priceText ?? "—", o.state ?? "")
            orders.insert(o, at: 0)            // optimistic: show it at the top at once
            Task { await refreshAccount() }    // reconcile balances + orders off the hot path
            // Auto-dismiss the success banner so it can't linger and invite a duplicate.
            Task { try? await Task.sleep(for: .seconds(5)); withAnimation { lastOrder = nil } }
            return true
        } catch SafeTradeError.placedUnverified {
            // The exchange may have booked it. Treat it as submitted (clear inputs) and
            // lock the button until the order list settles the question.
            placing = false
            unverifiedOrder = before
            error = SafeTradeError.placedUnverified.errorDescription
            Task { await verifyUnverifiedOrder() }
            return true
        } catch let e as SafeTradeError {
            placing = false
            await present(e)
            return false
        } catch {
            placing = false
            self.error = error.localizedDescription
            // Defensive: an unclassified failure here is treated as a clean failure, but
            // reconcile anyway so an order that slipped through despite the error surfaces
            // in the list before the user re-taps.
            Task { await refreshAccount() }
            return false
        }
    }

    /// Settle an unverified order: look for it in the recent list a few times (the
    /// engine can lag a moment). Found → it went in. Several clean looks at a list
    /// known to be complete → it didn't, and the button unlocks. Couldn't look → it
    /// stays locked and the banner offers 重新核对.
    func verifyUnverifiedOrder() async {
        guard let check = unverifiedOrder, !verifyingOrder else { return }
        verifyingOrder = true
        defer { verifyingOrder = false }
        var cleanLooks = 0
        for delay in [0, 3, 6] {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let recent = try? await client.orders(market: market) else { continue }
            if let hit = recent.first(where: check.isNew) {
                unverifiedOrder = nil
                error = nil
                lastOrder = Loc("已在订单列表找到这笔订单 #%@", hit.id.map(String.init) ?? "?")
                await refreshAccount()
                return
            }
            cleanLooks += 1
        }
        if check.knownComplete, cleanLooks >= 2 {
            unverifiedOrder = nil
            error = Loc("订单列表里没有这笔订单，下单没有成功，可以重新下单。")
        } else {
            error = Loc("暂时无法确认下单结果，请到 SafeTrade 网站核对，或稍后点「重新核对」。")
        }
        await refreshAccount()
    }

    /// Manual override once the user has checked on the SafeTrade website.
    func dismissUnverifiedOrder() {
        unverifiedOrder = nil
        error = nil
    }

    /// Cancel a resting order. Shows a per-row spinner (cancelingOrderID) until
    /// the exchange has accepted the cancel AND the order list has been
    /// re-fetched, so the row reflects the authoritative `cancel` state rather
    /// than optimistically flipping and risking a flicker back to `wait`.
    /// One cancel at a time keeps the spinner state unambiguous.
    func cancelOrder(_ order: STOrder) async {
        guard let id = order.id, cancelingOrderID == nil, !placing else { return }
        cancelingOrderID = id; error = nil; lastOrder = nil
        do {
            try await client.cancelOrder(id: id)
            await refreshAccount()   // pull the real state (and the unlocked balance)
        } catch {
            await present(error)
        }
        cancelingOrderID = nil
    }

    /// Balances + orders: the recent list plus EVERY open order (the recent list is
    /// capped, and an open order past the cap couldn't be canceled). Each part goes on
    /// screen as soon as it lands. A failure keeps
    /// what's on screen, flagged stale — an open order that "vanished" might get placed
    /// again.
    func refreshAccount() async {
        async let b = loadBalances()
        async let o = loadOrders()
        let balanceError = await b
        let orderError = await o
        await settleAccount(balanceError ?? orderError)
    }

    /// Balances, applied the moment they arrive (the balance card doesn't wait on the
    /// order lists). Returns the failure instead of reporting it — see settleAccount.
    private func loadBalances() async -> Error? {
        do {
            let next = try await client.balances()
            if next != balances { balances = next }
            if balancesAreCached { balancesAreCached = false }
            Self.rememberBalances(next)
            return nil
        } catch {
            return error
        }
    }

    // MARK: last known balances

    /// Per API key (a hash of it — the key itself never goes into UserDefaults), so
    /// switching to another account's key can't show the old account's figures.
    private static var balanceCacheKey: String? {
        let key = SafeTradeSecrets.apiKey
        guard !key.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "safetrade.lastBalances.\(digest)"
    }

    private static func cachedBalances() -> [STBalance]? {
        guard let k = balanceCacheKey, let rows = UserDefaults.standard.array(forKey: k) as? [[String: String]] else { return nil }
        let list = rows.compactMap { r -> STBalance? in
            guard let c = r["currency"], let b = r["balance"], let l = r["locked"] else { return nil }
            return STBalance(currency: c, balance: b, locked: l)
        }
        return list.isEmpty ? nil : list
    }

    private static func rememberBalances(_ list: [STBalance]) {
        guard let k = balanceCacheKey else { return }
        UserDefaults.standard.set(list.map { ["currency": $0.currency, "balance": $0.balance, "locked": $0.locked] }, forKey: k)
    }

    /// Recent + every resting order, merged. The open-orders read is best effort: if
    /// it fails, the open orders already on screen stand in.
    private func loadOrders() async -> Error? {
        async let o = client.orders(market: market)
        async let w = try? client.orders(market: market, state: "wait", limit: 100)
        do {
            let recent = try await o
            let open = await w ?? orders.filter(\.isOpen)
            let merged = Self.merge(recent: recent, open: open)
            if merged != orders { orders = merged }
            return nil
        } catch {
            return error
        }
    }

    /// One verdict for an account read: clear the flags, or keep what's on screen
    /// flagged stale and show why.
    private func settleAccount(_ error: Error?) async {
        if let error {
            accountStale = true
            await present(error, account: true)
        } else {
            accountStale = false
            accountError = nil
            ipIssue = nil
        }
    }

    /// Open orders first, then the recent list, each id once. An order in both lists
    /// takes the recent list's copy — it's at least as new (the open list may be the
    /// previous one, reused when the open-orders read fails), so a just-filled order
    /// isn't shown as still open.
    static func merge(recent: [STOrder], open: [STOrder]) -> [STOrder] {
        let fresh = Dictionary(recent.compactMap { o in o.id.map { ($0, o) } }, uniquingKeysWith: { first, _ in first })
        let stillOpen = open.map { o in o.id.flatMap { fresh[$0] } ?? o }.filter(\.isOpen)
        var seen = Set<Int>()
        return (stillOpen + recent).filter { o in
            guard let id = o.id else { return true }
            return seen.insert(id).inserted
        }
    }

    /// Show a failure. An untrusted-IP refusal gets the IP card (with the address
    /// SafeTrade sees) instead of a raw error line.
    private func present(_ e: Error, account: Bool = false) async {
        if (e as? SafeTradeError)?.authProblem == .untrustedIP {
            if account { accountError = nil } else { error = nil }
            if ipIssue == nil { ipIssue = SafeTradeIPIssue(ip: nil) }
            if let ip = try? await client.publicIP() { ipIssue = SafeTradeIPIssue(ip: ip) }
            return
        }
        if account { accountError = e.localizedDescription } else { error = e.localizedDescription }
    }

    private func nextCandleRequestID() -> Int {
        candleRequestID += 1
        return candleRequestID
    }

    private func applyCandles(_ nextCandles: [STCandle], requestID: Int, period requestedPeriod: Int) {
        guard requestID == candleRequestID, period == requestedPeriod else { return }
        #if DEBUG
        // Demo runs where SafeTrade is unreachable (its WAF blocks datacenter/proxy IPs):
        // draw a synthetic series so the chart can still be checked.
        if Self.shotDemo && nextCandles.isEmpty { candles = Self.demoCandles(period: requestedPeriod); return }
        #endif
        if nextCandles != candles { candles = nextCandles }
    }

    #if DEBUG
    /// 120 deterministic candles ending now, `period` minutes apart (a gentle random walk
    /// around $0.85), for SHOT_TRADE_DEMO runs without network access to SafeTrade.
    static func demoCandles(period: Int) -> [STCandle] {
        let step = TimeInterval(period * 60)
        let end = (Date().timeIntervalSince1970 / step).rounded(.down) * step
        var price = 0.85, seed: UInt64 = 0x9E3779B97F4A7C15
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        return (0..<120).map { i in
            let open = price
            price = max(0.3, price * (1 + (rnd() - 0.5) * 0.04))
            let hi = max(open, price) * (1 + rnd() * 0.01), lo = min(open, price) * (1 - rnd() * 0.01)
            return STCandle(time: Date(timeIntervalSince1970: end - Double(119 - i) * step),
                            open: open, high: hi, low: lo, close: price, volume: 1000 + rnd() * 5000)
        }
    }

    /// Believable demo account for SHOT_TRADE_DEMO App Store captures (DEBUG only).
    private func seedDemo() {
        balances = [
            STBalance(currency: "prl",  balance: "1284.50000000", locked: "200.00000000"),
            STBalance(currency: "usdt", balance: "642.18000000",  locked: "55.00000000"),
        ]
        orders = [
            STOrder(id: 90412, market: "prlusdt", side: "sell", type: "limit",
                    price: "0.5800", state: "wait", origin_amount: "200.0", avg_price: nil,
                    created_at: STTimestamp(Date().addingTimeInterval(-2 * 3600)), updated_at: nil),
            STOrder(id: 90398, market: "prlusdt", side: "buy",  type: "limit",
                    price: "0.4850", state: "wait", origin_amount: "500.0", avg_price: nil,
                    created_at: STTimestamp(Date().addingTimeInterval(-26 * 3600)), updated_at: nil),
        ]
        error = nil
        accountError = nil
        // SHOT_IP_ISSUE=1 adds the untrusted-IP card, to check its layout without an IP-bound key.
        if ProcessInfo.processInfo.environment["SHOT_IP_ISSUE"] == "1" {
            ipIssue = SafeTradeIPIssue(ip: "2605:52c0:2:b43:b037:29ff:fe00:f59a")
        }
    }
    #endif
}
