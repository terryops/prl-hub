import Foundation

// MARK: - Peryn (peryn.ai; PPS+ and PPLNS) — per miner
//   GET https://app.peryn.ai/api/v1/miner/<address> → the account and every worker in one
//   reply: hashrates in raw H/s ("MAC/s", the same 2^48 basis as the network's), amounts as
//   PRL strings. A stranger gets 200 with zeros and no workers; an address the pool can't
//   parse (bad checksum, "<address>.<worker>") gets 400.
//
// The pool publishes a 1-hour and a 24-hour rate, both calculated from accepted shares, per
// account and per worker — no instantaneous one. Each worker carries its own `online` flag
// (the pool's page shows the same), so that is used as is.

struct PerynMiner: Decodable, Sendable {
    struct Worker: Decodable, Sendable {
        let name: String?
        let online: Bool?
        let hashrate1h: FlexDouble?
        let hashrate24h: FlexDouble?
    }
    struct Balance: Decodable, Sendable {
        let owedPrl: FlexDouble?      // credited, paid in the next 2-hourly batch (≥ 1 PRL)
        let pendingPrl: FlexDouble?   // credited, still confirming
        let paidPrl: FlexDouble?      // lifetime, sent to this address
    }
    struct Payout: Decodable, Sendable { let amountPrl: FlexDouble? }
    let hashrate1h: FlexDouble?
    let hashrate24h: FlexDouble?
    let workers: [Worker]?
    let balance: Balance?
    let payouts: [Payout]?

    /// Has this address ever mined here? (The pool answers a stranger with all zeros.)
    var known: Bool {
        !(workers ?? []).isEmpty || !(payouts ?? []).isEmpty
            || [hashrate1h, hashrate24h, balance?.owedPrl, balance?.pendingPrl, balance?.paidPrl]
                .contains { ($0?.value ?? 0) > 0 }
    }
}

enum PerynSource: PoolMinerSource {
    static func miner(_ id: String, scope: PoolScope) async throws -> PoolMinerStats? {
        guard let a = pathComponent(id) else { return nil }
        return try parse(try await PoolHTTP.get("https://app.peryn.ai/api/v1/miner/\(a)", timeout: scope.timeout))
    }

    static func parse(_ data: Data) throws -> PoolMinerStats? {
        let m = try PoolHTTP.decode(PerynMiner.self, from: data)
        guard m.known else { return nil }
        var s = PoolMinerStats()
        s.windows = [.hour, .day]
        s.rates = [.hour: m.hashrate1h?.value ?? 0, .day: m.hashrate24h?.value ?? 0]
        // 待支付 = owed (the page's "Balance") + still confirming.
        s.pending = (m.balance?.owedPrl?.value ?? 0) + (m.balance?.pendingPrl?.value ?? 0)
        s.paid = m.balance?.paidPrl?.value ?? 0
        s.workers = (m.workers ?? []).map { w in
            let name = (w.name ?? "").trimmingCharacters(in: .whitespaces)
            return WatchWorker(name: name.isEmpty ? "—" : name,
                               online: w.online ?? false,
                               rates: [.hour: w.hashrate1h?.value ?? 0, .day: w.hashrate24h?.value ?? 0])
        }
        .sorted(by: onlineFirst)
        return s
    }
}
