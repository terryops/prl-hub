import Foundation
import Testing
@testable import Pearl

struct TradeDepthTests {
    /// `count` levels from `start`, `step` apart, `amount` each.
    private func levels(_ start: Double, _ step: Double, _ count: Int, amount: Double = 10) -> [STBookLevel] {
        (0..<count).map { STBookLevel(price: start + Double($0) * step, amount: amount) }
    }

    @Test func accumulatesEachSideFromTheBestPrice() throws {
        let book = STDepth(asks: [STBookLevel(price: 1.49, amount: 5), STBookLevel(price: 1.48, amount: 2)],
                           bids: [STBookLevel(price: 1.46, amount: 4), STBookLevel(price: 1.47, amount: 1)])
        let c = try #require(DepthCurve(book))
        #expect(c.bids.map(\.price) == [1.47, 1.46])          // best first even if the input isn't
        #expect(c.bids.map(\.cumulative) == [1, 5])
        #expect(c.asks.map(\.price) == [1.48, 1.49])
        #expect(c.asks.map(\.cumulative) == [2, 7])
        #expect(abs(c.asks[1].cumulativeValue - (2 * 1.48 + 5 * 1.49)) < 1e-9)
        #expect(c.bidTotal == 5 && c.askTotal == 7)
        #expect(abs(c.mid - 1.475) < 1e-12)
        #expect(abs(try #require(c.spread) - 0.01) < 1e-9)
        #expect(abs(try #require(c.spreadPercent) - 0.01 / 1.475 * 100) < 1e-9)
        #expect(abs(try #require(c.bidShare) - 5.0 / 12) < 1e-12)
    }

    @Test func windowDropsFarOutliers() throws {
        // A fine tick (0.01 at ~1.47) with a deep fetched book, plus the kind of junk
        // SafeTrade really has: an ask at 100000 and a bid at 0.01.
        let asks = levels(1.48, 0.01, 60) + [STBookLevel(price: 100000, amount: 7)]
        let bids = levels(1.47, -0.01, 60) + [STBookLevel(price: 0.01, amount: 55705)]
        let c = try #require(DepthCurve(STDepth(asks: asks, bids: bids)))
        // The farthest fetched levels are the outliers, so the reach cap doesn't bind:
        // the default ±10 % applies.
        #expect(abs(c.lo - c.mid * (1 - DepthCurve.baseHalfWidth)) < 1e-9)
        #expect(abs(c.hi - c.mid * (1 + DepthCurve.baseHalfWidth)) < 1e-9)
        #expect(c.asks.allSatisfy { $0.price <= c.hi } && c.bids.allSatisfy { $0.price >= c.lo })
        #expect(!c.asks.contains { $0.price == 100000 })
        #expect(!c.bids.contains { $0.price == 0.01 })
    }

    @Test func windowNeverPassesTheShorterFetchedSide() throws {
        // Bids only reach 5 % below the mid (the rest wasn't fetched): drawing ±10 %
        // would show the bid curve stopping short — a cliff that isn't there.
        let asks = levels(1.01, 0.01, 30)
        let bids = levels(0.99, -0.01, 5)       // down to 0.95
        let c = try #require(DepthCurve(STDepth(asks: asks, bids: bids)))
        #expect(abs(c.lo - 0.95) < 1e-9)
        #expect(abs((c.hi / c.mid - 1) - 0.05) < 1e-9)
    }

    @Test func coarseTickWidensToShowEnoughLevels() throws {
        // At 0.10 a 0.01 tick is 10 % per level; ±10 % would show one step per side.
        let asks = levels(0.11, 0.01, 20)
        let bids = levels(0.09, -0.01, 9)       // 0.09 … 0.01
        let c = try #require(DepthCurve(STDepth(asks: asks, bids: bids)))
        let halfWidth = c.hi / c.mid - 1
        #expect(halfWidth > DepthCurve.baseHalfWidth)
        #expect(c.bids.count >= DepthCurve.minLevels)
        #expect(c.asks.count >= DepthCurve.minLevels)
    }

    @Test func oneSidedAndEmptyBooks() throws {
        #expect(DepthCurve(STDepth(asks: [], bids: [])) == nil)
        let asksOnly = try #require(DepthCurve(STDepth(asks: levels(2, 0.01, 10), bids: [])))
        #expect(asksOnly.mid == 2 && asksOnly.bids.isEmpty && asksOnly.bestBid == nil)
        #expect(asksOnly.spread == nil && asksOnly.bidShare == 0)
        #expect(asksOnly.level(near: 1.5)?.side == .ask)
        let oneLevel = try #require(DepthCurve(STDepth(asks: [], bids: [STBookLevel(price: 1, amount: 3)])))
        #expect(oneLevel.hi > oneLevel.lo)       // the floor keeps a visible range
        #expect(oneLevel.bids.count == 1)
    }

    @Test func scrubSnapsToTheNearestLevelOnTheRightSide() throws {
        let c = try #require(DepthCurve(STDepth(asks: levels(1.48, 0.01, 20), bids: levels(1.47, -0.01, 20))))
        let deepBid = try #require(c.level(near: 1.402))
        #expect(deepBid.side == .bid && abs(deepBid.point.price - 1.40) < 1e-9)
        #expect(deepBid.point.cumulative == 80)               // 1.47 … 1.40 = 8 levels × 10
        let ask = try #require(c.level(near: 1.516))
        #expect(ask.side == .ask && abs(ask.point.price - 1.52) < 1e-9)
        // Inside the spread: the closer best price wins.
        #expect(c.level(near: 1.4720)?.side == .bid)
        #expect(c.level(near: 1.4785)?.side == .ask)
    }
}
