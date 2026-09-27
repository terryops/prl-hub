import Foundation

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
// Pool抽水 0%（促销至 2026-08-01，config.fee == 0），但 PRL 仅 SRBMiner 可挖，
// 矿工端 SRBMiner 抽水约 3% —— 这才是矿工的实际成本，故总览按 3% 展示。
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
    /// Effective miner cost: pool is 0%, but PRL needs SRBMiner whose dev抽水 ≈ 3%.
    static let fee = 3.0

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
