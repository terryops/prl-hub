import Foundation

/// Browser-like User-Agent for pool requests. The app runs on-device with the
/// user's own IP; a real-browser UA matches that and avoids non-browser soft-filters.
let poolBrowserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

// Extra Pearl pool clients. Lucky Pool's per-miner endpoint feeds the "Lucky Pool"
// watch cards; the public `stats()` calls remain available but are no longer used
// by a UI section (the efficiency comparison was removed).

/// Human-readable hashrate from raw H/s.
func formatHashrate(_ hps: Double) -> String {
    let units: [(String, Double)] = [("EH/s", 1e18), ("PH/s", 1e15), ("TH/s", 1e12), ("GH/s", 1e9), ("MH/s", 1e6), ("kH/s", 1e3)]
    for (u, v) in units where hps >= v { return String(format: "%.2f %@", hps / v, u) }
    return String(format: "%.0f H/s", hps)
}

/// Inverse of `formatHashrate`: parse "240.30 TH/s" → raw H/s. 0 if unparseable.
func parseHashrate(_ s: String) -> Double {
    let parts = s.split(separator: " ")
    // Strip grouping separators ("1,234.56 TH/s") before parsing so a comma-grouped
    // value isn't silently treated as 0.
    let numStr = String(parts.first ?? "").replacingOccurrences(of: ",", with: "")
    guard let v = Double(numStr) else { return 0 }
    let unit = parts.count > 1 ? String(parts[1]) : "H/s"
    let mult: [String: Double] = ["EH/s": 1e18, "PH/s": 1e15, "TH/s": 1e12,
                                  "GH/s": 1e9, "MH/s": 1e6, "kH/s": 1e3, "H/s": 1]
    return v * (mult[unit] ?? 1)
}

extension Double {
    /// Self when non-zero, else `fallback`. Lets a per-worker 1h hashrate fall back
    /// to the live rate for pools that don't report a distinct 1h figure.
    func nonZeroOr(_ fallback: Double) -> Double { self != 0 ? self : fallback }
}

// MARK: - Lucky Pool (open-ethereum-pool fork) — pearl.luckypool.io
struct LuckyStats: Decodable {
    struct Config: Decodable { let fee: Double?; let coinUnits: Double? }
    struct Network: Decodable { let hashrate: Double?; let reward: Double?; let blockTime: Double? }
    struct Pool: Decodable { let hashrate: Double?; let miners: Int?; let workers: Int? }
    let config: Config?
    let network: Network?
    let pool: Pool?
}

/// Per-miner stats from /api/stats_address?address= (amounts in grain, ÷1e8 = PRL).
struct LuckyMiner: Decodable {
    struct Stats: Decodable {
        let hashrate: Double?          // H/s, current
        let paid: Double?              // grain, lifetime
        let unlocked: Double?          // grain, withdrawable
        let locked: Double?            // grain, immature/pending
        let acceptedShares: String?
        let lastShare: String?
        struct Avg: Decodable {
            let h24: Double?; let h6: Double?; let h1: Double?
            enum CodingKeys: String, CodingKey { case h24 = "24h"; case h6 = "6h"; case h1 = "1h" }
        }
        let hashrateAvg: Avg?
    }
    struct Worker: Decodable, Identifiable {
        let name: String
        let minerAgent: String?
        let region: String?
        let hashrate: Double?          // H/s, instant (same window as stats.hashrate)
        let hashrateAvg: Stats.Avg?
        let lastShare: String?         // epoch MILLISECONDS, as a string
        var id: String { name }
        var lastShareSec: Double? { lastShare.flatMap(Double.init).map { $0 / 1000 } }
    }
    let stats: Stats?
    let workers: [Worker]?

    var unlockedPRL: Double { (stats?.unlocked ?? 0) / 1e8 }
    var lockedPRL: Double { (stats?.locked ?? 0) / 1e8 }
    var paidPRL: Double { (stats?.paid ?? 0) / 1e8 }
}

