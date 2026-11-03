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

    /// MAX before the recipient is filled in: the quote is built to a stand-in address, never the
    /// wallet's own (the core refuses a sweep to the sending address), and quotes the same as a real one.
    @Test func maxQuoteRecipient() throws {
        let fx = try JSONSerialization.jsonObject(with: try Fixture.data("nock_notes.json")) as? [String: Any] ?? [:]
        let own = try #require(fx["address"] as? String)
        let other = "AyzPiJoqcqmdZdjxZ9aGLnVsbYcCphidHERKBWVXyKhNqTirshTmicG"
        #expect(NockWalletStore.quoteRecipient(for: "", own: own) == NockWalletStore.quoteAddress)
        #expect(NockWalletStore.quoteRecipient(for: "nope", own: own) == NockWalletStore.quoteAddress)
        #expect(NockWalletStore.quoteRecipient(for: own, own: own) == NockWalletStore.quoteAddress)
        #expect(NockWalletStore.quoteRecipient(for: " \(other)\n", own: own) == other)
        #expect(NockCore.isValidAddress(NockWalletStore.quoteAddress) && NockWalletStore.quoteAddress != own)
        func sweep(_ to: String) throws -> [String: Any] {
            try NockCore.call("buildSend", ["mnemonic": fx["mnemonic"] as Any, "notes": fx["notes"] as Any,
                                            "recipient": to, "height": fx["height"] as Any, "sweep": true])
        }
        // What MAX used to quote against when the field was empty: "unbalanced transaction".
        #expect(throws: NockCore.Failure.self) { try sweep(own) }
        let quote = try sweep(NockWalletStore.quoteAddress), real = try sweep(other)
        #expect(quote["fee"] as? String == real["fee"] as? String)
        #expect(quote["amount"] as? String == real["amount"] as? String)
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

    /// NOCK is off unless switched on — except, on the first run of the opt-in build, where a
    /// wallet already uses it (so nobody loses sight of NOCK they hold).
    @Test func nockIsOptInButStaysOnWhereItsUsed() throws {
        func fresh() -> UserDefaults {
            let name = "nock-optin-\(UUID().uuidString)"
            let d = UserDefaults(suiteName: name)!
            d.removePersistentDomain(forName: name)
            return d
        }
        // New install: off, and that's remembered.
        let a = fresh()
        #expect(!NockWalletStore.initialEnabled(a))
        #expect(a.object(forKey: NockWalletStore.enabledKey) as? Bool == false)

        // Updating with a wallet that never touched NOCK (its state only cached an address): off.
        let b = fresh()
        var idle = NockWalletStore.State()
        idle.address = "a"
        b.set(try JSONEncoder().encode(idle), forKey: "nock.state.w1")
        b.set(true, forKey: "nock.linkHidden")
        #expect(!NockWalletStore.initialEnabled(b))
        #expect(b.object(forKey: "nock.linkHidden") == nil)

        // Updating with a wallet that has NOCK history: on.
        let c = fresh()
        var used = NockWalletStore.State()
        used.addressShown = true
        c.set(try JSONEncoder().encode(idle), forKey: "nock.state.w1")
        c.set(try JSONEncoder().encode(used), forKey: "nock.state.w2")
        #expect(NockWalletStore.initialEnabled(c))

        // Once set, the choice wins over what the wallets hold.
        c.set(false, forKey: NockWalletStore.enabledKey)
        #expect(!NockWalletStore.initialEnabled(c))
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

/// History from nockscan: what this device never saw (another device's sends, coins spent
/// before this install) shows up, and what it did see isn't counted twice.
struct NockScanHistoryTests {
    private let t0 = Date(timeIntervalSince1970: 1_792_577_061)

    private func entry(_ id: String, _ kind: NockScan.Entry.Kind, height: UInt64, amount: UInt64, fee: UInt64 = 0,
                       to: [String] = []) -> NockScan.Entry {
        NockScan.Entry(txId: id, kind: kind, height: height, time: t0, amount: amount, fee: fee, counterparties: to)
    }
    private func noteRow(_ name: String, _ kind: NockTx.Kind = .received, height: UInt64, amount: UInt64) -> NockTx {
        NockTx(id: "note:\(name)", kind: kind, amount: amount, fee: nil, counterparty: nil, txId: nil, height: height,
               time: t0.addingTimeInterval(-600), timeExact: false, status: .confirmed)
    }
    private func sendRow(_ id: String, amount: UInt64, fee: UInt64?, status: NockTx.Status, height: UInt64? = nil) -> NockTx {
        NockTx(id: id, kind: .sent, amount: amount, fee: fee, counterparty: "r", txId: id, height: height,
               time: t0.addingTimeInterval(-60), timeExact: true, status: status)
    }
    private func note(_ id: String, kind: String, height: UInt64) -> NockNote {
        NockNote(json: ["nameFirst": id, "nameLast": "x", "assets": "1", "raw": "", "originPage": height,
                        "kind": kind, "unlockHeight": 0, "spendable": true])!
    }

    /// The reply for 9mhAX…QV2 on 2026-10-22 (50 NOCK in, all of it back out), plus a mining reward.
    @Test func parsesTheAddressReply() throws {
        let json = #"""
        {"address":"9mhAX","ownerType":"pkh","totalTransactions":3,"currentBalance":0,
         "transactions":[
          {"txId":"AHHTf","blockHeight":169049,"timestamp":1792577748,"type":"sent","amount":3276800,"fee":258048,
           "counterparties":["2ToQh"],"isCoinbase":false},
          {"txId":"9pDtL","blockHeight":169044,"timestamp":1792577061,"type":"received","amount":3276800,"fee":0,
           "counterparties":["2ToQh"],"isCoinbase":false},
          {"txId":"coinbase-8x","blockHeight":169000,"timestamp":1792570000,"type":"received","amount":107374183,
           "fee":0,"counterparties":[],"isCoinbase":true},
          {"txId":"odd","blockHeight":1,"timestamp":1,"type":"burned","amount":1}],
         "pagination":{"limit":50,"offset":0,"hasMore":true}}
        """#
        let page = try NockScan.parse(Data(json.utf8))
        #expect(page.hasMore)
        #expect(page.entries.map(\.kind) == [.sent, .received, .mined])
        #expect(page.entries[0] == NockScan.Entry(txId: "AHHTf", kind: .sent, height: 169_049,
                                                  time: Date(timeIntervalSince1970: 1_792_577_748),
                                                  amount: 3_276_800, fee: 258_048, counterparties: ["2ToQh"]))
        #expect(throws: (any Error).self) { try NockScan.parse(Data("{}".utf8)) }
    }

    /// A device that never saw the address: both rows appear; a send shows what the recipient got.
    @Test func aNewDeviceGetsTheWholeHistory() {
        let rows = NockWalletStore.merge([], scan: [
            entry("AHHTf", .sent, height: 169_049, amount: 3_276_800, fee: 258_048, to: ["2ToQh"]),
            entry("9pDtL", .received, height: 169_044, amount: 3_276_800, to: ["2ToQh"]),
        ])
        #expect(rows.count == 2)
        let sent = rows.first { $0.kind == .sent }
        #expect(sent?.amount == 3_276_800 - 258_048 && sent?.fee == 258_048 && sent?.counterparty == "2ToQh")
        #expect(sent?.status == .confirmed && sent?.timeExact == true && sent?.height == 169_049)
        let got = rows.first { $0.kind == .received }
        #expect(got?.txId == "9pDtL" && got?.amount == 3_276_800 && got?.counterparty == nil)
    }

    /// A note this device recorded becomes the transaction that brought it — one row, not two.
    @Test func aRecordedNoteBecomesItsTransaction() {
        let rows = NockWalletStore.merge([noteRow("n1", height: 100, amount: 500)],
                                         scan: [entry("T1", .received, height: 100, amount: 500)])
        #expect(rows.map(\.id) == ["T1"])
        #expect(rows[0].timeExact && rows[0].time == t0)
        // Two notes from one payment collapse into it too.
        let two = NockWalletStore.merge([noteRow("a", height: 100, amount: 200), noteRow("b", height: 100, amount: 300)],
                                        scan: [entry("T1", .received, height: 100, amount: 500)])
        #expect(two.map(\.id) == ["T1"])
    }

    /// Amounts that don't add up: keep this device's rows, don't risk counting the coins twice.
    @Test func unmatchedNotesStay() {
        let rows = NockWalletStore.merge([noteRow("n1", height: 100, amount: 400)],
                                         scan: [entry("T1", .received, height: 100, amount: 500)])
        #expect(rows.map(\.id) == ["note:n1"])
    }

    /// This device's own send keeps its recipient amount; nockscan adds the block.
    @Test func ownSendKeepsItsAmount() {
        let rows = NockWalletStore.merge([sendRow("S1", amount: 1_000, fee: nil, status: .confirmed)],
                                         scan: [entry("S1", .sent, height: 120, amount: 1_100, fee: 100)])
        #expect(rows.count == 1)
        #expect(rows[0].amount == 1_000 && rows[0].fee == 100 && rows[0].height == 120 && rows[0].time == t0)
        // Still pending here: settling it is reconcileSends' job, not the merge's.
        let pending = NockWalletStore.merge([sendRow("S2", amount: 1_000, fee: 100, status: .pending)],
                                            scan: [entry("S2", .sent, height: 121, amount: 1_100, fee: 100)])
        #expect(pending[0].status == .pending && pending[0].height == nil)
    }

    /// Change of a send made on another device arrived here as a "received" note: it goes.
    @Test func changeOfAnotherDevicesSendIsNotIncome() {
        let rows = NockWalletStore.merge([noteRow("change", height: 130, amount: 9_000)],
                                         scan: [entry("S9", .sent, height: 130, amount: 1_100, fee: 100)])
        #expect(rows.map(\.id) == ["S9"])
    }

    /// Mining rewards match their own notes, and their "coinbase-…" id isn't offered as a txid.
    @Test func miningRewards() {
        let rows = NockWalletStore.merge([noteRow("cb", .mined, height: 140, amount: 7)],
                                         scan: [entry("coinbase-Q", .mined, height: 140, amount: 7)])
        #expect(rows.count == 1 && rows[0].id == "coinbase-Q" && rows[0].kind == .mined && rows[0].txId == nil)
    }

    /// Running it again changes nothing.
    @Test func mergingTwiceIsTheSame() {
        let scan = [entry("T1", .received, height: 100, amount: 500), entry("S9", .sent, height: 130, amount: 1_100, fee: 100)]
        let once = NockWalletStore.merge([noteRow("n1", height: 100, amount: 500)], scan: scan)
        #expect(NockWalletStore.merge(once, scan: scan) == once)
    }

    /// A note arriving after nockscan already listed its transaction doesn't add a second row.
    @Test func aNoteNockscanAlreadyListedAddsNoRow() {
        let history = NockWalletStore.merge([], scan: [entry("T1", .received, height: 100, amount: 500),
                                                       entry("S9", .sent, height: 130, amount: 1_100, fee: 100)])
        #expect(NockWalletStore.scanCovers(note("a", kind: "simple", height: 100), in: history))
        #expect(NockWalletStore.scanCovers(note("chg", kind: "simple", height: 130), in: history))   // that send's change
        #expect(!NockWalletStore.scanCovers(note("b", kind: "simple", height: 101), in: history))
        #expect(!NockWalletStore.scanCovers(note("cb", kind: "coinbase", height: 100), in: history))
    }

    /// The live reply for the address in the 2026-10-22 report (run with NOCK_LIVE=1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NOCK_LIVE"] != nil))
    func liveAddressHistory() async throws {
        let page = try await NockScan().page(address: "9mhAXQk6Bt2NwHY5p4XZHGyus28swdGRjsuAqCewrvbVmdBzQVtoQV2",
                                             limit: NockScan.pageSize, offset: 0)
        #expect(page.entries.map(\.txId).contains("AHHTfSRDWE2k6DBUJL1BWwntYiMbXFQpQordooYjLFWZwVvV5JfvodK"))
        let none = try await NockScan().page(address: NockWalletStore.quoteAddress, limit: 10, offset: 0)
        #expect(none.entries.isEmpty && !none.hasMore)
    }
}
