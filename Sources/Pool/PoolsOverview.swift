import SwiftUI
import Combine
import Charts

/// Public, address-free overview of every Pearl mining pool.
///
/// Built from lordofpearls.xyz (see LordOfPearlsClient): the explorer polls every pool's own
/// API on one ~10-minute cadence and counts each pool's blocks ON-CHAIN by coinbase
/// attribution, so the rows are comparable and the 出块 column doesn't rest on the pools'
/// self-reporting. Two older sources stay wired behind it — miningpoolstats.stream, then the
/// five pools that publish their own API — so the section degrades instead of going blank.

struct PoolOverview: Identifiable {
    let id: String          // unique per row (the pool's URL — 2Miners lists PPLNS and SOLO separately)
    let name: String
    let site: String
    let gradient: LinearGradient
    /// PPLNS · PPS · PROP · SOLO — shown next to the name, because it is what explains an
    /// outlying 收益/PH: a SOLO pool's payout is a lottery, not a rate.
    var feeType: String?
    var isSolo = false
    var poolHashrate: Double?      // raw H/s
    var networkHashrate: Double?   // raw H/s
    var miners: Int?
    var workers: Int?
    /// Blocks/day, measured over the sample window (not a raw count over an odd window).
    var blocksPerDay: Double?
    /// How many blocks the measurement rests on. Under ~20 the luck noise swamps the signal,
    /// so the row is marked "~" and can never take the green "best" badge.
    var blocksSample: Int = 0
    /// Measured earnings per PH·day (PRL), gross of fee: pool's blocks × reward ÷ hashrate.
    var earningsPerPH: Double?
    /// Gross theoretical PRL/PH·day on the same source/window as the observed yield.
    var theoreticalEarningsPerPH: Double?
    var blocksEstimated = false
    var feePercent: Double?
    /// True when the hashrate had to come from the pool's own API because the overview
    /// source doesn't carry one for it — footnoted, so the row isn't silently mixed-basis.
    var hashFromPoolAPI = false
    /// True for a row the primary source doesn't list at all and that was merged in from
    /// miningpoolstats (F2Pool). Also footnoted: its window is that source's, not this one's.
    var fromMiningPoolStats = false
    /// True when the row's fee / payout scheme was taken from the pool's OWN API because the
    /// aggregator has them wrong (Kryptex). Footnoted, since it changes how 收益/PH is derived.
    var feeFromPoolAPI = false
    var error: String?
    var hashrateHistory: [PoolHashratePoint] = []
    var averageHashrate7d: Double?
    var lastBlockDate: Date?
    var lifetimeBlocks: Int?
    var ppsMeasurement: PPSFeeMeasurement?
    var sharedPayouts: [PoolPayoutComparison]?
    var sharedTrustworthy: Bool?
    /// The service's 7-day block luck: the pool's blocks ÷ the blocks its reported work should
    /// have found, from five-minute samples. Nil until a week has been observed.
    var luck7d: SharedOverview.Luck?

    /// True when 预估收益 rests on the week rather than on one day of blocks.
    var usesWeekLuck: Bool {
        guard !isPPS, !isSolo, luck7d?.isUsable == true, let theory = theoreticalEarningsPerPH else { return false }
        return theory.isFinite && theory > 0
    }

    /// 预估收益 per PH·day, gross of fee. With a week of samples: today's theoretical yield ×
    /// the pool's 7-day luck — the luck is the pool's (a PPLNS miner gets it), the price is
    /// today's difficulty, the one PPS rows are quoted at. A day of ~20 blocks swings ±20% on
    /// luck alone, a week ~8%. Without the week, the 24h measurement.
    var estimatedEarningsPerPH: Double? {
        guard usesWeekLuck, let ratio = luck7d?.ratio, let theory = theoreticalEarningsPerPH else { return earningsPerPH }
        return ratio * theory
    }

    /// Observed block yield relative to the expected yield over the same window.
    /// A PPS contract's payout is independent of pool luck, so leave that comparison blank.
    var yieldRatio: Double? {
        guard !isPPS, !isSolo, let actual = earningsPerPH,
              let expected = theoreticalEarningsPerPH, expected > 0 else { return nil }
        return actual / expected
    }

    var share: Double? {
        guard let p = poolHashrate, let n = networkHashrate, n > 0 else { return nil }
        return p / n
    }
    /// PPS · PPS+ · FPPS — the pool pays a fixed rate per share, so its OWN luck never reaches
    /// the miner: it eats the variance and keeps the surplus. Deriving such a pool's yield
    /// from the blocks it happened to find therefore measures the wrong thing entirely —
    /// F2Pool's 4-block sample would price a 2% PPS contract as a lottery ticket. These rows
    /// carry the network's expected yield instead (see `networkYield` in build).
    var isPPS: Bool { (feeType ?? "").uppercased().hasPrefix("PPS") || (feeType ?? "").uppercased().hasPrefix("FPPS") }
    /// True when the measured yield rests on enough blocks to mean something. A PPS row's
    /// figure isn't measured at all, so it can't take the "best measured yield" badge either.
    var yieldTrustworthy: Bool {
        // The week's sample is the blocks its work should have found: a small pool that
        // found many by luck is still a small sample.
        if usesWeekLuck { return (luck7d?.expectedBlocks ?? 0) >= 20 }
        return sharedTrustworthy ?? (!isSolo && !isPPS && blocksSample >= 20 && earningsPerPH != nil)
    }

    /// Only PPS contracts participate in the real-cost column and its sorting.
    var realFeePercent: Double? {
        payoutComparisons.first(where: \.isPPS)?.realFeePercent
    }

    /// Keep PF as one physical pool, so its two contracts never double-count hashrate.
    var payoutComparisons: [PoolPayoutComparison] {
        if let sharedPayouts, !sharedPayouts.isEmpty {
            return sharedPayouts.map { original in
                var value = original
                if value.isPPS { value.measurement = ppsMeasurement }
                else if !value.solo, usesWeekLuck {
                    value.grossPerPH = estimatedEarningsPerPH
                    value.estimated = !yieldTrustworthy
                    value.weekly = true
                }
                return value
            }
        }
        if name == "Pearl Fortune", !isSolo {
            return [
                PoolPayoutComparison(scheme: "PPS", feePercent: 5,
                                     grossPerPH: theoreticalEarningsPerPH,
                                     theoreticalPerPH: theoreticalEarningsPerPH, estimated: true,
                                     measurement: ppsMeasurement),
                PoolPayoutComparison(scheme: "PPLNS", feePercent: feePercent ?? 2,
                                     grossPerPH: earningsPerPH,
                                     theoreticalPerPH: theoreticalEarningsPerPH,
                                     estimated: blocksEstimated || blocksSample < 20),
            ]
        }
        return [PoolPayoutComparison(scheme: feeType ?? "—", feePercent: feePercent,
                                     grossPerPH: earningsPerPH,
                                     theoreticalPerPH: theoreticalEarningsPerPH,
                                     estimated: isPPS || blocksEstimated || blocksSample < 20,
                                     solo: isSolo, measurement: ppsMeasurement)]
    }
}

/// A dated, paired observation. Actual credits and independent theoretical work earnings
/// are inputs; the advertised commission is deliberately absent.
struct PPSFeeMeasurement: Codable, Sendable {
    static let defaultsKey = "pool.ppsMeasuredFees"
    let pool: String
    let scheme: String
    let netPRL: Double
    let expectedPRL: Double
    let start: Double
    let end: Double
    let measuredAt: Double
    let estimated: Bool
    let sampleCount: Int
    var theoryBasis: String? = nil

    var realFeePercent: Double? {
        guard theoryBasis == "hashrate_chain",
              netPRL.isFinite, netPRL >= 0, expectedPRL.isFinite, expectedPRL > 0,
              start.isFinite, end.isFinite, start > 0, end > start,
              measuredAt.isFinite, measuredAt >= end, sampleCount > 0 else { return nil }
        let value = (1 - netPRL / expectedPRL) * 100
        return value.isFinite ? value : nil
    }
}

/// PPS income shortfall against theory. Shared and SOLO contracts leave real cost blank.
struct PoolPayoutComparison {
    let scheme: String
    let feePercent: Double?
    var grossPerPH: Double?
    let theoreticalPerPH: Double?
    var estimated: Bool
    var solo = false
    var measurement: PPSFeeMeasurement?
    /// `grossPerPH` is today's theory × the pool's 7-day luck, not one day's blocks.
    var weekly = false

