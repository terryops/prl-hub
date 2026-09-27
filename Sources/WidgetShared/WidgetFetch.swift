import Foundation

// MARK: - Dependency-light fetchers for the widget timeline
//
// These intentionally do NOT reuse the app's BlockbookClient: the widget extension
// must stay tiny (no OysterMobile, no Loc/UI graph) to fit the widget memory budget,
// so the few endpoints it needs are re-implemented here in pure Foundation. Pools are
// the exception — their per-miner sources (Pools/) are already pure Foundation and are
// shared with the app outright.

enum WidgetFetch {
    private static let browserUA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static func json(_ urlString: String, timeout: TimeInterval = 10,
                            xhr: Bool = false) async -> Any? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        // F2Pool's read-only page serves JSON only to XHR callers; otherwise it renders
        // its 280 KB HTML page with a 200 and JSONSerialization quietly fails.
        if xhr { req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With") }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func double(_ v: Any?) -> Double {
        if let s = v as? String { return Double(s) ?? 0 }
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }

    /// Total balance (confirmed + unconfirmed) for an account xpub, in PRL.
    /// Mirrors BlockbookClient.balance: PRL has 8 decimals. nil for a missing/empty
    /// xpub so the caller can fire it concurrently without a pre-guard.
    static func balancePRL(xpub: String?, network: String) async -> Double? {
        guard let xpub, !xpub.isEmpty else { return nil }
        let base = network == "testnet"
            ? "https://blockbook.testnet.pearlresearch.ai"
            : "https://blockbook.pearlresearch.ai"
        guard let obj = await json("\(base)/api/v2/xpub/\(xpub)?details=basic") as? [String: Any] else { return nil }
        let confirmed = double(obj["balance"])
        let unconfirmed = double(obj["unconfirmedBalance"])
        return (confirmed + unconfirmed) / 1e8
    }

    /// The price the app (or the other widget) fetched within the last 2 minutes,
    /// else a fresh fetch — so the widgets show the same number as the app.
    /// Returns the value and when it was fetched.
    static func sharedPrlUsd(_ snap: WidgetSnapshot) async -> (usd: Double, at: Date)? {
        if snap.prlUsd > 0, let at = snap.prlUsdAt, Date().timeIntervalSince(at) < WidgetBridge.freshFor { return (snap.prlUsd, at) }
        guard let v = await prlUsd() else { return nil }
        return (v, Date())
    }

    /// Spot price of 1 PRL in USD. First the price-alert worker's (the exact value it
    /// pushes to the 锁屏盯盘 Live Activity, which iOS shows without waking the app, so
    /// it can't reach the shared snapshot) — then the widgets and the Lock Screen agree.
    /// SafeTrade's public ticker if the worker is unreachable.
    static func prlUsd() async -> Double? {
        // Its last stored row comes back even if its cron stopped: only a recent one counts.
        if let obj = await json("https://prl.tools.video/v1/price", timeout: 6) as? [String: Any],
           Date().timeIntervalSince1970 - double(obj["ts"]) < 300 {
            let v = double(obj["usd"])
            if v > 0 { return v }
        }
        return await safeTradeUsd()
    }

    private static func safeTradeUsd() async -> Double? {
        guard let obj = await json("https://safetrade.com/api/v2/peatio/public/markets/prlusdt/tickers") as? [String: Any]
        else { return nil }
        let t = (obj["ticker"] as? [String: Any]) ?? obj
        let v = double(t["last"])
        return v > 0 ? v : nil
    }

    struct PoolLive {
        let hashrate: String     // formatted REAL-TIME, e.g. "1.23 GH/s"
        let hashrateRaw: Double  // raw real-time H/s
        let online: Int
        let total: Int
    }

    /// Per-miner REAL-TIME (瞬时) stats for every pool the app supports, through the SAME
    /// per-pool sources the app's 我的监控 cards use (Sources/WidgetShared/Pools) — so the
    /// widget and the app compute the same total from the same parsing. `.live` scope reads
    /// only each pool's rig endpoint. A nil result (network error / not mining here) makes the
    /// caller keep the app's last snapshot value for that pool.
    static func poolLive(kind: String, address: String) async -> PoolLive? {
        guard let pool = PoolKind(rawValue: kind),
              let s = try? await pool.source.miner(address, scope: .live) else { return nil }
        return PoolLive(hashrate: s.liveRateText, hashrateRaw: s.liveRate,
                        online: s.onlineCount, total: s.workers.count)
    }
}
