import Foundation

// MARK: - Order-book depth curve (买卖深度图 model)

/// One book level with everything resting between it and the best price on its side.
struct DepthPoint: Identifiable, Equatable {
    let price: Double
    /// PRL at this level and every better one on its side.
    let cumulative: Double
    /// USDT value of `cumulative` (Σ price × amount).
    let cumulativeValue: Double
    var id: Double { price }
}

/// The cumulative bid / ask curves of an order book, cut to a window around the mid
/// price. SafeTrade's book has absurd far-away orders (asks at 100000, bids at 0.01)
/// that would squash everything interesting into one pixel; see `halfWidth`.
struct DepthCurve: Equatable {
    enum Side: Equatable { case bid, ask }

    /// Best first (highest price first), cumulative — within the window.
    let bids: [DepthPoint]
    /// Best first (lowest price first), cumulative — within the window.
    let asks: [DepthPoint]
    let bestBid: Double?
    let bestAsk: Double?
    let mid: Double
    /// Price range drawn: mid × (1 ∓ halfWidth).
    let lo: Double
    let hi: Double

    /// Default reach either side of the mid: ±10 % (≈ 15 levels at today's PRL tick).
    /// Wider, the big walls further out set the scale and flatten the levels a trade
    /// actually meets into the baseline.
    static let baseHalfWidth = 0.10
    /// …widened, when the tick is coarse, until each side shows this many levels.
    static let minLevels = 8

    var spread: Double? { bestBid.flatMap { b in bestAsk.map { $0 - b } } }
    /// Spread as a % of the mid.
    var spreadPercent: Double? { spread.map { $0 / mid * 100 } }
    /// PRL on each side inside the window.
    var bidTotal: Double { bids.last?.cumulative ?? 0 }
    var askTotal: Double { asks.last?.cumulative ?? 0 }
    /// Bid share of the in-window book, 0…1 (nil when both sides are empty).
    var bidShare: Double? {
        let total = bidTotal + askTotal
        return total > 0 ? bidTotal / total : nil
    }
    var maxCumulative: Double { max(bidTotal, askTotal) }

    /// nil when the book is empty on both sides.
    init?(_ depth: STDepth) {
        // Defensive re-sort: the decoder already orders them, but the curve relies on it.
        let bidLevels = depth.bids.sorted { $0.price > $1.price }
        let askLevels = depth.asks.sorted { $0.price < $1.price }
        guard !bidLevels.isEmpty || !askLevels.isEmpty else { return nil }
        let bestBid = bidLevels.first?.price
        let bestAsk = askLevels.first?.price
        let mid: Double
        switch (bestBid, bestAsk) {
        case let (b?, a?): mid = (b + a) / 2
        case let (b?, nil): mid = b
        case let (nil, a?): mid = a
        default: return nil
        }
        guard mid > 0 else { return nil }
        let w = Self.halfWidth(mid: mid, bids: bidLevels, asks: askLevels)
        let lo = mid * (1 - w), hi = mid * (1 + w)
        self.bestBid = bestBid
        self.bestAsk = bestAsk
        self.mid = mid
        self.lo = lo
        self.hi = hi
        // The level that set the window's edge must survive the round trip through
        // mid × (1 ∓ w), so compare with a hair of slack.
        let slack = mid * 1e-9
        bids = Self.accumulate(bidLevels.filter { $0.price >= lo - slack })
        asks = Self.accumulate(askLevels.filter { $0.price <= hi + slack })
    }

    /// How far either side of the mid to draw, as a fraction of it:
    /// - ±10 % by default — the part of the book a trade can plausibly reach;
    /// - widened until each side shows `minLevels` levels (a coarse tick on a cheap
    ///   coin would otherwise leave two or three steps);
    /// - but never past the SHORTER side's last fetched level: the book is fetched
    ///   top-N, so beyond that we simply don't know, and letting one curve stop short
    ///   of the edge would draw a cliff that isn't really there.
    static func halfWidth(mid: Double, bids: [STBookLevel], asks: [STBookLevel]) -> Double {
        func reach(_ l: STBookLevel?) -> Double? { l.map { abs($0.price - mid) / mid } }
        func kth(_ side: [STBookLevel]) -> Double? { reach(side.prefix(minLevels).last) }
        let reaches = [reach(bids.last), reach(asks.last)].compactMap { $0 }
        let wanted = max(baseHalfWidth, [kth(bids), kth(asks)].compactMap { $0 }.max() ?? 0)
        let cap = reaches.min() ?? wanted
        // A floor so a one-level book still gets a visible range around it.
        return max(min(wanted, cap), 0.005)
    }

    /// Running totals, best level first.
    static func accumulate(_ levels: [STBookLevel]) -> [DepthPoint] {
        var amount = 0.0, value = 0.0
        return levels.map { l in
            amount += l.amount
            value += l.amount * l.price
            return DepthPoint(price: l.price, cumulative: amount, cumulativeValue: value)
        }
    }

    /// The level the scrub cursor at `price` points at: a bid at or below the best bid,
    /// an ask at or above the best ask, otherwise (inside the spread) whichever best
    /// price is closer. Snaps to the nearest drawn level on that side.
    func level(near price: Double) -> (side: Side, point: DepthPoint)? {
        let side: Side
        switch (bids.first, asks.first) {
        case let (b?, a?):
            if price <= b.price { side = .bid }
            else if price >= a.price { side = .ask }
            else { side = price - b.price <= a.price - price ? .bid : .ask }
        case (.some, nil): side = .bid
        case (nil, .some): side = .ask
        default: return nil
        }
        let points = side == .bid ? bids : asks
        guard let p = points.min(by: { abs($0.price - price) < abs($1.price - price) }) else { return nil }
        return (side, p)
    }
}
