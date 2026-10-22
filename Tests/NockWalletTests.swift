import Foundation
import Testing
@testable import Pearl

/// The NOCK wallet core as the app links it (NockMobile.xcframework through the FFI).
struct NockCoreTests {
    static let abandon = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    @Test func coreIsLinked() {
        #expect(NockCore.isAvailable)
    }

    /// The address a seed opens must be the one the official wallet shows for it.
    @Test func sameSeedSameAddressAsOfficialWallet() throws {
        // Logged by `nockchain-wallet keygen` (Iris iris-crypto test_keygen).
        let cli = "pass destroy hub reject cricket flight camp garden scale liquid increase pool miracle fly tower file door cage vault tone night zero push crime"
        #expect(try NockCore.account(mnemonic: cli).address == "AyzPiJoqcqmdZdjxZ9aGLnVsbYcCphidHERKBWVXyKhNqTirshTmicG")
        // 12 words, the length Pearl Hub generates.
        let a = try NockCore.account(mnemonic: Self.abandon)
        #expect(a.address == "3zxKWhhd8HY9pT2ZCZNUSEz2XWwSk15P2sD3atnnnxRtHa2Ta1H4jRy")
        #expect(a.simpleFirstName != a.coinbaseFirstName)
        #expect(try NockCore.account(mnemonic: Self.abandon, index: 1).address == "6RJZqW9NfrBuvakJ8fMcoH4Qb6A24Soxbp1SELkHW1PnoA6wPU5Hqvr")
    }

    @Test func badSeedIsRejected() {
        #expect(throws: NockCore.Failure.self) { try NockCore.account(mnemonic: "abandon abandon abandon") }
    }

    @Test func addressChecks() {
        let good = "3zxKWhhd8HY9pT2ZCZNUSEz2XWwSk15P2sD3atnnnxRtHa2Ta1H4jRy"
        #expect(NockCore.addressProblem(good) == nil)
        #expect(NockCore.addressProblem(" \(good)\n") == nil)
        #expect(NockCore.addressProblem(String(good.prefix(30))) == "invalid_address")
        #expect(NockCore.addressProblem("prl1pqvwgxsx2qxlz0q9m") == "invalid_address")
        #expect(NockCore.addressProblem("") == "invalid_address")
        #expect(NockCore.addressProblem(String(repeating: "z", count: 132)) == "legacy_address")
    }

    @Test func amounts() {
        #expect(NockCore.nock(fromNicks: 65_536) == 1)
        #expect(NockCore.nock(fromNicks: 1) == Decimal(string: "0.0000152587890625"))
        #expect(NockCore.nicks(fromNock: Decimal(string: "1.5")!) == 98_304)
        #expect(NockCore.nicks(fromNock: Decimal(string: "0.000001")!) == 0)
        #expect(NockCore.parseAmount("1,5") == Decimal(string: "1.5"))
        #expect(NockCore.parseAmount("12.123456") != nil)
        #expect(NockCore.parseAmount("12.1234567") == nil)
        #expect(NockCore.parseAmount("1.2.3") == nil)
        #expect(NockCore.parseAmount("abc") == nil)
        // MAX fills the form with something the form accepts.
        let max = NockCore.plainAmount(nicks: 2_802_626_000_123)
        #expect(max == "42764678.956954")
        #expect(NockCore.parseAmount(max) != nil)
        #expect(NockCore.plainAmount(nicks: 65_536) == "1")
    }

    private func frame(_ flag: UInt8, _ payload: Data) -> Data {
        var d = Data([flag])
        var n = UInt32(payload.count).bigEndian
        d.append(Data(bytes: &n, count: 4))
        d.append(payload)
        return d
    }

    @Test func grpcWebFrames() throws {
        let msg = Data([1, 2, 3])
        let ok = frame(0, msg) + frame(0x80, Data("grpc-status:0\r\ngrpc-message:\r\n".utf8))
        #expect(try NockClient.parseFrames(ok) == msg)
        let failed = frame(0x80, Data("grpc-status: 5\r\ngrpc-message: Transaction%20not%20found\r\n".utf8))
        #expect(throws: NockClient.RPCError.self) { try NockClient.parseFrames(failed) }
        #expect(throws: NockClient.RPCError.self) { try NockClient.parseFrames(frame(0, msg).dropLast()) }
    }

