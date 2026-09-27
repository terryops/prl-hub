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
        #expect(s.workers.count == 2)
        #expect(s.onlineCount == 2)
        #expect(close(s.rates[.live] ?? 0, 1_484_611_832_566_431.5))
        #expect(close(s.rates[.hour] ?? 0, 1_436_805_857_609_719))
        #expect(close(s.rates[.day] ?? 0, 1_146_779_915_064_822.2))
        // Per rig only a live rate exists — the 1h/24h stat falls back to the account figure.
        #expect(close(s.value(.live), 1_484_611_832_566_431.5))
        #expect(close(s.value(.day), 1_146_779_915_064_822.2))
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
