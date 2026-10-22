import Foundation
import Testing
@testable import Pearl

private struct SharedOverviewContract: Decodable {
    let snapshot: SharedOverview
}

private actor SharedOverviewTestLoader {
    let value: SharedOverview
    private(set) var calls = 0
    init(_ value: SharedOverview) { self.value = value }
    func load() async throws -> SharedOverview {
        calls += 1
        try await Task.sleep(for: .milliseconds(40))
        return value
    }
}

@MainActor
struct SharedPublicDataTests {
    private func snapshot() throws -> SharedOverview {
        try JSONDecoder().decode(SharedOverviewContract.self, from: Fixture.data("shared_overview.json")).snapshot
    }

    @Test func appAndWebUseTheSamePoolMeasurements() throws {
        let snapshot = try snapshot()
        let rows = PoolsOverviewStore.build(snapshot)
        let fortune = try #require(rows.first { $0.name == "Pearl Fortune" })
        #expect(fortune.poolHashrate == 2e15)
        #expect(fortune.share == 0.0004)
        #expect(fortune.blocksPerDay == 25)
        #expect(fortune.earningsPerPH == 80)
        #expect(fortune.theoreticalEarningsPerPH == 100)
        #expect(fortune.payoutComparisons.map(\.scheme) == ["PPS", "PPLNS"])
        #expect(fortune.payoutComparisons.map(\.grossPerPH) == [100, 80])
        #expect(fortune.payoutComparisons.map(\.realFeePercent) == [nil, nil])
        #expect(fortune.hashrateHistory.map(\.hashrate) == [100, 110, nil])
        #expect(fortune.lifetimeBlocks == 1000)
        let unknown = try #require(rows.first { $0.name == "Unknown Pool" })
        #expect(unknown.poolHashrate == nil)
        #expect(unknown.blocksPerDay == nil)
        #expect(!unknown.yieldTrustworthy)
        var config = Config()
        _ = applySharedNetwork(&config, try #require(snapshot.network))
        #expect(config.nethashEH == 5)
        #expect(config.perUnit == 0.02)
        #expect(config.diffNow == 1000)
        #expect(config.diff24 == 950)
        #expect(config.diff3 == 900)
        #expect(config.diff7 == 800)
    }

    @Test func sharedRowsKeepPersonalSettlementObservationsLocal() throws {
        let snapshot = try snapshot()
        let data = Data("""
        [{"pool":"Pearl Fortune","scheme":"PPS","netPRL":90,"expectedPRL":100,"start":100,"end":200,"measuredAt":250,"estimated":false,"sampleCount":10,"theoryBasis":"hashrate_chain"}]
        """.utf8)
        let rows = PoolsOverviewStore.applyMeasurements(PoolsOverviewStore.build(snapshot), data: data)
        let row = try #require(rows.first { $0.name == "Pearl Fortune" })
        #expect(close(try #require(row.realFeePercent), 10))
        #expect(row.payoutComparisons.last?.realFeePercent == nil)
    }

    @Test func aFreshInstallReadsRealFeesFromTheSharedServerResponse() throws {
        var document = try #require(try JSONSerialization.jsonObject(with: Fixture.data("shared_overview.json")) as? [String: Any])
        var value = try #require(document["snapshot"] as? [String: Any])
        var rows = try #require(value["rows"] as? [[String: Any]])
        let index = try #require(rows.firstIndex { $0["name"] as? String == "Pearl Fortune" })
        rows[index]["realFeeMeasurement"] = ["pool": "Pearl Fortune", "scheme": "PPS",
            "netPRL": 90, "expectedPRL": 100, "start": 100, "end": 200,
            "measuredAt": 250, "estimated": true, "sampleCount": 5, "theoryBasis": "hashrate_chain"] as [String: Any]
        value["rows"] = rows; document["snapshot"] = value
        let decoded = try JSONDecoder().decode(SharedOverviewContract.self, from: JSONSerialization.data(withJSONObject: document)).snapshot
        let pool = try #require(PoolsOverviewStore.build(decoded).first { $0.name == "Pearl Fortune" })
        #expect(close(try #require(pool.realFeePercent), 10))
        #expect(pool.ppsMeasurement?.start == 100)
        #expect(pool.ppsMeasurement?.estimated == true)
        #expect(pool.payoutComparisons.last?.realFeePercent == nil)
        #expect(PoolsOverviewStore.applyMeasurements([pool]).first?.realFeePercent == pool.realFeePercent)
    }

    private func snapshot(luck: Any, forPool name: String = "Pearl Fortune") throws -> SharedOverview {
        var document = try #require(try JSONSerialization.jsonObject(with: Fixture.data("shared_overview.json")) as? [String: Any])
        var value = try #require(document["snapshot"] as? [String: Any])
        var rows = try #require(value["rows"] as? [[String: Any]])
        let index = try #require(rows.firstIndex { $0["name"] as? String == name })
        rows[index]["luck"] = luck
        value["rows"] = rows; document["snapshot"] = value
        return try JSONDecoder().decode(SharedOverviewContract.self, from: JSONSerialization.data(withJSONObject: document)).snapshot
    }

    /// 预估收益 for a shared-reward pool = today's theory × its 7-day luck; the PPS contract
    /// beside it keeps the network's figure, and one day's blocks no longer decide the rank.
    @Test func aWeekOfLuckPricesSharedRewardPoolsAtTodaysTheory() throws {
        let week: [String: Any] = ["ratio": 0.98, "expectedBlocks": 190.5, "blocks": 187,
                                   "grossPerPH": 99, "theoreticalPerPH": 101, "start": 1, "end": 2, "covered": 1]
        let rows = PoolsOverviewStore.build(try snapshot(luck: ["24h": ["ratio": 0.8, "expectedBlocks": 25, "blocks": 20], "7d": week]))
        let fortune = try #require(rows.first { $0.name == "Pearl Fortune" })
        #expect(fortune.usesWeekLuck)
        #expect(close(try #require(fortune.estimatedEarningsPerPH), 98))   // 0.98 × theory 100
        #expect(fortune.earningsPerPH == 80)                               // the 24h figure is kept
        #expect(close(try #require(fortune.yieldRatio), 0.8))              // and so is its column
        let payouts = fortune.payoutComparisons
        #expect(payouts.map(\.scheme) == ["PPS", "PPLNS"])
        #expect(payouts.map(\.weekly) == [false, true])
        #expect(payouts[0].grossPerPH == 100)
        #expect(close(try #require(payouts[1].grossPerPH), 98))
        #expect(payouts[1].estimated == false)
        #expect(fortune.yieldTrustworthy)

        // A week in which the pool's work should have found only a few blocks stays a "~" guess.
        let small = PoolsOverviewStore.build(try snapshot(luck: ["7d": ["ratio": 2.4, "expectedBlocks": 3.2, "blocks": 8]]))
        let lucky = try #require(small.first { $0.name == "Pearl Fortune" })
        #expect(close(try #require(lucky.estimatedEarningsPerPH), 240))
        #expect(!lucky.yieldTrustworthy)
        #expect(lucky.payoutComparisons.last?.estimated == true)
    }

    /// The window is optional and lossy: an unreadable one leaves the 24h figure in place and
    /// never costs the rest of the snapshot.
    @Test func anUnreadableWeekFallsBackToTheDay() throws {
        let unreadable: [Any] = [NSNull(), ["24h": ["ratio": 0.8, "expectedBlocks": 25]],
                                 ["7d": ["ratio": "high", "expectedBlocks": 190]], ["7d": ["ratio": 0.9, "expectedBlocks": 0]],
                                 ["7d": ["ratio": -1, "expectedBlocks": 190]], ["7d": NSNull()], ["7d": "week"]]
        for luck in unreadable {
            let rows = PoolsOverviewStore.build(try snapshot(luck: luck))
            let fortune = try #require(rows.first { $0.name == "Pearl Fortune" })
            #expect(!fortune.usesWeekLuck)
            #expect(fortune.estimatedEarningsPerPH == 80)
            #expect(fortune.payoutComparisons.map(\.grossPerPH) == [100, 80])
            #expect(fortune.payoutComparisons.map(\.weekly) == [false, false])
        }
    }

    @Test func simultaneousConsumersShareOneLoadAndRefreshOnlyWhenNeeded() async throws {
        let snapshot = try snapshot()
        let loader = SharedOverviewTestLoader(snapshot)
        let client = SharedPublicData(load: { try await loader.load() })
        let date = Date(timeIntervalSince1970: snapshot.ts)
        try await withThrowingTaskGroup(of: Double.self) { group in
            for _ in 0..<12 { group.addTask { try await client.overview(at: date).ts } }
            for try await ts in group { #expect(ts == snapshot.ts) }
        }
        #expect(await loader.calls == 1)
        _ = try await client.overview(at: date.addingTimeInterval(299))
        #expect(await loader.calls == 1)
        _ = try await client.overview(at: date.addingTimeInterval(301))
        #expect(await loader.calls == 2)
        _ = try await client.overview(force: true, at: date.addingTimeInterval(302))
        #expect(await loader.calls == 3)
    }

    @Test func expiredDataCannotBePresentedAsAFreshSharedResult() async throws {
        let snapshot = try snapshot()
        let loader = SharedOverviewTestLoader(snapshot)
        let client = SharedPublicData(load: { try await loader.load() })
        let date = Date(timeIntervalSince1970: snapshot.ts + 901)
        for _ in 0..<2 {
            do {
                _ = try await client.overview(at: date)
                Issue.record("expired data was accepted")
            } catch { #expect((error as? URLError)?.code == .badServerResponse) }
        }
        #expect(await loader.calls == 2)
    }
}

struct PoolWatchStorageTests {
    private let addr = "prl1p8wznc8tkhlkjaq7v8ycugz93rgs8uezq6px7873934kh35nk9q2qlz0q9m"

    /// A watch on a pool this build doesn't know (added by a newer version on another device)
    /// must survive a load → save round trip, or the iCloud push would delete it everywhere.
    @Test func unknownPoolsAreKeptVerbatim() throws {
        let json = """
        [{"id":"6F1B7C2A-1111-4C1C-9C43-000000000001","pool":"AlphaPool","address":"\(addr)"},
         {"id":"6F1B7C2A-1111-4C1C-9C43-000000000002","pool":"FuturePool","address":"\(addr)","newField":7},
         {"id":"6F1B7C2A-1111-4C1C-9C43-000000000003","pool":"TW-Pool","address":"\(addr)"},
         42]
        """
        let s = try #require(PoolStore.decodeStoredWatches(Data(json.utf8)))
        #expect(s.known.map(\.pool) == [.alphaPool])
        #expect(s.foreign.count == 1)
        #expect(s.droppedRetired)
        let kept = try #require(try JSONSerialization.jsonObject(with: s.foreign[0]) as? [String: Any])
        #expect(kept["pool"] as? String == "FuturePool")
        #expect(kept["newField"] as? Int == 7)
    }

    @Test func garbageIsNotAList() {
        #expect(PoolStore.decodeStoredWatches(Data("{}".utf8)) == nil)
    }

    @Test func sameTargetIgnoresAlias() {
        let w = PoolWatch(pool: .alphaPool, address: addr)
        var renamed = w; renamed.alias = "Rig"
        var moved = w; moved.pool = .kryptex
        #expect(w.sameTarget(as: renamed))
        #expect(!w.sameTarget(as: moved))
    }
}

struct ChainIncomeTests {
    @Test func netsChangeOutOfBothLegs() {
        let legs = ChainIncome.legs([
            ["time": 100, "received": "500000000", "sent": "0", "sentToSelf": "0"],          // payout 5 PRL
            ["time": 200, "received": "90000000", "sent": "300000000", "sentToSelf": "90000000"], // send w/ change
        ])
        #expect(legs == [ChainIncome.Leg(t: 100, recv: 500_000_000, sent: 0),
                         ChainIncome.Leg(t: 200, recv: 0, sent: 210_000_000)])
    }

    /// A transfer from one own mining address to another is not income.
    @Test func excludesTransfersBetweenOwnAddresses() {
        let mine = [ChainIncome.Leg(t: 100, recv: 500_000_000, sent: 0),     // pool payout
                    ChainIncome.Leg(t: 300, recv: 199_990_000, sent: 0)]     // from my other address
        let other = [ChainIncome.Leg(t: 300, recv: 0, sent: 200_000_000)]    // (fee ≈ 0.0001)
        #expect(ChainIncome.external(mine, others: [other]) == 5)
        #expect(close(ChainIncome.external(mine, others: []), 6.9999))
    }

    @Test func dailyAverageSmoothsByDaysMined() {
        #expect(ChainIncome.dailyAverage(h24: 10, d7: 70) == 10)   // steady: d7 / 7
        #expect(ChainIncome.dailyAverage(h24: 10, d7: 10) == 10)   // resumed today: d7 / 1
        #expect(ChainIncome.dailyAverage(h24: 0, d7: 14) == 2)     // no payout today: /7
        #expect(ChainIncome.dailyAverage(h24: 3, d7: 0) == 3)      // no 7-day figure: the 24h one
    }
}

@MainActor
struct PoolsOverviewTests {
    @Test func historyDecodesDeltasAndPreservesMissingSamples() throws {
        let pool = try JSONDecoder().decode(MPSPool.self, from: Data(#"{"hashrate":45,"history_start":1000,"history_interval":3600,"history":[100,10,-20,"x",50,-5],"lastblocktime":"900"}"#.utf8))
        #expect(pool.hashrateHistory.map(\.hashrate) == [100, 110, 90, nil, 140, 135])
        #expect(pool.hashrateHistory.map(\.time) == [1000, 4600, 8200, 11800, 15400, 19000])
        #expect(pool.lastBlockDate == Date(timeIntervalSince1970: 900))
    }

    @Test func malformedOptionalHistoryDoesNotDiscardPool() throws {
        let coin = try JSONDecoder().decode(MPSCoin.self, from: Data(#"{"data":[{"url":"https://pearlhash.xyz","hashrate":100,"history":"unavailable","history_interval":-1,"lastblocktime":"—"}]}"#.utf8))
        #expect(coin.data.count == 1)
        #expect(coin.data.first?.hps == 100)
        #expect(coin.data.first?.hashrateHistory.isEmpty == true)
        #expect(coin.data.first?.lastBlockDate == nil)
    }

    @Test func overviewJoinsHistoryByPoolAndKeepsPrimaryHashrate() throws {
        let coin = try JSONDecoder().decode(MPSCoin.self, from: Data(#"{"data":[{"url":"https://pool.kryptex.com/prl","pool_id":"pool.kryptex.com","hashrate":900,"history_start":1000,"history_interval":3600,"history":[200,10],"hashrate_average_7d":205,"lastblocktime":1200}]}"#.utf8))
        let chain = try JSONDecoder().decode(LOPPublic.self, from: Data(#"{"leaderboard":{"recent_blocks":[{"time":1400,"pool":{"url":"https://prl.kryptex.network/"}},{"time":1500,"pool":{"url":"https://unrelated.example/"}}]},"lifetime":{"top":[{"blocks":50,"pool":{"url":"https://prl.kryptex.network/"}},{"blocks":10,"pool":{"url":"https://prl.kryptex.network/"}},{"blocks":100,"pool":{"url":"https://unrelated.example/"}}]}}"#.utf8))
        let rows = [LOPPool(name: "Kryptex Pool", url: "https://prl.kryptex.network/", hashrate: 300)]
        let pools = PoolsOverviewStore.build(rows, chain: chain, heroHashrate: nil, mps: coin)
        let pool = try #require(pools.first)
        #expect(pool.poolHashrate == 300)
        #expect(pool.hashrateHistory.map(\.hashrate) == [200, 210])
        #expect(pool.averageHashrate7d == 205)
        #expect(pool.lastBlockDate == Date(timeIntervalSince1970: 1400))
        #expect(pool.lifetimeBlocks == 60)
    }

    private func observation(net: Double, expected: Double, pool: String = "Example", scheme: String = "PPS") -> PPSFeeMeasurement {
        PPSFeeMeasurement(pool: pool, scheme: scheme, netPRL: net, expectedPRL: expected,
                          start: 100, end: 200, measuredAt: 300, estimated: false, sampleCount: 1,
                          theoryBasis: "hashrate_chain")
    }

    @Test func realCostRejectsPoolPricingAndUnverifiedLegacyObservations() throws {
        var pricing = observation(net: 95, expected: 100, pool: "Pearl Fortune")
        pricing.theoryBasis = "pool_pps_pricing"
        #expect(pricing.realFeePercent == nil)
        pricing.theoryBasis = nil
        #expect(pricing.realFeePercent == nil)
        let base = PoolOverview(id: "fortune", name: "Pearl Fortune", site: "https://pearlfortune.org",
                                gradient: Pearl.wash, feeType: "PPS")
        let data = try JSONEncoder().encode([pricing])
        #expect(PoolsOverviewStore.applyMeasurements([base], data: data).first?.realFeePercent == nil)
        pricing.theoryBasis = "pool_pps_pricing"
        let independent = observation(net: 90, expected: 100, pool: "Pearl Fortune")
        let mixed = try JSONEncoder().encode([pricing, independent])
        #expect(close(try #require(PoolsOverviewStore.applyMeasurements([base], data: mixed).first?.realFeePercent), 10))
    }

    @Test func realCostUsesMeasuredCreditsWithoutDeclaredFeeAndPreservesNegativeValues() throws {
        let comparison = PoolPayoutComparison(scheme: "PPS+", feePercent: 2,
                                             grossPerPH: 100, theoreticalPerPH: 100, estimated: false,
                                             measurement: observation(net: 80, expected: 100, scheme: "PPS+"))
        #expect(close(try #require(comparison.realFeePercent), 20))
        let unknownFee = PoolPayoutComparison(scheme: "PPS+", feePercent: nil,
                                             grossPerPH: nil, theoreticalPerPH: nil, estimated: false,
                                             measurement: comparison.measurement)
        #expect(unknownFee.realFeePercent == comparison.realFeePercent)
        let lucky = PoolPayoutComparison(scheme: "FPPS", feePercent: 99,
                                        grossPerPH: 100, theoreticalPerPH: 100, estimated: false,
                                        measurement: observation(net: 120, expected: 100, scheme: "FPPS"))
        #expect(close(try #require(lucky.realFeePercent), -20))
    }

    @Test func realCostOnlyIncludesPPSContracts() throws {
        for scheme in ["PPS", "PPS+", "FPPS", "pps", "pps+"] {
            let comparison = PoolPayoutComparison(scheme: scheme, feePercent: 2,
                                                 grossPerPH: 100, theoreticalPerPH: 100, estimated: true,
                                                 measurement: observation(net: 98, expected: 100, scheme: scheme))
            #expect(close(try #require(comparison.realFeePercent), 2))
        }
        for scheme in ["PPLNS", "PROP", "SOLO", "—"] {
            let comparison = PoolPayoutComparison(scheme: scheme, feePercent: 2,
                                                 grossPerPH: 80, theoreticalPerPH: 100, estimated: false,
                                                 measurement: observation(net: 80, expected: 100, scheme: scheme))
            #expect(comparison.realFeePercent == nil)
        }
    }

    @Test func realCostDistinguishesZeroIncomeFromMissingData() throws {
        let zero = PoolPayoutComparison(scheme: "PPS", feePercent: 0,
                                       grossPerPH: 100, theoreticalPerPH: 100, estimated: true,
                                       measurement: observation(net: 0, expected: 100))
        #expect(zero.realFeePercent == 100)
        let unmeasured = PoolPayoutComparison(scheme: "PPS", feePercent: 5,
                                             grossPerPH: 100, theoreticalPerPH: 100, estimated: true)
        #expect(unmeasured.realFeePercent == nil)
        for theory: Double in [0, -1, .infinity, .nan] {
            let invalid = PoolPayoutComparison(scheme: "PPS", feePercent: 1,
                                              grossPerPH: 100, theoreticalPerPH: 100, estimated: false,
                                              measurement: observation(net: 80, expected: theory))
            #expect(invalid.realFeePercent == nil)
        }
        for net: Double in [-1, .infinity, .nan] {
            let invalid = PoolPayoutComparison(scheme: "PPS", feePercent: 1,
                                              grossPerPH: 100, theoreticalPerPH: 100, estimated: false,
                                              measurement: observation(net: net, expected: 100))
            #expect(invalid.realFeePercent == nil)
        }
        let solo = PoolPayoutComparison(scheme: "SOLO", feePercent: 1,
                                       grossPerPH: 80, theoreticalPerPH: 100, estimated: false, solo: true,
                                       measurement: observation(net: 80, expected: 100))
        #expect(solo.realFeePercent == nil)
    }

    @Test func fortuneContractsUseTheSameWindowWithoutDuplicatingPoolHashrate() throws {
        let summary = try JSONDecoder().decode(PFSummary.self, from: Data(#"{"pool_stats":{"pool_fee_rate":0.02,"rolling_stats":[{"hours":1,"hashrate":2e15},{"hours":24,"hashrate":1e15,"total_coins":80,"expected_coins":100,"block_count":25}]}}"#.utf8))
        let rows = [LOPPool(name: "PF", url: "https://pearlfortune.org", blocks24h: 40,
                            feePercent: 5, payout: "PPS", hashrate: 3e15)]
        let pools = PoolsOverviewStore.build(rows, chain: nil, heroHashrate: nil, mps: nil, fortune: summary)
        #expect(pools.count == 1)
        let pool = try #require(pools.first)
        #expect(pool.poolHashrate == 2e15)
        let contracts = pool.payoutComparisons
        #expect(contracts.map(\.scheme) == ["PPS", "PPLNS"])
        #expect(contracts.map(\.feePercent) == [5, 2])
        #expect(contracts[0].realFeePercent == nil)
        #expect(contracts[0].estimated)
        #expect(contracts[1].realFeePercent == nil)
        #expect(pool.realFeePercent == nil)
        #expect(!contracts[1].estimated)
        var measured = pool
        measured.ppsMeasurement = observation(net: 95, expected: 100, pool: "Pearl Fortune")
        #expect(close(try #require(measured.realFeePercent), 5))
        #expect(measured.payoutComparisons[1].realFeePercent == nil)
    }

    @Test func ppsIncomeIgnoresPoolLuckAndMissingFortuneTheoryStaysUnknown() throws {
        let chain = try JSONDecoder().decode(LOPPublic.self, from: try Fixture.data("lordofpearls_public.json"))
        let rows = [LOPPool(name: "PPS", url: "https://pps.example", blocks24h: 0,
                            feePercent: 3, payout: "PPS", hashrate: 1e15)]
        let pool = try #require(PoolsOverviewStore.build(rows, chain: chain, heroHashrate: nil, mps: nil).first)
        #expect(pool.payoutComparisons[0].realFeePercent == nil)
        #expect(pool.payoutComparisons[0].estimated)
        var pf = PoolOverview(id: "pf", name: "Pearl Fortune", site: "https://pearlfortune.org", gradient: pool.gradient,
                              earningsPerPH: 100, theoreticalEarningsPerPH: 200, feePercent: 5)
        let missing = try JSONDecoder().decode(PFSummary.self, from: Data(#"{"pool_stats":{"rolling_stats":[{"hours":24,"hashrate":1e15,"total_coins":80,"block_count":25}]}}"#.utf8))
        PoolsOverviewStore.applyFortune(&pf, missing)
        #expect(pf.payoutComparisons.allSatisfy { $0.realFeePercent == nil })
    }

    /// Every row of one table shares one network hashrate, so the 占比 column adds up: PF's
    /// own figure is only for its stand-alone row, which has no other.
    @Test func fortuneKeepsTheTablesNetworkHashrate() throws {
        let summary = try JSONDecoder().decode(PFSummary.self, from: Data(#"{"stats":{"network_hashrate":"40 EH/s"},"pool_stats":{"rolling_stats":[{"hours":24,"hashrate":2e18,"total_coins":80,"expected_coins":90,"block_count":25}]}}"#.utf8))
        var inTable = PoolOverview(id: "pf", name: "Pearl Fortune", site: "https://pearlfortune.org", gradient: Pearl.wash,
                                   networkHashrate: 32e18)
        PoolsOverviewStore.applyFortune(&inTable, summary)
        #expect(inTable.networkHashrate == 32e18)
        #expect(inTable.share == 2e18 / 32e18)
        var alone = PoolOverview(id: "pf", name: "Pearl Fortune", site: "https://pearlfortune.org", gradient: Pearl.wash)
        PoolsOverviewStore.applyFortune(&alone, summary)
        #expect(alone.networkHashrate == 40e18)
    }

    @Test func datedMeasurementsMatchThePoolAndContract() throws {
        let base = PoolOverview(id: "k", name: "Kryptex", site: "https://pool.kryptex.com/prl",
                                gradient: Pearl.wash, feeType: "PPS+")
        let right = observation(net: 92, expected: 100, pool: "Kryptex", scheme: "PPS+")
        let wrongScheme = observation(net: 1, expected: 100, pool: "Kryptex", scheme: "PPS")
        let wrongPool = observation(net: 1, expected: 100, pool: "Other", scheme: "PPS+")
        let data = try JSONEncoder().encode([right, wrongScheme, wrongPool])
        let rows = PoolsOverviewStore.applyMeasurements([base], data: data)
        #expect(close(try #require(rows.first?.realFeePercent), 8))
        #expect(rows.first?.ppsMeasurement?.start == 100)
        #expect(PoolsOverviewStore.applyMeasurements([base], data: Data("corrupt".utf8)).first?.realFeePercent == nil)
        let invalidWindow = PPSFeeMeasurement(pool: "Kryptex", scheme: "PPS+", netPRL: 92, expectedPRL: 100,
                                               start: 200, end: 100, measuredAt: 300, estimated: false, sampleCount: 1,
                                               theoryBasis: "hashrate_chain")
        #expect(invalidWindow.realFeePercent == nil)
    }

    @Test func miningPoolStatsSharedPoolsKeepYieldsWithoutRealCosts() throws {
        let coin = try JSONDecoder().decode(MPSCoin.self, from: Data(#"{"nethash_estimat":1e18,"block_time_average":86.4,"supply":{"emission24":10000},"data":[{"pool_id":"observed","url":"https://observed.example","hashrate":1e17,"fee":2,"feetype":"PPLNS","blocks_1000":50},{"pool_id":"zero","url":"https://zero.example","hashrate":1e17,"fee":2,"feetype":"PPLNS","blocks_1000":0},{"pool_id":"missing","url":"https://missing.example","hashrate":1e17,"fee":2,"feetype":"PPLNS"}]}"#.utf8))
        let pools = PoolsOverviewStore.build(coin)
        let observed = try #require(pools.first { $0.name == "observed" })
        #expect(close(try #require(observed.earningsPerPH), 5))
        #expect(close(try #require(observed.theoreticalEarningsPerPH), 10))
        #expect(observed.realFeePercent == nil)
        #expect(observed.payoutComparisons[0].realFeePercent == nil)
        let zero = try #require(pools.first { $0.name == "zero" })
        #expect(zero.payoutComparisons[0].realFeePercent == nil)
        #expect(zero.payoutComparisons[0].estimated)
        let missing = try #require(pools.first { $0.name == "missing" })
        #expect(missing.payoutComparisons[0].realFeePercent == nil)
    }

    @Test func lordOfPearlsTableParses() throws {
        let rows = LOPPool.parse(try Fixture.string("lordofpearls_pools.html"))
        #expect(rows.count >= 5)
        #expect(rows.allSatisfy { !$0.name.isEmpty })
        #expect(rows.contains { ($0.hashrate ?? 0) > 1e15 })
    }

    /// Both tabs now use one network hashrate: 难度 × 2^48 ÷ 24h 出块时间.
    @Test func overviewShareUses24hNetworkHashrate() throws {
        let chain = try JSONDecoder().decode(LOPPublic.self, from: try Fixture.data("lordofpearls_public.json"))
        let n24 = try #require(chain.networkHashrate24h)
        let diff = try #require(chain.difficulty)
        let bt = try #require(chain.blockTime24h ?? chain.blockTimeSec)
        #expect(close(n24, diff * prlWorkPerDifficulty / bt))
        let rows = [LOPPool(name: "AlphaMine", url: "https://pearl.alphapool.tech", hashrate: n24 / 10)]
        let pools = PoolsOverviewStore.build(rows, chain: chain, heroHashrate: nil, mps: nil)
        #expect(close(try #require(pools.first?.share), 0.1))
    }

    /// HeroMiners' pool `hashrate` is >>32; without `realHashrate` it must be scaled back up.
    @Test func heroMinersFallbackHashrateIsScaled() throws {
        let s = try JSONDecoder().decode(HeroPoolStats.self, from: Data(#"{"pool":{"hashrate":803000000}}"#.utf8))
        #expect(close(try #require(s.poolHashrate), 803_000_000.0 * HeroMinersSource.hashScale))
        let real = try JSONDecoder().decode(HeroPoolStats.self,
                                            from: Data(#"{"pool":{"hashrate":803000000,"realHashrate":3.45e18}}"#.utf8))
        #expect(real.poolHashrate == 3.45e18)
    }
}