    /// Sign a real payment through the FFI from notes shaped like the node's (fixture written
    /// by tools/nock-mobile `cargo test write_swift_fixture -- --ignored`).
    @Test func buildAndSignThroughFFI() throws {
        let fx = try JSONSerialization.jsonObject(with: try Fixture.data("nock_notes.json")) as? [String: Any] ?? [:]
        let nock: UInt64 = 65_536
        var params: [String: Any] = [
            "mnemonic": fx["mnemonic"] as Any, "notes": fx["notes"] as Any,
            "recipient": fx["recipient"] as Any, "height": fx["height"] as Any,
            "amount": String(40 * nock), "sweep": false,
        ]
        let r = try NockCore.call("buildSend", params)
        let n = { (k: String) in UInt64(r[k] as? String ?? "") ?? 0 }
        #expect(n("amount") == 40 * nock)
        #expect(n("fee") >= n("minFee") && n("fee") > 0)
        #expect(n("inputTotal") == n("amount") + n("fee") + n("change"))
        #expect((r["body"] as? String).flatMap { Data(base64Encoded: $0) }?.isEmpty == false)
        #expect((r["outputs"] as? [[String: Any]])?.contains { ($0["mine"] as? Bool) == true } == true)
        #expect(n("returning") == n("change"))

        params["sweep"] = true
        let s = try NockCore.call("buildSend", params)
        let sn = { (k: String) in UInt64(s[k] as? String ?? "") ?? 0 }
        #expect(sn("change") == 0)
        #expect(sn("amount") + sn("fee") == 85 * nock)   // the mature notes only

        params["sweep"] = false
        params["amount"] = String(85 * nock)
        #expect(throws: NockCore.Failure.self) { try NockCore.call("buildSend", params) }
    }
}

@MainActor
struct NockStoreTests {
    private func note(_ id: String, _ nicks: UInt64, kind: String, spendable: Bool, unlock: UInt64 = 0) -> NockNote {
        NockNote(json: ["nameFirst": id, "nameLast": "x", "assets": String(nicks), "raw": "",
                        "originPage": 100, "kind": kind, "unlockHeight": unlock, "spendable": spendable])!
    }

    @Test func balanceSplitsLockedRewards() {
        let store = NockWalletStore.shared
        let account = NockCore.Account(address: "a", simpleFirstName: "s", coinbaseFirstName: "c")
        store._testAdopt(account: account, notes: [
            note("p1", 10, kind: "simple", spendable: true),
            note("c1", 20, kind: "coinbase", spendable: true),
            note("c2", 30, kind: "coinbase", spendable: false, unlock: 1_040),
        ], tip: 1_000)
        #expect(store.balance == NockBalance(total: 60, available: 30, locked: 30))
        #expect(store.blocksUntilNextUnlock == 40)
    }

    /// Only the node's own "no" frees a send for a retry; anything unclear keeps it blocked.
    @Test func broadcastErrorsThatProveNothingWentOut() {
        #expect(NockWalletStore.isRefusal(NockCore.Failure(code: "server", message: "fee too low")))
        #expect(NockWalletStore.isRefusal(NockClient.RPCError.status(3, "invalid")))
        #expect(NockWalletStore.isRefusal(NockClient.RPCError.http(429)))
        #expect(!NockWalletStore.isRefusal(NockCore.Failure(code: "decode", message: "")))
        #expect(!NockWalletStore.isRefusal(NockClient.RPCError.http(504)))
        #expect(!NockWalletStore.isRefusal(NockClient.RPCError.status(4, "deadline")))
        #expect(!NockWalletStore.isRefusal(NockClient.RPCError.status(13, "internal")))
        #expect(!NockWalletStore.isRefusal(NockClient.RPCError.transport("lost")))
        #expect(NockWalletStore.isAlreadyKnown(NockClient.RPCError.status(6, "exists")))
    }

    /// The wallet page shows the NOCK card once the wallet holds NOCK (or fetched its address).
    @Test func holdingNockCountsAsInUse() {
        let store = NockWalletStore.shared
        store._testAdopt(account: NockCore.Account(address: "a", simpleFirstName: "s", coinbaseFirstName: "c"),
                         notes: [note("p1", 10, kind: "simple", spendable: true)], tip: 1_000)
        #expect(store.inUse)
    }

