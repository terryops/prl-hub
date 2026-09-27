import Foundation

// MARK: - Kryptex (K 池, prl-api.kryptex.network) — per miner
//
//   GET /api/v3/miner/workers/{addr}        → per-rig status + 30m / 3h / 24h averages
//   GET /api/v1/miner/balance/{addr}        → confirmed + unconfirmed (immature) balance
//   GET /api/v1/miner/payouts/{addr}/stats  → lifetime paid + last week/month earned
//
// NOT `pool.kryptex.com/prl/api/…`: that host answers non-browsers with a JS cookie challenge.
// The per-miner endpoints answer 200 with zeros / [] for an address that never mined here, so
// "not mining on Kryptex" is a data question, not an HTTP one. Every hashrate is REAL H/s, as
// STRINGS — hence FlexDouble. Pool-level endpoints live in Pool/Kryptex.swift.

/// `/miner/balance/{addr}` — `total` = confirmed + unconfirmed, where unconfirmed is the part
/// still maturing (100 blocks). Both are money the miner has earned, so 待支付 shows the total.
struct KryptexBalance: Decodable, Sendable {
    let total: FlexDouble?
    let unconfirmed: FlexDouble?
    let confirmed: FlexDouble?
    let threshold: FlexDouble?     // payout threshold, PRL
    let last_active: FlexDouble?   // epoch MILLISECONDS, 0 = never mined here
}

/// `/miner/payouts/{addr}/stats` — `paid` is the LIFETIME total (the payouts list itself is
/// paginated, so it must not be summed for this), `unpaid` mirrors balance.confirmed.
struct KryptexPayoutStats: Decodable, Sendable {
    struct Reward: Decodable, Sendable { let week: FlexDouble?; let month: FlexDouble? }
    let reward: Reward?
    let paid: FlexDouble?
    let unpaid: FlexDouble?
}

/// One rig, from the v3 workers endpoint. Kryptex publishes 30-minute / 3-hour / 24-hour
/// rolling averages and NO instantaneous rate — its freshest figure is the 30-minute one.
struct KryptexWorker: Decodable, Sendable {
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

struct KryptexWorkersResp: Decodable, Sendable { let results: [KryptexWorker]? }

/// One address's snapshot across the three per-miner endpoints.
struct KryptexMiner: Sendable {
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

enum KryptexSource: PoolMinerSource {
    static let base = "https://prl-api.kryptex.network"

    private static func get<T: Decodable>(_ path: String, as: T.Type, scope: PoolScope) async throws -> T {
        try PoolHTTP.decode(T.self, from: try await PoolHTTP.get(base + path, timeout: scope.timeout))
    }

    /// The workers call decides whether the pool answered at all — a failure there throws so
    /// the card retries; balance and payouts are best-effort (full scope only), since a hiccup
    /// on either must not blank an otherwise good card.
    static func miner(_ id: String, scope: PoolScope) async throws -> PoolMinerStats? {
        guard let enc = pathComponent(id) else { return nil }
        let full = scope == .full
        async let bal: KryptexBalance? =
            full ? (try? await get("/api/v1/miner/balance/\(enc)", as: KryptexBalance.self, scope: scope)) : nil
        async let pay: KryptexPayoutStats? =
            full ? (try? await get("/api/v1/miner/payouts/\(enc)/stats", as: KryptexPayoutStats.self, scope: scope)) : nil
        let workers = try await get("/api/v3/miner/workers/\(enc)", as: KryptexWorkersResp.self, scope: scope).results ?? []
        return stats(KryptexMiner(workers: workers, balance: await bal, payouts: await pay))
    }

    static func stats(_ m: KryptexMiner) -> PoolMinerStats? {
        guard m.active else { return nil }
        var s = PoolMinerStats()
        // No instantaneous rate: the freshest per-rig figure is a 30-minute average, then 3h,
        // then 24h. All three are real H/s.
        s.windows = [.m30, .h3, .day]
        s.pending = m.pending          // matured + still-maturing, like HeroMiners
        s.paid = m.paid
        s.workers = m.workers.map { w in
            WatchWorker(name: w.displayName,
                        online: w.online,
                        rates: [.m30: w.avg_hashrate_30m?.value ?? 0,
                                .h3:  w.avg_hashrate_3h?.value ?? 0,
                                .day: w.avg_hashrate_24h?.value ?? 0])
        }
        .sorted(by: onlineFirst)
        return s
    }
}