    var isPPS: Bool { scheme.uppercased().hasPrefix("PPS") || scheme.uppercased().hasPrefix("FPPS") }

    var netPerPH: Double? {
        guard let gross = grossPerPH, gross.isFinite, gross >= 0,
              let fee = feePercent, fee.isFinite, (0...100).contains(fee) else { return nil }
        return gross * (1 - fee / 100)
    }

    var realFeePercent: Double? {
        guard isPPS, !solo, let measurement,
              measurement.scheme.uppercased() == scheme.uppercased() else { return nil }
        return measurement.realFeePercent
    }
}

/// Which feed the current rows came from — it decides the footnotes, because the columns
/// mean subtly different things per source (a 24h window vs a 1000-block one).
enum PoolsSource { case lordOfPearls, miningPoolStats, poolAPIs }

@MainActor
final class PoolsOverviewStore: ObservableObject {
    /// One store for the app's lifetime: the 矿池 section is rebuilt every time the user
    /// switches to it, and a per-view store refetched ~6 feeds from scratch on every switch.
    static let shared = PoolsOverviewStore()

    @Published var pools: [PoolOverview] = []
    @Published var loading = false
    /// Days the measured columns span (1 for lordofpearls' 24h window, ≈2.5 for
    /// miningpoolstats' 1000 blocks). Shown in the footnote so the numbers are legible.
    @Published var sampleDays: Double = 0
    /// Drives the "数据来源 …" caption; .poolAPIs until a source answers.
    @Published var source: PoolsSource = .poolAPIs
    @Published private(set) var updatedAt: Date?

    /// The aggregators re-poll the pools every ~10 minutes (lordofpearls sends max-age=300 on
    /// /pools), so re-entering the section within 5 minutes shows what's here.
    private static let ttl: TimeInterval = 300
    private var fetchedAt: Date?

    /// `force`: pull-to-refresh — skip the TTL AND the HTTP cache. Otherwise the feeds are read
    /// with the protocol cache policy, so the sites' own Cache-Control applies.
    func refresh(force: Bool = false) async {
        if loading { return }
        if !force, !pools.isEmpty, let t = fetchedAt, Date().timeIntervalSince(t) < Self.ttl { return }
        loading = true
        defer { loading = false }
        let live = force
        if let snapshot = try? await SharedPublicData.shared.overview(force: force), !snapshot.rows.isEmpty {
            guard !Task.isCancelled else { return }
            pools = Self.build(snapshot)
            source = snapshot.source == "lordofpearls" ? .lordOfPearls : .miningPoolStats
            sampleDays = snapshot.source == "lordofpearls" ? 1 : (snapshot.rows.first?.sampleDays ?? 1)
            fetchedAt = Date()
            updatedAt = Date(timeIntervalSince1970: snapshot.ts)
            return
        }
        guard !Task.isCancelled else { return }
        let measurementData = try? await Self.serverFeeData(live: live)
        if let rows = try? await Self.lordOfPearls(live: live), !rows.isEmpty {
            pools = Self.applyMeasurements(rows, data: measurementData)
            sampleDays = 1          // the site's block column is a flat 24h count
            source = .lordOfPearls
            fetchedAt = Date()
            updatedAt = fetchedAt
            return
        }
        // Left the section mid-load: the requests above were cancelled, not refused — don't
        // fall through and replace a good (shared) table with a fallback built from failures.
        guard !Task.isCancelled else { return }
        if let mps = try? await MiningPoolStatsClient(live: live).fetch() {
            async let kryptex = try? KryptexClient().poolStats(live: live)
            async let fortune = try? PearlFortuneClient().summary(live: live)
            pools = Self.applyMeasurements(Self.build(mps, kryptex: await kryptex, fortune: await fortune), data: measurementData)
            sampleDays = mps.sampleDays
            source = .miningPoolStats
            fetchedAt = Date()
            updatedAt = fetchedAt
            return
        }
        guard !Task.isCancelled else { return }
        // Both aggregators unreachable → the six pools with their own public API, as before.
        async let a = Self.alpha(live: live)
        async let l = Self.lucky(live: live)
        async let h = Self.hero(live: live)
        async let p = Self.pearlHash(live: live)
        async let f = Self.pearlFortune(live: live)
        async let k = Self.kryptex(live: live)
        async let chainTask = try? LordOfPearlsClient(live: live).publicStats()
        // Sorted by hashrate like the primary path — the table renders rows in the order it
        // is handed them, so an unsorted fallback would shuffle the ranking under the user.
        var rows = [await a, await l, await h, await p, await f, await k]
        if let chain = await chainTask, let reward = chain.rewardPerBlock,
           let difficulty = chain.averageDifficulty(days: 1) ?? chain.difficulty {
            let theoretical = reward * 86400 * 1e15 / (difficulty * prlWorkPerDifficulty)
            for i in rows.indices where rows[i].theoreticalEarningsPerPH == nil && rows[i].name != "Pearl Fortune" {
                rows[i].theoreticalEarningsPerPH = theoretical
            }
        }
        guard !Task.isCancelled else { return }
        pools = Self.applyMeasurements(rows.sorted { ($0.poolHashrate ?? 0) > ($1.poolHashrate ?? 0) }, data: measurementData)
        sampleDays = 1
        source = .poolAPIs
        // A fallback table is a degraded answer — worth retrying on the next visit.
        fetchedAt = nil
        updatedAt = pools.contains { $0.poolHashrate != nil } ? Date() : nil
    }

    /// Explicit server observations only. Never read a device-specific audit cache.
    static func applyMeasurements(_ rows: [PoolOverview], data: Data? = nil) -> [PoolOverview] {
        guard let data, let measurements = try? JSONDecoder().decode([PPSFeeMeasurement].self, from: data) else { return rows }
        return rows.map { original in
            var row = original
            row.ppsMeasurement = measurements.filter { observation in
                observation.pool == row.name && observation.realFeePercent != nil &&
                    row.payoutComparisons.contains { $0.isPPS && $0.scheme.uppercased() == observation.scheme.uppercased() }
            }
                .max { $0.measuredAt < $1.measuredAt }
            return row
        }
    }

    private static func serverFeeData(live: Bool) async throws -> Data {
        struct Reply: Decodable { let ok: Bool; let measurements: [PPSFeeMeasurement] }
        let data = try await PoolHTTP.get("https://pearlhub.net/v1/pool-fees", live: live)
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard reply.ok else { throw URLError(.badServerResponse) }
        return try JSONEncoder().encode(reply.measurements)
    }

    // MARK: lordofpearls → the table

    /// Use the same normalized rows as Web, including each source's actual window.
    static func build(_ snapshot: SharedOverview) -> [PoolOverview] {
        snapshot.rows.map { row in
            var pool = PoolOverview(id: row.id, name: row.name, site: row.url,
                                    gradient: gradients[row.name] ?? Pearl.wash,
                                    feeType: row.scheme, isSolo: row.solo,
                                    poolHashrate: row.hashrate, networkHashrate: snapshot.network?.hashrate,
                                    miners: row.miners, blocksPerDay: row.blocksPerDay,
                                    blocksSample: row.blocksSample ?? 0,
                                    earningsPerPH: row.earningsPerPH,
                                    theoreticalEarningsPerPH: row.theoreticalEarningsPerPH,
                                    blocksEstimated: row.payouts?.first(where: { $0.scheme == row.scheme })?.estimated ?? ((row.blocksSample ?? 0) < 20),
                                    feePercent: row.fee, hashFromPoolAPI: row.hashFromPoolAPI ?? false,
                                    fromMiningPoolStats: row.source == "miningpoolstats",
                                    feeFromPoolAPI: row.feeFromPoolAPI ?? false)
            pool.hashrateHistory = (row.history ?? []).map { PoolHashratePoint(time: $0.ts, hashrate: $0.hashrate) }
            pool.averageHashrate7d = row.averageHashrate7d
            pool.lastBlockDate = row.lastBlockTime.map { Date(timeIntervalSince1970: $0) }
            pool.lifetimeBlocks = row.lifetimeBlocks
            pool.sharedTrustworthy = row.trustworthy
            pool.luck7d = row.luck?["7d"]
            pool.sharedPayouts = row.payouts?.map {
                PoolPayoutComparison(scheme: $0.scheme ?? "—", feePercent: $0.fee,
                                     grossPerPH: $0.grossPerPH, theoreticalPerPH: row.theoreticalEarningsPerPH,
                                     estimated: $0.estimated, solo: $0.solo)
            }
            if let observation = row.realFeeMeasurement, observation.pool == row.name,
               observation.realFeePercent != nil,
               pool.payoutComparisons.contains(where: { $0.isPPS && $0.scheme == observation.scheme }) {
                pool.ppsMeasurement = observation
            }
            return pool
        }
    }

