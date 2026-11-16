import Foundation
import Testing
@testable import Pearl

/// The per-pool sources (shared by the app's cards and the widget) against recorded payloads.
/// Expected values were computed independently from the same fixtures with the PRE-refactor
/// mapping (PoolWatch.fetchWatchDataOnce + each client's "not mining here" gate), so these pin
/// the move into Sources/WidgetShared/Pools as behaviour-preserving.
struct PoolParsingTests {
    /// The instant the online/offline cut-offs are judged against (fixtures are from just before).
    let now = 1_790_475_200.0

    @Test func alphaPoolIdleMinerIsFound() throws {
        let s = try #require(try AlphaPoolSource.parse(try Fixture.data("alphapool_miner_idle.json"), now: now))
        #expect(s.windows == [.live, .hour, .day])
        #expect(close(s.pending, 0.92900789))
        #expect(close(s.paid, 13.19344688))
        #expect(s.workers.count == 1)
        #expect(s.onlineCount == 0)
        #expect(s.value(.live) == 0)
    }

    /// AlphaPool answers 200 with zeros for an address it has never seen — that must read as
    /// "未在此矿池挖矿", not as a found miner doing 0 H/s.
    @Test func alphaPoolStrangerIsNotFound() throws {
        #expect(try AlphaPoolSource.parse(try Fixture.data("alphapool_miner_empty.json"), now: now) == nil)
    }

    @Test func luckyPool() throws {
        let s = try #require(try LuckyPoolSource.parse(try Fixture.data("luckypool_miner.json"), now: now))
        #expect(close(s.pending, 13.29889069))
        #expect(close(s.paid, 3039.00403603))
        #expect(s.pendingKind == .withdrawableAndUnconfirmed)
        #expect(s.workers.count == 3)
        #expect(s.onlineCount == 3)
        #expect(close(s.rates[.live] ?? 0, 1_896_897_765_508_319))
        #expect(close(s.rates[.hour] ?? 0, 1_590_254_225_893_836))
        #expect(close(s.rates[.day] ?? 0, 1_665_315_710_915_441))
        #expect(close(s.value(.live), 1_896_897_765_508_319))
        #expect(close(s.value(.day), 1_665_315_710_915_441))
    }

    @Test func heroMinersScalesEveryRateBy2To32() throws {
        let s = try #require(try HeroMinersSource.parse(try Fixture.data("herominers_miner.json"), now: now))
        #expect(close(s.pending, 13.54228383))
        #expect(close(s.paid, 510.91818277))
        #expect(s.workers.count == 3)
        #expect(s.onlineCount == 3)
        #expect(close(s.rates[.live] ?? 0, 1_651_320_436_031_488))
        #expect(close(s.rates[.hour] ?? 0, 1_569_755_571_106_611.2))
        #expect(close(s.rates[.day] ?? 0, 1_415_611_950_790_519.5))
        #expect(close(s.value(.live), 1_651_320_436_031_488))
        #expect(close(s.value(.day), 1_415_614_134_065_561.8))
    }

    @Test func heroMinersStrangerIsNotFound() throws {
        #expect(try HeroMinersSource.parse(try Fixture.data("herominers_miner_empty.json"), now: now) == nil)
    }

    private func pf<T: Decodable>(_ name: String, _ t: T.Type) throws -> T? {
        try JSONDecoder().decode(PFEnvelope<T>.self, from: try Fixture.data(name)).data
    }

