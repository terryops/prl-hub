import Foundation
import Combine

// ============================================================
// $PRL spot price (USD)
// ------------------------------------------------------------
// "如果有 SafeTrade 就用它，否则用其他公开 API。"
// Primary source is SafeTrade's PUBLIC PRL/USDT ticker — no API
// keys required, it's the real market price. When SafeTrade can't
// be reached we fall back to WhatToMine's PRL exchange_rate × the
// live BTC/USD price (CoinGecko) — the same derivation the mining
// monitor uses (see fetchLive in PRLStore). The last good value is
// cached to disk so the wallet shows a fiat estimate instantly on
// launch, then refreshes in the background. Pair with
// CurrencyManager to also render the user's secondary currency.
//
// This is THE app-wide PRL price: the wallet, pools, mining monitor
// and widgets all read it, and whoever sees a fresher SafeTrade
// quote (the Trade tab polls every 5 s) hands it in via adopt(),
// so every screen shows the same number.
// ============================================================

@MainActor
final class PRLPriceManager: ObservableObject {
    /// Shared instance — the wallet dashboard (and anyone else wanting a quick
    /// PRL→USD estimate) reads this without an environment injection.
    static let shared = PRLPriceManager()

    /// Spot price of 1 PRL in USD, or nil before the first successful fetch.
    @Published private(set) var usd: Double?
    /// Not @Published: no view shows it, and the Trade tab re-stamps it every 5 s —
    /// publishing it re-rendered every screen observing the price that often.
    private(set) var lastUpdated: Date?
    private var lastPersisted: Date?

    private var inFlight = false
    private static let cacheKey = "prl.priceUSD"
    private static let atKey    = "prl.priceAt"
    private static let maxAge: TimeInterval = 60    // hit the network at most once a minute

    init() {
        let v = UserDefaults.standard.double(forKey: Self.cacheKey)
        if v > 0 { usd = v }
        let at = UserDefaults.standard.double(forKey: Self.atKey)
        if at > 0 { lastUpdated = Date(timeIntervalSince1970: at) }
    }

    /// USD value of a PRL amount at the current price, or nil if no price yet.
    func value(of prl: Decimal) -> Double? {
        guard let usd else { return nil }
        return NSDecimalNumber(decimal: prl).doubleValue * usd
    }

    /// Fetch only when we've never fetched or the cache is older than `maxAge`.
    func refreshIfStale() async {
        if let at = lastUpdated, Date().timeIntervalSince(at) < Self.maxAge, usd != nil { return }
        await refresh()
    }

    /// Pull a fresh price: SafeTrade public ticker first, WhatToMine×BTC fallback.
    func refresh() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        var price = await fetchPRLUsdSafeTrade()
        if price == nil {
            // Fallback: WhatToMine's PRL→BTC exchange_rate × live BTC/USD.
            if let d = await httpGET("https://whattomine.com/coins/469.json"),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let xr = num(o["exchange_rate"]), let btc = await fetchBTC() {
                let p = xr * btc
                if p > 0.00001 && p < 1e5 { price = p }
            }
        }
        guard let p = price else { return }
        adopt(p)
    }

    /// Take a freshly fetched price from anywhere in the app (e.g. the Trade tab's
    /// ticker): cache it, and hand it to the widgets (which reload only if it moved).
    func adopt(_ p: Double, at now: Date = Date()) {
        guard p > 0, p.isFinite else { return }
        let moved = usd != p
        if moved { usd = p }
        lastUpdated = now
        // An unchanged quote only needs its freshness stamp written now and then, not on
        // every 5 s tick (each write also round-trips the widget snapshot's JSON).
        if !moved, let at = lastPersisted, now.timeIntervalSince(at) < 30 { return }
        lastPersisted = now
        UserDefaults.standard.set(p, forKey: Self.cacheKey)
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.atKey)
        WidgetBridge.updatePrice(prlUsd: p, usdCny: nil, prlUsdAt: now)
    }
}
