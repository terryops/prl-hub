import Foundation

// MARK: - Pearl Fortune (pearlfortune.org, public-pool fork, PPLNS, read-only API) — per miner
// Per-miner data spans 3 endpoints, all enveloped in {"data": …}:
//   /api/v1/miners/{addr}              → balance + pending estimate + hourly share series
//   /api/v1/miners/{addr}/connections  → live workers + reported hashrate
//   /api/v1/miners/{addr}/ledger       → lifetime credited / paid-out totals
// `_atomic` amounts are ÷ atomic_units (1e8); the API returns ledger amounts as
// STRINGS, so those go through FlexDouble. The widget reads /connections alone.

struct PFEnvelope<T: Decodable>: Decodable { let data: T? }

struct PFMinerDetail: Decodable, Sendable {
    struct Balance: Decodable, Sendable { let balance_atomic: Double? }
    struct Pending: Decodable, Sendable { let pending_estimate_amount_atomic: Double? }
    struct Hourly: Decodable, Sendable {
        struct Point: Decodable, Sendable { let share_sum: Double?; let total_share_sum: Double?; let pool_hashrate: Double? }
        /// Server-computed per-miner rolling average hashrate (H/s), one entry per
        /// window (hours = 1 / 8 / 24). Only present for active miners — absent for
        /// addresses with no recent shares, so the share-series derivation stays as
        /// a fallback.
        struct Rolling: Decodable, Sendable { let hours: Int?; let hashrate: Double? }
        let series: [Point]?
        let rolling_hashrates: [Rolling]?
    }
    let balance: Balance?
    let pending_shares: Pending?
    let hourly_shares: Hourly?
}

struct PFConnections: Decodable, Sendable {
    struct Summary: Decodable, Sendable { let reported_hashrate: Double? }
    struct Worker: Decodable, Sendable {
        let worker: String?            // worker name (NB: key is `worker`, not `worker_name`)
        let reported_hashrate: Double?
        let stale: Bool?               // online == !stale
    }
    let configured: Bool?
    let online: Bool?
    let workers: [Worker]?
    let summary: Summary?
}

struct PFLedger: Decodable, Sendable {
    let sum_payout_amount_coin: FlexDouble?   // PRL, lifetime paid out (string in JSON)
    let sum_credit_amount_coin: FlexDouble?   // PRL, lifetime credited
}

enum PearlFortuneSource: PoolMinerSource {
    static let atomicUnits = 100_000_000.0
    private static let base = "https://pearlfortune.org"

    private static func get<T: Decodable>(_ path: String, as: T.Type, scope: PoolScope) async throws -> T? {
        try PoolHTTP.decode(PFEnvelope<T>.self,
                            from: try await PoolHTTP.get(base + path, timeout: scope.timeout)).data
    }

    /// Full: detail + connections + ledger, concurrently — the detail decides whether the pool
    /// answered at all; connections and ledger are best-effort so a hiccup on either can't
    /// blank a good card. Live: the connections endpoint alone.
    static func miner(_ id: String, scope: PoolScope) async throws -> PoolMinerStats? {
        guard let enc = pathComponent(id) else { return nil }
        if scope == .live {
            return live(try await get("/api/v1/miners/\(enc)/connections", as: PFConnections.self, scope: scope))
        }
        async let detail = get("/api/v1/miners/\(enc)", as: PFMinerDetail.self, scope: scope)
        async let conn = get("/api/v1/miners/\(enc)/connections", as: PFConnections.self, scope: scope)
        async let ledger = get("/api/v1/miners/\(enc)/ledger", as: PFLedger.self, scope: scope)
        guard let d = try await detail else { return nil }
        return combine(detail: d, conn: (try? await conn) ?? nil, ledger: (try? await ledger) ?? nil)
    }

    private static func rigs(_ c: PFConnections?) -> [WatchWorker] {
        // Per RIG, Pearl Fortune publishes a live rate and nothing else — the 1h/24h
        // rolling averages exist only for the account. So the rig rows honestly show
        // "—" on those windows rather than repeating the live number three times.
        (c?.workers ?? []).map { w in
            WatchWorker(name: w.worker ?? "—",
                        online: !(w.stale ?? true),
                        rates: [.live: w.reported_hashrate ?? 0])
        }
        .sorted(by: onlineFirst)
    }

    /// The widget's view: rigs + reported total, nothing else. nil when the address has no
    /// rigs and reports nothing (nothing to show — the widget keeps its last snapshot).
    static func live(_ c: PFConnections?) -> PoolMinerStats? {
        let workers = rigs(c)
        let reported = c?.summary?.reported_hashrate ?? 0
        guard !workers.isEmpty || reported > 0 else { return nil }
        var s = PoolMinerStats()
        s.windows = [.live]
        s.rates = [.live: reported]
        s.workers = workers
        return s
    }

    /// nil if the address has never mined here. The connections `configured` flag is true for
    /// ANY queried address, so it can't gate "mining here" — real signals (balance / pending /
    /// payouts / live workers) do.
    static func combine(detail d: PFMinerDetail, conn c: PFConnections?, ledger l: PFLedger?) -> PoolMinerStats? {
        let bal = d.balance?.balance_atomic ?? 0
        let pend = d.pending_shares?.pending_estimate_amount_atomic ?? 0
        let paid = l?.sum_payout_amount_coin?.value ?? 0
        if bal == 0 && pend == 0 && paid == 0 && (c?.workers ?? []).isEmpty { return nil }

        let live = c?.summary?.reported_hashrate ?? 0
        // Server-computed per-miner rolling averages (1h / 8h / 24h), keyed by window.
        let roll = Dictionary(
            (d.hourly_shares?.rolling_hashrates ?? []).compactMap { r in
                (r.hours).flatMap { h in (r.hashrate).map { (h, $0) } }
            }, uniquingKeysWith: { a, _ in a })
        // Fallback when rolling_hashrates is absent: derive a 24h average from the
        // hourly share series — mean of (this miner's share fraction × pool hashrate).
        var sum = 0.0, n = 0
        for p in (d.hourly_shares?.series ?? []) {
            if let tot = p.total_share_sum, tot > 0, let ph = p.pool_hashrate, let ss = p.share_sum {
                sum += ss / tot * ph; n += 1
            }
        }
        let derived24 = n > 0 ? sum / Double(n) : 0
        var s = PoolMinerStats()
        // Prefer the authoritative rolling field; fall back to derived / live.
        s.windows = [.live, .hour, .day]
        s.rates = [.live: live,
                   .hour: (roll[1]).flatMap { $0 > 0 ? $0 : nil } ?? live,
                   .day:  (roll[24]).flatMap { $0 > 0 ? $0 : nil } ?? (derived24 > 0 ? derived24 : live)]
        s.pending = (bal + pend) / atomicUnits
        s.paid = paid
        s.workers = rigs(c)
        return s
    }
}