/// The richer `/api/stats?v=2` payload: pool hashrate (stats.hashrate, H/s), per-block
/// fee, network block reward, and a clean JSON `blocks` array (timestamp in ms, reward
/// atomic, status) — enough to measure 24h/1h出块 and 24h收益/PH for the comparison table.
struct LuckyV2: Decodable {
    struct Config: Decodable { let fee: Double? }
    struct Stats: Decodable { let hashrate: Double? }   // pool hashrate, H/s
    struct Network: Decodable { let reward: Double? }   // atomic, per block
    struct Block: Decodable { let timestamp: Double?; let reward: Double?; let status: String? }
    let config: Config?
    let stats: Stats?
    let network: Network?
    let blocks: [Block]?
}

struct LuckyPoolClient {
    func stats() async throws -> LuckyStats {
        var req = URLRequest(url: URL(string: "https://pearl.luckypool.io/api/stats")!)
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(poolBrowserUA, forHTTPHeaderField: "User-Agent")
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(LuckyStats.self, from: d)
    }

    /// `/api/stats?v=2` — pool hashrate + the JSON blocks array (the `?v=2` is the
    /// key the SPA uses; the bare `/api/stats` omits blocks). Powers LuckyPool's
    /// 24h出块 / 1h出块 / 24h收益/PH in the comparison table.
    func statsV2() async throws -> LuckyV2 {
        var req = URLRequest(url: URL(string: "https://pearl.luckypool.io/api/stats?v=2")!)
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(poolBrowserUA, forHTTPHeaderField: "User-Agent")
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(LuckyV2.self, from: d)
    }

    /// Per-miner stats; nil if the address isn't mining on Lucky Pool (404) or is empty.
    func minerStats(_ address: String) async throws -> LuckyMiner? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else { return nil }
        guard var comps = URLComponents(string: "https://pearl.luckypool.io/api/stats_address") else { return nil }
        comps.queryItems = [.init(name: "address", value: addr)]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData   // refresh = fetch live miner stats
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let m = try JSONDecoder().decode(LuckyMiner.self, from: d)
        return m.stats == nil ? nil : m
    }
}

// PearlHash lives in PearlHash.swift — it outgrew a stats-only client once it gained
// per-miner watches (see that file for its endpoints).

// MARK: - HeroMiners (英雄池) — pearl.herominers.com (cryptonote-nodejs-pool fork)
// Pool抽水 0%（促销至 2026-08-01，config.fee == 0），但 PRL 仅 SRBMiner 可挖，
// 矿工端 SRBMiner 抽水约 3% —— 这才是矿工的实际成本，故总览按 3% 展示。
// Per-miner: GET /api/stats_address?address=  →  { stats, workers, unconfirmed,
//   unlocked, payments }. This fork does NOT return stats.balance/stats.paid —
//   待支付 lives at the top level as block-share lists (`unconfirmed` = immature,
//   `unlocked` = matured awaiting payout), each entry's `reward` being THIS
//   miner's cut in ATOMIC units (÷ coinUnits 1e8 = PRL); lifetime paid comes from
//   the alternating `payments` list. stats.hashrate / hashrate_1h / hashrate_24h
//   are H/s; workers[] carry the same.
// Pool-level:  GET /api/stats  →  { config, pool, network } for the 矿池总览 card.

/// HeroMiners is inconsistent about JSON types — amounts (balance/paid) and
/// stats.lastShare arrive as strings, while hashrates and worker.lastShare arrive
/// as numbers, even within one response. Decode either form to a Double.
struct FlexDouble: Decodable {
    let value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self), let d = Double(s) { value = d }
        else { value = 0 }
    }
}

