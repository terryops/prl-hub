import Foundation

// AlphaPool (pearl.alphapool.tech) — open mining-pool API, pool level.
//   GET /api/stats → pool + network + chain stats (the overview's last-resort row)
// The per-miner half (/api/miner/{address}) is AlphaPoolSource, shared with the widget.

struct PoolStats: Decodable {
    struct Pool: Decodable {
        let hashrate: String?
        let hashrate1h: String?
        let miners24h: Int?
        let workers: Int?
        let blocks24h: Int?
        let ttfLabel: String?
        let payouts24h: Double?
    }
    struct Coin: Decodable {
        let network_hash: String?
        let reward: Double?
        let symbol: String?
        let ttfLabel: String?
        let difficulty: Double?
    }
    struct RecentBlock: Decodable {
        let time: Int?
        let status: String?   // "immature" / "matured" / "orphan"
    }
    let pool: Pool?
    let coins: [Coin]?
    let feePercent: Double?
    let recentBlocks: [RecentBlock]?
}

struct PoolClient {
    func stats(live: Bool = true) async throws -> PoolStats {
        try PoolHTTP.decode(PoolStats.self, from: try await PoolHTTP.get(AlphaPoolSource.base + "/api/stats", timeout: 25, live: live))
    }
}
