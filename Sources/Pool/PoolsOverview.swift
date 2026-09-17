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
    var blocksEstimated = false
    var feePercent: Double?
    var feeNote: String?
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
    var yieldTrustworthy: Bool { !isSolo && !isPPS && blocksSample >= 20 && earningsPerPH != nil }
}

/// Which feed the current rows came from — it decides the footnotes, because the columns
/// mean subtly different things per source (a 24h window vs a 1000-block one).
enum PoolsSource { case lordOfPearls, miningPoolStats, poolAPIs }

@MainActor
final class PoolsOverviewStore: ObservableObject {
    @Published var pools: [PoolOverview] = []
    @Published var loading = false
    /// Days the measured columns span (1 for lordofpearls' 24h window, ≈2.5 for
    /// miningpoolstats' 1000 blocks). Shown in the footnote so the numbers are legible.
    @Published var sampleDays: Double = 0
    /// Drives the "数据来源 …" caption; .poolAPIs until a source answers.
    @Published var source: PoolsSource = .poolAPIs

    func refresh() async {
        loading = true
        defer { loading = false }
        if let rows = try? await Self.lordOfPearls(), !rows.isEmpty {
            pools = rows
            sampleDays = 1          // the site's block column is a flat 24h count
            source = .lordOfPearls
            return
        }
        if let mps = try? await MiningPoolStatsClient().fetch() {
            pools = Self.build(mps, kryptex: try? await KryptexClient().poolStats())
            sampleDays = mps.sampleDays
            source = .miningPoolStats
            return
        }
        // Both aggregators unreachable → the six pools with their own public API, as before.
        async let a = Self.alpha()
        async let l = Self.lucky()
        async let h = Self.hero()
        async let p = Self.pearlHash()
        async let f = Self.pearlFortune()
        async let k = Self.kryptex()
        // Sorted by hashrate like the primary path — the table renders rows in the order it
        // is handed them, so an unsorted fallback would shuffle the ranking under the user.
        pools = [await a, await l, await h, await p, await f, await k]
            .sorted { ($0.poolHashrate ?? 0) > ($1.poolHashrate ?? 0) }
        sampleDays = 1
        source = .poolAPIs
    }

    // MARK: lordofpearls → the table

    /// The /pools table joined to the chain numbers /api/public publishes: the table itself
    /// carries neither the network hashrate (→ 占比) nor the block reward (→ 收益/PH·天).
    /// HeroMiners rides along because the site prints "—" for its hashrate while the pool's
    /// own API does publish one — see `build` below.
    private static func lordOfPearls() async throws -> [PoolOverview] {
        let client = LordOfPearlsClient()
        async let rowsTask = client.pools()
        async let chainTask = client.publicStats()
        async let heroTask = HeroMinersClient().stats()
        async let mpsTask = MiningPoolStatsClient().fetch()
        async let kryptexTask = KryptexClient().poolStats()
        let rows = try await rowsTask
        let chain = try? await chainTask
        let hero = try? await heroTask
        return build(rows, chain: chain,
                     heroHashrate: (hero?.pool?.realHashrate?.value).flatMap { $0 > 0 ? $0 : nil },
                     mps: try? await mpsTask,
                     kryptex: try? await kryptexTask)
    }

