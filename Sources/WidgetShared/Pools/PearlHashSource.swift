import Foundation

// MARK: - PearlHash (pearlhash.xyz) — per miner
//
//   GET /api/account/{address} → connected rigs · full balance ledger · pending epochs
//   GET /api/stats             → pool hashrate (needed to turn an epoch share into H/s)
//
// `/api/account` answers **404 for an address that has never mined here** — the clean
// "not mining on PearlHash" signal. Pool-level endpoints live in Pool/PearlHash.swift.
//
// Its only per-rig hashrate is what the MINER reports (WildRig's own per-GPU numbers), which
// runs visibly above the rate the pool actually credits. The pool-side figure is derived: each
// pending epoch carries this miner's `share` of the pool for that hour, so share × pool
// hashrate is a real, pool-measured hourly average. The card shows both.

/// `/api/stats`. `hashrate` is raw H/s; the two counts are pool-wide.
struct PearlHashStats: Decodable, Sendable {
    let hashrate: Double?
    let total_accounts: Int?
    let total_workers: Int?
}

/// One connected rig. PearlHash reports per GPU, so the rig's rate is the sum — and its
/// `worker_name` is very often EMPTY (the miner command doesn't require one), which is why
/// the IP is the fallback label: it's what identifies the box on the pool's own lookup page.
/// (`worker_id` is deliberately not decoded: it exceeds Int64 and is no more legible.)
struct PearlHashWorker: Decodable, Sendable {
    struct GPU: Decodable, Sendable { let name: String?; let hashrate: Double? }
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
struct PearlHashLedgerRow: Decodable, Sendable {
    let amount: Double?
    let reason: String?
    let timestamp: Double?    // epoch MILLISECONDS
    let coin_type: String?
    var isPRL: Bool { (coin_type ?? "pearl").caseInsensitiveCompare("pearl") == .orderedSame }
}

/// Rewards from epochs that haven't been credited yet. `share` is this miner's fraction OF THE
/// POOL for that hour — a ratio, so an epoch still in progress is not diluted by being partial.
struct PearlHashPending: Decodable, Sendable {
    struct Epoch: Decodable, Sendable {
        let epoch_label: String?
        let amount: Double?
        let share: Double?
        let coin_type: String?
        var isPRL: Bool { (coin_type ?? "pearl").caseInsensitiveCompare("pearl") == .orderedSame }
    }
    let total_pending_prl: Double?
    let epochs: [Epoch]?
}

struct PearlHashAccount: Decodable, Sendable {
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

enum PearlHashSource: PoolMinerSource {
    static let base = "https://pearlhash.xyz"

    /// The pool's own totals — also what the overview's last-resort row reads.
    static func poolStats(live: Bool = true) async throws -> PearlHashStats {
        try PoolHTTP.decode(PearlHashStats.self, from: try await PoolHTTP.get(base + "/api/stats", live: live))
    }

    static func miner(_ id: String, scope: PoolScope) async throws -> PoolMinerStats? {
        guard let enc = pathComponent(id) else { return nil }
        // The pool hashrate rides along (full scope only) because the pool-measured hourly
        // rate has to be derived from this miner's share of the pool (see latestShare).
        async let poolHash: Double? = scope == .full ? (try? await poolStats())?.hashrate : nil
        let data: Data
        do {
            // The response is large (~40 KB gzipped — it carries the full payout ledger), but
            // that is still the smallest thing this pool will answer with.
            data = try await PoolHTTP.get(base + "/api/account/\(enc)", timeout: scope == .full ? 25 : 20)
        } catch PoolHTTPError.status(404) {
            return nil        // no such account — the definitive "not mining here"
        }
        return try parse(data, poolHashrate: await poolHash ?? 0)
    }

    static func parse(_ data: Data, poolHashrate: Double) throws -> PoolMinerStats? {
        let a = try PoolHTTP.decode(PearlHashAccount.self, from: data)
        guard a.active else { return nil }
        let derived1h = (a.latestShare ?? 0) * poolHashrate
        var s = PoolMinerStats()
        // 1h only when it can actually be derived — an idle account has no pending epoch,
        // and a zero there would read as "your rigs did nothing this hour".
        s.windows = derived1h > 0 ? [.live, .hour] : [.live]
        s.rates = [.live: a.reportedHashrate, .hour: derived1h]
        s.pending = a.pending          // credited balance + epochs still maturing
        s.paid = a.paid
        // Per rig, only the reported rate exists — the epoch share is per ACCOUNT, so the
        // 1h column honestly reads "—" on the rig rows (same as Pearl Fortune).
        // Every rig in `connected_workers` is by definition connected right now.
        //
        // PearlHash rigs are frequently UNNAMED, so the label falls back to the rig's IP — and
        // two unnamed rigs behind one NAT then carry the identical label. Numbering the repeats
        // keeps them apart: without it the second rig vanishes from the device sync, which keys
        // on (pool, address, worker name) and drops the duplicate. Numbered after sorting, so
        // the suffixes stay put between refreshes.
        var seenNames: [String: Int] = [:]
        s.workers = (a.connected_workers ?? [])
            .sorted { $0.reportedHashrate > $1.reportedHashrate }
            .map { w in
                let base = w.displayName
                let n = (seenNames[base] ?? 0) + 1
                seenNames[base] = n
                return WatchWorker(name: n > 1 ? "\(base) (\(n))" : base,
                                   online: true, rates: [.live: w.reportedHashrate])
            }
        return s
    }
}
