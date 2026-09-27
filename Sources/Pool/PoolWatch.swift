import Foundation

// A user-added per-miner watch = (pool, address). The pools themselves — PoolKind, and one
// PoolMinerSource per pool that reads its per-miner API — live in Sources/WidgetShared/Pools/,
// because the widget extension refreshes the same watches with the same parsing code.

/// Normalise a pasted watch identifier for its pool, or nil when it isn't usable.
/// Address pools take a lowercase PRL address; F2Pool takes its read-only page URL
/// (kept verbatim — the account name in it may be mixed-case).
func normalizeWatchAddress(_ pool: PoolKind, _ raw: String) -> String? {
    // F2Pool's identifier is a URL, so it gets the RAW paste: cleanAddr keeps only the first
    // whitespace-delimited token, which decapitates a link that arrived inside a sentence.
    guard pool.isAddressBased else { return F2PoolRef(raw)?.pageURL }
    let a = PoolStore.cleanAddr(raw).lowercased()
    return PRLAddress.isValid(a, network: .mainnet) ? a : nil
}

struct PoolWatch: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var pool: PoolKind
    var address: String
    /// User-set nickname shown instead of the pool's default label. Optional so
    /// watches saved before this feature (no `alias` key) still decode.
    var alias: String?
    /// Paused watches keep their card, position and settings but are not fetched, not
    /// pushed to the widget, and not synced as devices — for a pool you've stopped mining
    /// on but don't want to lose. Optional (not a plain `Bool = true`) because a watch
    /// saved before this feature has no key at all, and a missing key must read as ENABLED.
    var enabled: Bool?

    var isEnabled: Bool { enabled ?? true }

    /// What to show as the watch's title: the alias if set, else the pool label.
    var displayName: String {
        if let a = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty { return a }
        return pool.label
    }

    /// True when the user has given this watch a custom alias.
    var hasAlias: Bool {
        !(alias?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Same pool and identifier — i.e. a fetch made for `other` is still valid for this watch.
    /// (An edit that switches pools keeps the id, so id alone can't tell a late result apart.)
    func sameTarget(as other: PoolWatch) -> Bool {
        id == other.id && pool == other.pool && address == other.address
    }
}

extension SpeedWindow {
    var label: String {
        switch self {
        case .live: return Loc("实时")
        case .m15:  return Loc("15分")
        case .m30:  return Loc("30分")
        case .hour: return Loc("1h")
        case .h3:   return Loc("3h")
        case .day:  return Loc("24h")
        }
    }

    /// The caption under the stat card's number.
    var sub: String {
        switch self {
        case .live: return Loc("瞬时")
        case .m15:  return Loc("近 15 分钟")
        case .m30:  return Loc("近 30 分钟")
        case .hour: return Loc("近 1 小时")
        case .h3:   return Loc("近 3 小时")
        case .day:  return Loc("平均")
        }
    }
}

/// What one watch card renders: the pool-agnostic stats plus whether the pool knows the
/// address at all, or why it couldn't be asked.
struct WatchData {
    var found = false
    var stats = PoolMinerStats()
    var error: String?

    init() {}

    /// nil stats = the pool's definitive "never mined here".
    init(_ stats: PoolMinerStats?) {
        guard var s = stats else { return }
        #if DEBUG
        // Screenshot-only: SHOT_ANON_WORKERS=1 lists workers as worker-01, worker-02 … so an
        // App Store capture of a real watch doesn't publish the owner's machine hostnames
        // (and carries no "rig" wording — see guideline 3.1.5(ii)).
        if Self.anonymizeWorkers {
            s.workers = s.workers.enumerated().map { i, w in
                WatchWorker(name: String(format: "worker-%02d", i + 1), online: w.online, rates: w.rates)
            }
        }
        #endif
        found = true
        self.stats = s
    }
    #if DEBUG
    static let anonymizeWorkers = ProcessInfo.processInfo.environment["SHOT_ANON_WORKERS"] == "1"
    #endif

    var windows: [SpeedWindow] { stats.windows }
    var pending: Double { stats.pending }
    var paid: Double { stats.paid }
    var workers: [WatchWorker] { stats.workers }
    func value(_ w: SpeedWindow) -> Double { stats.value(w) }
    var hr24hRaw: Double { stats.hr24hRaw }

    var pendingLabel: String {
        switch stats.pendingKind {
        case .pending:                    return Loc("待支付")
        case .withdrawableAndUnconfirmed: return Loc("可提+待确认")
        case .todayEstimate:              return Loc("今日预估")
        }
    }
}

/// Fetch one watch's per-miner stats. Free function (no actor state) so it can
/// run concurrently for many watches.
///
/// Cold-entry / transient API hiccups are common, so a TRANSIENT failure (timeout, dropped
/// connection, 5xx, 429) is retried — the card keeps its spinner because we only return once —
/// and 失败 surfaces only if every attempt fails. A definitive answer (4xx, an undecodable
/// body) is not retried, and the whole watch is bounded by one deadline, so a slow pool holds
/// its own card for at most `deadline` seconds, never the rest of the refresh.
/// Returns nil when the work is CANCELLED (e.g. the user navigated away mid-refresh):
/// the caller then leaves the card's current state untouched instead of flashing 失败.
func fetchWatchData(_ w: PoolWatch, deadline: TimeInterval = 45) async -> WatchData? {
    // Guard against a corrupted stored identifier, per the pool's own rules.
    guard let addr = normalizeWatchAddress(w.pool, w.address) else {
        var d = WatchData()
        d.error = w.pool.isAddressBased ? Loc("地址格式不正确") : Loc("只读页链接不正确")
        return d
    }
    let source = w.pool.source
    do {
        return WatchData(try await PoolHTTP.retrying(deadline: deadline) {
            try await source.miner(addr, scope: .full)
        })
    } catch {
        if Task.isCancelled || error is CancellationError
            || (error as? URLError)?.code == .cancelled { return nil }
        var d = WatchData(); d.error = Loc("查询失败，请稍后重试"); return d
    }
}