    static func build(_ rows: [LOPPool], chain: LOPPublic?, heroHashrate: Double?,
                      mps: MPSCoin?, kryptex: KryptexPoolStats? = nil) -> [PoolOverview] {
        let network = chain?.networkHashrate
        let reward = chain?.rewardPerBlock ?? mps?.rewardPerBlock ?? 0
        let expected = networkYield(reward: reward, network: network, blockTime: chain?.blockTimeSec)
        var out = rows.map { r -> PoolOverview in
            let key = brandKey(r.host)
            let name = pretty[key] ?? r.name       // the site's own label when we have no better
            // lordofpearls doesn't poll HeroMiners' hashrate ("does not publish a
            // machine-readable feed" — it does; the site simply hasn't wired it), which would
            // leave the network's third-biggest block producer with no 算力 and no 收益 at all.
            // Its own API is the same kind of poll the site runs for every other row.
            let filled = r.hashrate == nil && key == "herominers.com" ? heroHashrate : nil
            let hps = r.hashrate ?? filled
            let solo = (r.payout ?? "").uppercased().contains("SOLO") || r.url.lowercased().contains("solo")
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
            // BEFORE the yield below: the correction can flip the row to PPS, and a PPS row's
            // 收益/PH is the network's expected value rather than a block count.
            if name == "Kryptex", let k = kryptex { applyKryptex(&o, k) }
            if o.isPPS {
                o.earningsPerPH = expected         // a fixed rate per share — see isPPS
            } else if reward > 0, let h = hps, h > 0, let b = r.blocks24h, b > 0 {
                // Measured, luck-included yield over the same 24h the block column counts.
                o.earningsPerPH = Double(b) * reward / (h / 1e15)
                o.blocksEstimated = b < 20         // too few blocks to trust → shown as "~"
            }
            if name == "HeroMiners" {
                o.feeNote = Loc("矿池 0%，SRBMiner 抽水约 3%")
            }
            return o
        }
        if let f2 = mps.flatMap({ f2pool($0, network: network, reward: reward, expected: expected) }) {
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
    private static func f2pool(_ c: MPSCoin, network: Double?, reward: Double,
                               expected: Double?) -> PoolOverview? {
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
                             blocksPerDay: days > 0 && sample > 0 ? Double(sample) / days : nil,
                             blocksSample: sample,
                             feePercent: p.fee?.value,
                             fromMiningPoolStats: true)
        if o.isPPS {
            o.earningsPerPH = expected             // 2% PPS — a contract, not a block count
        } else if reward > 0, days > 0, sample > 0 {
            o.earningsPerPH = Double(sample) * reward / (days * p.hps / 1e15)
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

    private static let gradients: [String: LinearGradient] = [
        "AlphaPool": Pearl.brand, "Lucky Pool": Pearl.mint, "HeroMiners": Pearl.positive,
        "PearlHash": Pearl.brandVivid, "Pearl Fortune": Pearl.sunrise, "Kryptex": Pearl.negative,
        // Teal-led, matching the slice the donut already gives F2Pool.
        "F2Pool": LinearGradient(colors: [Pearl.teal, Pearl.accent],
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

    static func build(_ c: MPSCoin, kryptex: KryptexPoolStats? = nil) -> [PoolOverview] {
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
                                     blocksPerDay: days > 0 && sample > 0 ? Double(sample) / days : nil,
                                     blocksSample: sample,
                                     feePercent: p.fee?.value)
                // Before the yield, as in the lordofpearls path — the correction decides
                // whether this row is measured at all.
                if name == "Kryptex", let k = kryptex { applyKryptex(&o, k) }
                if o.isPPS {
                    o.earningsPerPH = expected          // fixed rate per share — see isPPS
                } else if reward > 0, days > 0, hps > 0, sample > 0 {
                    // Measured, luck-included yield: what this pool's hashrate ACTUALLY earned
                    // over the sample, per PH per day. Gross of fee — fee has its own column.
                    o.earningsPerPH = Double(sample) * reward / (days * hps / 1e15)
                    o.blocksEstimated = sample < 20     // too few blocks to trust → shown as "~"
                }
                if name == "HeroMiners" {
                    o.feeNote = Loc("矿池 0%，SRBMiner 抽水约 3%")
                }
                return o
            }
    }

    // MARK: fallback — the pools that publish their own API

    private static func alpha() async -> PoolOverview {
        var o = PoolOverview(id: "AlphaPool", name: "AlphaPool",
                             site: "https://pearl.alphapool.tech", gradient: Pearl.brand)
        do {
            let s = try await PoolClient().stats()
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

    private static func lucky() async -> PoolOverview {
        var o = PoolOverview(id: "Lucky Pool", name: "Lucky Pool",
                             site: "https://pearl.luckypool.io", gradient: Pearl.mint)
        do {
            let v = try await LuckyPoolClient().statsV2()
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

    private static func hero() async -> PoolOverview {
        var o = PoolOverview(id: "HeroMiners", name: "HeroMiners",
                             site: "https://pearl.herominers.com", gradient: Pearl.positive)
        o.feePercent = HeroMinersClient.fee   // 3.0 — pool 0%, but PRL needs SRBMiner (~3% dev fee)
        o.feeNote = Loc("矿池 0%，SRBMiner 抽水约 3%")
        do {
            let s = try await HeroMinersClient().stats()
            o.poolHashrate = (s.pool?.realHashrate?.value).flatMap { $0 > 0 ? $0 : nil }
                ?? s.pool?.hashrate?.value
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

    private static func pearlHash() async -> PoolOverview {
        var o = PoolOverview(id: "PearlHash", name: "PearlHash",
                             site: "https://pearlhash.xyz", gradient: Pearl.brandVivid)
        o.feePercent = PearlHashClient.fee
        do {
            let client = PearlHashClient()
            // The pool's own node answers for the network, and its wallet ledger for its blocks
            // — so this row carries 占比 and a measured 收益/PH even with every aggregator down.
            async let chainTask = try? client.chainInfo()
            async let blocksTask = try? client.recentBlocks()
            let s = try await client.stats()
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
    private static func kryptex() async -> PoolOverview {
        var o = PoolOverview(id: "Kryptex", name: "Kryptex",
                             site: "https://pool.kryptex.com/prl", gradient: Pearl.negative)
        do {
            let client = KryptexClient()
            async let blocksTask = try? client.blocks()
            let s = try await client.poolStats()
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
        } catch { o.error = Loc("暂时无法获取矿池数据") }
        return o
    }

    private static func pearlFortune() async -> PoolOverview {
        var o = PoolOverview(id: "Pearl Fortune", name: "Pearl Fortune",
                             site: "https://pearlfortune.org", gradient: Pearl.sunrise)
        do {
            let s = try await PearlFortuneClient().summary()
            let roll = Dictionary(
                (s.pool_stats?.rolling_stats ?? []).compactMap { r in r.hours.map { ($0, r) } },
                uniquingKeysWith: { a, _ in a })
            o.feePercent = (s.pool_stats?.pool_fee_rate).map { ($0 * 10000).rounded() / 100 }
            o.networkHashrate = (s.stats?.network_hashrate).map(parseHashrate)
            o.poolHashrate = (roll[1]?.hashrate).flatMap { $0 > 0 ? $0 : nil } ?? roll[24]?.hashrate
            if let r24 = roll[24] {
                o.blocksPerDay = (r24.block_count).map(Double.init)
                o.blocksSample = r24.block_count ?? 0
                if let coins = r24.total_coins, let hps = r24.hashrate, hps > 0 {
                    o.earningsPerPH = coins / (hps / 1e15)
                }
            }
        } catch { o.error = Loc("暂时无法获取矿池数据") }
        return o
    }
}

/// Pool overview rendered as a section inside the PRL monitor's segmented control.
struct PoolsOverviewSection: View {
    @StateObject private var store = PoolsOverviewStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                PearlSectionHeader(Loc("矿池总览"), systemImage: "server.rack",
                                   subtitle: Loc("全部 Pearl 矿池对比：费率 · 出块 · 每 PH 收益 · 算力（无需地址）"))
                if store.pools.isEmpty && store.loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 140)
                } else {
                    PoolComparisonTable(pools: store.pools, sampleDays: store.sampleDays,
                                        source: store.source)
                    HashShareChart(pools: store.pools)
                }
            }
            .animation(.snappy, value: store.pools.map(\.id))
            .padding(Pearl.Space.screen).frame(maxWidth: 860).frame(maxWidth: .infinity)
        }
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
    }
}

/// 矿池 · 手续费 · 出块/天 · 收益/PH·天 · 算力 · 占比 · 矿工.
/// Every measured column spans the same window for every pool (see MPSCoin.sampleDays), so the
/// rows are actually comparable. Sorted by hashrate; the green badge marks the best measured
/// yield among pools whose sample is big enough to trust (never a SOLO pool — that's a lottery).
private struct PoolComparisonTable: View {
    let pools: [PoolOverview]
    let sampleDays: Double
    let source: PoolsSource

    // Sized so a typical value fits at full size — a cell that overflows gets scaled down by
    // minimumScaleFactor, and one row rendering a hair smaller than its neighbours is exactly
    // the kind of "the font is different" wrongness the eye catches even when it can't name it.
    private let wName: CGFloat = 150, wFee: CGFloat = 46, wBlk: CGFloat = 58,
                wEarn: CGFloat = 100, wHash: CGFloat = 92, wShare: CGFloat = 52, wMiners: CGFloat = 58

    private var best: Double {
        pools.filter(\.yieldTrustworthy).compactMap(\.earningsPerPH).max() ?? -1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    headerRow
                    Divider().padding(.top, 5)
                    ForEach(Array(pools.enumerated()), id: \.element.id) { idx, p in
                        dataRow(p)
                        if idx < pools.count - 1 { Divider() }
                    }
                }
            }
            footnotes
        }
        .pearlCard()
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Text(Loc("矿池")).frame(width: wName, alignment: .leading)
            Text(Loc("手续费")).frame(width: wFee, alignment: .trailing)
            Text(Loc("出块/天")).frame(width: wBlk, alignment: .trailing)
            Text(Loc("收益/PH·天")).frame(width: wEarn, alignment: .trailing)
            Text(Loc("总算力")).frame(width: wHash, alignment: .trailing)
            Text(Loc("占比")).frame(width: wShare, alignment: .trailing)
            Text(Loc("矿工")).frame(width: wMiners, alignment: .trailing)
        }
        .font(.caption).foregroundStyle(.secondary)
        .lineLimit(1).minimumScaleFactor(0.6)
    }

    @ViewBuilder private func dataRow(_ p: PoolOverview) -> some View {
        let tilde = p.blocksEstimated ? "~" : ""
        let isBest = p.yieldTrustworthy && p.earningsPerPH == best
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                PearlIconBadge(systemImage: "server.rack", gradient: p.gradient, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.callout.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
                    // ALWAYS render the type line, "—" when the feed omits it (PearlHash does,
                    // and it sorts first) — an `if let` here left that one row a single-line
                    // cell, so its name centred against everyone else's two-line cell and read
                    // as a different font size.
                    Text(p.feeType ?? "—").font(.caption2)
                        .foregroundStyle(p.isSolo ? Color.orange : .secondary)
                }
            }
            .frame(width: wName, alignment: .leading)
            num(p.feePercent.map { f($0, $0 == $0.rounded() ? 0 : 1) + "%" }, width: wFee)
            // A decimal only when there is one to show: lordofpearls' column is an exact 24h
            // count, so "6.0 blocks" would read as precision that isn't being claimed, while
            // miningpoolstats' blocks÷days genuinely lands between whole numbers.
            num(p.blocksPerDay.map { f($0, $0 < 10 && $0 != $0.rounded() ? 1 : 0) }, width: wBlk)
            num(p.earningsPerPH.map { tilde + f($0, 1) }, width: wEarn,
                color: isBest ? .green : (p.isSolo || p.blocksEstimated ? .secondary : .primary),
                bold: isBest)
            num(p.poolHashrate.map(formatHashrate), width: wHash)
            num(p.share.map { f($0 * 100, 1) + "%" }, width: wShare)
            num(p.miners.map { "\($0)" }, width: wMiners)
        }
        .padding(.vertical, 8)
    }

