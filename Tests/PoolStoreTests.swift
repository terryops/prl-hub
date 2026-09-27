import Foundation
import Testing
@testable import Pearl

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