    /// The /pools table joined to the chain numbers /api/public publishes: the table itself
    /// carries neither the network hashrate (→ 占比) nor the block reward (→ 收益/PH·天).
    /// HeroMiners rides along because the site prints "—" for its hashrate while the pool's
    /// own API does publish one — see `build` below.
    private static func lordOfPearls(live: Bool) async throws -> [PoolOverview] {
        let client = LordOfPearlsClient(live: live)
        async let rowsTask = client.pools()
        async let chainTask = client.publicStats()
        async let heroTask = HeroMinersClient().stats(live: live)
        async let mpsTask = MiningPoolStatsClient(live: live).fetch()
        async let kryptexTask = KryptexClient().poolStats(live: live)
        async let fortuneTask = PearlFortuneClient().summary(live: live)
        let rows = try await rowsTask
        let chain = try? await chainTask
        let hero = try? await heroTask
        return build(rows, chain: chain,
                     heroHashrate: hero?.poolHashrate,
                     mps: try? await mpsTask,
                     kryptex: try? await kryptexTask,
                     fortune: try? await fortuneTask,
                     heroFeePercent: hero?.config?.fee?.value)
    }

    static func build(_ rows: [LOPPool], chain: LOPPublic?, heroHashrate: Double?,
                      mps: MPSCoin?, kryptex: KryptexPoolStats? = nil,
                      fortune: PFSummary? = nil, heroFeePercent: Double? = nil) -> [PoolOverview] {
        // The 24h chain-identity figure, the same one the monitor's dashboard shows: the
        // site's own 60-block `networkhashps` ran ~10% high, understating every pool's 占比.
        let network = chain?.networkHashrate24h ?? chain?.networkHashrate
        let reward = chain?.rewardPerBlock ?? mps?.rewardPerBlock ?? 0
        let expected = networkYield(reward: reward, network: network,
                                    blockTime: chain?.blockTime24h ?? chain?.blockTimeSec)
        let theoretical = chain?.averageDifficulty(days: 1).flatMap { difficulty in
            reward > 0 ? reward * 86400 * 1e15 / (difficulty * prlWorkPerDifficulty) : nil
        } ?? expected
        var out = rows.map { r -> PoolOverview in
            let key = brandKey(r.host)
            let name = pretty[key] ?? r.name       // the site's own label when we have no better
            // lordofpearls doesn't poll HeroMiners' hashrate ("does not publish a
            // machine-readable feed" — it does; the site simply hasn't wired it), which would
            // leave the network's third-biggest block producer with no 算力 and no 收益 at all.
            // Its own API is the same kind of poll the site runs for every other row.
            let filled = r.hashrate == nil && key == "herominers.com" ? heroHashrate : nil
            let hps = r.hashrate ?? filled
            let solo = (r.payout ?? "").uppercased() == "SOLO" || r.url.lowercased().contains("solo")
            var o = PoolOverview(id: r.url.isEmpty ? r.name : r.url,
                                 name: name,
                                 site: r.url,
                                 gradient: gradients[name] ?? Pearl.wash,
                                 feeType: r.payout,
                                 isSolo: solo,
                                 poolHashrate: hps,
                                 networkHashrate: network,
                                 miners: r.miners,
                                 blocksPerDay: r.blocks24h.map(Double.init),
                                 blocksSample: r.blocks24h ?? 0,
                                 feePercent: r.feePercent,
                                 hashFromPoolAPI: filled != nil)
            o.theoreticalEarningsPerPH = theoretical
            // BEFORE the yield below: the correction can flip the row to PPS, and a PPS row's
            // 收益/PH is the network's expected value rather than a block count.
            if name == "Kryptex", let k = kryptex { applyKryptex(&o, k) }
            if name == "Pearl Fortune" { o.feeType = "PPLNS"; o.feePercent = 2 }
            if name == "PearlHash" { o.feePercent = PearlHashClient.fee }
            if name == "HeroMiners", let heroFeePercent { o.feePercent = heroFeePercent }
            if o.isPPS {
                o.earningsPerPH = theoretical      // a fixed rate per share — see isPPS
            } else if reward > 0, let h = hps, h > 0, let b = r.blocks24h, b >= 0 {
                // Measured, luck-included yield over the same 24h the block column counts.
                o.earningsPerPH = Double(b) * reward / (h / 1e15)
                o.blocksEstimated = b < 20         // too few blocks to trust → shown as "~"
            }
            if name == "Pearl Fortune", let fortune { applyFortune(&o, fortune) }
            if let history = mps?.data.first(where: {
                samePoolHost(host($0), key: key) && !($0.url ?? "").lowercased().contains("solo")
            }) {
                applyHistory(&o, history)
            }
            let matchesPool: (LOPPublic.PoolIdentity?) -> Bool = { identity in
                guard let url = identity?.url, let host = URLComponents(string: url)?.host else { return false }
                return samePoolHost(host.lowercased(), key: key)
            }
            let lifetime = (chain?.lifetime?.top ?? []).filter { matchesPool($0.pool) }.compactMap(\.blocks)
            if !lifetime.isEmpty { o.lifetimeBlocks = lifetime.reduce(0, +) }
            let recent = (chain?.leaderboard?.recent_blocks ?? []).filter { matchesPool($0.pool) }
                .compactMap(\.time).filter { $0.isFinite && $0 > 0 }.max()
            if let recent {
                o.lastBlockDate = max(o.lastBlockDate ?? .distantPast, Date(timeIntervalSince1970: recent))
            }
            return o
        }
        if let f2 = mps.flatMap({ f2pool($0, network: network) }) {
            out.append(f2)
        }
        // The site ranks by live hashrate; re-sort so the rows it didn't rank itself
        // (HeroMiners' filled hashrate, F2Pool) land where they belong. No hashrate = last.
        return out.sorted { ($0.poolHashrate ?? -1) > ($1.poolHashrate ?? -1) }
    }

    /// lordofpearls lists eight pools but not F2Pool — while F2Pool does mine PRL (its blocks
    /// land in the site's unattributed bucket), it is one of the pools this app itself watches,
    /// and F2Pool publishes no pool-level API to fill the gap from. miningpoolstats does carry
    /// it, so the row is merged from there — measured on THAT source's window (its last-1000-
    /// block sample, ≈4 days) rather than the table's 24h, hence the footnote.
    private static func f2pool(_ c: MPSCoin, network: Double?) -> PoolOverview? {
        guard let p = c.data.first(where: { host($0) == "f2pool.com" }), p.hps > 0 else { return nil }
        let days = c.sampleDays, sample = p.blocksIn1000
        var o = PoolOverview(id: p.url ?? "f2pool.com",
                             name: "F2Pool",
                             site: p.url ?? "https://www.f2pool.com",
                             gradient: gradients["F2Pool"] ?? Pearl.wash,
                             feeType: feeType(p.feetype),
                             poolHashrate: p.hps,
                             networkHashrate: network,
                             miners: p.minerCount,
                             blocksPerDay: days > 0 && p.blocks_1000 != nil && sample >= 0 ? Double(sample) / days : nil,
                             blocksSample: sample,
                             feePercent: p.fee?.value,
                             fromMiningPoolStats: true)
        o.theoreticalEarningsPerPH = networkYield(reward: c.rewardPerBlock,
                                                  network: c.network, blockTime: c.blockTime)
        applyHistory(&o, p)
        if o.isPPS {
            o.earningsPerPH = o.theoreticalEarningsPerPH
        } else if c.rewardPerBlock > 0, days > 0, p.blocks_1000 != nil, sample >= 0 {
            o.earningsPerPH = Double(sample) * c.rewardPerBlock / (days * p.hps / 1e15)
            o.blocksEstimated = sample < 20
        }
        return o
    }

