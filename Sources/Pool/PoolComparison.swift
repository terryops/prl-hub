import Foundation

/// The public snapshot used by both Web and the app. Upstream parsing, measurement
/// windows and yield calculations belong to the service; personal miner data does not.
struct SharedOverview: Decodable, Sendable {
    struct Network: Decodable, Sendable {
        let ts: Double?
        let difficulty, hashrate, blockTime, reward, prlPerTHDay: Double?
        let difficulty24h, difficulty3d, difficulty7d: Double?

        func isUsable(at date: Date) -> Bool {
            guard let ts, ts > 0, date.timeIntervalSince1970 - ts <= 900,
                  ts <= date.timeIntervalSince1970 + 60,
                  let difficulty, difficulty > 0,
                  let hashrate, hashrate > 1e12, hashrate < 1e24 else { return false }
            return true
        }
    }
    struct Row: Decodable, Sendable {
        struct Point: Decodable, Sendable { let ts: Double; let hashrate: Double? }
        struct Payout: Decodable, Sendable {
            let scheme: String?
            let fee, grossPerPH: Double?
            let estimated, solo: Bool
        }
        let id, name, url: String
        let hashrate, share, fee: Double?
        let scheme: String?
        let solo: Bool
        let miners, blocksSample: Int?
        let blocksPerDay, sampleDays, earningsPerPH, theoreticalEarningsPerPH: Double?
        let trustworthy: Bool
        let source: String
        let hashFromPoolAPI, feeFromPoolAPI: Bool?
        let history: [Point]?
        let averageHashrate7d, lastBlockTime: Double?
        let lifetimeBlocks: Int?
        let payouts: [Payout]?
        var realFeeMeasurement: PPSFeeMeasurement? = nil
    }
    let ok: Bool
    let ts: Double
    let source: String
    let network: Network?
    let rows: [Row]
    let partial, stale: Bool

    func isUsable(at date: Date) -> Bool {
        ok && !stale && ts > 0 && ts <= date.timeIntervalSince1970 + 60 &&
            date.timeIntervalSince1970 - ts <= 900 &&
            (!rows.isEmpty || network?.isUsable(at: date) == true)
    }
}

/// Pool overview and the calculator share one request and a five-minute cache.
/// An explicit refresh bypasses the local TTL, while the service controls upstream polling.
actor SharedPublicData {
    static let shared = SharedPublicData()
    private let load: @Sendable () async throws -> SharedOverview
    private var cached: SharedOverview?
    private var fetchedAt: Date?
    private var inFlight: Task<SharedOverview, Error>?

    init(load: @escaping @Sendable () async throws -> SharedOverview = { try await SharedPublicData.fetch() }) {
        self.load = load
    }

    func overview(force: Bool = false, at date: Date = Date()) async throws -> SharedOverview {
        if !force, let cached, let fetchedAt, date.timeIntervalSince(fetchedAt) < 300,
           cached.isUsable(at: date) { return cached }
        if let inFlight { return try await inFlight.value }
        let task = Task {
            let value = try await load()
            guard value.isUsable(at: date) else { throw URLError(.badServerResponse) }
            return value
        }
        inFlight = task
        defer { inFlight = nil }
        let value = try await task.value
        guard value.isUsable(at: date) else { throw URLError(.badServerResponse) }
        cached = value
        fetchedAt = date
        return value
    }

    private static func fetch() async throws -> SharedOverview {
        var request = URLRequest(url: URL(string: "https://pearlhub.net/v1/pools")!)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(SharedOverview.self, from: data)
    }
}

// Pool-LEVEL clients for the 矿池总览 (address-free) — Lucky Pool, HeroMiners, Pearl Fortune.
// Their per-MINER halves (what a 我的监控 card reads) live in Sources/WidgetShared/Pools/,
// shared with the widget extension; hashrate formatting/parsing and FlexDouble live there too.
//
// `live`: an explicit (pull-to-)refresh must reach the pool; the overview's own cached loads
// pass false so the shared URLCache can honour the pool's Cache-Control.

// MARK: - Lucky Pool (open-ethereum-pool fork) — pearl.luckypool.io

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
    /// `/api/stats?v=2` — pool hashrate + the JSON blocks array (the `?v=2` is the
    /// key the SPA uses; the bare `/api/stats` omits blocks). Powers LuckyPool's
    /// 24h出块 / 1h出块 / 24h收益/PH in the comparison table.
    func statsV2(live: Bool = true) async throws -> LuckyV2 {
        try PoolHTTP.decode(LuckyV2.self, from: try await PoolHTTP.get("https://pearl.luckypool.io/api/stats?v=2", live: live))
    }
}

// MARK: - HeroMiners (英雄池) — pearl.herominers.com (cryptonote-nodejs-pool fork)
// Pool fee comes from config.fee. Miner software fees depend on the chosen software
// and are not part of the address-free pool's yield comparison.
// Pool-level:  GET /api/stats  →  { config, pool, network } for the 矿池总览 card.

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

    /// Real pool H/s: `realHashrate`, else the >>32 `hashrate` scaled back up — used raw,
    /// that fallback put the pool at ~0% of the network and its 收益/PH ~4 billion× high.
    var poolHashrate: Double? {
        if let r = pool?.realHashrate?.value, r > 0 { return r }
        return (pool?.hashrate?.value).flatMap { $0 > 0 ? $0 * HeroMinersSource.hashScale : nil }
    }
}

struct HeroMinersClient {
    static let coinUnits = HeroMinersSource.coinUnits
    /// Pool-wide stats (hashrate / miners / workers / fee) for the address-free
    /// 矿池总览. Throws on a network/HTTP failure so the card shows its inline error.
    func stats(live: Bool = true) async throws -> HeroPoolStats {
        try PoolHTTP.decode(HeroPoolStats.self, from: try await PoolHTTP.get("https://pearl.herominers.com/api/stats", live: live))
    }
}

// MARK: - Pearl Fortune — pearlfortune.org (public-pool fork, PPLNS, read-only API)

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
        let expected_coins: Double? // theoretical PRL for the same window and credited work
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
    /// Address-free pool summary for the overview table (fee · 出块 · 收益/PH · 算力).
    func summary(live: Bool = true) async throws -> PFSummary {
        guard let s = try PoolHTTP.decode(PFEnvelope<PFSummary>.self,
                                          from: try await PoolHTTP.get("https://pearlfortune.org/api/v1/summary", live: live)).data
        else { throw URLError(.badServerResponse) }
        return s
    }
}
