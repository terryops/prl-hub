import Foundation

// MARK: - Kryptex (K 池) — pool.kryptex.com/prl
//
// The network's third-biggest PRL pool (~21% of hashrate, 2.7k miners). It was long treated
// here as a pool with no public API — it has one; the site simply never documents it. These
// paths come from the pool's own web app, and `prl-api.kryptex.network` is the same service
// behind another host, so the documented-looking `pool.kryptex.com/prl` form is used.
//
//   GET /prl/api/v1/pool/stats                  → miners · workers · hashrate · fee · reward
//   GET /prl/api/v1/pool/blocks                 → the pool's last blocks (height + time)
//   GET /prl/api/v3/miner/workers/{addr}        → per-rig status + 30m / 3h / 24h averages
//   GET /prl/api/v1/miner/balance/{addr}        → confirmed + unconfirmed (immature) balance
//   GET /prl/api/v1/miner/payouts/{addr}/stats  → lifetime paid + last week/month earned
//
// The per-miner endpoints answer 200 with zeros / [] for an address that never mined here, so
// "not mining on Kryptex" is a data question, not an HTTP one — nothing to special-case on 404.
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

/// `/miner/balance/{addr}` — `total` = confirmed + unconfirmed, where unconfirmed is the part
/// still maturing (100 blocks). Both are money the miner has earned, so 待支付 shows the total,
/// as it does for HeroMiners.
struct KryptexBalance: Decodable {
    let total: FlexDouble?
    let unconfirmed: FlexDouble?
    let confirmed: FlexDouble?
    let threshold: FlexDouble?     // payout threshold, PRL
    let last_active: FlexDouble?   // epoch MILLISECONDS, 0 = never mined here
}

/// `/miner/payouts/{addr}/stats` — `paid` is the LIFETIME total (the payouts list itself is
/// paginated, so it must not be summed for this), `unpaid` mirrors balance.confirmed.
struct KryptexPayoutStats: Decodable {
    struct Reward: Decodable { let week: FlexDouble?; let month: FlexDouble? }
    let reward: Reward?
    let paid: FlexDouble?
    let unpaid: FlexDouble?
}

/// One rig, from the v3 workers endpoint. Kryptex publishes 30-minute / 3-hour / 24-hour
/// rolling averages and NO instantaneous rate — its freshest figure is the 30-minute one.
struct KryptexWorker: Decodable {
    let worker: String?
    let scheme: String?              // "pps" · "solo" — a wallet can run both at once
    let status: String?              // "online" · "offline"
    let last_share: FlexDouble?      // epoch MILLISECONDS
    let avg_hashrate_30m: FlexDouble?
    let avg_hashrate_3h: FlexDouble?
    let avg_hashrate_24h: FlexDouble?

    var online: Bool { (status ?? "").caseInsensitiveCompare("online") == .orderedSame }
    /// Rig label. A wallet mining both schemes lists the same name twice, so the scheme is
    /// appended for solo rows — otherwise two rows read as one rig reported inconsistently.
    var displayName: String {
        let n = (worker ?? "").trimmingCharacters(in: .whitespaces)
        let base = n.isEmpty ? "—" : n
        return (scheme ?? "").caseInsensitiveCompare("solo") == .orderedSame ? base + " (SOLO)" : base
    }
}

private struct KryptexWorkersResp: Decodable { let results: [KryptexWorker]? }

/// One address's snapshot across the three per-miner endpoints.
struct KryptexMiner {
    let workers: [KryptexWorker]
    let balance: KryptexBalance?
    let payouts: KryptexPayoutStats?

    /// Everything earned and not yet paid out — matured plus still-maturing.
    var pending: Double { balance?.total?.value ?? 0 }
    var paid: Double { payouts?.paid?.value ?? 0 }
    /// Has this address ever mined here? Every endpoint answers 200 for a stranger, so the
    /// answer has to come from the payload: rigs, money, or a last-active stamp.
    var active: Bool {
        !workers.isEmpty || pending > 0 || paid > 0 || (balance?.last_active?.value ?? 0) > 0
    }
}

struct KryptexClient {
    private static let base = "https://pool.kryptex.com/prl"

    private func get<T: Decodable>(_ path: String, as: T.Type, timeout: TimeInterval = 20) async throws -> T {
        guard let url = URL(string: Self.base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData   // refresh must fetch live numbers
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(poolBrowserUA, forHTTPHeaderField: "User-Agent")
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: d)
    }

    /// Address-free pool stats for the 矿池总览.
    func poolStats() async throws -> KryptexPoolStats {
        try await get("/api/v1/pool/stats", as: KryptexPoolStats.self)
    }

    /// The pool's recent blocks — newest first, one page.
    func blocks() async throws -> [KryptexBlock] {
        try await get("/api/v1/pool/blocks", as: KryptexBlocksResp.self).results ?? []
    }

    /// Per-miner snapshot; nil when the address has never mined here (so the card says
    /// "未在此矿池挖矿" rather than showing a row of zeros). The workers call decides whether
    /// the pool answered at all — a failure there throws so the card retries; balance and
    /// payouts are best-effort, since a hiccup on either must not blank an otherwise good card.
    func minerStats(_ address: String) async throws -> KryptexMiner? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty,
              let enc = addr.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        async let bal = try? get("/api/v1/miner/balance/\(enc)", as: KryptexBalance.self)
        async let pay = try? get("/api/v1/miner/payouts/\(enc)/stats", as: KryptexPayoutStats.self)
        let workers = try await get("/api/v3/miner/workers/\(enc)", as: KryptexWorkersResp.self).results ?? []
        let m = KryptexMiner(workers: workers, balance: await bal, payouts: await pay)
        return m.active ? m : nil
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
