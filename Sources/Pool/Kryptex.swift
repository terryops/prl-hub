import Foundation

// MARK: - Kryptex (K 池) — prl-api.kryptex.network
//
// The network's third-biggest PRL pool (~21% of hashrate, 2.7k miners). It was long treated
// here as a pool with no public API — it has one; the site simply never documents it. These
// paths come from the pool's own web app, served by `prl-api.kryptex.network`.
//
// NOT `pool.kryptex.com/prl/api/…`: since 2026-09 that host sits behind an anti-bot wall that
// answers every non-browser request with 200 + a text/html JS cookie challenge (`__js_p_` →
// `__jhash_`), which fails to decode and reads as "pool unreachable". The API host has no
// such wall and takes the same paths WITHOUT the `/prl` prefix.
//
//   GET /api/v1/pool/stats                  → miners · workers · hashrate · fee · reward
//   GET /api/v1/pool/blocks                 → the pool's last blocks (height + time)
//   GET /api/v3/miner/workers/{addr}        → per-rig status + 30m / 3h / 24h averages
//   GET /api/v1/miner/balance/{addr}        → confirmed + unconfirmed (immature) balance
//   GET /api/v1/miner/payouts/{addr}/stats  → lifetime paid + last week/month earned
//
// The per-miner endpoints (KryptexSource, shared with the widget) answer 200 with zeros / [] for
// an address that never mined here, so "not mining on Kryptex" is a data question there.
//
// Every hashrate is REAL H/s (a rig reads "451547962638754.05" ≈ 451 TH/s, and the workers sum
// to the pool total) — no HeroMiners-style bit-shift, no F2Pool-style per-worker unit change.
// They do arrive as STRINGS while the pool-level ones are numbers, hence FlexDouble throughout.

/// `/pool/stats` — the pool as it describes itself. This is the only source that gets Kryptex's
/// CONTRACT right: both aggregators the overview is built from print "PROP" / "1%", while the
/// pool runs PPS+ at 2% (SOLO 1%). See `PoolsOverviewStore.applyKryptex`.
struct KryptexPoolStats: Decodable {
    let miners: Int?
    let workers: Int?
    let hashrate: FlexDouble?        // raw H/s
    let net_hashrate: FlexDouble?    // raw H/s, the pool's view of the network
    let fee: FlexDouble?             // FRACTION for the default (shared) mode: 0.02 = 2%
    let fee_type: String?            // "PPS+"
    let block_reward: FlexDouble?    // PRL, current subsidy
    let commission: [String: FlexDouble]?   // {"PPS+": 0.02, "SOLO": 0.01}
    /// The pool's CONFIGURED block time (120), not what the chain does (~240s). Decoded so the
    /// field isn't silently re-read as a measurement later — `blockTime(from:)` measures instead.
    let block_time: FlexDouble?

    /// Fee as a percentage, the unit the overview table renders.
    var feePercent: Double? { (fee?.value).flatMap { $0 > 0 ? $0 * 100 : nil } }
    var soloFeePercent: Double? { (commission?["SOLO"]?.value).flatMap { $0 > 0 ? $0 * 100 : nil } }
    var poolHashrate: Double? { (hashrate?.value).flatMap { $0 > 0 ? $0 : nil } }
    var networkHashrate: Double? { (net_hashrate?.value).flatMap { $0 > 0 ? $0 : nil } }
    var rewardPerBlock: Double? { (block_reward?.value).flatMap { $0 > 0 ? $0 : nil } }
}

/// One block the pool found. `height` is the NETWORK height, which is what makes this feed
/// useful beyond luck-counting: see `KryptexClient.blockTime`.
struct KryptexBlock: Decodable {
    let height: Int?
    let date: FlexDouble?     // unix seconds, as a string
    let reward: FlexDouble?   // PRL, as a string
}

private struct KryptexBlocksResp: Decodable { let results: [KryptexBlock]? }

struct KryptexClient {
    private func get<T: Decodable>(_ path: String, as: T.Type, live: Bool) async throws -> T {
        try PoolHTTP.decode(T.self, from: try await PoolHTTP.get(KryptexSource.base + path, live: live))
    }

    /// Address-free pool stats for the 矿池总览.
    func poolStats(live: Bool = true) async throws -> KryptexPoolStats {
        try await get("/api/v1/pool/stats", as: KryptexPoolStats.self, live: live)
    }

    /// The pool's recent blocks — newest first, one page.
    func blocks(live: Bool = true) async throws -> [KryptexBlock] {
        try await get("/api/v1/pool/blocks", as: KryptexBlocksResp.self, live: live).results ?? []
    }

    /// Seconds per block, MEASURED off the pool's block feed. Each entry carries the network
    /// height it was found at, so the span between the oldest and newest entry counts NETWORK
    /// blocks over real time — a chain measurement, not a count of this pool's luck (which is
    /// what a blocks-per-day figure would be). Kryptex's own `block_time` (120) is a config
    /// value, roughly half what the chain actually runs at, so it is never used for this.
    ///
    /// nil when the feed is too short to measure or the result is implausible — the caller
    /// then shows no yield rather than a wrong one.
    static func blockTime(from blocks: [KryptexBlock]) -> Double? {
        let pts = blocks.compactMap { b -> (h: Int, t: Double)? in
            guard let h = b.height, h > 0, let t = b.date?.value, t > 0 else { return nil }
            return (h, t)
        }.sorted { $0.h < $1.h }
        guard let first = pts.first, let last = pts.last, last.h > first.h else { return nil }
        let secs = (last.t - first.t) / Double(last.h - first.h)
        return (30...3600).contains(secs) ? secs : nil
    }

    /// Current subsidy as the MEDIAN of the feed's rewards — a mean would be pulled by a block
    /// that carried unusual fees, while the subsidy only steps at a halving.
    static func rewardPerBlock(from blocks: [KryptexBlock]) -> Double? {
        let r = blocks.compactMap { $0.reward?.value }.filter { $0 > 0 }.sorted()
        return r.isEmpty ? nil : r[r.count / 2]
    }
}