struct HeroMinerStats: Decodable {
    struct Stats: Decodable {
        let hashrate: FlexDouble?        // current H/s
        let hashrate_1h: FlexDouble?
        let hashrate_24h: FlexDouble?
        let balance: FlexDouble?         // atomic, pending
        let paid: FlexDouble?            // atomic, lifetime
        let lastShare: FlexDouble?       // unix seconds
    }
    struct Worker: Decodable {
        let name: String?
        let hashrate: FlexDouble?        // current H/s
        let hashrate_1h: FlexDouble?     // 1h rolling average
        let hashrate_24h: FlexDouble?
        let lastShare: FlexDouble?
    }
    /// One block this miner contributed to: the reward is the miner's own cut
    /// of that block (atomic), NOT the full block reward. The API ships these in
    /// TWO shapes — `unconfirmed` as objects ({"reward":"8819143","status":"pending",…})
    /// and `unlocked` as alternating colon-joined strings + bare unix timestamps
    /// ("height:hash:diff:blockReward:reward:shares:…:status:…", "1781126201", …) —
    /// so decode both; a bare timestamp carries no reward.
    struct BlockShare: Decodable {
        let rewardAtomic: Double?
        let status: String?
        init(from decoder: Decoder) throws {
            if let c = try? decoder.singleValueContainer(), let s = try? c.decode(String.self) {
                let p = s.split(separator: ":")
                rewardAtomic = p.count > 4 ? Double(p[4]) : nil
                status = p.count > 7 ? String(p[7]) : nil
            } else {
                let k = try decoder.container(keyedBy: CodingKeys.self)
                rewardAtomic = try k.decodeIfPresent(FlexDouble.self, forKey: .reward)?.value
                status = try k.decodeIfPresent(String.self, forKey: .status)
            }
        }
        private enum CodingKeys: String, CodingKey { case reward, status }
    }
    let stats: Stats?
    let workers: [Worker]?
    let unconfirmed: [BlockShare]?   // immature block shares (pending depth)
    /// RECENT-BLOCK HISTORY, capped at `recentBlocksAmount` (20) and including
    /// orphaned + already-paid blocks — NOT a pending-payout list. Decoded only
    /// so the payload stays parseable; never sum it into 待支付.
    let unlocked: [BlockShare]?
    /// Alternating ["txHash:amount:fee:recipients", "timestamp", …]; amount atomic.
    /// Also capped at 20 entries — stats.paid is the true lifetime total.
    let payments: [String]?

    /// Immature block shares (atomic), orphans excluded. Matured-but-unpaid lives
    /// in stats.balance now that the pool ships it — the caller adds the two.
    var pendingAtomic: Double {
        (unconfirmed ?? []).reduce(0) { $0 + ($1.status == "orphaned" ? 0 : ($1.rewardAtomic ?? 0)) }
    }
    /// Lifetime paid (atomic). Bare-timestamp entries have no ":" fields and are skipped.
    var paidAtomic: Double {
        (payments ?? []).reduce(0.0) { sum, e in
            let p = e.split(separator: ":")
            guard p.count >= 2, let amt = Double(p[1]) else { return sum }
            return sum + amt
        }
    }
}

/// Pool-level stats for the 矿池总览 card (GET /api/stats). hashrate is H/s;
/// miners/workers are counts; config.fee is the pool抽水 (0). All numeric fields
/// arrive as numbers here, but stay FlexDouble-tolerant for safety.
struct HeroPoolStats: Decodable {
    struct Config: Decodable { let fee: FlexDouble? }
    struct Pool: Decodable {
        // PRL on HeroMiners reports two fields: `hashrate` is the TRUE value
        // right-shifted by 32 bits (≈803 MH/s — a difficulty-encoding artifact, NOT
        // the real rate), while `realHashrate` is the actual H/s (≈3.45 EH/s, on the
        // same scale as AlphaPool/network). Always prefer realHashrate.
        let hashrate: FlexDouble?
        let realHashrate: FlexDouble?
        let miners: Int?
        let workers: Int?
        let totalBlocks: Int?
        let averageReward: FlexDouble?     // atomic, per-block — ÷ coinUnits = PRL
        // Recent found blocks, each a colon-joined string:
        //   "hash:time:diff:…:status:reward:address:region:type:" — fields [1]=unix
        //   time, [6]=status (pending/unlocked/orphaned), [7]=reward (atomic).
        let blocks: [String]?
    }
    let config: Config?
    let pool: Pool?
}

struct HeroMinersClient {
    static let coinUnits = 100_000_000.0   // config.coinUnits — atomic → PRL
    static let poolFee = 0.0               // config.fee == 0 (matches AlphaPool/Lucky semantics)
    /// Effective miner cost: pool is 0%, but PRL needs SRBMiner whose dev抽水 ≈ 3%.
    static let fee = 3.0
    /// HeroMiners reports PRL hashrate right-shifted by 32 bits — both the pool
    /// `hashrate` field (≈803 MH/s vs real 3.45 EH/s) and EVERY per-miner/worker
    /// hashrate (verified against a payout's recipients: a 1-GPU rig shows ~52 kH/s,
    /// ×2^32 → ~226 TH/s). Pool-level has `realHashrate`; per-miner has no corrected
    /// field, so multiply its hashrates by this to recover real H/s.
    static let hashScale = 4_294_967_296.0   // 2^32

