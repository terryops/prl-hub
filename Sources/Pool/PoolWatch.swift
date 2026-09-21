import Foundation

// A user-added per-miner watch = (pool, address). Pools with a public
// per-miner-by-address API: PearlHash, AlphaPool, Lucky Pool, HeroMiners, Pearl Fortune,
// Kryptex. (TW-Pool was removed; stored TW-Pool watches are dropped on load.)
// F2Pool is the exception — it has no by-address API, so its watches are keyed by the
// account's read-only page URL instead. See F2PoolRef.
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
}

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
}

/// A hashrate averaging window. Ordered freshest → smoothest, which is the order the
/// card's picker renders and the order `nearest(in:)` falls back through.
///
/// No pool publishes all of them: the four by-address pools report a live rate but no
/// 15-minute one, F2Pool is the mirror image — its freshest figure IS a 15-minute average
/// and it has no instantaneous rate at all — and Kryptex publishes its own trio (30m / 3h /
/// 24h). So a window is only ever OFFERED for a pool that actually publishes it
/// (`WatchData.windows`); nothing is faked into a slot it doesn't fit.
enum SpeedWindow: String, CaseIterable, Sendable {
    case live, m15, m30, hour, h3, day

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

struct WatchWorker: Identifiable {
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

/// Pool-agnostic per-miner result the card renders.
struct WatchData {
    var found = false
    /// Account-level raw H/s per window, as the pool reports it.
    var rates: [SpeedWindow: Double] = [:]
    /// The windows THIS pool publishes, freshest first — exactly what the card offers.
    var windows: [SpeedWindow] = []
    var pending: Double = 0
    var pendingLabel = Loc("待支付")
    var paid: Double = 0
    var workers: [WatchWorker] = [] {
        didSet {
            #if DEBUG
            // Screenshot-only: SHOT_ANON_WORKERS=1 lists workers as worker-01, worker-02 … so an
            // App Store capture of a real watch doesn't publish the owner's machine hostnames
            // (and carries no "rig" wording — see guideline 3.1.5(ii)). Every pool parser
            // assigns `d.workers = …`, so this one observer covers them all.
            if Self.anonymizeWorkers {
                workers = workers.enumerated().map { i, w in
                    WatchWorker(name: String(format: "worker-%02d", i + 1), online: w.online, rates: w.rates)
                }
            }
            #endif
        }
    }
    #if DEBUG
    static let anonymizeWorkers = ProcessInfo.processInfo.environment["SHOT_ANON_WORKERS"] == "1"
    #endif
    var error: String?

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
}

/// Fetch one watch's per-miner stats. Free function (no actor state) so it can
/// run concurrently for many watches.
func fetchWatchData(_ w: PoolWatch) async -> WatchData? {
    // Guard against a corrupted stored identifier, per the pool's own rules.
    guard let addr = normalizeWatchAddress(w.pool, w.address) else {
        var d = WatchData()
        d.error = w.pool.isAddressBased ? Loc("地址格式不正确") : Loc("只读页链接不正确")
        return d
    }
    // Cold-entry / transient API hiccups are common; retry a few times — the card keeps
    // showing its spinner because we only return once — and surface 失败 only if every
    // attempt throws, so the user never sees a flash of red before the data loads.
    // Returns nil when the work is CANCELLED (e.g. the user navigated away mid-refresh):
    // the caller then leaves the card's current state untouched instead of flashing 失败.
    for attempt in 1...3 {
        if Task.isCancelled { return nil }
        do {
            return try await fetchWatchDataOnce(w, addr: addr)
        } catch {
            if Task.isCancelled || error is CancellationError
                || (error as? URLError)?.code == .cancelled { return nil }
            guard attempt < 3 else { break }
            try? await Task.sleep(for: .milliseconds(600 * attempt))   // 0.6s, 1.2s backoff
        }
    }
    var d = WatchData(); d.error = Loc("查询失败，请稍后重试"); return d
}

/// One fetch attempt. Throws on a network/API error (the caller retries a few times);
/// returns `found=false` with no error for the definitive "not mining here" answer.
private func fetchWatchDataOnce(_ w: PoolWatch, addr: String) async throws -> WatchData {
    var d = WatchData()
    do {
        switch w.pool {
        case .alphaPool:
            let m = try await PoolClient().miner(addr)
            d.found = true
            d.windows = [.live, .hour, .day]
            d.rates = [.hour: m.estHash1hRaw ?? 0, .day: m.estHash24hRaw ?? 0]
            d.pending = m.balance_prl ?? 0
            d.paid = m.total_paid_prl ?? 0
            d.pendingLabel = Loc("待支付")
            let now = Date().timeIntervalSince1970
            d.workers = (m.workers ?? []).map {
                WatchWorker(name: $0.name,
                            online: $0.online ?? ($0.time.map { now - Double($0) < 600 } ?? false),
                            rates: [.live: parseHashrate($0.hashrate_live ?? ""),
                                    .hour: parseHashrate($0.hashrate_1h ?? ""),
                                    .day:  parseHashrate($0.hashrate ?? "")])
            }
        case .luckyPool:
            guard let lm = try await LuckyPoolClient().minerStats(addr), let s = lm.stats else { return d }
            d.found = true
            d.windows = [.live, .hour, .day]
            d.rates = [.live: s.hashrate ?? 0,
                       .hour: s.hashrateAvg?.h1 ?? 0,
                       .day:  s.hashrateAvg?.h24 ?? 0]
            let now = Date().timeIntervalSince1970
            d.pending = lm.unlockedPRL + lm.lockedPRL
            d.paid = lm.paidPRL
            d.pendingLabel = Loc("可提+待确认")
            d.workers = (lm.workers ?? []).map { w in
                WatchWorker(name: w.name,
                            online: w.lastShareSec.map { now - $0 < 600 } ?? true,
                            rates: [.live: w.hashrate ?? 0,
                                    .hour: w.hashrateAvg?.h1 ?? 0,
                                    .day:  w.hashrateAvg?.h24 ?? 0])
            }
            .sorted { a, b in a.online != b.online ? a.online : a.name < b.name }
        case .heroMiners:
            guard let m = try await HeroMinersClient().minerStats(addr) else { return d }
            d.found = true
            let s = m.stats
            let now = Date().timeIntervalSince1970
            let units = HeroMinersClient.coinUnits
            // HeroMiners reports PRL hashrate >>32 — scale every value back to real H/s.
            let scale = HeroMinersClient.hashScale
            d.windows = [.live, .hour, .day]
            d.rates = [.live: (s?.hashrate?.value ?? 0) * scale,
                       .hour: (s?.hashrate_1h?.value ?? 0) * scale,
                       .day:  (s?.hashrate_24h?.value ?? 0) * scale]
            // 待支付 = matured awaiting payout (stats.balance) + immature block
            // shares (unconfirmed). unlocked/payments are 20-entry recent-history
            // lists, so lifetime paid comes from stats.paid (list-sum as fallback).
            d.pending = ((s?.balance?.value ?? 0) + m.pendingAtomic) / units
            let heroPaid = s?.paid?.value ?? 0
            d.paid = (heroPaid > 0 ? heroPaid : m.paidAtomic) / units
            d.pendingLabel = Loc("待支付")
            d.workers = (m.workers ?? []).map { w in
                WatchWorker(name: w.name ?? "—",
                            online: (w.lastShare?.value).map { now - $0 < 600 } ?? false,
                            rates: [.live: (w.hashrate?.value ?? 0) * scale,
                                    .hour: (w.hashrate_1h?.value ?? 0) * scale,
                                    .day:  (w.hashrate_24h?.value ?? 0) * scale])
            }
            .sorted { a, b in a.online != b.online ? a.online : a.name < b.name }
        case .pearlFortune:
            guard let m = try await PearlFortuneClient().minerStats(addr) else { return d }
            d.found = true
            let units = PearlFortuneClient.atomicUnits
            let live = m.conn?.summary?.reported_hashrate ?? 0
            // Server-computed per-miner rolling averages (1h / 8h / 24h), keyed by
            // window. Present only for active miners.
            let roll = Dictionary(
                (m.detail.hourly_shares?.rolling_hashrates ?? []).compactMap { r in
                    (r.hours).flatMap { h in (r.hashrate).map { (h, $0) } }
                }, uniquingKeysWith: { a, _ in a })
            // Fallback when rolling_hashrates is absent: derive a 24h average from the
            // hourly share series — mean of (this miner's share fraction × pool hashrate).
            var sum = 0.0, n = 0
            for p in (m.detail.hourly_shares?.series ?? []) {
                if let tot = p.total_share_sum, tot > 0, let ph = p.pool_hashrate, let ss = p.share_sum {
                    sum += ss / tot * ph; n += 1
                }
            }
            let derived24 = n > 0 ? sum / Double(n) : 0
            // Prefer the authoritative rolling field; fall back to derived / live.
            d.windows = [.live, .hour, .day]
            d.rates = [.live: live,
                       .hour: (roll[1]).flatMap { $0 > 0 ? $0 : nil } ?? live,
                       .day:  (roll[24]).flatMap { $0 > 0 ? $0 : nil }
                              ?? (derived24 > 0 ? derived24 : live)]
            d.pending = ((m.detail.balance?.balance_atomic ?? 0)
                         + (m.detail.pending_shares?.pending_estimate_amount_atomic ?? 0)) / units
            d.paid = m.ledger?.sum_payout_amount_coin?.value ?? 0
            d.pendingLabel = Loc("待支付")
            // Per RIG, Pearl Fortune publishes a live rate and nothing else — the 1h/24h
            // rolling averages exist only for the account. So the rig rows honestly show
            // "—" on those windows rather than repeating the live number three times.
            d.workers = (m.conn?.workers ?? []).map { w in
                WatchWorker(name: w.worker ?? "—",
                            online: !(w.stale ?? true),
                            rates: [.live: w.reported_hashrate ?? 0])
            }
            .sorted { a, b in a.online != b.online ? a.online : a.name < b.name }
        case .pearlHash:
            // The pool hashrate rides along because PearlHash's own per-rig figure is
            // MINER-REPORTED; the pool-measured hourly rate has to be derived from this
            // miner's share of the pool (see PearlHashAccount.latestShare).
            async let poolStats = try? PearlHashClient().stats()
            guard let a = try await PearlHashClient().account(addr) else { return d }
            d.found = true
            let poolHash = (await poolStats)?.hashrate ?? 0
            let derived1h = (a.latestShare ?? 0) * poolHash
            // 1h only when it can actually be derived — an idle account has no pending epoch,
            // and a zero there would read as "your rigs did nothing this hour".
            d.windows = derived1h > 0 ? [.live, .hour] : [.live]
            d.rates = [.live: a.reportedHashrate, .hour: derived1h]
            d.pending = a.pending          // credited balance + epochs still maturing
            d.paid = a.paid
            d.pendingLabel = Loc("待支付")
            // Per rig, only the reported rate exists — the epoch share is per ACCOUNT, so the
            // 1h column honestly reads "—" on the rig rows (same as Pearl Fortune).
            // Every rig in `connected_workers` is by definition connected right now.
            //
            // PearlHash rigs are frequently UNNAMED (its miner doesn't require a worker name),
            // so the label falls back to the rig's IP — and two unnamed rigs behind one NAT
            // then carry the identical label. Numbering the repeats keeps them apart: without
            // it the second rig vanishes from the device sync, which keys on (pool, address,
            // worker name) and drops the duplicate. Numbered after sorting, so the suffixes
            // stay put between refreshes.
            var seenNames: [String: Int] = [:]
            d.workers = (a.connected_workers ?? [])
                .sorted { $0.reportedHashrate > $1.reportedHashrate }
                .map { w in
                    let base = w.displayName
                    let n = (seenNames[base] ?? 0) + 1
                    seenNames[base] = n
                    return WatchWorker(name: n > 1 ? "\(base) (\(n))" : base,
                                       online: true, rates: [.live: w.reportedHashrate])
                }
        case .kryptex:
            guard let m = try await KryptexClient().minerStats(addr) else { return d }
            d.found = true
            // Kryptex publishes no instantaneous rate: its freshest per-rig figure is a
            // 30-minute average, then 3h, then 24h. All three are real H/s.
            d.windows = [.m30, .h3, .day]
            d.pending = m.pending          // matured + still-maturing, like HeroMiners
            d.paid = m.paid
            d.pendingLabel = Loc("待支付")
            d.workers = m.workers.map { w in
                WatchWorker(name: w.displayName,
                            online: w.online,
                            rates: [.m30: w.avg_hashrate_30m?.value ?? 0,
                                    .h3:  w.avg_hashrate_3h?.value ?? 0,
                                    .day: w.avg_hashrate_24h?.value ?? 0])
            }
            .sorted { a, b in a.online != b.online ? a.online : a.name < b.name }
        case .f2pool:
            guard let ref = F2PoolRef(addr) else { return d }
            let m: F2Miner?
            do { m = try await F2PoolClient(ref: ref).minerStats() }
            catch F2PoolError.http(404) { return d }   // key revoked / mistyped → 未在此矿池
            guard let m else { return d }
            d.found = true
            // Account-level figures are raw H/s; per-worker are TH/s (×hashScale → H/s).
            // F2Pool publishes NO instantaneous rate: its freshest figure is a 15-minute
            // average, and there is no 1h series either — hence only [15分, 24h]. Nothing
            // is passed off as 实时.
            let scale = F2PoolClient.hashScale
            d.windows = [.m15, .day]
            d.rates = [.m15: m.summary?.hash_rate?.value ?? 0,
                       .day: m.summary?.hash_rate_daily?.value ?? 0]
            d.paid = m.paid
            // F2Pool settles PPS once a day (00:00 UTC): until then the day's earnings sit in
            // the "today's estimate" tile and `balance` reads 0 — which would show a freshly
            // pointed rig as earning nothing. Fall back to the estimate, and RELABEL so the
            // figure is never passed off as a settled balance.
            if m.balance > 0 || m.estToday <= 0 {
                d.pending = m.balance
                d.pendingLabel = Loc("待支付")
            } else {
                d.pending = m.estToday
                d.pendingLabel = Loc("今日预估")
            }
            d.workers = m.workers.map { w in
                WatchWorker(name: w.name ?? "—",
                            online: (w.status ?? 1) == 0,   // 0 online · 1 offline · 2 dead
                            rates: [.m15: (w.hashrate?.value ?? 0) * scale,
                                    .day: (w.hashrate_last_day?.value ?? 0) * scale])
            }
            .sorted { a, b in a.online != b.online ? a.online : a.name < b.name }
        }
    }
    return d
}
