import Foundation

// MARK: - Jetski Pool (pearl.jetskipool.ai — the site titles itself PEARLSKI; PPLNS) — per miner
//   GET /api/stats/<address> → the account and every worker, rates in raw H/s, amounts in
//   grains (÷ 1e8 = PRL). A stranger gets 200 with zeros and no workers; an address the pool
//   can't parse gets 400.
//
// The pool calculates each rate from verified shares over 5m / 10m / 1h / 6h (`hashrate_5m`
// …); the unsuffixed per-worker `hashrate` is what the miner REPORTS and is often null, so it
// is never used. 5m is the pool's own headline figure (its account `hashrate` equals it), so
// it is the live rate here; 10m is left out — it sits between live and 15分 and is never more
// than a smoother copy of the 5m one.

struct JetskiMiner: Decodable, Sendable {
    struct Worker: Decodable, Sendable {
        let worker: String?              // "<address>.<name>"
        let hashrate_5m: FlexDouble?
        let hashrate_1h: FlexDouble?
        let hashrate_6h: FlexDouble?
        let last_share_time: FlexDouble? // unix seconds; null = never shared
    }
    let hashrate_5m: FlexDouble?
    let hashrate_1h: FlexDouble?
    let hashrate_6h: FlexDouble?
    let current_balance_grains: FlexDouble?          // matured, waiting for the next payout
    let pending_balance_grains: FlexDouble?          // still confirming
    let estimated_pending_balance_grains: FlexDouble?
    let total_paid_grains: FlexDouble?
    let rolling_24h_mined_grains: FlexDouble?
    let accepted_shares: FlexDouble?
    let last_share_time: FlexDouble?
    let workers: [Worker]?

    /// Has this address ever mined here? (The pool answers a stranger with all zeros.)
    var known: Bool {
        !(workers ?? []).isEmpty
            || [last_share_time, current_balance_grains, pending_balance_grains, total_paid_grains,
                rolling_24h_mined_grains, accepted_shares].contains { ($0?.value ?? 0) > 0 }
    }
}

enum JetskiSource: PoolMinerSource {
    static let grainsPerPRL = 100_000_000.0
    /// The pool's own page marks a worker stale 10 minutes after its last share.
    static let staleAfter = 600.0

    static func miner(_ id: String, scope: PoolScope) async throws -> PoolMinerStats? {
        guard let a = pathComponent(id) else { return nil }
        return try parse(try await PoolHTTP.get("https://pearl.jetskipool.ai/api/stats/\(a)", timeout: scope.timeout),
                         now: Date().timeIntervalSince1970)
    }

    /// The name the pool's page shows: what follows "<address>."; a rig that logged in with the
    /// bare address keeps it whole (as on the page), and one with no name at all is "default".
    static func workerName(_ raw: String?) -> String {
        let s = raw ?? ""
        guard let dot = s.firstIndex(of: ".") else { return s.isEmpty ? "default" : s }
        let name = s[s.index(after: dot)...]
        return name.isEmpty ? "default" : String(name)
    }

    static func parse(_ data: Data, now: Double) throws -> PoolMinerStats? {
        let m = try PoolHTTP.decode(JetskiMiner.self, from: data)
        guard m.known else { return nil }
        var s = PoolMinerStats()
        s.windows = [.live, .hour, .h6]
        s.rates = [.live: m.hashrate_5m?.value ?? 0,
                   .hour: m.hashrate_1h?.value ?? 0,
                   .h6:   m.hashrate_6h?.value ?? 0]
        // 待支付 = matured awaiting payout + still confirming — the pool's two tiles.
        let confirming = (m.pending_balance_grains?.value ?? 0).nonZeroOr(m.estimated_pending_balance_grains?.value ?? 0)
        s.pending = ((m.current_balance_grains?.value ?? 0) + confirming) / grainsPerPRL
        s.paid = (m.total_paid_grains?.value ?? 0) / grainsPerPRL
        s.workers = (m.workers ?? []).map { w in
            WatchWorker(name: workerName(w.worker),
                        online: (w.last_share_time?.value).map { $0 > 0 && now - $0 < staleAfter } ?? false,
                        rates: [.live: w.hashrate_5m?.value ?? 0,
                                .hour: w.hashrate_1h?.value ?? 0,
                                .h6:   w.hashrate_6h?.value ?? 0])
        }
        .sorted(by: onlineFirst)
        return s
    }
}
