import Foundation

// MARK: - One miner on one pool — the pool-agnostic shape both the app and the widget read
//
// Each pool publishes a different set of endpoints, units and windows. A `PoolMinerSource`
// per pool (see the other files in this folder) turns its payloads into a `PoolMinerStats`,
// so the app's monitor card and the widget's self-refresh compute the SAME numbers from the
// SAME parsing code — they used to parse every pool twice, and drifted.

/// A user-added per-miner watch = (pool, address). Pools with a public per-miner-by-address
/// API: PearlHash, AlphaPool, Lucky Pool, HeroMiners, Pearl Fortune, Kryptex. F2Pool is the
/// exception — it has no by-address API, so its watches are keyed by the account's read-only
/// page URL instead. See F2PoolRef.
enum PoolKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case alphaPool = "AlphaPool"
    case luckyPool = "Lucky Pool"
    case heroMiners = "HeroMiners"
    case pearlFortune = "Pearl Fortune"
    case pearlHash = "PearlHash"
    case kryptex = "Kryptex"
    case f2pool = "F2Pool"
    var id: String { rawValue }
    var label: String { rawValue }

    /// False for pools whose watches are keyed by something other than a PRL address,
    /// so the PRL-address rules (lowercasing, bech32 validation) must not be applied.
    var isAddressBased: Bool { self != .f2pool }

    /// The adapter that reads this pool's per-miner API.
    var source: any PoolMinerSource.Type {
        switch self {
        case .alphaPool:    return AlphaPoolSource.self
        case .luckyPool:    return LuckyPoolSource.self
        case .heroMiners:   return HeroMinersSource.self
        case .pearlFortune: return PearlFortuneSource.self
        case .pearlHash:    return PearlHashSource.self
        case .kryptex:      return KryptexSource.self
        case .f2pool:       return F2PoolSource.self
        }
    }
}

/// A hashrate averaging window. Ordered freshest → smoothest, which is the order the
/// card's picker renders and the order `nearest(in:)` falls back through.
///
/// No pool publishes all of them: the four by-address pools report a live rate but no
/// 15-minute one, F2Pool is the mirror image — its freshest figure IS a 15-minute average
/// and it has no instantaneous rate at all — and Kryptex publishes its own trio (30m / 3h /
/// 24h). So a window is only ever OFFERED for a pool that actually publishes it
/// (`PoolMinerStats.windows`); nothing is faked into a slot it doesn't fit.
enum SpeedWindow: String, CaseIterable, Sendable {
    case live, m15, m30, hour, h3, day

    /// The closest window this pool DOES publish. Ties (one step either way) go to the
    /// fresher one, so a user parked on 实时 lands on F2Pool's 15分 rather than its 24h.
    func nearest(in available: [SpeedWindow]) -> SpeedWindow? {
        guard !available.isEmpty else { return nil }
        if available.contains(self) { return self }
        let mine = Self.allCases.firstIndex(of: self) ?? 0
        return available.min { a, b in
            let ia = Self.allCases.firstIndex(of: a) ?? 0, ib = Self.allCases.firstIndex(of: b) ?? 0
            return (abs(ia - mine), ia) < (abs(ib - mine), ib)
        }
    }
}

struct WatchWorker: Identifiable, Sendable {
    let name: String
    let online: Bool
    /// Raw H/s per window. A window this pool doesn't publish PER RIG is absent (not 0) —
    /// an absent window renders "—", while a real 0 means the rig is idle. Pearl Fortune,
    /// for instance, publishes only a live rate per rig even though the ACCOUNT has 1h/24h.
    var rates: [SpeedWindow: Double] = [:]
    var id: String { name }

    func rate(_ w: SpeedWindow) -> Double { rates[w] ?? 0 }

    /// Freshest published rate — "what this rig is doing now", whatever the pool calls it.
    /// (F2Pool's freshest is its 15-minute average; Kryptex's is a 30-minute one.) Drives the
    /// live totals elsewhere — including the widget, which would otherwise fall all the way
    /// back to a 24h average for a pool that publishes no instantaneous rate.
    var instant: Double { rate(.live).nonZeroOr(rate(.m15)).nonZeroOr(rate(.m30)) }
    /// 24h average where published, else the freshest figure. Used for the device sync.
    var hashrate: Double { rate(.day).nonZeroOr(instant) }
}