    /// Kryptex, as Kryptex describes itself, laid over the aggregator's row.
    ///
    /// Both aggregators get its CONTRACT wrong — lordofpearls prints "PROP · 1%",
    /// miningpoolstats "1" — while the pool runs PPS+ at 2% (SOLO 1%). That is not cosmetic:
    /// a PPS pool eats its own luck and pays a fixed rate per share, so deriving its yield
    /// from the blocks it happened to find measures the wrong thing entirely (see `isPPS`),
    /// and at 21% of the network this is the row most likely to take the green badge on a
    /// figure that was never a rate. The pool's own /pool/stats is the authority for its fee
    /// and scheme, and carries a live miner/worker count while it's there.
    private static func applyKryptex(_ o: inout PoolOverview, _ k: KryptexPoolStats) {
        // The SOLO listing is a different contract (1%, lottery payout) and must keep the
        // aggregator's row — /pool/stats describes the shared one.
        guard !o.isSolo else { return }
        if let t = k.fee_type, !t.isEmpty { o.feeType = t }
        if let f = k.feePercent { o.feePercent = f }
        if let m = k.miners, m > 0 { o.miners = m }
        if let w = k.workers, w > 0 { o.workers = w }
        if (o.poolHashrate ?? 0) <= 0, let h = k.poolHashrate {
            o.poolHashrate = h
            o.hashFromPoolAPI = true
        }
        o.feeFromPoolAPI = true
    }

    /// What one PH·day earns from the NETWORK, gross of fee: 单块奖励 × 每天出块 ÷ 全网算力.
    /// This is the figure a PPS pool's fixed rate is written against, and it is what such a
    /// row shows instead of a block count. Window-independent by construction: the network
    /// hashrate a source reports and the block time it measures come from the same sample and
    /// cancel (nethash ∝ difficulty ÷ blocktime), so a lucky hour can't inflate it.
    ///
    /// Deliberately NOT the rate a pool advertises: F2Pool's own PRL page quotes 0.0375
    /// PRL/TH·day, which is its 194s block-time assumption — the chain has been running near
    /// 300s, and one row priced on a different chain than the rest is worse than no row.
    private static func networkYield(reward: Double, network: Double?, blockTime: Double?) -> Double? {
        guard reward > 0, let n = network, n > 0, let bt = blockTime, bt > 0 else { return nil }
        return reward * (86400 / bt) / (n / 1e15)
    }

    /// A pool's host reduced to the key `pretty`/`gradients` are written against: hosts are
    /// subdomained per coin ("pearl.herominers.com"), and each source spells the names its
    /// own way ("AlphaMine" is the app's AlphaPool).
    private static func brandKey(_ host: String) -> String {
        pretty.keys.first { host == $0 || host.hasSuffix("." + $0) } ?? host
    }

    /// Kryptex has two public domains; its history and live API use different ones.
    private static func samePoolHost(_ host: String, key: String) -> Bool {
        let other = brandKey(host)
        return other == key || (pretty[other] != nil && pretty[other] == pretty[key])
    }

    private static func applyHistory(_ o: inout PoolOverview, _ p: MPSPool) {
        o.hashrateHistory = p.hashrateHistory
        o.averageHashrate7d = (p.hashrate_average_7d?.value).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        o.lastBlockDate = p.lastBlockDate
    }

    // MARK: miningpoolstats → the table

    /// Pretty names for the pools worth naming; everything else keeps its own domain, which is
    /// honest and needs no upkeep as pools come and go.
    private static let pretty: [String: String] = [
        "alphapool.tech": "AlphaPool", "luckypool.io": "Lucky Pool", "herominers.com": "HeroMiners",
        "pearlhash.xyz": "PearlHash", "pearlfortune.org": "Pearl Fortune", "f2pool.com": "F2Pool",
        "pool.kryptex.com": "Kryptex", "kryptex.network": "Kryptex", "2miners.com": "2Miners",
        "k1pool.com": "K1Pool",
        "c3pool.org": "C3Pool", "baikalmine.com": "BaikalMine", "woolypooly.com": "WoolyPooly",
        "suprnova.cc": "Suprnova", "rabbitminer.cc": "RabbitMiner", "grandpool.io": "GrandPool",
        "himpool.com": "HimPool", "nushypool.com": "NushyPool", "akoyapool.com": "AkoyaPool",
    ]

    /// Each pool's own colour — the same in either palette (配色), so from `Pearl.classic`.
    private static let gradients: [String: LinearGradient] = [
        "AlphaPool": Pearl.classic.brand, "Lucky Pool": Pearl.classic.mint, "HeroMiners": Pearl.classic.positive,
        "PearlHash": Pearl.classic.brandVivid, "Pearl Fortune": Pearl.classic.sunrise, "Kryptex": Pearl.classic.negative,
        // Teal-led, matching the slice the donut already gives F2Pool.
        "F2Pool": LinearGradient(colors: [Pearl.classic.teal, Pearl.classic.accent],
                                 startPoint: .topLeading, endPoint: .bottomTrailing),
    ]

