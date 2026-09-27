import Foundation

// MARK: - HeroMiners (英雄池, pearl.herominers.com, cryptonote-nodejs-pool fork) — per miner
//   GET /api/stats_address?address=&longpoll=false → { stats, workers, unconfirmed, unlocked,
//   payments }. A stranger gets 200 {"error":"Not found"}, so "not mining here" is decided from
//   the payload. stats.balance is matured-awaiting-payout; `unconfirmed` holds the immature
//   block shares, each entry's `reward` being THIS miner's cut in ATOMIC units (÷ 1e8 = PRL);
//   lifetime paid is stats.paid (the `payments` list is capped at 20).

struct HeroMinerStats: Decodable, Sendable {
    struct Stats: Decodable, Sendable {
        let hashrate: FlexDouble?        // current, >>32 (see HeroMinersSource.hashScale)
        let hashrate_1h: FlexDouble?
        let hashrate_24h: FlexDouble?
        let balance: FlexDouble?         // atomic, pending
        let paid: FlexDouble?            // atomic, lifetime
        let lastShare: FlexDouble?       // unix seconds
    }
    struct Worker: Decodable, Sendable {
        let name: String?
        let hashrate: FlexDouble?        // current, >>32
        let hashrate_1h: FlexDouble?     // 1h rolling average, >>32
        let hashrate_24h: FlexDouble?
        let lastShare: FlexDouble?
    }
    /// One block this miner contributed to: the reward is the miner's own cut
    /// of that block (atomic), NOT the full block reward. The API ships these in
    /// TWO shapes — `unconfirmed` as objects ({"reward":"8819143","status":"pending",…})
    /// and `unlocked` as alternating colon-joined strings + bare unix timestamps
    /// ("height:hash:diff:blockReward:reward:shares:…:status:…", "1781126201", …) —
    /// so decode both; a bare timestamp carries no reward.
    struct BlockShare: Decodable, Sendable {
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
    /// Alternating ["txHash:amount:fee:recipients", "timestamp", …]; amount atomic.
    /// Also capped at 20 entries — stats.paid is the true lifetime total.
    let payments: [String]?

    /// Immature block shares (atomic), orphans excluded. Matured-but-unpaid lives
    /// in stats.balance — the caller adds the two.
    var pendingAtomic: Double {
        (unconfirmed ?? []).reduce(0) { $0 + ($1.status == "orphaned" ? 0 : ($1.rewardAtomic ?? 0)) }
    }
    /// Lifetime paid (atomic) from the capped list. Bare-timestamp entries have no ":" fields
    /// and are skipped.
    var paidAtomic: Double {
        (payments ?? []).reduce(0.0) { sum, e in
            let p = e.split(separator: ":")
            guard p.count >= 2, let amt = Double(p[1]) else { return sum }
            return sum + amt
        }
    }

    /// Has this address ever mined here?
    var active: Bool {
        let s = stats
        return (s?.hashrate?.value ?? 0) > 0 || (s?.balance?.value ?? 0) > 0
            || (s?.paid?.value ?? 0) > 0 || (s?.lastShare?.value ?? 0) > 0 || !(workers ?? []).isEmpty
            || pendingAtomic > 0 || paidAtomic > 0
    }
}

enum HeroMinersSource: PoolMinerSource {
    static let coinUnits = 100_000_000.0   // config.coinUnits — atomic → PRL
    /// HeroMiners reports PRL hashrate right-shifted by 32 bits — both the pool
    /// `hashrate` field (≈803 MH/s vs real 3.45 EH/s) and EVERY per-miner/worker
    /// hashrate (verified against a payout's recipients: a 1-GPU rig shows ~52 kH/s,
    /// ×2^32 → ~226 TH/s). Pool-level has `realHashrate`; per-miner has no corrected
    /// field, so multiply its hashrates by this to recover real H/s.
    static let hashScale = 4_294_967_296.0   // 2^32

    static func miner(_ id: String, scope: PoolScope) async throws -> PoolMinerStats? {
        let addr = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty, var c = URLComponents(string: "https://pearl.herominers.com/api/stats_address")
        else { return nil }
        c.queryItems = [.init(name: "address", value: addr), .init(name: "longpoll", value: "false")]
        guard let url = c.url else { return nil }
        return try parse(try await PoolHTTP.get(url, timeout: scope.timeout), now: Date().timeIntervalSince1970)
    }

    static func parse(_ data: Data, now: Double) throws -> PoolMinerStats? {
        let m = try PoolHTTP.decode(HeroMinerStats.self, from: data)
        guard m.active else { return nil }
        let st = m.stats
        let scale = hashScale
        var s = PoolMinerStats()
        s.windows = [.live, .hour, .day]
        s.rates = [.live: (st?.hashrate?.value ?? 0) * scale,
                   .hour: (st?.hashrate_1h?.value ?? 0) * scale,
                   .day:  (st?.hashrate_24h?.value ?? 0) * scale]
        // 待支付 = matured awaiting payout (stats.balance) + immature block shares.
        s.pending = ((st?.balance?.value ?? 0) + m.pendingAtomic) / coinUnits
        let heroPaid = st?.paid?.value ?? 0
        s.paid = (heroPaid > 0 ? heroPaid : m.paidAtomic) / coinUnits
        s.workers = (m.workers ?? []).map { w in
            WatchWorker(name: w.name ?? "—",
                        online: (w.lastShare?.value).map { now - $0 < 600 } ?? false,
                        rates: [.live: (w.hashrate?.value ?? 0) * scale,
                                .hour: (w.hashrate_1h?.value ?? 0) * scale,
                                .day:  (w.hashrate_24h?.value ?? 0) * scale])
        }
        .sorted(by: onlineFirst)
        return s
    }
}
