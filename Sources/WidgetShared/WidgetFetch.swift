import Foundation

// MARK: - Dependency-light fetchers for the widget timeline
//
// These intentionally do NOT reuse the app's BlockbookClient / PoolClient: the
// widget extension must stay tiny (no OysterMobile, no Loc/UI graph) to fit the
// widget memory budget, so the few endpoints it needs are re-implemented here in
// pure Foundation. The app keeps its richer clients; this is the minimal subset.

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

    /// Spot price of 1 PRL in USD (SafeTrade public ticker).
    static func prlUsd() async -> Double? {
        guard let obj = await json("https://safetrade.com/api/v2/peatio/public/markets/prlusdt/tickers") as? [String: Any]
        else { return nil }
        let t = (obj["ticker"] as? [String: Any]) ?? obj
        let v = double(t["last"])
        return v > 0 ? v : nil
    }

    /// 1 USD in CNY (open exchange-rate API).
    static func usdCny() async -> Double? {
        guard let obj = await json("https://open.er-api.com/v6/latest/USD") as? [String: Any],
              let rates = obj["rates"] as? [String: Any] else { return nil }
        let v = double(rates["CNY"])
        return v > 0 ? v : nil
    }

    struct PoolLive {
        let hashrate: String     // formatted REAL-TIME, e.g. "1.23 GH/s"
        let hashrateRaw: Double  // raw real-time H/s
        let online: Int
        let total: Int
    }

    /// Parse a formatted hashrate ("484.52 TH/s") back to raw H/s. 0 if unparseable.
    /// Local copy (the widget target links neither the app's PoolComparison nor its
    /// helpers) so the extension stays dependency-light.
    private static func parseHashrate(_ s: String) -> Double {
        let parts = s.split(separator: " ")
        let numStr = (parts.first.map(String.init) ?? "").replacingOccurrences(of: ",", with: "")
        guard let v = Double(numStr) else { return 0 }
        let unit = (parts.count > 1 ? String(parts[1]) : "H/s").uppercased()
        let mult: [String: Double] = ["EH/S": 1e18, "PH/S": 1e15, "TH/S": 1e12,
                                      "GH/S": 1e9, "MH/S": 1e6, "KH/S": 1e3, "H/S": 1]
        return v * (mult[unit] ?? 1)
    }

    /// HeroMiners reports every hashrate right-shifted by 32 bits; ×2^32 recovers
    /// real H/s (matches the app's HeroMinersClient.hashScale).
    private static let heroHashScale = 4_294_967_296.0   // 2^32

    /// Per-miner REAL-TIME (瞬时) stats, re-fetched dependency-light for every pool the
    /// app supports. A nil result (network error / not-mining) makes the caller keep
    /// the app's last snapshot value for that pool.
    static func poolLive(kind: String, address: String) async -> PoolLive? {
        switch kind {
        case "AlphaPool":     return await alphaPoolLive(address)
        case "HeroMiners":    return await heroMinersLive(address)
        case "Lucky Pool":    return await luckyPoolLive(address)
        case "Pearl Fortune": return await pearlFortuneLive(address)
        case "PearlHash":     return await pearlHashLive(address)
        case "Kryptex":       return await kryptexLive(address)
        case "F2Pool":        return await f2poolLive(address)
        default:              return nil
        }
    }

    /// PearlHash — GET /api/account/{addr}. Its per-rig rate is what the MINER reports, per
    /// GPU, so a rig's rate is the sum of its cards; everything in `connected_workers` is
    /// connected right now, hence online == total. 404 (never mined here) and a decode miss
    /// both yield nil, so the widget keeps the app's last snapshot instead of showing a zero.
    /// The response is large (~40 KB gzipped — it carries the full payout ledger), but that is
    /// still the smallest thing this pool will answer with.
    private static func pearlHashLive(_ address: String) async -> PoolLive? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty,
              let obj = await json("https://pearlhash.xyz/api/account/\(addr)", timeout: 20) as? [String: Any],
              let workers = obj["connected_workers"] as? [[String: Any]], !workers.isEmpty
        else { return nil }
        var liveRaw = 0.0
        for w in workers {
            for g in (w["gpu_info"] as? [[String: Any]] ?? []) { liveRaw += double(g["hashrate"]) }
        }
        return PoolLive(hashrate: formatHashrate(liveRaw), hashrateRaw: liveRaw,
                        online: workers.count, total: workers.count)
    }

    /// Kryptex — GET /prl/api/v3/miner/workers/{addr}. Values are real H/s but arrive as
    /// STRINGS, and there is no instantaneous rate: the freshest figure the pool publishes
    /// per rig is a 30-minute average (then 3h, then 24h), so that is what the widget shows.
    /// An address that never mined here answers 200 with `results: []` — no rigs, no total,
    /// so the caller keeps the app's last snapshot rather than showing a zero.
    private static func kryptexLive(_ address: String) async -> PoolLive? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty,
              let obj = await json("https://pool.kryptex.com/prl/api/v3/miner/workers/\(addr)", timeout: 15) as? [String: Any],
              let workers = obj["results"] as? [[String: Any]], !workers.isEmpty
        else { return nil }
        var liveRaw = 0.0
        var online = 0
        for w in workers {
            liveRaw += double(w["avg_hashrate_30m"])
            if (w["status"] as? String)?.lowercased() == "online" { online += 1 }
        }
        // No rig reported a 30-minute figure (all just started / all idle) → the 24h average.
        if liveRaw <= 0 { liveRaw = workers.reduce(0) { $0 + double($1["avg_hashrate_24h"]) } }
        return PoolLive(hashrate: formatHashrate(liveRaw), hashrateRaw: liveRaw,
                        online: online, total: workers.count)
    }

    /// F2Pool — the account's read-only page. Its `address` is that page's URL (F2Pool has
    /// no by-address API); the 32-hex path component is the key the server identifies the
    /// account by. Per-worker `hashrate` is TH/s while the account `summary.hash_rate` is
    /// raw H/s — the two units genuinely differ. There is no instantaneous rate: the
    /// freshest figure f2pool publishes is a 15-minute average.
    private static let f2HashScale = 1e12   // per-worker TH/s → H/s
    private static func f2poolLive(_ address: String) async -> PoolLive? {
        guard let c = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              (c.host ?? "").hasSuffix("f2pool.com") else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "mining-user-prl"), i + 1 < parts.count else { return nil }
        let key = parts[i + 1]
        let account = c.queryItems?.first { $0.name == "user_name" }?.value ?? ""
        let url = "https://www.f2pool.com/mining-user-prl/\(key)"
            + "?user_name=\(account)&account=\(account)&currency=PRL&action=get_pagination_workers"
        guard let obj = await json(url, timeout: 15, xhr: true) as? [String: Any],
              let origin = obj["originData"] as? [String: Any] else { return nil }
        let workers = origin["workers"] as? [[String: Any]] ?? []
        var liveRaw = 0.0
        var online = 0
        for w in workers {
            liveRaw += double(w["hashrate"]) * f2HashScale
            if (w["status"] as? NSNumber)?.intValue == 0 { online += 1 }   // 0 online · 1 offline · 2 dead
        }
        // Fall back to the account summary (already raw H/s) when no worker reports.
        let summary = origin["summary"] as? [String: Any]
        let raw = liveRaw > 0 ? liveRaw : double(summary?["hash_rate"])
        return PoolLive(hashrate: formatHashrate(raw), hashrateRaw: raw, online: online, total: workers.count)
    }

    private static func alphaPoolLive(_ address: String) async -> PoolLive? {
        guard let obj = await json("https://pearl.alphapool.tech/api/miner/\(address)", timeout: 15) as? [String: Any]
        else { return nil }
        let workers = obj["workers"] as? [[String: Any]] ?? []
        let now = Date().timeIntervalSince1970
        var online = 0
        var liveRaw = 0.0   // REAL-TIME total = Σ per-worker live hashrate (not the 24h estimate)
        for w in workers {
            liveRaw += parseHashrate(w["hashrate_live"] as? String ?? "")
            let isOnline: Bool
            if let b = w["online"] as? Bool { isOnline = b }
            else if let t = w["time"] as? NSNumber { isOnline = now - t.doubleValue < 600 }
            else { isOnline = false }
            if isOnline { online += 1 }
        }
        // Fall back to the miner-level 1h estimate only if no worker reported a live rate.
        let raw = liveRaw > 0 ? liveRaw : double(obj["estHash1hRaw"])
        return PoolLive(hashrate: formatHashrate(raw), hashrateRaw: raw, online: online, total: workers.count)
    }

    /// HeroMiners (英雄池) — GET /api/stats_address. Each worker carries a live
    /// `hashrate` and a unix-seconds `lastShare` (both NUMBERS here), every value >>32
    /// so ×2^32 = real H/s. REAL-TIME total = Σ per-worker live; falls back to the
    /// miner-level current / 1h figure when no worker reports.
    private static func heroMinersLive(_ address: String) async -> PoolLive? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty,
              let obj = await json("https://pearl.herominers.com/api/stats_address?address=\(addr)&longpoll=false", timeout: 15) as? [String: Any]
        else { return nil }
        let workers = obj["workers"] as? [[String: Any]] ?? []
        let now = Date().timeIntervalSince1970
        var online = 0
        var liveRaw = 0.0
        for w in workers {
            liveRaw += double(w["hashrate"]) * heroHashScale
            if now - double(w["lastShare"]) < 600 { online += 1 }
        }
        // No live workers → miner-level current, else the 1h estimate (same >>32 scale).
        let stats = obj["stats"] as? [String: Any]
        let live = double(stats?["hashrate"])
        let fallback = (live > 0 ? live : double(stats?["hashrate_1h"])) * heroHashScale
        let raw = liveRaw > 0 ? liveRaw : fallback
        return PoolLive(hashrate: formatHashrate(raw), hashrateRaw: raw, online: online, total: workers.count)
    }

    /// Lucky Pool — GET /api/stats_address. Values are real H/s (no bit-shift). A
    /// missing `stats` object means the address isn't mining here (mirrors the app's
    /// `m.stats == nil ? nil`). Per-worker `lastShare` is epoch MILLISECONDS (string).
    private static func luckyPoolLive(_ address: String) async -> PoolLive? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty,
              let obj = await json("https://pearl.luckypool.io/api/stats_address?address=\(addr)", timeout: 15) as? [String: Any],
              obj["stats"] is [String: Any]
        else { return nil }
        let workers = obj["workers"] as? [[String: Any]] ?? []
        let now = Date().timeIntervalSince1970
        var online = 0
        var liveRaw = 0.0
        for w in workers {
            liveRaw += double(w["hashrate"])
            let ls = double(w["lastShare"]) / 1000        // ms → s; 0 = no value (treat as online, like the app's `?? true`)
            if ls <= 0 || now - ls < 600 { online += 1 }
        }
        let stats = obj["stats"] as? [String: Any]
        let raw = liveRaw > 0 ? liveRaw : double(stats?["hashrate"])
        return PoolLive(hashrate: formatHashrate(raw), hashrateRaw: raw, online: online, total: workers.count)
    }

    /// Pearl Fortune — GET /api/v1/miners/{addr}/connections (live workers only; the
    /// {data:…} envelope). `reported_hashrate` is real H/s; online == !stale.
    private static func pearlFortuneLive(_ address: String) async -> PoolLive? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty,
              let env = await json("https://pearlfortune.org/api/v1/miners/\(addr)/connections", timeout: 15) as? [String: Any],
              let data = env["data"] as? [String: Any]
        else { return nil }
        let workers = data["workers"] as? [[String: Any]] ?? []
        var online = 0
        var liveRaw = 0.0
        for w in workers {
            liveRaw += double(w["reported_hashrate"])
            if !((w["stale"] as? Bool) ?? true) { online += 1 }
        }
        let summary = data["summary"] as? [String: Any]
        let raw = liveRaw > 0 ? liveRaw : double(summary?["reported_hashrate"])
        return PoolLive(hashrate: formatHashrate(raw), hashrateRaw: raw, online: online, total: workers.count)
    }
}