    /// The pool's own domain — the stable key behind both its name and its colour.
    private static func host(_ p: MPSPool) -> String {
        if let id = p.pool_id, !id.isEmpty { return id }
        let h = (p.url.flatMap { URLComponents(string: $0)?.host } ?? "?")
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// "PPS+%2|SOLO%1" → "PPS+". The scheme, without the rates glued to it.
    private static func feeType(_ raw: String?) -> String? {
        guard let s = raw?.split(separator: "|").first?.split(separator: "%").first, !s.isEmpty
        else { return nil }
        return String(s)
    }

    static func build(_ c: MPSCoin, kryptex: KryptexPoolStats? = nil,
                      fortune: PFSummary? = nil) -> [PoolOverview] {
        let reward = c.rewardPerBlock, days = c.sampleDays, network = c.network
        let expected = networkYield(reward: reward, network: network > 0 ? network : nil,
                                    blockTime: c.blockTime)
        return c.data
            .filter { $0.hps > 0 }                      // a dead pool is noise, not a choice
            .sorted { $0.hps > $1.hps }
            .map { p -> PoolOverview in
                let key = host(p)
                let name = pretty[key] ?? key
                let url = p.url ?? ""
                // A pool that runs a SOLO endpoint alongside a shared one lists them as two
                // rows under one pool_id (2Miners, K1Pool…) — tell them apart by the URL, not
                // by feetype, which also says "SOLO" for a shared pool that merely offers it.
                let solo = url.lowercased().contains("solo") || feeType(p.feetype) == "SOLO"
                let hps = p.hps
                let sample = p.blocksIn1000
                var o = PoolOverview(id: url.isEmpty ? key : url,
                                     name: solo && pretty[key] != nil ? name + " SOLO" : name,
                                     site: url,
                                     gradient: gradients[name] ?? Pearl.wash,
                                     feeType: feeType(p.feetype),
                                     isSolo: solo,
                                     poolHashrate: hps,
                                     networkHashrate: network > 0 ? network : nil,
                                     miners: p.minerCount,
                                     workers: p.workerCount,
                                     blocksPerDay: days > 0 && p.blocks_1000 != nil && sample >= 0 ? Double(sample) / days : nil,
                                     blocksSample: sample,
                                     feePercent: p.fee?.value)
                o.theoreticalEarningsPerPH = expected
                applyHistory(&o, p)
                // Before the yield, as in the lordofpearls path — the correction decides
                // whether this row is measured at all.
                if name == "Kryptex", let k = kryptex { applyKryptex(&o, k) }
                if name == "Pearl Fortune" { o.feeType = "PPLNS"; o.feePercent = 2 }
                if name == "PearlHash" { o.feePercent = PearlHashClient.fee }
                if o.isPPS {
                    o.earningsPerPH = expected          // fixed rate per share — see isPPS
                } else if reward > 0, days > 0, hps > 0, p.blocks_1000 != nil, sample >= 0 {
                    // Measured, luck-included yield: what this pool's hashrate ACTUALLY earned
                    // over the sample, per PH per day. Gross of fee — fee has its own column.
                    o.earningsPerPH = Double(sample) * reward / (days * hps / 1e15)
                    o.blocksEstimated = sample < 20     // too few blocks to trust → shown as "~"
                }
                if name == "Pearl Fortune", let fortune { applyFortune(&o, fortune) }
                return o
            }
    }

    // MARK: fallback — the pools that publish their own API

    private static func alpha(live: Bool) async -> PoolOverview {
        var o = PoolOverview(id: "AlphaPool", name: "AlphaPool",
                             site: "https://pearl.alphapool.tech", gradient: Pearl.classic.brand)
        do {
            let s = try await PoolClient().stats(live: live)
            let coin = s.coins?.first
            o.poolHashrate = (s.pool?.hashrate).map(parseHashrate)
            o.networkHashrate = (coin?.network_hash).map(parseHashrate)
            o.miners = s.pool?.miners24h
            o.workers = s.pool?.workers
            o.blocksPerDay = (s.pool?.blocks24h).map(Double.init)
            o.blocksSample = s.pool?.blocks24h ?? 0
            o.feePercent = s.feePercent
            if let b24 = s.pool?.blocks24h, let rew = coin?.reward,
               let hps = o.poolHashrate, hps > 0 {
                o.earningsPerPH = Double(b24) * rew / (hps / 1e15)
            }
        } catch { o.error = Loc("暂时无法获取矿池数据") }
        return o
    }

    private static func lucky(live: Bool) async -> PoolOverview {
        var o = PoolOverview(id: "Lucky Pool", name: "Lucky Pool",
                             site: "https://pearl.luckypool.io", gradient: Pearl.classic.mint)
        do {
            let v = try await LuckyPoolClient().statsV2(live: live)
            o.feePercent = v.config?.fee
            o.poolHashrate = v.stats?.hashrate
            let now = Date().timeIntervalSince1970
            var b24 = 0, rew24 = 0.0
            for blk in v.blocks ?? [] {
                guard (blk.status ?? "") != "orphaned", let tms = blk.timestamp else { continue }
                if now - tms / 1000 < 86400 { b24 += 1; rew24 += (blk.reward ?? 0) / 1e8 }
            }
            o.blocksPerDay = Double(b24)
            o.blocksSample = b24
            if let hps = o.poolHashrate, hps > 0, rew24 > 0 {
                o.earningsPerPH = rew24 / (hps / 1e15)
            }
        } catch { o.error = Loc("暂时无法获取矿池数据") }
        return o
    }

    private static func hero(live: Bool) async -> PoolOverview {
        var o = PoolOverview(id: "HeroMiners", name: "HeroMiners",
                             site: "https://pearl.herominers.com", gradient: Pearl.classic.positive)
        do {
            let s = try await HeroMinersClient().stats(live: live)
            o.feePercent = s.config?.fee?.value
            o.poolHashrate = s.poolHashrate   // realHashrate, else the >>32 field scaled back up
            o.miners = s.pool?.miners
            o.workers = s.pool?.workers
            let now = Date().timeIntervalSince1970
            var times: [Double] = [], rew24 = 0.0
            for blk in s.pool?.blocks ?? [] {
                let p = blk.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                guard p.count > 7, let t = Double(p[1]), p[6] != "orphaned" else { continue }
                if now - t < 86400 { times.append(t); rew24 += (Double(p[7]) ?? 0) / HeroMinersClient.coinUnits }
            }
            if let oldest = times.min(), let hps = o.poolHashrate, hps > 0, !times.isEmpty {
                let span = min(max((now - oldest) / 3600, 1), 24)   // hours the feed covers, 1…24
                o.blocksPerDay = Double(times.count) / span * 24
                o.blocksSample = times.count
                o.earningsPerPH = (rew24 / span * 24) / (hps / 1e15)
                o.blocksEstimated = (now - oldest) < 23 * 3600      // feed shorter than ~23h
            }
        } catch { o.error = Loc("暂时无法获取矿池数据") }
        return o
    }

    private static func pearlHash(live: Bool) async -> PoolOverview {
        var o = PoolOverview(id: "PearlHash", name: "PearlHash",
                             site: "https://pearlhash.xyz", gradient: Pearl.classic.brandVivid)
        o.feePercent = PearlHashClient.fee
        do {
            let client = PearlHashClient()
            // The pool's own node answers for the network, and its wallet ledger for its blocks
            // — so this row carries 占比 and a measured 收益/PH even with every aggregator down.
            async let chainTask = try? client.chainInfo(live: live)
            async let blocksTask = try? client.recentBlocks(live: live)
            let s = try await client.stats(live: live)
            o.poolHashrate = s.hashrate
            o.miners = s.total_accounts
            o.workers = s.total_workers
            o.networkHashrate = (await chainTask?.networkhashps).flatMap { $0 > 0 ? $0 : nil }
            // Measured over the window the feed actually covers (one page ≈ 8h), the same way
            // HeroMiners' fallback row is measured — extrapolated to a day and marked "~",
            // because 8 hours of luck is not a day's worth of evidence.
            let blocks = await blocksTask ?? []
            let now = Date().timeIntervalSince1970
            let times = blocks.compactMap { ($0.timeMs).map { $0 / 1000 } }.filter { now - $0 < 86400 }
            if let oldest = times.min(), !times.isEmpty, let hps = o.poolHashrate, hps > 0 {
                let span = min(max((now - oldest) / 3600, 1), 24)      // hours covered, 1…24
                let rewards = blocks.map(\.rewardPRL).filter { $0 > 0 }.sorted()
                let reward = rewards.isEmpty ? 0 : rewards[rewards.count / 2]
                o.blocksPerDay = Double(times.count) / span * 24
                o.blocksSample = times.count
                o.earningsPerPH = Double(times.count) / span * 24 * reward / (hps / 1e15)
                o.blocksEstimated = (now - oldest) < 23 * 3600
            }
        } catch { o.error = Loc("暂时无法获取矿池数据") }
        return o
    }

    /// Kryptex from its own API alone — no aggregator involved, so this row is also the
    /// yardstick the corrections above are written against.
    private static func kryptex(live: Bool) async -> PoolOverview {
        var o = PoolOverview(id: "Kryptex", name: "Kryptex",
                             site: "https://pool.kryptex.com/prl", gradient: Pearl.classic.negative)
        do {
            let client = KryptexClient()
            async let blocksTask = try? client.blocks(live: live)
            let s = try await client.poolStats(live: live)
            o.poolHashrate = s.poolHashrate
            o.networkHashrate = s.networkHashrate
            o.miners = s.miners
            o.workers = s.workers
            o.feePercent = s.feePercent
            o.feeType = s.fee_type
            o.feeFromPoolAPI = true
            // PPS+ — the yield is the CONTRACT's, i.e. what one PH·day is worth on the network,
            // not what this pool's blocks happened to pay. Both inputs come from the pool's own
            // block feed: the subsidy, and a block time measured across network heights (the
            // pool's advertised `block_time` of 120s is a config value, ~half the real one).
            let blocks = await blocksTask ?? []
            o.earningsPerPH = networkYield(reward: KryptexClient.rewardPerBlock(from: blocks)
                                               ?? s.rewardPerBlock ?? 0,
                                           network: o.networkHashrate,
                                           blockTime: KryptexClient.blockTime(from: blocks))
            o.theoreticalEarningsPerPH = o.earningsPerPH
        } catch { o.error = Loc("暂时无法获取矿池数据") }
        return o
    }

    private static func pearlFortune(live: Bool) async -> PoolOverview {
        var o = PoolOverview(id: "Pearl Fortune", name: "Pearl Fortune",
                             site: "https://pearlfortune.org", gradient: Pearl.classic.sunrise,
                             feeType: "PPLNS", feePercent: 2)
        do {
            let s = try await PearlFortuneClient().summary(live: live)
            applyFortune(&o, s)
        } catch { o.error = Loc("暂时无法获取矿池数据") }
        return o
    }

    /// PF supplies actual and expected coins for the SAME rolling window and work sample.
    static func applyFortune(_ o: inout PoolOverview, _ s: PFSummary) {
        o.feeType = "PPLNS"
        o.feePercent = s.pool_stats?.pool_fee_rate.map { ($0 * 10000).rounded() / 100 } ?? 2
        o.feeFromPoolAPI = true
        // PF's own network figure only when the row has none (its stand-alone row): a table
        // built with the chain's 24h figure keeps that for every row, or this pool's 占比
        // would be measured against a different network from the others'.
        o.networkHashrate = o.networkHashrate ?? s.stats?.network_hashrate.map(parseHashrate)
        let roll = s.pool_stats?.rolling_stats ?? []
        if let h = roll.first(where: { $0.hours == 1 })?.hashrate, h > 0 { o.poolHashrate = h }
        guard let r24 = roll.first(where: { $0.hours == 24 }),
              let h = r24.hashrate, h > 0 else { return }
        if o.poolHashrate == nil { o.poolHashrate = h }
        o.blocksPerDay = r24.block_count.map(Double.init)
        o.blocksSample = r24.block_count ?? 0
        o.blocksEstimated = o.blocksSample < 20
        // Clear older-source values when this window omits either half of the comparison.
        o.earningsPerPH = r24.total_coins.map { $0 / (h / 1e15) }
        o.theoreticalEarningsPerPH = r24.expected_coins.map { $0 / (h / 1e15) }
    }
}

/// Pool overview rendered as a section inside the PRL monitor's segmented control.
struct PoolsOverviewSection: View {
    @ObservedObject private var store = PoolsOverviewStore.shared
    @Environment(\.locale) private var locale
    @State private var showingNotes = false
    @State private var showingShare = false