/// What the pool's "unpaid" figure actually is — the card labels it accordingly.
enum PendingKind: Sendable {
    /// Earned, not yet paid out (matured + still-maturing where the pool splits them).
    case pending
    /// Lucky Pool: withdrawable + still-confirming, which it reports as two figures.
    case withdrawableAndUnconfirmed
    /// F2Pool before its 00:00 UTC settlement: the day's PPS estimate, not a balance.
    case todayEstimate
}

/// How much of a pool to read. The widget runs on a tight time/memory budget and shows only
/// the live total and the rig count, so it skips the balance / ledger / payout endpoints (and
/// F2Pool's 280 KB HTML page) that only the app's card renders.
enum PoolScope: Sendable {
    case full, live

    var timeout: TimeInterval { self == .full ? 20 : 15 }
}

/// One miner's stats on one pool, pool-agnostic.
struct PoolMinerStats: Sendable {
    /// The windows THIS pool publishes, freshest first — exactly what the card offers.
    var windows: [SpeedWindow] = []
    /// Account-level raw H/s per window, as the pool reports it.
    var rates: [SpeedWindow: Double] = [:]
    var pending: Double = 0
    var pendingKind: PendingKind = .pending
    var paid: Double = 0
    var workers: [WatchWorker] = []

    /// The headline number for a window: Σ per-rig where the pool publishes it per rig (a
    /// true total that actually moves between refreshes), else the account-level figure.
    func value(_ w: SpeedWindow) -> Double {
        let sum = workers.reduce(0) { $0 + $1.rate(w) }
        return sum > 0 ? sum : (rates[w] ?? 0)
    }

    /// H/s for the efficiency comparison (每 P·天) and the device sync: the SMOOTHEST published
    /// window that actually carries a value — 24h wherever the pool publishes one, else the
    /// next-smoothest, and only then the freshest. Smoothest-first matters for PearlHash, whose
    /// live figure is what the miner REPORTS while its 1h is what the pool actually credited;
    /// falling through to the freshest still covers a rig that started minutes ago and has
    /// nothing but a live rate yet. (`windows` is ordered freshest → smoothest.)
    var hr24hRaw: Double {
        windows.reversed().first { value($0) > 0 }.map { value($0) } ?? 0
    }

    /// REAL-TIME (瞬时) total for the widget: Σ per-rig freshest rate, falling back to the
    /// smoothest published figure only for a pool whose rigs report nothing live. The app
    /// writes the widget snapshot with this and the widget re-computes it on its own refresh,
    /// so the two can no longer disagree about the same rig.
    var liveRate: Double {
        let live = workers.reduce(0) { $0 + $1.instant }
        return live > 0 ? live : hr24hRaw
    }

    /// `liveRate` as the widget prints it — "—" when there is nothing to show.
    var liveRateText: String { liveRate > 0 ? formatHashrate(liveRate) : "—" }

    var onlineCount: Int { workers.filter(\.online).count }
}

/// One pool's per-miner API.
protocol PoolMinerSource: Sendable {
    /// This miner's stats. nil = the pool has definitively never seen this identifier
    /// (未在此矿池挖矿); throws = couldn't tell (transport, HTTP, undecodable body) — the app
    /// retries a transient failure, and the widget keeps its last snapshot either way.
    static func miner(_ id: String, scope: PoolScope) async throws -> PoolMinerStats?
}

extension PoolMinerSource {
    /// The identifier as a single URL path component. nil for an empty one.
    static func pathComponent(_ id: String) -> String? {
        let s = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    }
}

/// Stable rig order: online first, then by name — so rows don't reshuffle between refreshes.
func onlineFirst(_ a: WatchWorker, _ b: WatchWorker) -> Bool {
    a.online != b.online ? a.online : a.name < b.name
}
