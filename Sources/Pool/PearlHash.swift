import Foundation

// MARK: - PearlHash (pearlhash.xyz) — the network's biggest PRL pool
//
// ~30% of Pearl's hashrate and ~20k accounts. It publishes no documented API (/api-docs 404s),
// but its site is a plain Next.js app calling three JSON routes, and those are what the "Lookup"
// box on its homepage uses:
//
//   GET /api/stats                    → pool hashrate · accounts · workers
//   GET /api/chain-info               → height · difficulty · NETWORK hashrate · supply
//   GET /api/pool-wallet-txs?page=1   → the pool wallet's ledger; its `coinbase` rows ARE the
//                                       pool's blocks (50 rows ≈ the last 8h)
//   GET /api/account/{address}        → connected rigs · full balance ledger · pending epochs
//                                       (per miner — PearlHashSource, shared with the widget)
//
// `/api/account` answers **404 for an address that has never mined here**, which is the clean
// "not mining on PearlHash" signal — every other pool in this app makes that a data question.
//
// Two things about this pool shape the per-miner code:
//
//  1. It pays per hourly EPOCH, not per block. Money is therefore in three places: credited
//     epochs (`balance_transactions`, which also carries the payouts OUT as negative rows),
//     and epochs still maturing (`pending_rewards`). 待支付 is the sum of the two, as it is for
//     HeroMiners and Kryptex.
//  2. Its only per-rig hashrate is what the MINER reports (WildRig's own per-GPU numbers), which
//     runs visibly above the rate the pool actually credits. The pool-side figure has to be
//     derived: each pending epoch carries this miner's `share` of the pool for that hour, so
//     share × pool hashrate is a real, pool-measured hourly average. The card shows both and
//     says which is which — the gap between 实时 and 1h is exactly the reported-vs-effective
//     gap a miner wants to see, so neither number is dropped and neither is passed off as the
//     other.

/// `/api/chain-info` — the pool's own node, so the overview's 占比 has a network figure even
/// when every aggregator is unreachable.
struct PearlHashChain: Decodable {
    let blocks: Int?
    let difficulty: Double?
    let networkhashps: Double?
    let chain: String?
}

/// One row of the pool wallet's ledger. `type == "coinbase"` is a block the pool found —
/// `receivedGrains` is that block's full reward (grains, ÷1e8 = PRL), `timeMs` its time.
struct PearlHashWalletTx: Decodable {
    let type: String?
    let timeMs: Double?
    let receivedGrains: Double?
    var isBlock: Bool { type == "coinbase" }
    var rewardPRL: Double { (receivedGrains ?? 0) / 1e8 }
}

private struct PearlHashWalletResp: Decodable { let transactions: [PearlHashWalletTx]? }

struct PearlHashClient {
    /// Pool fee as the site states it (its API publishes no fee field). Used only by the
    /// last-resort overview path — the aggregators carry the fee on the primary paths.
    static let fee = 3.0

    private func get<T: Decodable>(_ path: String, as: T.Type, live: Bool) async throws -> T {
        try PoolHTTP.decode(T.self, from: try await PoolHTTP.get(PearlHashSource.base + path, timeout: 25, live: live))
    }

    func stats(live: Bool = true) async throws -> PearlHashStats { try await PearlHashSource.poolStats(live: live) }

    func chainInfo(live: Bool = true) async throws -> PearlHashChain {
        try await get("/api/chain-info", as: PearlHashChain.self, live: live)
    }

    /// The pool's recent blocks, newest first — the `coinbase` rows of its wallet ledger.
    func recentBlocks(live: Bool = true) async throws -> [PearlHashWalletTx] {
        (try await get("/api/pool-wallet-txs?page=1", as: PearlHashWalletResp.self, live: live).transactions ?? [])
            .filter(\.isBlock)
    }
}