    var body: some View {
        GeometryReader { geometry in
            // The phone's table (PoolComparisonTable.mobileTable) takes the same cut.
            let compact = geometry.size.width - 60 < 720
            ScrollView {
                VStack(alignment: .leading, spacing: compact ? 14 : 20) {
                    if compact {
                        // The 矿池 pill right above already names the page: on a phone
                        // the big title only pushed the table down.
                        updateStatus
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .firstTextBaseline) {
                                title
                                Spacer(minLength: 24)
                                updateStatus
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                title
                                updateStatus
                            }
                        }
                    }
                    if store.pools.isEmpty && store.loading {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    } else if store.pools.isEmpty {
                        PearlEmptyState(systemImage: "server.rack", title: Loc("矿池总览"),
                                        message: Loc("暂时无法获取矿池数据"))
                    } else {
                        PoolComparisonTable(pools: store.pools, source: store.source,
                                            availableWidth: min(geometry.size.width - 60, 1500))
                        DisclosureGroup(Loc("数据说明"), isExpanded: $showingNotes) {
                            PoolComparisonNotes(pools: store.pools, sampleDays: store.sampleDays,
                                                source: store.source)
                                .padding(.top, 12)
                        }
                        .font(.callout)
                        .pearlCard(padding: 16, radius: 12)
                        DisclosureGroup(Loc("算力占比"), isExpanded: $showingShare) {
                            HashShareChart(pools: store.pools).padding(.top, 12)
                        }
                        .font(.callout)
                        .pearlCard(padding: 16, radius: 12)
                    }
                }
                .padding(compact ? 16 : 20)
                .frame(maxWidth: 1540)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await store.refresh(force: true) }
        }
        .task { await store.refresh() }
    }

    private var title: some View {
        Text(Loc("矿池总览"))
            .font(.system(size: 30, weight: .bold))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var updateStatus: some View {
        HStack(spacing: 12) {
            if let updated = store.updatedAt {
                Text(Loc("更新于 %@", updated.formatted(.dateTime.hour().minute().locale(locale))))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(store.source == .miningPoolStats ? f(store.sampleDays, 1) + "d" : "24h")
                .font(.callout.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Pearl.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Pearl.surfaceEdge))
            Button { Task { await store.refresh(force: true) } } label: {
                if store.loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.plain)
            .disabled(store.loading)
            .accessibilityLabel(Loc("刷新矿池数据"))
        }
    }
}

/// A roomy comparison table on iPad/Mac; the same metrics stack on a narrow phone.
/// Missing figures stay missing, and the existing PPS / low-sample distinctions remain visible.
private struct PoolComparisonTable: View {
    let pools: [PoolOverview]
    let source: PoolsSource
    let availableWidth: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @State private var sortColumn: Column = .hashrate
    @State private var ascending = false

    private enum Column: CaseIterable {
        case name, hashrate, trend, earnings, blocks, fee, realFee, lastBlock

        var fraction: CGFloat {
            switch self {
            case .name: 0.18
            case .hashrate: 0.14
            case .trend: 0.105
            case .earnings: 0.14
            case .blocks: 0.11
            case .fee: 0.08
            case .realFee: 0.12
            case .lastBlock: 0.125
            }
        }
    }

    private var tableWidth: CGFloat { max(availableWidth, 1080) }
    /// The phone's table. Each cell keeps to its figure and one line under it, so a
    /// row stays short and the eye can run down a column.
    private var compact: Bool { availableWidth < 720 }
    private var lineGap: CGFloat { compact ? 3 : 8 }
    private var best: Double { pools.filter(\.yieldTrustworthy).compactMap(\.estimatedEarningsPerPH).max() ?? -1 }
    private var sortedPools: [PoolOverview] {
        let selectedColumn = sortColumn
        let ascending = ascending
        return pools.sorted { a, b in
            if selectedColumn == .name {
                return ascending ? a.name < b.name : a.name > b.name
            }
            func value(_ pool: PoolOverview) -> Double? {
                switch selectedColumn {
                case .hashrate: pool.poolHashrate
                case .earnings: pool.isSolo ? nil : pool.estimatedEarningsPerPH
                case .blocks: pool.blocksPerDay
                case .fee: pool.feePercent
                case .realFee: pool.realFeePercent
                case .lastBlock: pool.lastBlockDate?.timeIntervalSince1970
                default: nil
                }
            }
            // Missing values always sort to the end, including in ascending order.
            guard let av = value(a) else { return value(b) == nil ? a.name < b.name : false }
            guard let bv = value(b) else { return true }
            if av == bv { return a.name < b.name }
            return ascending ? av < bv : av > bv
        }
    }