    /// Pool-wide stats (hashrate / miners / workers / fee) for the address-free
    /// 矿池总览. Throws on a network/HTTP failure so the card shows its inline error.
    func stats() async throws -> HeroPoolStats {
        var req = URLRequest(url: URL(string: "https://pearl.herominers.com/api/stats")!)
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(poolBrowserUA, forHTTPHeaderField: "User-Agent")
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(HeroPoolStats.self, from: d)
    }

    /// Per-miner stats; nil if the address has no activity on HeroMiners (so the
    /// card shows "未在 HeroMiners 挖矿" rather than a query error). A genuine
    /// network/HTTP failure throws so it surfaces as "查询失败".
    func minerStats(_ address: String) async throws -> HeroMinerStats? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else { return nil }
        var c = URLComponents(string: "https://pearl.herominers.com/api/stats_address")!
        c.queryItems = [.init(name: "address", value: addr), .init(name: "longpoll", value: "false")]
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData   // refresh = fetch live miner stats
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let m = try JSONDecoder().decode(HeroMinerStats.self, from: d)
        let s = m.stats
        let active = (s?.hashrate?.value ?? 0) > 0 || (s?.balance?.value ?? 0) > 0
            || (s?.paid?.value ?? 0) > 0 || (s?.lastShare?.value ?? 0) > 0 || !(m.workers ?? []).isEmpty
            || m.pendingAtomic > 0 || m.paidAtomic > 0
        return active ? m : nil
    }
}

// MARK: - Pearl Fortune — pearlfortune.org (public-pool fork, PPLNS, read-only API)
// Per-miner data spans 3 endpoints, all enveloped in {"data": …}:
//   /api/v1/miners/{addr}              → balance + pending estimate + hourly share series
//   /api/v1/miners/{addr}/connections  → live workers + reported hashrate
//   /api/v1/miners/{addr}/ledger       → lifetime credited / paid-out totals
// `_atomic` amounts are ÷ atomic_units (1e8); the API returns ledger amounts as
// STRINGS, so those go through FlexDouble. There's no per-miner hashrate field —
// it's derived per hour as (this miner's share fraction × pool hashrate).
private struct PFEnvelope<T: Decodable>: Decodable { let data: T? }

struct PFMinerDetail: Decodable {
    struct Balance: Decodable { let balance_atomic: Double? }
    struct Pending: Decodable { let pending_estimate_amount_atomic: Double? }
    struct Hourly: Decodable {
        struct Point: Decodable { let share_sum: Double?; let total_share_sum: Double?; let pool_hashrate: Double? }
        /// Server-computed per-miner rolling average hashrate (H/s), one entry per
        /// window (hours = 1 / 8 / 24). Only present for active miners — absent for
        /// addresses with no recent shares, so the share-series derivation stays as
        /// a fallback.
        struct Rolling: Decodable { let hours: Int?; let hashrate: Double? }
        let series: [Point]?
        let rolling_hashrates: [Rolling]?
    }
    let balance: Balance?
    let pending_shares: Pending?
    let hourly_shares: Hourly?
}

struct PFConnections: Decodable {
    struct Summary: Decodable { let reported_hashrate: Double? }
    struct Worker: Decodable {
        let worker: String?            // worker name (NB: key is `worker`, not `worker_name`)
        let reported_hashrate: Double?
        let stale: Bool?               // online == !stale
    }
    let configured: Bool?
    let online: Bool?
    let workers: [Worker]?
    let summary: Summary?
}

struct PFLedger: Decodable {
    let sum_payout_amount_coin: FlexDouble?   // PRL, lifetime paid out (string in JSON)
    let sum_credit_amount_coin: FlexDouble?   // PRL, lifetime credited
}

struct PFMiner { let detail: PFMinerDetail; let conn: PFConnections?; let ledger: PFLedger? }

