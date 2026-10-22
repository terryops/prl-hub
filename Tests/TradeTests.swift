import Foundation
import Testing
@testable import Pearl

struct SafeTradeSigningTests {
    /// hex(HMAC-SHA256(secret, nonce + key)) — vector from Python's hmac module.
    @Test func signatureMatchesReferenceHMAC() {
        let sig = SafeTradeClient.signature(nonce: "1790474921000", apiKey: "test-key", apiSecret: "test-secret")
        #expect(sig == "426f9f52954773d96d0d96b04386023394e032d90e254e598cd15c5081848371")
    }

    @Test func clockOffsetOnlyCorrectsAClearlyWrongClock() {
        let local = Date(timeIntervalSince1970: 1_790_474_921)
        // Header 02:08:41 vs a device at …:41.0 — within the header's resolution.
        #expect(SafeTradeNonceGenerator.offset(server: local, local: local) == 0)
        // Device 10 s behind the server → nonces move 10.5 s forward.
        #expect(SafeTradeNonceGenerator.offset(server: local.addingTimeInterval(10), local: local) == 10_500)
        // Device 5 s ahead → nonces move back.
        #expect(SafeTradeNonceGenerator.offset(server: local.addingTimeInterval(-5), local: local) == -4_500)
    }

    @Test func noncesStayIncreasing() async {
        let g = SafeTradeNonceGenerator()
        var last = 0
        for _ in 0..<50 {
            let n = Int(await g.next())!
            #expect(n > last)
            last = n
        }
    }
}

struct SafeTradeErrorTests {
    private func problem(_ status: Int, _ keys: [String]) -> SafeTradeAuthProblem? {
        let body = String(data: try! JSONSerialization.data(withJSONObject: ["errors": keys]), encoding: .utf8)!
        return SafeTradeAuthProblem(status: status, body: body)
    }

    @Test func untrustedIPIsRecognised() {
        #expect(problem(401, ["authz.not_trusted_ip"]) == .untrustedIP)
        #expect(problem(403, ["authz.ip_not_trusted"]) == .untrustedIP)
        #expect(problem(401, ["authz.ip_not_whitelisted"]) == .untrustedIP)
        // The user-facing text of an HTTP error is the human message, not raw JSON.
        let e = SafeTradeError.http(401, #"{"errors":["authz.not_trusted_ip"]}"#)
        #expect(e.authProblem == .untrustedIP)
        #expect(e.errorDescription?.contains("HTTP") == false)
    }

    @Test func otherAuthProblemsAreTold() {
        #expect(problem(401, ["authz.nonce_expired"]) == .clock)
        #expect(problem(401, ["authz.invalid_signature"]) == .badKey)
        #expect(problem(401, ["authz.unexistent_apikey"]) == .badKey)
        // "ip" must match as a word, not inside "invalid_permission".
        #expect(problem(403, ["authz.invalid_permission"]) == .other(["authz.invalid_permission"]))
        #expect(SafeTradeAuthProblem(status: 403, body: "<!DOCTYPE html><html><title>Attention Required!") == .firewall)
        #expect(problem(422, ["authz.not_trusted_ip"]) == nil)   // not an auth status
        #expect(SafeTradeAuthProblem.isNonceKey("authz.nonce_expired"))
        #expect(!SafeTradeAuthProblem.isNonceKey("authz.invalid_signature"))
    }

    @Test func orderErrorsGetHumanText() {
        for key in ["market.order.non_round_price", "market.order.non_round_amount",
                    "market.order.amount_less_than_min_amount", "market.account.insufficient_balance",
                    "market.order.insufficient_market_liquidity", "market.order.price_less_than_min_price"] {
            #expect(SafeTradeError.message(forKey: key) != nil, "\(key)")
        }
        #expect(SafeTradeError.message(forKey: "market.order.something_new") == nil)
        #expect(SafeTradeError.message(forKey: "account.withdraw.invalid_otp_code") != nil)
    }

    @Test func ambiguousPostOutcomes() {
        #expect(SafeTradeClient.isAmbiguousPostStatus(502))
        #expect(SafeTradeClient.isAmbiguousPostStatus(0))
        #expect(!SafeTradeClient.isAmbiguousPostStatus(422))
        #expect(SafeTradeClient.isAmbiguousPostFailure(URLError(.badServerResponse)))
        #expect(SafeTradeClient.isAmbiguousPostFailure(URLError(.timedOut)))
        #expect(!SafeTradeClient.isAmbiguousPostFailure(URLError(.notConnectedToInternet)))
    }

    /// A GET is re-sent once only when the connection dropped under it; a cancelled read
    /// (the view task went away) is no verdict at all.
    @Test func droppedAndCancelledRequests() {
        #expect(SafeTradeClient.isDroppedConnection(URLError(.networkConnectionLost)))
        #expect(SafeTradeClient.isDroppedConnection(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)))
        #expect(SafeTradeClient.isDroppedConnection(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNABORTED))))
        #expect(!SafeTradeClient.isDroppedConnection(URLError(.timedOut)))
        #expect(!SafeTradeClient.isDroppedConnection(URLError(.notConnectedToInternet)))
        #expect(!SafeTradeClient.isDroppedConnection(URLError(.cancelled)))
        #expect(SafeTradeClient.isCancellation(URLError(.cancelled)))
        #expect(SafeTradeClient.isCancellation(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        #expect(SafeTradeClient.isCancellation(CancellationError()))
        #expect(!SafeTradeClient.isCancellation(URLError(.networkConnectionLost)))
        #expect(!SafeTradeClient.isCancellation(SafeTradeError.http(401, "")))
    }
}

@MainActor
struct SafeTradeOrderTrackingTests {
    private func order(_ id: Int, _ side: String, _ state: String) -> STOrder {
        STOrder(id: id, market: "prlusdt", side: side, type: "limit", price: "1.5", state: state,
                origin_amount: "10", avg_price: nil, created_at: nil, updated_at: nil)
    }