    var body: some View {
        if availableWidth < 720 {
            mobileTable
        } else {
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    headerRow
                    ForEach(sortedPools) { pool in
                        Divider()
                        dataRow(pool)
                    }
                }
                .frame(width: tableWidth)
            }
            .background(Pearl.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Pearl.surfaceEdge, lineWidth: 1))
        }
    }

    // One shared horizontal scroll keeps every pool's columns aligned. The name
    // column stays outside it, so the pool remains identifiable at any offset.
    private var mobileColumns: [Column] { [.hashrate, .realFee, .fee, .earnings, .blocks, .trend, .lastBlock] }
    private func mobileWidth(_ column: Column) -> CGFloat {
        switch column {
        case .name: 120
        case .hashrate: 128
        case .realFee: 118
        case .fee: 90
        case .earnings: 132
        case .blocks: 116
        case .trend: 110
        case .lastBlock: 124
        }
    }
    private func rowHeight(_ pool: PoolOverview) -> CGFloat {
        let schemes = pool.payoutComparisons.count > 1
        return compact ? (schemes ? 108 : 76) : (schemes ? 126 : 100)
    }

    private var mobileTable: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    heading(.name, width: mobileWidth(.name))
                    ForEach(sortedPools) { pool in
                        Divider()
                        VStack(alignment: .leading, spacing: lineGap) {
                            if let url = URL(string: pool.site), ["http", "https"].contains(url.scheme ?? "") {
                                Link(pool.name, destination: url).foregroundStyle(.primary)
                            } else { Text(pool.name) }
                            Text(pool.share.map { f($0 * 100, 1) + "%" } ?? "—")
                                .font(.caption2).foregroundStyle(.secondary)
                            if pool.isSolo { Text("SOLO").font(.caption2).foregroundStyle(.orange) }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .multilineTextAlignment(.leading)   // a Link that wraps centres its lines
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 10)
                        .frame(width: mobileWidth(.name), height: rowHeight(pool), alignment: .leading)
                    }
                }
                .frame(width: mobileWidth(.name))
                .accessibilityIdentifier("pool-comparison-names")
                Rectangle().fill(Pearl.surfaceEdge).frame(width: 1)
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ForEach(mobileColumns, id: \.self) { heading($0, width: mobileWidth($0)) }
                        }
                        ForEach(sortedPools) { pool in
                            Divider()
                            HStack(spacing: 0) {
                                ForEach(mobileColumns, id: \.self) { column in
                                    cell(pool, column: column)
                                        .padding(.horizontal, 8)
                                        .frame(width: mobileWidth(column), alignment: .trailing)
                                }
                            }
                            .frame(height: rowHeight(pool))
                        }
                    }
                }
                .accessibilityIdentifier("pool-comparison-metrics")
            }
            Label(Loc("左右滑动查看完整对比"), systemImage: "arrow.left.and.right")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(10)
        }
        .background(Pearl.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Pearl.surfaceEdge))
        .accessibilityIdentifier("pool-comparison-table")
    }

    private func columnTitle(_ column: Column) -> String {
        switch column {
        case .name: Loc("矿池")
        case .hashrate: Loc("总算力")
        case .trend: Loc("7 天算力")
        case .earnings: Loc("预估收益")
        case .blocks: Loc(source == .miningPoolStats ? "出块/天" : "24h 出块")
        case .fee: Loc("手续费")
        case .realFee: Loc("真实费用")
        case .lastBlock: Loc("最近出块")
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(Column.allCases, id: \.self) { column in
                heading(column, width: tableWidth * column.fraction)
            }
        }
    }

    private func heading(_ column: Column, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            if column == .trend {
                Text(columnTitle(column)).frame(maxWidth: .infinity)
            } else {
                Button {
                    if sortColumn == column { ascending.toggle() }
                    else { sortColumn = column; ascending = column == .fee || column == .realFee || column == .name }
                } label: {
                    HStack(spacing: 5) {
                        Text(columnTitle(column))
                        if sortColumn == column {
                            Image(systemName: ascending ? "arrow.up" : "arrow.down").font(.caption2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: column == .name ? .leading : .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if column == .realFee, availableWidth >= 720 { RealFeeHelpButton() }
        }
        .padding(.horizontal, availableWidth < 720 ? 8 : 16)
        .frame(width: width)
        .foregroundStyle(sortColumn == column ? Color.primary : .secondary)
        .font(.caption.weight(.medium))
        .frame(height: 46)
        .background(Color.primary.opacity(0.025))
    }


    private func dataRow(_ pool: PoolOverview) -> some View {
        HStack(spacing: 0) {
            ForEach(Column.allCases, id: \.self) { column in
                cell(pool, column: column)
                    .padding(.horizontal, 16)
                    .frame(width: tableWidth * column.fraction,
                           alignment: column == .name ? .leading : .trailing)
            }
        }
        .frame(height: rowHeight(pool))
        .background(alignment: .leading) {
            Color.cyan.opacity(colorScheme == .dark ? 0.10 : 0.07)
                .frame(width: tableWidth * min(max(pool.share ?? 0, 0), 1))
        }
    }

    @ViewBuilder private func cell(_ pool: PoolOverview, column: Column) -> some View {
        switch column {
        case .name: poolName(pool)
        case .hashrate:
            VStack(alignment: .trailing, spacing: lineGap) {
                value(pool.poolHashrate.map(formatHashrate))
                if let average = pool.averageHashrate7d {
                    secondary(Loc("7 天均值 %@", formatHashrate(average)))
                } else if let miners = pool.miners {
                    secondary("\(Loc("矿工")) · \(miners.formatted())")
                }
            }
        case .trend:
            PoolHashrateSparkline(points: pool.hashrateHistory).frame(height: 42)
        case .earnings:
            VStack(alignment: .trailing, spacing: lineGap) {
                ForEach(pool.payoutComparisons.indices, id: \.self) { index in
                    let comparison = pool.payoutComparisons[index]
                    let contract = comparison.scheme.hasPrefix("PPS") || comparison.scheme.hasPrefix("FPPS")
                    value(comparison.solo ? nil : comparison.grossPerPH.map {
                        (contract ? "≈" : (comparison.estimated ? "~" : "")) + f($0, 1) + " PRL"
                    }, color: pool.yieldTrustworthy && pool.estimatedEarningsPerPH == best && !contract ? .green : .primary)
                    if pool.payoutComparisons.count > 1 { secondary(comparison.scheme) }
                }
                secondary(pool.usesWeekLuck ? Loc("每 PH/天 · 7 天") : Loc("每 PH/天"))
            }
        case .blocks:
            VStack(alignment: .trailing, spacing: lineGap) {
                value(pool.blocksPerDay.map {
                    (pool.fromMiningPoolStats || source == .miningPoolStats ? "≈" : "") +
                        f($0, $0 < 10 && $0 != $0.rounded() ? 1 : 0)
                })
                if pool.fromMiningPoolStats { secondary(Loc("出块/天")) }
                else if let ratio = pool.yieldRatio {
                    secondary(Loc("%@ 的理论值", f(ratio * 100, 0) + "%"))
                }
            }
        case .fee, .realFee:
            VStack(alignment: .trailing, spacing: lineGap) {
                ForEach(pool.payoutComparisons.indices, id: \.self) { index in
                    let comparison = pool.payoutComparisons[index]
                    if column == .fee || comparison.isPPS || !pool.payoutComparisons.contains(where: \.isPPS) {
                        let amount = column == .fee ? comparison.feePercent : comparison.realFeePercent
                        HStack(spacing: 4) {
                            if column == .realFee, amount != nil {
                                RealFeeHelpButton(observation: comparison.measurement)
                            }
                            value(amount.map {
                                (column == .realFee && comparison.measurement?.estimated == true ? "≈" : "") +
                                    (column == .realFee ? f($0, 2) + "%" : percent($0))
                            })
                        }
                        if pool.payoutComparisons.count > 1 { secondary(comparison.scheme) }
                    }
                }
                if pool.payoutComparisons.count == 1 { secondary(pool.feeType ?? "—") }
                // On a phone the sample period is left to the ⓘ beside the figure, which
                // gives it in full.
                if column == .realFee, !compact, pool.realFeePercent != nil, let observation = pool.ppsMeasurement {
                    secondary(Loc("样本 %@", samplePeriod(observation)))
                }
            }
        case .lastBlock:
            VStack(alignment: .trailing, spacing: lineGap) {
                if let date = pool.lastBlockDate {
                    value(relativeDate(date))
                } else { value(nil) }
                if let count = pool.lifetimeBlocks { secondary(Loc("累计 %@ 块", count.formatted())) }
            }
        }
    }

    private func poolName(_ pool: PoolOverview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(pool.name).font(.system(size: 20, weight: .semibold))
                if let url = URL(string: pool.site), ["http", "https"].contains(url.scheme ?? "") {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square").font(.caption)
                            .foregroundStyle(.secondary)
                    }.accessibilityLabel(pool.name)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            secondary(pool.share.map { Loc("全网占比 %@", f($0 * 100, 1) + "%") } ?? "—")
            if pool.isSolo { Text("SOLO").font(.caption2.weight(.medium)).foregroundStyle(.orange) }
        }
    }

    private func value(_ text: String?, color: Color = .primary) -> some View {
        Text(text ?? "—")
            .font(.system(size: availableWidth < 720 ? 15 : availableWidth < 1280 ? 18 : 20, weight: .semibold).monospacedDigit())
            .foregroundStyle(text == nil ? .secondary : color)
            .fixedSize(horizontal: true, vertical: false)
    }

    private func secondary(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .lineLimit(compact ? 1 : nil).minimumScaleFactor(compact ? 0.8 : 1)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func percent(_ amount: Double) -> String {
        let rounded = (amount * 10).rounded() / 10
        return f(rounded == 0 ? 0 : rounded, rounded == rounded.rounded() ? 0 : 1) + "%"
    }

    private func samplePeriod(_ observation: PPSFeeMeasurement) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter.string(from: Date(timeIntervalSince1970: observation.start),
                                to: Date(timeIntervalSince1970: observation.end))
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Shared explanation next to the desktop column title and each phone metric.
/// Its button stays separate from sorting so opening help never reorders pools.
private struct RealFeeHelpButton: View {
    var observation: PPSFeeMeasurement? = nil
    @Environment(\.locale) private var locale
    @State private var showingExplanation = false

    private var explanation: String {
        guard let observation, observation.realFeePercent != nil else {
            return Loc("这是按各矿池标注的样本时间段，计算的实际结算收益相对理论收益的折损率。")
        }
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let period = formatter.string(from: Date(timeIntervalSince1970: observation.start),
                                      to: Date(timeIntervalSince1970: observation.end))
        return Loc("这是 %@ 期间，实际结算收益相对理论收益的折损率。", period)
    }

    var body: some View {
        Button { showingExplanation = true } label: {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Loc("真实费用说明"))
        .accessibilityIdentifier("pool-real-fee-help")
        .help(Loc("真实费用说明"))
        .popover(isPresented: $showingExplanation, arrowEdge: .top) {
            HStack(alignment: .top, spacing: 10) {
                Text(explanation)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showingExplanation = false } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Loc("关闭"))
            }
            .foregroundStyle(.primary)
            .padding(16)
            .frame(width: 280)
            .fixedSize(horizontal: false, vertical: true)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// The chart uses source timestamps and preserves gaps in the delta-encoded feed.
private struct PoolHashrateSparkline: View {
    let points: [PoolHashratePoint]

    var body: some View {
        if points.compactMap(\.hashrate).count >= 2 {
            Canvas { context, size in
                let valid = points.compactMap(\.hashrate)
                guard let first = points.first, let last = points.last, last.time > first.time,
                      let low = valid.min(), let high = valid.max() else { return }
                let range = max(high - low, max(high * 0.02, 1))
                var line = Path()
                var connected = false
                var lastPosition: CGPoint?
                for sample in points {
                    guard let rate = sample.hashrate else { connected = false; continue }
                    let x = 2 + (size.width - 4) * (sample.time - first.time) / (last.time - first.time)
                    let y = 3 + (size.height - 6) * (high == low ? 0.5 : 1 - (rate - low) / range)
                    let position = CGPoint(x: x, y: y)
                    if connected { line.addLine(to: position) } else { line.move(to: position) }
                    connected = true
                    lastPosition = position
                }
                var baseline = Path()
                baseline.move(to: CGPoint(x: 2, y: size.height - 1))
                baseline.addLine(to: CGPoint(x: size.width - 2, y: size.height - 1))
                context.stroke(baseline, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
                context.stroke(line, with: .color(.cyan), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let end = lastPosition, points.last?.hashrate != nil {
                    context.fill(Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)),
                                 with: .color(.cyan))
                }
            }
            .accessibilityLabel(Loc("7 天算力"))
        } else {
            Text("—").font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        }
    }
}

private struct PoolComparisonNotes: View {
    let pools: [PoolOverview]
    let sampleDays: Double
    let source: PoolsSource
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if pools.contains(where: \.usesWeekLuck) {
                Text(Loc("预估收益 = 当前理论收益 × 该池近 7 天出块运气（实际出块 ÷ 按其算力应出的块，每 5 分钟采样）；PRL/PH·天，未扣手续费；绿色 = 最高。"))
                if pools.contains(where: { !$0.usesWeekLuck && !$0.isPPS && !$0.isSolo && $0.earningsPerPH != nil }) {
                    Text(Loc("未标「7 天」的矿池不足 7 天样本，按实际挖到的块 × 单块奖励 ÷ 算力计算。"))
                }
            } else {
                Text(Loc("收益/PH·天 = 该池实际挖到的块 × 单块奖励 ÷ 算力（PRL，未扣手续费）；绿色 = 最高。"))
            }
            Text(Loc("真实费用 =（1 − 实际结算收益 ÷ 同期理论收益）× 100%；负值表示收益高于理论。"))
            Text(Loc("真实费用仅计算 PPS、PPS+ 与 FPPS；其他方案或数据不足显示「—」。不含矿工软件抽水及转账费。"))
            if pools.contains(where: { $0.name == "Pearl Fortune" }) {
                Text(Loc("PF 保留两种方案的公示费率，仅计算 PPS 的真实费用。"))
            }
            if source == .lordOfPearls {
                Text(Loc("出块为最近 24 小时链上实测（按 coinbase 归属统计），算力取自各矿池自身 API。"))
            }
            if source == .miningPoolStats {
                Text(Loc("出块与收益按最近 1000 个区块（≈%@ 天）实测，比 24h 更抗运气波动。", f(sampleDays, 1)))
            }
            if pools.contains(where: { $0.blocksEstimated || $0.payoutComparisons.contains { !$0.isPPS && !$0.solo && $0.estimated } }) {
                Text(Loc("「~」= 样本区块太少（<20），该数字运气成分大，仅供参考。"))
            }
            if pools.contains(where: \.isSolo) {
                Text(Loc("SOLO 池为「彩票式」收益，不参与最高收益的比较。"))
            }
            if pools.contains(where: { $0.payoutComparisons.contains(where: \.isPPS) }) {
                Text(Loc("PPS 池按份额固定结算，收益/PH·天 取全网期望值（与该池运气无关），不参与最高收益的比较。"))
                Text(Loc("「≈」表示估算，可能包含算力统计、观测缺口补估和链上历史插值误差；结果反映样本期收益折损，不等同于矿池公示手续费或额外抽水。"))
            }
            if pools.contains(where: \.hashFromPoolAPI) {
                Text(Loc("HeroMiners 的算力数据源未收录，改取矿池自身 API。"))
            }
            // No numbers spelled out here: they come from the API and would go stale in the
            // footnote the moment the pool changed them — the row already shows them.
            if pools.contains(where: { $0.name == "Kryptex" && $0.feeFromPoolAPI }) {
                Text(Loc("Kryptex 的费率与结算方式取自矿池自身 API（数据源记录有误）。"))
            }
            if source == .lordOfPearls, pools.contains(where: \.fromMiningPoolStats) {
                Text(Loc("F2Pool 数据源未收录，该行取自 miningpoolstats（出块按其最近 1000 个区块口径）。"))
            }
            Text(Loc("走势展示近 7 天算力；数据缺失时显示「—」。"))
            switch source {
            case .lordOfPearls:    Text(Loc("数据来源：lordofpearls.xyz"))
            case .miningPoolStats: Text(Loc("数据来源：miningpoolstats.stream"))
            case .poolAPIs:        EmptyView()
            }
        }
        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 算力占比饼图

/// Donut of each pool's share of the network. Tail pools (<1%) collapse into 其他小池 so the
/// legend stays readable, and whatever the listed pools don't account for becomes 独立/未知.
private struct HashShareChart: View {
    let pools: [PoolOverview]

    private struct Slice: Identifiable {
        let id: String
        let name: String
        let hps: Double
        let share: Double
        let color: Color
    }

    private static let colors: [String: Color] = [
        "AlphaPool": Pearl.classic.accent, "Lucky Pool": .mint, "HeroMiners": .green,
        "PearlHash": Pearl.classic.gold, "Pearl Fortune": .orange, "Kryptex": .purple,
        "F2Pool": Pearl.classic.teal,
    ]

    private var slices: [Slice] {
        let known = pools.compactMap { p -> (PoolOverview, Double)? in
            guard let h = p.poolHashrate, h > 0 else { return nil }
            return (p, h)
        }
        guard !known.isEmpty else { return [] }
        let knownSum = known.reduce(0) { $0 + $1.1 }
        let network = pools.compactMap(\.networkHashrate).max() ?? 0
        let total = max(network, knownSum)

        var out: [Slice] = []
        var tail = 0.0
        for (p, h) in known.sorted(by: { $0.1 > $1.1 }) {
            if h / total < 0.01 { tail += h; continue }   // sub-1% pools would be unreadable slivers
            out.append(Slice(id: p.id, name: p.name, hps: h, share: h / total,
                             color: Self.colors[p.name] ?? .gray.opacity(0.6)))
        }
        if tail / total > 0.002 {
            out.append(Slice(id: "_tail", name: Loc("其他小池"), hps: tail,
                             share: tail / total, color: Color.gray.opacity(0.55)))
        }
        let rest = total - knownSum
        if rest / total > 0.005 {
            out.append(Slice(id: "_other", name: Loc("独立/未知"), hps: rest,
                             share: rest / total, color: Color.gray.opacity(0.3)))
        }
        return out
    }

    var body: some View {
        let slices = self.slices
        if !slices.isEmpty {
            VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                Text(Loc("算力占比")).font(.headline)
                Chart(slices) { s in
                    SectorMark(angle: .value(Loc("算力"), s.hps),
                               innerRadius: .ratio(0.62), angularInset: 1.5)
                        .cornerRadius(3)
                        .foregroundStyle(s.color)
                        .annotation(position: .overlay) {
                            if s.share >= 0.08 {
                                Text(f(s.share * 100, 0) + "%")
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .frame(height: 210)
                .overlay {
                    VStack(spacing: 2) {
                        Text(Loc("全网算力")).font(.caption2).foregroundStyle(.secondary)
                        Text(formatHashrate(slices.reduce(0) { $0 + $1.hps }))
                            .font(.callout.weight(.semibold).monospacedDigit())
                    }
                }
                VStack(spacing: 6) {
                    ForEach(slices) { s in
                        HStack(spacing: 8) {
                            Circle().fill(s.color).frame(width: 8, height: 8)
                            Text(s.name).font(.caption).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(formatHashrate(s.hps))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(f(s.share * 100, 1) + "%")
                                .font(.caption.monospacedDigit().weight(.medium))
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pearlCard()
        }
    }
}