/// Pool-wide summary (no address) from /api/v1/summary — fee, network hashrate,
/// and a `rolling_stats` breakdown keyed by window (1h / 8h / 24h) carrying this
/// pool's hashrate, block count, and per-hash daily yield. Powers Pearl Fortune's
/// row in the overview comparison table.
struct PFSummary: Decodable {
    struct Stats: Decodable { let network_hashrate: String? }   // e.g. "31.36 EH/s"
    struct Rolling: Decodable {
        let hours: Int?
        let hashrate: Double?      // pool average over the window, H/s
        let total_coins: Double?   // PRL the pool mined within the window
        let block_count: Int?      // pool blocks found within the window
    }
    struct PoolStats: Decodable {
        let pool_fee_rate: Double?   // fraction (0.01 = 1%)
        let rolling_stats: [Rolling]?
    }
    let stats: Stats?
    let pool_stats: PoolStats?
}

struct PearlFortuneClient {
    static let atomicUnits = 100_000_000.0
    private let base = "https://pearlfortune.org"

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T? {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.cachePolicy = .reloadIgnoringLocalCacheData   // refresh = fetch live miner stats
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(PFEnvelope<T>.self, from: d).data
    }

    /// Per-miner snapshot across detail + connections + ledger (fetched
    /// concurrently). nil if the address has never mined here. The connections
    /// `configured` flag is true for ANY queried address, so it can't gate
    /// "mining here" — real signals (balance / pending / payouts / live workers) do.
    func minerStats(_ address: String) async throws -> PFMiner? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty,
              let enc = addr.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        async let detail = get("/api/v1/miners/\(enc)", as: PFMinerDetail.self)
        async let conn = get("/api/v1/miners/\(enc)/connections", as: PFConnections.self)
        async let ledger = get("/api/v1/miners/\(enc)/ledger", as: PFLedger.self)
        guard let d = try await detail else { return nil }
        let c = (try? await conn) ?? nil
        let l = (try? await ledger) ?? nil
        let bal = d.balance?.balance_atomic ?? 0
        let pend = d.pending_shares?.pending_estimate_amount_atomic ?? 0
        let paid = l?.sum_payout_amount_coin?.value ?? 0
        let workers = c?.workers?.count ?? 0
        if bal == 0 && pend == 0 && paid == 0 && workers == 0 { return nil }
        return PFMiner(detail: d, conn: c, ledger: l)
    }

    /// Address-free pool summary for the overview table (fee · 出块 · 收益/PH · 算力).
    func summary() async throws -> PFSummary {
        guard let s = try await get("/api/v1/summary", as: PFSummary.self) else {
            throw URLError(.badServerResponse)
        }
        return s
    }
}

// MARK: - F2Pool (鱼池) — the account's read-only page
//
// F2Pool has no public per-address API. Its v2 API doesn't list `pearl` as a currency at
// all (and the hashrate module is bitcoin/bitcoin-cash/litecoin only), and v1
// (`api.f2pool.com/pearl/{account}`) now demands an account-wide `F2P-API-SECRET` token
// that ALSO authorises withdrawals — not something to ship in a watch-only app.
//
// What is public is the account's *read-only page*: a revocable share link the user
// creates on f2pool. The tables on that page are fed by JSON `action=…` endpoints on the
// page's own URL, gated solely by the `X-Requested-With: XMLHttpRequest` header — without
// it the server answers 200 with the 280 KB HTML page instead of JSON.
//
// So a F2Pool watch stores that page URL rather than a PRL address. The 32-hex `key` is
// the identity: the server resolves the account from it and ignores a wrong `account`
// param. We still send `user_name`/`account` to mirror what the real page sends.
enum F2PoolError: Error { case http(Int) }

struct F2PoolRef: Equatable {
    let key: String        // read-only key — the capability
    let account: String    // f2pool account name (display + mirrors the page's params)

    /// Canonical form, persisted in `PoolWatch.address`. Note the coin slug: F2Pool SHARES
    /// the coin-less `/mining-user/{key}`, but only `-prl` answers the AJAX endpoints
    /// (`-pearl` 404s), so the stored URL is always rewritten to the form the client calls.
    /// Built through URLComponents so a spaced/CJK account name is percent-encoded — the
    /// stored URL is re-parsed on every load, and a raw space would fail URLComponents and
    /// make the watch silently vanish.
    var pageURL: String {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "www.f2pool.com"
        c.path = "/mining-user-prl/\(key)"
        if !account.isEmpty { c.queryItems = [URLQueryItem(name: "user_name", value: account)] }
        return c.string ?? "https://www.f2pool.com/mining-user-prl/\(key)"
    }

