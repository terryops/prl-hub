import Foundation
import Combine
import SwiftUI

@MainActor
final class SafeTradeStore: ObservableObject {
    @Published var balances: [STBalance] = []
    @Published var ticker: STTicker?
    @Published var orders: [STOrder] = []
    @Published var candles: [STCandle] = []
    /// 1-minute candles for the last ~4 h — only used to work out the rolling
    /// "last 5 min / 15 min / 1 h / 4 h" change shown next to the price.
    @Published var minuteCandles: [STCandle] = []
    private var minutesFetchedAt: Date?
    @Published var period = 60          // minutes: 15 / 60 / 240 / 1440
    @Published var loading = false
    /// An order POST is in flight. SEPARATE from `loading` (which refresh() also
    /// toggles) so a stray refresh completing mid-order can never drop the order
    /// overlay or re-enable the order button and invite a duplicate.
    @Published var placing = false
    /// The id of the order currently being canceled, so the row can show a
    /// spinner in place of its 撤单 button. nil when no cancel is in flight.
    @Published var cancelingOrderID: Int?
    @Published var error: String?
    @Published var lastOrder: String?

    private let client = SafeTradeClient()
    private var candleRequestID = 0
    var market: String { SafeTradeMarket.normalized(UserDefaults.standard.string(forKey: "safetrade.market")) }

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

    func refresh() async {
        #if DEBUG
        if Self.shotDemo { seedDemo(); await loadPublic(); return }   // demo account + real public market
        #endif
        guard hasCredentials else {
            balances = []
            orders = []
            lastOrder = nil
            loading = false
            error = Loc("未配置 API 密钥")
            return
        }
        loading = true; error = nil
        let currentMarket = market
        let candlePeriod = period
        let requestID = nextCandleRequestID()
        async let b = client.balances()
        async let t = client.ticker(market: currentMarket)
        async let o = client.orders(market: currentMarket)
        async let k = client.kline(market: currentMarket, period: candlePeriod)
        do {
            balances = try await b
            ticker = try? await t
            share(ticker)
            orders = (try? await o) ?? []
            let nextCandles = (try? await k) ?? []
            applyCandles(nextCandles, requestID: requestID, period: candlePeriod)
        } catch {
            self.error = (error as? SafeTradeError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }

    func setPeriod(_ p: Int) {
        period = p
        UserDefaults.standard.set(p, forKey: "safetrade.period")
        CloudSync.push("safetrade.period")
        let currentMarket = market
        let requestID = nextCandleRequestID()
        Task {
            let nextCandles = (try? await client.kline(market: currentMarket, period: p)) ?? []
            applyCandles(nextCandles, requestID: requestID, period: p)
        }
    }

    /// Adopt a chart period synced in from another device (re-fetches candles).
    func adoptSyncedPeriod() {
        let stored = UserDefaults.standard.integer(forKey: "safetrade.period")
        guard SafeTradeStore.periods.contains(stored), stored != period else { return }
        setPeriod(stored)
    }

    /// Public ticker doesn't need credentials — load it even before keys are set.
    func loadPublic() async {
        let currentMarket = market
        let candlePeriod = period
        let requestID = nextCandleRequestID()
        async let m: Void = refreshMinutes()
        setTicker(try? await client.ticker(market: currentMarket))
        let nextCandles = (try? await client.kline(market: currentMarket, period: candlePeriod)) ?? []
        applyCandles(nextCandles, requestID: requestID, period: candlePeriod)
        await m
    }

    /// The 5-second 现价 poll. The 1-minute candles only gain a row per minute,
    /// so they're re-fetched at most every 30 s rather than on every tick.
    func refreshTickerOnly() async {
        let minutesDue = minutesFetchedAt.map { Date().timeIntervalSince($0) >= 30 } ?? true
        async let m: Void = minutesDue ? refreshMinutes() : ()
        setTicker(try? await client.ticker(market: market))
        await m
    }

    /// Publish only a quote that actually changed: an identical tick every 5 s would
    /// otherwise re-render the whole Trade tab (K-line included) for nothing.
    private func setTicker(_ t: STTicker?) {
        if t != ticker { ticker = t }
        share(t)
    }

    /// Hand a fresh PRL/USDT quote to the app-wide price (only for the PRL market —
    /// the market is configurable).
    private func share(_ t: STTicker?) {
        guard market == SafeTradeMarket.defaultValue, let last = t?.last.flatMap(Double.init) else { return }
        PRLPriceManager.shared.adopt(last)
    }

    private func refreshMinutes() async {
        if let m = try? await client.kline(market: market, period: 1, limit: 250), !m.isEmpty {
            if m != minuteCandles { minuteCandles = m }
            minutesFetchedAt = Date()
        }
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
        guard !placing else { return false }   // never start a second order while one is in flight
        // Canonicalize the decimal separator: a ru/vi decimalPad yields "1,5", but the
        // exchange (and Double()) only accept "1.5" — sending the raw comma string would
        // silently corrupt the order amount/price (truncate or reject).
        let volume = Self.canonicalDecimal(volume)
        let price = price.map(Self.canonicalDecimal)
        placing = true; error = nil; lastOrder = nil
        do {
            let o = try await client.placeOrder(market: market, side: side, amount: volume, price: price, type: ordType)
            placing = false   // order accepted — stop blocking the screen right away
            lastOrder = Loc("已下单 #%@ · %@ %@ @ %@ · %@", o.id.map(String.init) ?? "?", o.side ?? side, o.origin_amount ?? volume, o.displayPrice ?? price ?? "—", o.state ?? "")
            orders.insert(o, at: 0)            // optimistic: show it at the top at once
            Task { await refreshAccount() }    // reconcile balances + orders off the hot path
            // Auto-dismiss the success banner so it can't linger and invite a duplicate.
            Task { try? await Task.sleep(for: .seconds(5)); withAnimation { lastOrder = nil } }
            return true
        } catch let e as SafeTradeError {
            placing = false
            if case .placedUnverified = e {
                // The exchange ACCEPTED the order (2xx) but we couldn't read the
                // result. Treat it as submitted (clear inputs, reconcile) and surface
                // an ambiguous warning rather than a hard "failed" that invites a
                // duplicate re-tap.
                self.error = e.errorDescription
                Task { await refreshAccount() }
                return true
            }
            self.error = e.errorDescription
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
        } catch let e as SafeTradeError {
            self.error = e.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
        cancelingOrderID = nil
    }

    /// Reconcile account-side data (balances + open orders) without raising the
    /// blocking overlay. Used after placing an order; ticker/K-line are left to
    /// the periodic refresh since your own order doesn't move them.
    private func refreshAccount() async {
        async let b = client.balances()
        async let o = client.orders(market: market)
        if let bb = try? await b { balances = bb }
        if let oo = try? await o { orders = oo }
    }

    private func nextCandleRequestID() -> Int {
        candleRequestID += 1
        return candleRequestID
    }

    /// Canonicalize a user-typed number to a period decimal separator for the API.
    static func canonicalDecimal(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
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
    }
    #endif
}