    /// A state saved before `addressShown` existed still loads (as not shown).
    @Test func olderSavedStateStillLoads() throws {
        let old = try JSONDecoder().decode(NockWalletStore.State.self, from: Data(#"{"address":"a","history":[]}"#.utf8))
        #expect(old.address == "a" && !old.addressShown)
        var shown = NockWalletStore.State()
        shown.addressShown = true
        let back = try JSONDecoder().decode(NockWalletStore.State.self, from: try JSONEncoder().encode(shown))
        #expect(back.addressShown)
    }

    @Test func removingAWalletDropsItsNockState() {
        let key = "nock.state.test-removed"
        UserDefaults.standard.set(Data("{}".utf8), forKey: key)
        NockWalletStore.shared.forgetWallet("test-removed")
        #expect(UserDefaults.standard.data(forKey: key) == nil)
    }

    @Test func preparedFeeWarning() {
        func p(_ amount: UInt64, _ fee: UInt64) -> NockPreparedSend {
            NockPreparedSend(txId: "t", recipient: "r", amount: amount, fee: fee, change: 0, returning: 0, sweep: false,
                             body: Data(), inputs: [], changeNotes: [], walletID: "w", generation: 0)
        }
        #expect(p(100, 10).feeIsHigh)
        #expect(!p(100, 9).feeIsHigh)
    }
}

/// Two public nodes: one failing (its gateway's "upstream connect error", the HTTP 503 users
/// saw) must not fail the wallet while the other answers.
struct NockFailoverTests {
    /// By host: down.* = trailers-only UNAVAILABLE (rpc.nockbox.org with its node unreachable),
    /// yes.* / no.* = TransactionAccepted true / false, ack.* = send acknowledged,
    /// refuse.* = the node's own "no" to a send.
    final class NodeStub: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".nock.test") == true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        static func frame(_ flag: UInt8, _ payload: [UInt8]) -> Data {
            var d = Data([flag])
            var n = UInt32(payload.count).bigEndian
            d.append(Data(bytes: &n, count: 4))
            d.append(contentsOf: payload)
            return d
        }
        override func startLoading() {
            let host = request.url?.host ?? ""
            var headers = ["content-type": "application/grpc-web+proto"]
            let ok = Self.frame(0x80, Array("grpc-status:0\r\n".utf8))
            let body: Data
            if host.hasPrefix("down.") {
                headers["grpc-status"] = "14"
                headers["grpc-message"] = "upstream%20connect%20error"
                body = Data()
            } else if host.hasPrefix("yes.") {
                body = Self.frame(0, [0x08, 0x01]) + ok
            } else if host.hasPrefix("no.") {
                body = Self.frame(0, [0x08, 0x00]) + ok
            } else if host.hasPrefix("ack.") {
                body = Self.frame(0, [0x0a, 0x00]) + ok
            } else {   // refuse.*: ErrorStatus { code: 3, message: "fee too low" }
                let status: [UInt8] = [0x08, 0x03, 0x12, 11] + Array("fee too low".utf8)
                body = Self.frame(0, [0x12, UInt8(status.count)] + status) + ok
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [NodeStub.self]
        return URLSession(configuration: c)
    }()
    private func client(_ hosts: String...) -> NockClient {
        NockClient(session: session, nodes: hosts.map { URL(string: $0)! })
    }
    /// Any valid digest works as a tx id here.
    private let txId = "BeZ1AGS1UCEnebHrHifcyuU9zGM5grQ77qKgQNTqm4nx9y7Fgnynhgw"

    /// Live: the official node answers from inside the app (so the ATS exception for its
    /// plain-HTTP address works), and the client as shipped gets an answer even where
    /// rpc.nockbox.org is failing. Run with TEST_RUNNER_NOCK_LIVE=1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOCK_LIVE"] != nil))
    func theNodesAnswerLive() async throws {
        let official = NockClient(nodes: [NockClient.nodes[1]])
        #expect(try await !official.blockTimes(downTo: .max, maxPages: 1).isEmpty)
        #expect(try await !NockClient().blockTimes(downTo: .max, maxPages: 1).isEmpty)
    }

    @Test func theOfficialNodeIsBuiltIn() {
        #expect(NockClient.nodes.map(\.absoluteString) == ["https://rpc.nockbox.org", "http://216.158.95.10:5556"])
    }

    @Test func aDownNodeFallsThroughAndIsBenched() async throws {
        let down = "https://down.a.nock.test", up = "http://ok.a.nock.test:5556"
        let c = client(down, up)
        let answeredBy = try await c.withNode { node, _ in
            _ = try await c.unary("x/y", Data(), node: node)
            return node.absoluteString
        }
        #expect(answeredBy == up)
        #expect(await BackendHealth.shared.order([down, up]) == [up, down])
    }

    @Test func aNodesOwnVerdictIsNotRetriedElsewhere() async {
        var asked: [String] = []
        await #expect(throws: NockClient.RPCError.self) {
            try await client("https://first.b.nock.test", "https://second.b.nock.test").withNode { node, _ -> Int in
                asked.append(node.host ?? "")
                throw NockClient.RPCError.status(3, "invalid")
            }
        }
        #expect(asked == ["first.b.nock.test"])
    }

    @Test func everyNodeDownIsAnError() async {
        await #expect(throws: NockClient.RPCError.self) {
            _ = try await client("https://down.c.nock.test", "https://down.d.nock.test").accepted(txId: txId)
        }
    }

    @Test func acceptedAsksEveryNode() async throws {
        #expect(try await client("https://down.e.nock.test", "https://yes.e.nock.test").accepted(txId: txId))
        // One node not having it yet isn't final while the other does.
        #expect(try await client("https://no.f.nock.test", "https://yes.f.nock.test").accepted(txId: txId))
        #expect(try await client("https://no.g.nock.test", "https://down.g.nock.test").accepted(txId: txId) == false)
    }

    @Test func aSendGoesThroughWhileOneNodeIsDown() async throws {
        try await client("https://down.h.nock.test", "http://ack.h.nock.test:5556").send(body: Data([1]))
    }

    @Test func aSendIsRefusedOnlyWhenEveryNodeRefuses() async {
        do {
            try await client("https://refuse.i.nock.test", "https://refuse.j.nock.test").send(body: Data([1]))
            Issue.record("expected a refusal")
        } catch {
            #expect(NockWalletStore.isRefusal(error))
        }
        // One refusal and one node unreachable: the tx may still be out there — not a refusal.
        do {
            try await client("https://refuse.k.nock.test", "https://down.k.nock.test").send(body: Data([1]))
            Issue.record("expected an open outcome")
        } catch {
            #expect(!NockWalletStore.isRefusal(error))
        }
    }
}
