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