    private func num(_ s: String?, width: CGFloat, color: Color = .primary, bold: Bool = false) -> some View {
        Text(s ?? "—")
            .font(.callout.monospacedDigit())
            .fontWeight(bold ? .semibold : .regular)
            .foregroundStyle(s == nil ? Color.secondary : color)
            .lineLimit(1).minimumScaleFactor(0.6)
            .frame(width: width, alignment: .trailing)
    }

    @ViewBuilder private var footnotes: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Loc("收益/PH·天 = 该池实际挖到的块 × 单块奖励 ÷ 算力（PRL，未扣手续费）；绿色 = 最高。"))
            if source == .lordOfPearls {
                Text(Loc("出块为最近 24 小时链上实测（按 coinbase 归属统计），算力取自各矿池自身 API。"))
            }
            if source == .miningPoolStats {
                Text(Loc("出块与收益按最近 1000 个区块（≈%@ 天）实测，比 24h 更抗运气波动。", f(sampleDays, 1)))
            }
            if pools.contains(where: \.blocksEstimated) {
                Text(Loc("「~」= 样本区块太少（<20），该数字运气成分大，仅供参考。"))
            }
            if pools.contains(where: \.isSolo) {
                Text(Loc("SOLO 池为「彩票式」收益，不参与最高收益的比较。"))
            }
            if pools.contains(where: \.isPPS) {
                Text(Loc("PPS 池按份额固定结算，收益/PH·天 取全网期望值（与该池运气无关），不参与最高收益的比较。"))
            }
            if pools.contains(where: { $0.feeNote != nil }) {
                Text(Loc("HeroMiners：矿池 0%，需 SRBMiner（矿工端抽水约 3%）。"))
            }
            if pools.contains(where: \.hashFromPoolAPI) {
                Text(Loc("HeroMiners 的算力数据源未收录，改取矿池自身 API。"))
            }
            // No numbers spelled out here: they come from the API and would go stale in the
            // footnote the moment the pool changed them — the row already shows them.
            if pools.contains(where: \.feeFromPoolAPI) {
                Text(Loc("Kryptex 的费率与结算方式取自矿池自身 API（数据源记录有误）。"))
            }
            if source == .lordOfPearls, pools.contains(where: \.fromMiningPoolStats) {
                Text(Loc("F2Pool 数据源未收录，该行取自 miningpoolstats（出块按其最近 1000 个区块口径）。"))
            }
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
        "AlphaPool": Pearl.accent, "Lucky Pool": .mint, "HeroMiners": .green,
        "PearlHash": Pearl.gold, "Pearl Fortune": .orange, "Kryptex": .purple,
        "F2Pool": Pearl.teal,
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
