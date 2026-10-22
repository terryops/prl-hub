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