    @Test func pearlFortuneFull() throws {
        let detail = try #require(try pf("pearlfortune_miner.json", PFMinerDetail.self))
        let s = try #require(PearlFortuneSource.combine(detail: detail,
                                                        conn: try pf("pearlfortune_connections.json", PFConnections.self),
                                                        ledger: try pf("pearlfortune_ledger.json", PFLedger.self)))
        #expect(close(s.pending, 1.10506955))
        #expect(close(s.paid, 63.40524874))
        #expect(s.workers.count == 8)
        #expect(s.onlineCount == 8)
        #expect(close(s.rates[.live] ?? 0, 2_183_690_777_336_575.8))
        #expect(close(s.rates[.hour] ?? 0, 1_436_805_857_609_719))
        #expect(close(s.rates[.day] ?? 0, 1_146_779_915_064_822.2))
        // Per rig: live from the connections, 1h / 24h as the pool measured them.
        #expect(close(s.value(.live), 2_183_690_777_336_575.8))
        #expect(close(s.value(.hour), 2_138_171_915_226_689.5))
        #expect(close(s.value(.day), 2_263_271_839_527_266))
        // A rig on two connections: both reports add up.
        let storage = try #require(s.workers.first { $0.name == "storage01" })
        #expect(close(storage.rate(.live), 230_952_662_098_890.88))
        #expect(close(storage.rate(.hour), 225_055_001_718_919.88))
        #expect(close(storage.rate(.day), 238_843_688_127_861.56))
    }

    /// A stale connection doesn't count; a rig with none left is offline at 0; a live one that
    /// reports nothing leaves live out so the 1h stands in. Before 2026-11-06 a rig was a single
    /// connection with no measured rates.
    @Test func pearlFortuneConnections() throws {
        let json = """
        {"data":{"workers":[
          {"worker":"a","sessions":[{"stale":false,"reported_hashrate":5},{"stale":true,"reported_hashrate":7}],
           "pool":{"hashrate_1h":4,"observed_1h_s":3600,"hashrate_24h":3,"observed_24h_s":0}},
          {"worker":"b","sessions":[{"stale":true,"reported_hashrate":7}],"pool":{"hashrate_1h":6,"observed_1h_s":60}},
          {"worker":"c","sessions":[{"stale":false,"reported_hashrate":9,"reported_telemetry":{"hashrate_source":"proxy"}}],
           "pool":{"hashrate_1h":8,"observed_1h_s":60}},
          {"worker":"old","stale":false,"reported_hashrate":2}]}}
        """
        let s = try #require(PearlFortuneSource.live(PoolHTTP.decode(PFEnvelope<PFConnections>.self, from: Data(json.utf8)).data))
        let rig = { (n: String) in s.workers.first { $0.name == n }! }
        #expect(rig("a").online && rig("a").rates == [.live: 5, .hour: 4])
        #expect(!rig("b").online && rig("b").rates == [.live: 0, .hour: 6])
        #expect(rig("c").online && rig("c").rates == [.hour: 8] && rig("c").instant == 8)
        #expect(rig("old").online && rig("old").rates == [.live: 2])
    }

    @Test func pearlFortuneStrangerIsNotFound() throws {
        let detail = try #require(try pf("pearlfortune_miner_empty.json", PFMinerDetail.self))
        #expect(PearlFortuneSource.combine(detail: detail,
                                           conn: try pf("pearlfortune_connections_empty.json", PFConnections.self),
                                           ledger: try pf("pearlfortune_ledger_empty.json", PFLedger.self)) == nil)
        #expect(PearlFortuneSource.live(try pf("pearlfortune_connections_empty.json", PFConnections.self)) == nil)
    }

    /// The widget reads /connections alone — same rigs, same live total as the full read.
    @Test func pearlFortuneLiveMatchesFull() throws {
        let conn = try pf("pearlfortune_connections.json", PFConnections.self)
        let live = try #require(PearlFortuneSource.live(conn))
        let detail = try #require(try pf("pearlfortune_miner.json", PFMinerDetail.self))
        let full = try #require(PearlFortuneSource.combine(detail: detail, conn: conn, ledger: nil))
        #expect(close(live.liveRate, full.liveRate))
        #expect(live.workers.count == full.workers.count)
        #expect(live.onlineCount == full.onlineCount)
    }

    @Test func pearlHash() throws {
        let pool = try JSONDecoder().decode(PearlHashStats.self, from: try Fixture.data("pearlhash_stats.json"))
        let s = try #require(try PearlHashSource.parse(try Fixture.data("pearlhash_account.json"),
                                                       poolHashrate: pool.hashrate ?? 0))
        #expect(close(s.pending, 1.921944989121971))
        #expect(close(s.paid, 54.67318902928431))
        #expect(s.workers.count == 9)
        #expect(close(s.value(.live), 486_951_712_142_131.2))
        // No pending epoch in this snapshot → no pool-measured 1h, and none is offered.
        #expect(s.windows == [.live])
        // Duplicate rig labels are numbered, so the device sync can't collapse two rigs.
        #expect(Set(s.workers.map(\.name)).count == s.workers.count)
    }

    @Test func kryptex() throws {
        let workers = try JSONDecoder().decode(KryptexWorkersResp.self, from: try Fixture.data("kryptex_workers.json")).results ?? []
        let m = KryptexMiner(workers: workers,
                             balance: try JSONDecoder().decode(KryptexBalance.self, from: try Fixture.data("kryptex_balance.json")),
                             payouts: try JSONDecoder().decode(KryptexPayoutStats.self, from: try Fixture.data("kryptex_payouts.json")))
        let s = try #require(KryptexSource.stats(m))
        #expect(close(s.pending, 39.809957971072265))
        #expect(close(s.paid, 2903.8023297))
        #expect(s.windows == [.m30, .h3, .day])
        #expect(s.onlineCount == 1)
        #expect(close(s.value(.m30), 6_805_439_436_915_416))
        #expect(close(s.value(.h3), 6_539_393_458_928_159))
        #expect(close(s.value(.day), 8_277_240_815_138_024))
        // Kryptex's freshest window is 30 minutes — that IS its live figure.
        #expect(close(s.liveRate, 6_805_439_436_915_416))
    }

    @Test func kryptexStrangerIsNotFound() throws {
        let workers = try JSONDecoder().decode(KryptexWorkersResp.self, from: try Fixture.data("kryptex_workers_empty.json")).results ?? []
        #expect(KryptexSource.stats(KryptexMiner(workers: workers, balance: nil, payouts: nil)) == nil)
    }

    /// Jetski: the pool's calculated 5m / 1h / 6h (never the miner-reported `hashrate`, null on
    /// P3630), grains → PRL, and a worker stale 10 min after its last share like the pool's page.
    @Test func jetski() throws {
        let s = try #require(try JetskiSource.parse(try Fixture.data("jetski_miner.json"), now: 1_792_283_530))
        #expect(s.windows == [.live, .hour, .h6])
        #expect(close(s.pending, 4.19832521))
        #expect(close(s.paid, 348.29822081))
        #expect(s.pendingKind == .pending)
        #expect(s.workers.map(\.name) == ["AP201", "C4000F", "NZXTH3", "P3630"])
        #expect(s.workers.map(\.online) == [true, true, true, false])
        #expect(close(s.value(.live), 658_561_652_053_333.4))
        #expect(close(s.value(.hour), 634_700_722_631_111.1))
        #expect(close(s.value(.h6), 659_754_698_524_444.5))
        // 6h is the smoothest it publishes, so it's what the efficiency comparison uses.
        #expect(close(s.hr24hRaw, 659_754_698_524_444.5))
        #expect(s.workers[3].rate(.live) == 0)
        #expect(close(s.workers[3].rate(.h6), 75_957_291_994_074.08))
    }

    /// 200 with zeros and no workers for an address the pool has never seen.
    @Test func jetskiStrangerIsNotFound() throws {
        #expect(try JetskiSource.parse(try Fixture.data("jetski_miner_empty.json"), now: 1_792_283_590) == nil)
        // Known by its payouts alone: found, with no workers.
        let paidOnly = Data(#"{"hashrate_5m":0,"total_paid_grains":250000000,"last_share_time":null,"workers":[]}"#.utf8)
        let s = try #require(try JetskiSource.parse(paidOnly, now: 0))
        #expect(close(s.paid, 2.5) && s.workers.isEmpty)
    }

    /// Peryn: 1h and 24h only, per account and per rig; the pool's own `online` flag (RIG004 is
    /// offline though it shared six minutes earlier — the pool tracks the connection); owed +
    /// still confirming = pending.
    @Test func peryn() throws {
        let s = try #require(try PerynSource.parse(try Fixture.data("peryn_miner.json")))
        #expect(s.windows == [.hour, .day])
        #expect(close(s.pending, 0.83860819))
        #expect(close(s.paid, 24.1883303))
        #expect(s.pendingKind == .pending)
        #expect(s.workers.map(\.name) == ["4090", "Rig001", "Rig003", "RIG004"])
        #expect(s.workers.map(\.online) == [true, true, true, false])
        #expect(s.onlineCount == 3)
        #expect(close(s.value(.hour), 2_374_365_596_771_335.5))   // Σ rigs (the account says 2.338e15)
        #expect(close(s.value(.day), 2_243_537_486_614_917.2))
        #expect(close(s.hr24hRaw, 2_243_537_486_614_917.2))
        // Nothing under an hour is published: the hour is the live figure, not the 24h average.
        #expect(close(s.workers[0].instant, 290_310_298_295_937.75))
        #expect(close(s.liveRate, 2_374_365_596_771_335.5))
    }

    /// 200 with zeros and no workers for an address the pool has never seen.
    @Test func perynStrangerIsNotFound() throws {
        #expect(try PerynSource.parse(try Fixture.data("peryn_miner_empty.json")) == nil)
        // Known by its payouts alone: found, with no workers.
        let paidOnly = Data(#"{"hashrate1h":0,"workers":[],"balance":{"owedPrl":"0","pendingPrl":"0","paidPrl":"2.5"},"payouts":[]}"#.utf8)
        let s = try #require(try PerynSource.parse(paidOnly))
        #expect(close(s.paid, 2.5) && s.workers.isEmpty)
        // An unnamed rig still gets a row.
        let unnamed = Data(#"{"workers":[{"name":"","online":true,"hashrate1h":5}]}"#.utf8)
        #expect(try PerynSource.parse(unnamed)?.workers.map(\.name) == ["—"])
    }

    /// The hour stands in for "now" only on a pool with no sub-hour figure: a rig that HAS a live
    /// rate and reads 0 there has stopped, whatever its hourly average still says.
    @Test func hourIsLiveOnlyWithoutSubHourRates() {
        #expect(WatchWorker(name: "a", online: false, rates: [.live: 0, .hour: 7]).instant == 0)
        #expect(WatchWorker(name: "b", online: true, rates: [.hour: 7, .day: 9]).instant == 7)
        #expect(WatchWorker(name: "c", online: true, rates: [.m30: 0, .h3: 7]).instant == 0)
    }

    @Test func jetskiWorkerNames() {
        #expect(JetskiSource.workerName("prl1pabc.rig-1") == "rig-1")
        #expect(JetskiSource.workerName("prl1pabc.rig.gpu0") == "rig.gpu0")
        #expect(JetskiSource.workerName("prl1pabc") == "prl1pabc")
        #expect(JetskiSource.workerName("prl1pabc.") == "default")
        #expect(JetskiSource.workerName(nil) == "default")
    }

    /// Per-worker TH/s vs account raw H/s, and a `status` that arrives as a string on one row —
    /// which used to throw typeMismatch and blank the whole card.
    @Test func f2poolUnitsAndMixedTypes() throws {
        let w = try JSONDecoder().decode(F2WorkersResp.self, from: try Fixture.data("f2pool_workers.json"))
        let rev = F2PoolSource.revenue(html: try Fixture.string("f2pool_page.html"))
        #expect(close(rev.balance, 0.43125))
        #expect(close(rev.estToday, 1234.5678))
        let paid = try F2PoolSource.paid(from: try Fixture.data("f2pool_payouts.json"))
        #expect(close(paid, 1003.90106604))

        let s = try #require(F2PoolSource.stats(w, revenue: rev, paid: paid))
        #expect(s.windows == [.m15, .day])
        #expect(s.workers.map(\.name) == ["rig-a", "rig-b", "—"])
        #expect(s.workers.map(\.online) == [true, false, false])
        #expect(close(s.workers[0].rate(.m15), 12.51e12))
        #expect(close(s.workers[1].rate(.day), 1234.5e12))          // "1,234.5" TH/s
        #expect(close(s.rates[.m15] ?? 0, 12_509_998_964_918.04))  // account: raw H/s, NOT ×1e12
        #expect(close(s.value(.m15), (12.51 + 3.2) * 1e12))
        #expect(close(s.pending, 0.43125))
        #expect(s.pendingKind == .pending)
        #expect(close(s.paid, 1003.90106604))

        // Before the 00:00 UTC settlement the balance is 0 → the day's estimate, relabelled.
        let unsettled = try #require(F2PoolSource.stats(w, revenue: F2Revenue(balance: 0, estToday: 2.5), paid: 0))
        #expect(close(unsettled.pending, 2.5))
        #expect(unsettled.pendingKind == .todayEstimate)
    }

    @Test func f2poolRefAcceptsSharedLinks() {
        let ref = F2PoolRef("我的只读页 www.f2pool.com/mining-user/0123456789abcdef0123456789ABCDEF?user_name=My Rig 请查收")
        #expect(ref?.key == "0123456789abcdef0123456789abcdef")
        #expect(ref?.pageURL.hasPrefix("https://www.f2pool.com/mining-user-prl/0123456789abcdef0123456789abcdef") == true)
        #expect(F2PoolRef("https://example.com/mining-user/0123456789abcdef") == nil)
    }

    /// The card never shows an F2Pool link: its key is the capability to read the account.
    @Test func f2poolWatchShowsAccountNotLink() {
        let key = "0123456789abcdef0123456789abcdef"
        let named = PoolWatch(pool: .f2pool, address: "https://www.f2pool.com/mining-user-prl/\(key)?user_name=My%20Rig")
        #expect(named.displayAddress == "My Rig")
        let bare = PoolWatch(pool: .f2pool, address: "https://www.f2pool.com/mining-user-prl/\(key)")
        #expect(bare.displayAddress == "F2Pool")
        #expect(!named.displayAddress.contains(key) && !bare.displayAddress.contains(key))
        let addr = "prl1pexampleexampleexampleexampleexampleexampleexample"
        #expect(PoolWatch(pool: .kryptex, address: addr).displayAddress == addr)
    }

    /// The widget total and the app's snapshot total are the same function now.
    @Test func liveRateFallsBackToSmoothestWindow() {
        var s = PoolMinerStats()
        s.windows = [.live, .hour, .day]
        s.rates = [.day: 5e12]
        s.workers = [WatchWorker(name: "a", online: false, rates: [.live: 0, .day: 0])]
        #expect(s.liveRate == 5e12)
        #expect(s.liveRateText == formatHashrate(5e12))
        s.workers = [WatchWorker(name: "a", online: true, rates: [.live: 2e12])]
        #expect(s.liveRate == 2e12)
        #expect(PoolMinerStats().liveRateText == "—")
    }
}