    /// Parse a pasted read-only-page link. Deliberately forgiving about the SHAPE of the
    /// paste: what F2Pool's share button hands out is `/mining-user/{key}` (no coin slug),
    /// on a phone it usually arrives wrapped in chat text or missing its scheme, and it may
    /// carry a locale prefix. Only the key is non-negotiable — it is the whole capability,
    /// and a wrong one just 404s (→ "未在此矿池") rather than silently reporting someone else.
    init?(_ raw: String) {
        // Pick the link out of whatever was pasted ("我的只读页 https://… 请查收").
        guard let r = raw.range(of: #"(?i)(https?://)?[a-z0-9.-]*f2pool\.com(/\S*)?"#,
                                options: .regularExpression) else { return nil }
        var s = String(raw[r]).trimmingCharacters(in: CharacterSet(charactersIn: "。，、）)]》」』.,;"))
        // Without a scheme, URLComponents parses the host as a path and `host` comes back nil.
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let c = URLComponents(string: s), (c.host ?? "").hasSuffix("f2pool.com") else { return nil }
        // Take the first key-shaped segment AFTER the page slug — scanning forward (rather
        // than demanding slug+1) accepts `/mining-user/{key}`, `/mining-user-prl/{key}` and a
        // coin that sits in its own segment alike.
        let parts = c.path.split(separator: "/").map(String.init)
        guard let slug = parts.firstIndex(where: { $0.hasPrefix("mining-user") }),
              let k = parts[(slug + 1)...].first(where: { $0.count >= 16 && $0.allSatisfy(\.isHexDigit) })
        else { return nil }
        key = k.lowercased()
        account = c.queryItems?.first { $0.name == "user_name" }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// One rig. F2Pool mixes JSON types across sibling fields (`hashrate` is a string,
/// `stalerate` a number), hence FlexDouble throughout.
struct F2Worker: Decodable {
    let name: String?
    let hashrate: FlexDouble?           // TH/s — pre-scaled to the currency's `scale: "T"`
    let hashrate_last_day: FlexDouble?  // TH/s
    let last_share: Double?             // unix seconds
    let status: Int?                    // 0 online · 1 offline · 2 dead
}

/// ⚠️ Account-level hashrates are RAW H/s here, unlike the per-worker TH/s above —
/// verified live: summary.hash_rate "12509998964918.04" alongside worker "12.51".
struct F2Summary: Decodable {
    let hash_rate: FlexDouble?          // raw H/s, 15-minute window
    let hash_rate_daily: FlexDouble?    // raw H/s, 24-hour window
}

struct F2OriginData: Decodable {
    let summary: F2Summary?
    let workers: [F2Worker]?
    let worker_length_all: Int?
    let worker_length_online: Int?
}

struct F2WorkersResp: Decodable {
    let status: String?
    let originData: F2OriginData?
}

private struct F2Payout: Decodable { let amount: FlexDouble? }
private struct F2PayoutsResp: Decodable { let data: [F2Payout]? }

/// The two figures the read-only page renders only as HTML.
struct F2Revenue {
    let balance: Double     // settled, accumulating toward the 1.0 PRL payout threshold
    let estToday: Double    // this UTC day's PPS estimate — not in `balance` until 00:00 UTC
}

/// Everything the F2Pool watch card needs, gathered from the read-only page.
struct F2Miner {
    let workers: [F2Worker]
    let summary: F2Summary?
    let total: Int
    let online: Int
    let balance: Double
    let estToday: Double
    let paid: Double
}

struct F2PoolClient {
    /// Per-worker hashrates arrive in TH/s; ×1e12 recovers real H/s.
    static let hashScale = 1e12

    let ref: F2PoolRef
    private var base: String { "https://www.f2pool.com/mining-user-prl/\(ref.key)" }

    /// The page's own AJAX transport. `X-Requested-With` is load-bearing, not politeness.
    private func get(_ items: [URLQueryItem], timeout: TimeInterval = 20) async throws -> Data {
        guard var c = URLComponents(string: base) else { throw URLError(.badURL) }
        c.queryItems = [URLQueryItem(name: "user_name", value: ref.account)] + items
        guard let url = c.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        req.setValue(poolBrowserUA, forHTTPHeaderField: "User-Agent")
        let (d, r) = try await URLSession.shared.data(for: req)
        guard let code = (r as? HTTPURLResponse)?.statusCode else { throw URLError(.badServerResponse) }
        guard code == 200 else { throw F2PoolError.http(code) }   // 404 = revoked / mistyped key
        return d
    }

    /// Workers + account hashrate summary. `currency` is required: omit it and the server
    /// falls back to rendering the HTML page.
    func workers() async throws -> F2WorkersResp {
        let d = try await get([.init(name: "action", value: "get_pagination_workers"),
                               .init(name: "account", value: ref.account),
                               .init(name: "currency", value: "PRL")])
        return try JSONDecoder().decode(F2WorkersResp.self, from: d)
    }

    /// Lifetime paid = Σ of the payout table, which this action returns in full (unpaginated).
    func totalPaid() async throws -> Double {
        let d = try await get([.init(name: "action", value: "load_payout_history_outcome"),
                               .init(name: "account", value: ref.account),
                               .init(name: "currency_code", value: "prl")])
        return (try JSONDecoder().decode(F2PayoutsResp.self, from: d).data ?? [])
            .reduce(0) { $0 + ($1.amount?.value ?? 0) }
    }

    /// A money amount as f2pool renders it, e.g. "1.15106604" or "1,234.5" — strip grouping
    /// separators before parsing, or a comma silently truncates the value.
    private static func amount(_ s: Substring) -> Double {
        Double(s.replacingOccurrences(of: ",", with: "")) ?? 0
    }

    /// Balance and today's estimate are the figures with NO JSON action — both are
    /// server-rendered. Each has a stable, language-independent hook:
    ///   • balance      → `<span class="balance-num" data-balance=1.23…>` (attribute unquoted)
    ///   • today's est. → the `.num` cell right after the `revenue-est-today-tooltip` marker
    /// (Anchoring on the CSS class, not the label text, is what survives `?lang=`.)
    ///
    /// Both default to 0 rather than throwing: a markup change must degrade the card, not
    /// break it. Note f2pool settles PPS once a day at 00:00 UTC — until then the day's
    /// earnings sit in `estToday` and `balance` reads 0.
    func revenue() async throws -> F2Revenue {
        guard var c = URLComponents(string: base) else { throw URLError(.badURL) }
        c.queryItems = [URLQueryItem(name: "user_name", value: ref.account)]
        guard let url = c.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(poolBrowserUA, forHTTPHeaderField: "User-Agent")
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: d, encoding: .utf8) else { return F2Revenue(balance: 0, estToday: 0) }

        var balance = 0.0
        if let m = html.range(of: "data-balance=\"?[0-9][0-9.,]*", options: .regularExpression),
           let num = html[m].split(separator: "=").last {
            balance = Self.amount(num.drop { $0 == "\"" })
        }
        var est = 0.0
        if let anchor = html.range(of: "revenue-est-today-tooltip"),
           let cell = html.range(of: "class=\"num\"", range: anchor.upperBound..<html.endIndex),
           let num = html.range(of: "[0-9][0-9.,]*", options: .regularExpression,
                                range: cell.upperBound..<html.endIndex) {
            est = Self.amount(html[num])
        }
        return F2Revenue(balance: balance, estToday: est)
    }

    /// One snapshot. Workers decide whether the key is live; revenue/paid are best-effort so
    /// a hiccup on either can't blank an otherwise healthy card.
    func minerStats() async throws -> F2Miner? {
        async let rev = try? revenue()
        async let pd = try? totalPaid()
        let w = try await workers()
        guard let o = w.originData else { return nil }
        let r = await rev
        return F2Miner(workers: o.workers ?? [], summary: o.summary,
                       total: o.worker_length_all ?? (o.workers?.count ?? 0),
                       online: o.worker_length_online ?? 0,
                       balance: r?.balance ?? 0, estToday: r?.estToday ?? 0,
                       paid: await pd ?? 0)
    }
}
