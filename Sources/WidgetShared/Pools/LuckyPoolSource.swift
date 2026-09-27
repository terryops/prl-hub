import Foundation

// MARK: - Lucky Pool (open-ethereum-pool fork, pearl.luckypool.io) — per miner
//   GET /api/stats_address?address= → stats + workers (amounts in grain, ÷1e8 = PRL)
//   404 {"error":"Address not found"} is the pool's own "never mined here".

struct LuckyMiner: Decodable, Sendable {
    struct Stats: Decodable, Sendable {
        let hashrate: Double?          // H/s, current
        let paid: Double?              // grain, lifetime
        let unlocked: Double?          // grain, withdrawable
        let locked: Double?            // grain, immature/pending
        struct Avg: Decodable, Sendable {
            let h24: Double?; let h6: Double?; let h1: Double?
            enum CodingKeys: String, CodingKey { case h24 = "24h"; case h6 = "6h"; case h1 = "1h" }
        }
        let hashrateAvg: Avg?
    }
    struct Worker: Decodable, Sendable {
        let name: String?
        let hashrate: Double?          // H/s, instant (same window as stats.hashrate)
        let hashrateAvg: Stats.Avg?
        let lastShare: FlexDouble?     // epoch MILLISECONDS, as a string
        /// nil when the pool gave no usable stamp ("0" / missing).
        var lastShareSec: Double? { (lastShare?.value).flatMap { $0 > 0 ? $0 / 1000 : nil } }
    }
    let stats: Stats?
    let workers: [Worker]?

    var unlockedPRL: Double { (stats?.unlocked ?? 0) / 1e8 }
    var lockedPRL: Double { (stats?.locked ?? 0) / 1e8 }
    var paidPRL: Double { (stats?.paid ?? 0) / 1e8 }
}

enum LuckyPoolSource: PoolMinerSource {
    static func miner(_ id: String, scope: PoolScope) async throws -> PoolMinerStats? {
        let addr = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty, var comps = URLComponents(string: "https://pearl.luckypool.io/api/stats_address")
        else { return nil }
        comps.queryItems = [.init(name: "address", value: addr)]
        guard let url = comps.url else { return nil }
        do {
            return try parse(try await PoolHTTP.get(url, timeout: scope.timeout), now: Date().timeIntervalSince1970)
        } catch PoolHTTPError.status(404) {
            return nil      // "Address not found" — anything else (5xx, 429) is 查询失败, not 未在此矿池
        }
    }

    static func parse(_ data: Data, now: Double) throws -> PoolMinerStats? {
        let lm = try PoolHTTP.decode(LuckyMiner.self, from: data)
        guard let st = lm.stats else { return nil }
        var s = PoolMinerStats()
        s.windows = [.live, .hour, .day]
        s.rates = [.live: st.hashrate ?? 0,
                   .hour: st.hashrateAvg?.h1 ?? 0,
                   .day:  st.hashrateAvg?.h24 ?? 0]
        s.pending = lm.unlockedPRL + lm.lockedPRL
        s.paid = lm.paidPRL
        s.pendingKind = .withdrawableAndUnconfirmed
        s.workers = (lm.workers ?? []).map { w in
            // No usable last-share stamp → trust the pool listing the rig at all.
            WatchWorker(name: w.name ?? "—",
                        online: w.lastShareSec.map { now - $0 < 600 } ?? true,
                        rates: [.live: w.hashrate ?? 0,
                                .hour: w.hashrateAvg?.h1 ?? 0,
                                .day:  w.hashrateAvg?.h24 ?? 0])
        }
        .sorted(by: onlineFirst)
        return s
    }
}
