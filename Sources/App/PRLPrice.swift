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
// ============================================================

@MainActor
final class PRLPriceManager: ObservableObject {
    /// Shared instance — the wallet dashboard (and anyone else wanting a quick
    /// PRL→USD estimate) reads this without an environment injection.
    static let shared = PRLPriceManager()

    /// Spot price of 1 PRL in USD, or nil before the first successful fetch.
    @Published private(set) var usd: Double?
    @Published private(set) var lastUpdated: Date?

    private var inFlight = false
    private static let cacheKey = "prl.priceUSD"
    private static let atKey    = "prl.priceAt"
    private static let maxAge: TimeInterval = 120   // hit the network at most every 2 min

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
        guard let p = price, p > 0, p.isFinite else { return }

        usd = p
        let now = Date()
        lastUpdated = now
        UserDefaults.standard.set(p, forKey: Self.cacheKey)
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.atKey)
    }
}
