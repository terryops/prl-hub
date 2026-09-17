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
//
// `/api/account` answers **404 for an address that has never mined here**, which is the clean
// "not mining on PearlHash" signal — every other pool in this app makes that a data question.
//
// Two things about this pool shape the code below:
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

/// `/api/stats`. `hashrate` is raw H/s; the two counts are pool-wide.
struct PearlHashStats: Decodable {
    let hashrate: Double?
    let total_accounts: Int?
    let total_workers: Int?
}

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

/// One connected rig. PearlHash reports per GPU, so the rig's rate is the sum — and its
/// `worker_name` is very often EMPTY (the miner command doesn't require one), which is why
/// the IP is the fallback label: it's what identifies the box on the pool's own lookup page.
/// (`worker_id` is deliberately not decoded: it exceeds Int64 and is no more legible.)
struct PearlHashWorker: Decodable {
    struct GPU: Decodable { let name: String?; let hashrate: Double? }
    let ip: String?
    let worker_name: String?
    let version: String?      // "WildRig_0.49.6" — the miner build, not a hashrate window
    let gpu_info: [GPU]?

    /// Miner-REPORTED raw H/s for this rig, summed across its cards.
    var reportedHashrate: Double { (gpu_info ?? []).reduce(0) { $0 + ($1.hashrate ?? 0) } }
    var gpuCount: Int { (gpu_info ?? []).count }
    var displayName: String {
        let n = (worker_name ?? "").trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        let ip = (self.ip ?? "").trimmingCharacters(in: .whitespaces)
        return ip.isEmpty ? "—" : ip
    }
}

/// One ledger row: an epoch credit (+), a loyalty bonus (+) or a payout (−). PearlHash pays a
/// second coin as well, so `coin_type` must be checked — summing the lot would fold MDL into
/// the PRL total.
struct PearlHashLedgerRow: Decodable {
    let amount: Double?
    let reason: String?
    let timestamp: Double?    // epoch MILLISECONDS
    let coin_type: String?
    var isPRL: Bool { (coin_type ?? "pearl").caseInsensitiveCompare("pearl") == .orderedSame }
}

/// Rewards from epochs that haven't been credited yet. `share` is this miner's fraction OF THE
/// POOL for that hour — a ratio, so an epoch still in progress is not diluted by being partial.
struct PearlHashPending: Decodable {
    struct Epoch: Decodable {
        let epoch_label: String?
        let amount: Double?
        let share: Double?
        let coin_type: String?
        var isPRL: Bool { (coin_type ?? "pearl").caseInsensitiveCompare("pearl") == .orderedSame }
    }
    let total_pending_prl: Double?
    let epochs: [Epoch]?
}

struct PearlHashAccount: Decodable {
    let connected_workers: [PearlHashWorker]?
    let balance_transactions: [PearlHashLedgerRow]?
    let pending_rewards: PearlHashPending?

    private var prlRows: [PearlHashLedgerRow] { (balance_transactions ?? []).filter(\.isPRL) }

    /// Credited and not yet paid out: the whole PRL ledger nets to the current balance.
    var creditedBalance: Double { prlRows.reduce(0) { $0 + ($1.amount ?? 0) } }
    /// Lifetime paid = the payouts, which are the ledger's negative rows.
    var paid: Double { -prlRows.reduce(0) { $0 + min($1.amount ?? 0, 0) } }
    /// Still maturing — not in the ledger yet, so it adds rather than double-counts.
    var immature: Double { pending_rewards?.total_pending_prl ?? 0 }
    var pending: Double { creditedBalance + immature }

    /// Miner-reported total, Σ over rigs.
    var reportedHashrate: Double { (connected_workers ?? []).reduce(0) { $0 + $1.reportedHashrate } }

    /// This miner's share of the pool in the most recent epoch it earned in. Multiplied by the
    /// pool's hashrate this is a POOL-MEASURED hourly average — the honest counterpart to the
    /// rig-reported rate above. nil when there is no pending epoch to read it from.
    var latestShare: Double? {
        (pending_rewards?.epochs ?? []).last { $0.isPRL && ($0.share ?? 0) > 0 }?.share
    }

    /// Has this address ever mined here? (`/api/account` 404s for a stranger, so by the time
    /// this is asked the answer is nearly always yes — but an emptied-out account still exists.)
    var active: Bool {
        !(connected_workers ?? []).isEmpty || pending > 0 || paid > 0 || !prlRows.isEmpty
    }
}

struct PearlHashClient {
    /// Pool fee as the site states it (its API publishes no fee field). Used only by the
    /// last-resort overview path — the aggregators carry the fee on the primary paths.
    static let fee = 3.0
    private static let base = "https://pearlhash.xyz"

    private func get<T: Decodable>(_ path: String, as: T.Type, timeout: TimeInterval = 25) async throws -> T {
        guard let url = URL(string: Self.base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData   // refresh must fetch live numbers
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(poolBrowserUA, forHTTPHeaderField: "User-Agent")
        let (d, r) = try await URLSession.shared.data(for: req)
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw PoolHTTPError.status(code) }
        return try JSONDecoder().decode(T.self, from: d)
    }

    func stats() async throws -> PearlHashStats { try await get("/api/stats", as: PearlHashStats.self) }

    func chainInfo() async throws -> PearlHashChain { try await get("/api/chain-info", as: PearlHashChain.self) }

    /// The pool's recent blocks, newest first — the `coinbase` rows of its wallet ledger.
    func recentBlocks() async throws -> [PearlHashWalletTx] {
        (try await get("/api/pool-wallet-txs?page=1", as: PearlHashWalletResp.self).transactions ?? [])
            .filter(\.isBlock)
    }

    /// Per-miner snapshot; nil when this address has never mined here (the endpoint's own 404).
    /// A real network/HTTP failure throws, so the card retries rather than claiming "未在此矿池".
    func account(_ address: String) async throws -> PearlHashAccount? {
        let addr = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty,
              let enc = addr.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        do {
            let a = try await get("/api/account/\(enc)", as: PearlHashAccount.self)
            return a.active ? a : nil
        } catch PoolHTTPError.status(404) {
            return nil        // no such account — the definitive "not mining here"
        }
    }
}

/// A pool answered with a non-200. Carries the code so a 404 ("no such miner") can be told
/// apart from a 5xx ("try again"), which is the difference between 未在此矿池 and 查询失败.
enum PoolHTTPError: Error { case status(Int) }