    @Test func mergePutsEveryOpenOrderFirstOnce() {
        let recent = [order(9, "buy", "done"), order(8, "sell", "wait"), order(7, "buy", "cancel")]
        let open = [order(8, "sell", "wait"), order(3, "buy", "wait")]   // #3 is past the recent cap
        let merged = SafeTradeStore.merge(recent: recent, open: open)
        #expect(merged.compactMap(\.id) == [8, 3, 9, 7])
    }

    @Test func mergePrefersTheRecentCopy() {
        // A stale open list (reused after a failed read) still says #8 is open, but the
        // fresh recent list shows it filled: it must not stay pinned as open.
        let recent = [order(8, "sell", "done")]
        let staleOpen = [order(8, "sell", "wait"), order(3, "buy", "wait")]
        let merged = SafeTradeStore.merge(recent: recent, open: staleOpen)
        #expect(merged.map(\.id) == [3, 8])
        #expect(merged.last?.state == "done")
    }

    @Test func unverifiedOrderMatchesOnlyNewOnSameSide() {
        let check = PendingOrderCheck(side: "buy", knownIDs: [9, 8], knownComplete: true)
        #expect(check.isNew(order(10, "buy", "wait")))
        #expect(!check.isNew(order(9, "buy", "done")))     // was already there
        #expect(!check.isNew(order(11, "sell", "wait")))   // other side
    }

    @Test func unverifiedWithdrawMatchesAnyNewRow() throws {
        let check = PendingWithdrawCheck(knownIDs: [1, 2], knownComplete: true)
        let rows = try JSONDecoder().decode([STWithdraw].self, from: Data(#"[{"id":3,"amount":"5"},{"id":2,"amount":"1"}]"#.utf8))
        #expect(rows.filter(check.isNew).map(\.id) == [3])
    }

    @Test func ipIssueKnowsIPv6() {
        #expect(SafeTradeIPIssue(ip: "2605:52c0::1").isIPv6)
        #expect(!SafeTradeIPIssue(ip: "203.0.113.9").isIPv6)
    }
}

struct CandleVolumeBandTests {
    @Test func bandSitsUnderThePriceRange() {
        let b = CandleVolumeBand(priceLow: 1.30, priceHigh: 1.50, maxVolume: 4000)
        #expect(b.ceiling == 1.30)
        // The band is `share` of the whole plot (band + price range).
        #expect(abs((b.ceiling - b.floor) / (1.50 - b.floor) - CandleVolumeBand.share) < 1e-12)
        #expect(b.top(0) == b.floor)
        // The tallest bar stops short of the price range, leaving the caption's row.
        #expect(abs(b.top(4000) - (b.floor + (b.ceiling - b.floor) * CandleVolumeBand.barShare)) < 1e-12)
        #expect(abs(b.top(2000) - (b.floor + b.top(4000)) / 2) < 1e-12)
        #expect(b.top(9000) == b.top(4000) && b.top(-5) == b.floor)
    }

    @Test func noVolumeDrawsNoBars() {
        let b = CandleVolumeBand(priceLow: 1.30, priceHigh: 1.50, maxVolume: 0)
        #expect(b.top(0) == b.floor && b.top(100) == b.floor)
    }

    /// Chinese has no unit for thousands, so three significant digits would print
    /// 4,567 as "4570" — next to a tooltip that says 4,567.
    @Test func compactVolumeKeepsWholeDigitsWithoutAUnit() {
        let zh = Locale(identifier: "zh-Hans"), en = Locale(identifier: "en")
        #expect(CandleChart.compactVolume(4567, locale: zh) == "4567")
        #expect(CandleChart.compactVolume(12_345_678, locale: zh) == "1235万")
        #expect(CandleChart.compactVolume(35_612, locale: zh) == "3.56万")
        #expect(CandleChart.compactVolume(4567, locale: en) == "4.57K")
        #expect(CandleChart.compactVolume(5.25, locale: en) == "5.25")
    }

    /// Spreading two fingers shows fewer candles, pinching more — never closer than
    /// `minVisible`, never more than are loaded.
    @Test func pinchZoomsBetweenTheClosestViewAndEverythingLoaded() {
        #expect(CandleChart.zoomedCount(from: 60, scale: 2, loaded: 120) == 30)
        #expect(CandleChart.zoomedCount(from: 60, scale: 0.5, loaded: 120) == 120)
        #expect(CandleChart.zoomedCount(from: 60, scale: 0.1, loaded: 120) == 120)
        #expect(CandleChart.zoomedCount(from: 60, scale: 50, loaded: 120) == CandleChart.minVisible)
        // A stored count from a longer series, and a market with barely any history.
        #expect(CandleChart.zoomedCount(from: 120, scale: 1, loaded: 80) == 80)
        #expect(CandleChart.zoomedCount(from: 60, scale: 1, loaded: 5) == CandleChart.minVisible)
        #expect(CandleChart.zoomedCount(from: 60, scale: 0, loaded: 120) == 60)
        #expect(CandleChart.zoomedCount(from: 60, scale: .nan, loaded: 120) == 60)
    }

    /// A mouse wheel zooms a notch at a time: away from you closer, towards you further,
    /// however small the turn is reported, and a fast spin no more than three notches.
    @Test func mouseWheelZoomsANotchAtATime() {
        #expect(CandleChart.wheelScale(lines: 1) == 1.15)
        #expect(CandleChart.wheelScale(lines: 0.1) == 1.15)
        #expect(abs(CandleChart.wheelScale(lines: -1) - 1 / 1.15) < 1e-9)
        #expect(abs(CandleChart.wheelScale(lines: 40) - 1.15 * 1.15 * 1.15) < 1e-9)
        #expect(abs(CandleChart.wheelScale(lines: -40) - 1 / (1.15 * 1.15 * 1.15)) < 1e-9)
        #expect(CandleChart.wheelScale(lines: 0) == 1)
        #expect(CandleChart.wheelScale(lines: .nan) == 1)
        // A notch always moves the chart, at either end of the range, until it gets there.
        #expect(CandleChart.zoomedCount(from: 60, scale: CandleChart.wheelScale(lines: 1), loaded: 120) == 52)
        #expect(CandleChart.zoomedCount(from: 60, scale: CandleChart.wheelScale(lines: -1), loaded: 120) == 69)
        #expect(CandleChart.zoomedCount(from: 21, scale: CandleChart.wheelScale(lines: 1), loaded: 120) == 20)
        #expect(CandleChart.zoomedCount(from: 20, scale: CandleChart.wheelScale(lines: -1), loaded: 120) == 23)
        #expect(CandleChart.zoomedCount(from: 119, scale: CandleChart.wheelScale(lines: -1), loaded: 120) == 120)
    }

    /// Dragging the chart to the right brings older candles in, a candle's width at a
    /// time; it stops at the oldest one loaded, and at the latest going back.
    @Test func draggingPansThroughTheLoadedCandles() {
        // 60 candles across 300 points: 5 points each.
        #expect(CandleChart.pannedOffset(from: 0, by: 50, plotWidth: 300, shown: 60, loaded: 120) == 10)
        #expect(CandleChart.pannedOffset(from: 10, by: -20, plotWidth: 300, shown: 60, loaded: 120) == 6)
        #expect(CandleChart.pannedOffset(from: 10, by: -500, plotWidth: 300, shown: 60, loaded: 120) == 0)
        #expect(CandleChart.pannedOffset(from: 0, by: 5000, plotWidth: 300, shown: 60, loaded: 120) == 60)
        // Everything loaded is on screen: nowhere to go. And zooming out pulls the window back in.
        #expect(CandleChart.pannedOffset(from: 0, by: 200, plotWidth: 300, shown: 120, loaded: 120) == 0)
        #expect(CandleChart.pannedOffset(from: 60, by: 0, plotWidth: 300, shown: 100, loaded: 120) == 20)
        #expect(CandleChart.pannedOffset(from: 3, by: .nan, plotWidth: 300, shown: 60, loaded: 120) == 3)
        #expect(CandleChart.pannedOffset(from: 3, by: 10, plotWidth: 0, shown: 60, loaded: 120) == 3)

        #expect(CandleChart.window(loaded: 120, shown: 60, hidden: 0) == 60..<120)
        #expect(CandleChart.window(loaded: 120, shown: 60, hidden: 10) == 50..<110)
        #expect(CandleChart.window(loaded: 120, shown: 60, hidden: 60) == 0..<60)
        // A market with hardly any history, and nothing loaded yet.
        #expect(CandleChart.window(loaded: 5, shown: 20, hidden: 0) == 0..<5)
        #expect(CandleChart.window(loaded: 0, shown: 20, hidden: 0) == 0..<0)
    }
}
