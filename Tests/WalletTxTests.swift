import Foundation
import Testing
@testable import Pearl

/// Real mainnet transactions (blockbook.pearlresearch.ai, block 119565) so the codec is
/// checked against what the node actually relays, witness data included.
enum TxFixtures {
    static let oneInputHex = "01000000000101e81047d98fce07a8c0df863f715c8b0f15ccdc1a2912b8897be27bdf655c48f54301000000ffffffff0249fa8a00000000002251208a9f2483038b6a647b8ee934d97c1e8f5549687fead2e08cd49d9e73f51c231fdbc046110000000022512053e71242e7e00be65197831601854b375cf92ff1c730527ba0b26d28c193c50101408b7b26806770924a7b77b2d1b1f72c9036313e9ae3efa5104aa2a3decdc5af3dded0616ecc681e02d90acee67838b77962b520129d66f6e64403715c78aefe1400000000"
    static let oneInputTxid = "998578dbea941fbe90fbc5335c314300bf07af568230d0239f29127688ad4e3e"
    static let fiveInputsHex = "0100000000010514272b97a5245faf8f6e91a43e57588d8777555f175ba4193eab97ec2913004c0000000000ffffffff652d22280fe4f2f7bb13503f188f8664561eaa21a38244689474d257069adc1d0100000000ffffffffbd315c42438b4e55502b4d27982c86197f5c75b97735ef3aa6316e6caf3888360000000000ffffffffb1416bf7411834a9c19ef2a907b44db6a8493b08e7b29770ae217eb70a4779970000000000ffffffffc7e5ea644dd75246fb03728bf744544e032fb25f7ba1a84b8df165ff40cc18680000000000ffffffff02dbbb25b6010000002251205fd440f720848d93bfafeb05220eb7822a5201dfe9f79294335ad7e54886d7e4005039278c0400002252200e84d5d2f780cd4fd9524c31af9c94ba3b19b08f483102c11bd9b1bb49253a7a0140ff58d72a9d708422d05d88bd04cd5c919f4c165c55340498ae1ad7c2496e972b26c351af588996ce119b0a4fc2a469f8e68b61064f2857515b2c8d4763efd263014038ccd3db7c43f50962b23171dd6b00d8ea6b1b7a5f6e3a899535cc96f0ff2d38a37c4c56cbbd672404364129365cb5de6d3b637ac6f8941ccdf7b3c3059c3fa20140283f908814ddce3af3ada41201341790ee79b1ff6a018de095a4436698f9e7b9dd8b4fc586da6cc9c06b4d30780534c39c1f4a3e0eaa2309a387910cdcfec4aa0140308ba925bcc783fc579a36446aa6f53fff40a273d9f5c4646c2bb099d0e9d62f06d3f38cc1ea7463b63036b542253c63b80aa7f974d2ab1b22c1cde79f3d526a0140ae90be54b6a9dad02648c57ce16df2844c726740af0cad18ab46215f97d8fde6194b163c1f294fc70a5bed04e23ef8abc8cdf54dfa510f899a8a11a8a208887600000000"
    static let fiveInputsTxid = "5e7bdfb4f846b072f20772b3843ae6795f3a5abdd1ae3d34b03df4b40bc0ce0a"
    static let coinbaseHex = "020000000001010000000000000000000000000000000000000000000000000000000000000000ffffffff27030dd301042477b86a2f706f6f6c2e6b7279707465782e636f6d2fc1573e59bf12190cad424e79ffffffff0245c323a735000000225120e31e8032a67b9af27dc279f448c003457bae6c5d28de7ee719bc87b6801ede170000000000000000266a24aa21a9edd8983965f6b7bdb83b76607e99f84912169efae110ce0fbfd5ecc007bf0bdb970120000000000000000000000000000000000000000000000000000000000000000000000000"
    static let coinbaseTxid = "e9ea9774622ceb8464eb26b9ceb53e6b33ef9485a758844ff73eb76b33654b78"
}

struct WalletTxTests {
    @Test func txidOfSegwitSpend() throws {
        let tx = try #require(RawTx(hex: TxFixtures.oneInputHex))
        #expect(tx.txid == TxFixtures.oneInputTxid)
        #expect(tx.inputs == [.init(txid: "f5485c65df7be27b89b812291adccc150f8b5c713f86dfc0a807ce8fd94710e8", vout: 323)])
        #expect(tx.outputs == [9_108_041, 289_849_563])
        // Blockbook reports a 94 369 sat fee for this tx: input 299 051 973 − outputs.
        #expect(299_051_973 - tx.outputs.reduce(0, +) == 94_369)
    }

    @Test func txidAndOutpointsOfMultiInputSpend() throws {
        let tx = try #require(RawTx(hex: TxFixtures.fiveInputsHex))
        #expect(tx.txid == TxFixtures.fiveInputsTxid)
        #expect(tx.outpoints == [
            "4c001329ec97ab3e19a45b175f5577878d58573ea4916e8faf5f24a5972b2714:0",
            "1ddc9a0657d27494684482a321aa1e5664868f183f5013bbf7f2e40f28222d65:1",
            "368838af6c6e31a63aef3577b9755c7f19862c98274d2b50554e8b43425c31bd:0",
            "9779470ab77e21ae7097b2e7083b49a8b64db407a9f29ec1a9341841f76b41b1:0",
            "6818cc40ff65f18d4ba8a17b5fb22f034e5444f78b7203fb4652d74d64eae5c7:0",
        ])
        #expect(tx.outputs == [7_350_893_531, 5_000_000_000_000])
    }

    @Test func txidOfCoinbase() throws {
        let tx = try #require(RawTx(hex: TxFixtures.coinbaseHex))
        #expect(tx.txid == TxFixtures.coinbaseTxid)
        #expect(tx.outputs == [230_437_405_509, 0])
    }

    /// The same tx without its witness (legacy serialization) has the same txid.
    @Test func witnessStrippedSerializationKeepsTxid() throws {
        let hex = TxFixtures.oneInputHex
        // version | marker+flag | body (inputs+outputs) | witness | locktime
        let body = hex.dropFirst(12).prefix(hex.count - 12 - 8 - witnessHexLength(hex))
        let stripped = String(hex.prefix(8)) + body + String(hex.suffix(8))
        let tx = try #require(RawTx(hex: stripped))
        #expect(tx.txid == TxFixtures.oneInputTxid)
        #expect(tx.outputs == [9_108_041, 289_849_563])
    }

    @Test func rejectsTruncatedAndGarbledHex() {
        let hex = TxFixtures.fiveInputsHex
        for cut in stride(from: 2, to: hex.count, by: 38) {
            #expect(RawTx(hex: String(hex.prefix(cut))) == nil)
        }
        #expect(RawTx(hex: "") == nil)
        #expect(RawTx(hex: "zz" + hex.dropFirst(2)) == nil)
        #expect(RawTx(hex: String(hex.dropLast())) == nil)
        // A varint claiming far more inputs than the bytes that follow must not trap.
        #expect(RawTx(hex: "01000000" + "fe" + "ffffff7f" + "00") == nil)
        #expect(RawTx(hex: "01000000" + "ff" + "ffffffffffffffff") == nil)
    }

    @Test func outputValuesHelperMatchesCodec() {
        #expect(WalletStore.txOutputValues(TxFixtures.oneInputHex) == [9_108_041, 289_849_563])
        #expect(WalletStore.txOutputValues("0100") == [])
    }

    @Test func satoshiConversion() {
        #expect(RawTx.satoshis(from: Decimal(string: "1.5")!) == 150_000_000)
        #expect(RawTx.satoshis(from: Decimal(string: "0.00000001")!) == 1)
        #expect(RawTx.satoshis(from: Decimal(string: "0.000000001")!) == nil)
        #expect(RawTx.satoshis(from: 0) == nil)
        #expect(RawTx.prl(fromSat: 150_000_000) == Decimal(string: "1.5"))
    }

    @Test func feeEstimateClampsGarbage() {
        #expect(RawTx.estimateFeeSat(inputs: 1, outputs: 2, feePerKB: 1_000) == 156)
        // 58 097 vbytes × Int64.max sat/kB overflows Int64 — clamped, not trapped.
        #expect(RawTx.estimateFeeSat(inputs: 1_000, outputs: 2, feePerKB: .max) == .max - 1)
    }

    /// Hex length of the witness section of a one-input tx with a single 64-byte
    /// schnorr signature: item count (1) + length (1) + 64 bytes.
    private func witnessHexLength(_ hex: String) -> Int { (1 + 1 + 64) * 2 }
}

/// Send fee choice and the shortfall message (2026-10-20: the official node's 2-block
/// estimate was ~1 955 sat/vB while recent blocks were including 1–81 sat/vB txs).
struct WalletFeeTests {
    @Test func skewedFastEstimateIsCappedByRecentBlocks() {
        // The real numbers from 2026-10-20: fast 1 954 566, slow 1 708, block medians up to 81 441.
        let rate = BlockbookClient.chooseFeePerKB(fast: 1_954_566, slow: 1_708,
                                                  recentMedians: [1_004, 10_047, 81_441, 1_007])
        #expect(rate == 81_441)
    }

    @Test func realCongestionKeepsTheFastEstimate() {
        // Blocks themselves are paying more than the 2-block estimate → it isn't skewed.
        #expect(BlockbookClient.chooseFeePerKB(fast: 200_000, slow: 150_000, recentMedians: [250_000]) == 200_000)
        #expect(BlockbookClient.chooseFeePerKB(fast: 200_000, slow: 300_000, recentMedians: []) == 200_000)
    }

    @Test func quietNetworkStaysAtTheFloor() {
        #expect(BlockbookClient.chooseFeePerKB(fast: 1_000, slow: 1_000, recentMedians: [1_000, 1_002]) == 1_000)
        #expect(BlockbookClient.chooseFeePerKB(fast: 500, slow: nil, recentMedians: []) == BlockbookClient.minFeePerKB)
    }

    @Test func missingDataFallsBackStepByStep() {
        // No block stats or slow estimate → the fast estimate as before.
        #expect(BlockbookClient.chooseFeePerKB(fast: 1_954_566, slow: nil, recentMedians: []) == 1_954_566)
        // No fast estimate → the cap alone.
        #expect(BlockbookClient.chooseFeePerKB(fast: nil, slow: 3_000, recentMedians: [2_000]) == 3_000)
        // Nothing at all → the old 50 sat/vB default.
        #expect(BlockbookClient.chooseFeePerKB(fast: nil, slow: nil, recentMedians: []) == BlockbookClient.fallbackFeePerKB)
        // An absurd backend value stays bounded.
        #expect(BlockbookClient.chooseFeePerKB(fast: .max, slow: nil, recentMedians: []) == BlockbookClient.maxFeePerKB)
    }

    @Test func shortfallFeeIsReadFromOysterError() {
        // Captured from OysterMobile: 5 PRL input, 4.999 PRL payment at 1 954 566 sat/kB.
        let m = "insufficient funds: have 500000000, need 500118911"
        #expect(WalletStore.shortfallFeeSat(m, amountSat: 499_900_000) == 218_911)
        #expect(WalletStore.shortfallFeeSat("the passed output does not belong to the wallet", amountSat: 1) == nil)
        #expect(WalletStore.shortfallFeeSat("insufficient funds", amountSat: 1) == nil)
    }
}

/// Two indexers (own + official): how their broadcast answers combine, and the read order.
struct WalletBackendTests {
    private typealias E = BlockbookClient.BroadcastError
    private func outcome(_ results: [Result<String, E>]) -> String {
        do { return "sent \(try BlockbookClient.combine(results))" } catch let e as E {
            switch e { case .rejected(let m): return "rejected \(m)"; case .transport: return "unknown"; case .notDelivered: return "not sent" }
        } catch { return "?" }
    }

    @Test func acceptedByEitherNodeIsSent() {
        #expect(outcome([.failure(.transport("timeout")), .success("ab")]) == "sent ab")
        #expect(outcome([.success("ab"), .failure(.rejected("-26: mempool min fee not met"))]) == "sent ab")
    }

    @Test func onlyAUnanimousRefusalIsAVerdict() {
        #expect(outcome([.failure(.rejected("-26: x")), .failure(.rejected("-25: y"))]) == "rejected -26: x")
        #expect(outcome([.failure(.rejected("-26: x"))]) == "rejected -26: x")
        // One node refused, the other didn't answer: it may have relayed it.
        #expect(outcome([.failure(.rejected("-26: x")), .failure(.transport("timeout"))]) == "unknown")
        // A gateway's complaint is not a node's verdict.
        #expect(outcome([.failure(.rejected("node unhealthy")), .failure(.rejected("-26: x"))]) == "unknown")
    }

    @Test func aRequestNoNodeSawLeavesTheVerdictToTheOthers() {
        // Our gateway refused the old app key; the official node's refusal stands.
        #expect(outcome([.failure(.notDelivered("unauthorized (HTTP 401)")), .failure(.rejected("-26: x"))]) == "rejected -26: x")
        #expect(outcome([.failure(.notDelivered("rate limited (HTTP 429)")), .success("ab")]) == "sent ab")
        // The other may have relayed it.
        #expect(outcome([.failure(.notDelivered("HTTP 401")), .failure(.transport("timeout"))]) == "unknown")
        // No node saw it at all: certainly not sent.
        do { _ = try BlockbookClient.combine([.failure(.notDelivered("HTTP 401")), .failure(.notDelivered("HTTP 429"))]); Issue.record("no throw") }
        catch BlockbookClient.BroadcastError.notDelivered {} catch { Issue.record("\(error)") }
    }

    @Test func aNodeHavingTheTxEndsTheWait() {
        #expect(BlockbookClient.wentOut(.success("ab")))
        #expect(BlockbookClient.wentOut(.failure(.rejected("-26: txn-already-known"))))
        #expect(!BlockbookClient.wentOut(.failure(.rejected("-26: mempool min fee not met"))))
        #expect(!BlockbookClient.wentOut(.failure(.transport("timeout"))))
    }

    @Test func onlyTroubleBenchesAnIndexer() {
        #expect(BlockbookClient.benchTime(URLError(.timedOut)) == nil)   // a slow query
        #expect(BlockbookClient.benchTime(URLError(.cannotConnectToHost)) == BackendHealth.bench)
        #expect(BlockbookClient.benchTime(BlockbookClient.httpStatusError(503)) == BackendHealth.bench)
        #expect(BlockbookClient.benchTime(BlockbookClient.httpStatusError(429)) == BackendHealth.bench)
        #expect(BlockbookClient.benchTime(BlockbookClient.httpStatusError(401)) == BackendHealth.keyRefusedBench)
        #expect(BlockbookClient.benchTime(BlockbookClient.httpStatusError(400)) == nil)
        #expect(BlockbookClient.benchTime(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: ""))) == nil)
    }

    @Test func aPinnedRefreshReadsOneIndex() {
        let c = BlockbookClient(bases: ["https://a.test", "https://b.test"])
        #expect(c.pinned(to: "https://b.test", strict: true).bases == ["https://b.test"])
        #expect(c.pinned(to: "https://b.test", strict: false).bases == ["https://b.test", "https://a.test"])
        // Broadcasts and lookups still go everywhere.
        #expect(c.pinned(to: "https://b.test", strict: true).allBases == ["https://a.test", "https://b.test"])
        #expect(c.pinned(to: nil, strict: true).bases == c.bases)
        #expect(c.pinned(to: "https://elsewhere.test", strict: true).bases == c.bases)
    }

    @Test func alreadyKnownAnywhereMeansItWentOut() {
        #expect(outcome([.failure(.rejected("-26: x")), .failure(.rejected("-27: transaction already exists"))])
                == "rejected -27: transaction already exists")
    }

    @Test func mainnetPrefersOwnIndexerTestnetOnlyOfficial() {
        // A build without the app key (the public repo) never tries our own indexer.
        #expect(BlockbookClient(network: .mainnet).bases == (NodeAccess.enabled
            ? [BlockbookClient.ownMainnet, BlockbookClient.officialMainnet] : [BlockbookClient.officialMainnet]))
        #expect(BlockbookClient(network: .testnet).bases == [BlockbookClient.officialTestnet])
    }

    @Test func onlyOurIndexerGetsTheAppKey() {
        var own = URLRequest(url: URL(string: BlockbookClient.ownMainnet + "/api/v2/")!)
        BlockbookClient.authorize(&own)
        #expect(own.value(forHTTPHeaderField: NodeAccess.header) == NodeAccess.key)
        var official = URLRequest(url: URL(string: BlockbookClient.officialMainnet + "/api/v2/")!)
        BlockbookClient.authorize(&official)
        #expect(official.value(forHTTPHeaderField: NodeAccess.header) == nil)
        // A look-alike host must not get it either.
        var lookalike = URLRequest(url: URL(string: "https://node.pearlhub.net.evil.example/api/v2/")!)
        BlockbookClient.authorize(&lookalike)
        #expect(lookalike.value(forHTTPHeaderField: NodeAccess.header) == nil)
    }

    @Test func aFailedIndexerMovesToTheBack() async {
        let health = BackendHealth()
        #expect(await health.order(["a", "b"]) == ["a", "b"])
        await health.failed("a")
        #expect(await health.order(["a", "b"]) == ["b", "a"])
        await health.failed("b", for: -1)   // already over
        #expect(await health.order(["a", "b"]) == ["b", "a"])
    }

    @Test func concurrentFeeAsksShareOneEstimateAndOnlyCompleteOnesStay() async {
        let cache = FeeRateCache()
        final class Count: @unchecked Sendable { var n = 0; let lock = NSLock()
            func bump() { lock.lock(); n += 1; lock.unlock() } }
        let count = Count()
        let compute: @Sendable () async -> (rate: Int64, keep: Bool) = {
            count.bump(); try? await Task.sleep(for: .milliseconds(200)); return (81_000, true)
        }
        async let a = cache.rate(for: "k", compute: compute)
        async let b = cache.rate(for: "k", compute: compute)
        #expect(await [a, b] == [81_000, 81_000])
        #expect(count.n == 1)
        #expect(await cache.rate(for: "k", compute: compute) == 81_000 && count.n == 1)   // cached
        // The fallback rate (nothing learned) is used but not kept.
        #expect(await cache.rate(for: "f") { (BlockbookClient.fallbackFeePerKB, false) } == BlockbookClient.fallbackFeePerKB)
        #expect(await cache.rate(for: "f") { (2_000, true) } == 2_000)
        #expect(BlockbookClient.feeDataComplete(fast: 1, slow: nil, recentMedians: [5]))
        #expect(!BlockbookClient.feeDataComplete(fast: 1, slow: nil, recentMedians: []))
        #expect(!BlockbookClient.feeDataComplete(fast: nil, slow: 1, recentMedians: [5]))
    }
}

/// Reads through `BlockbookClient.get` (wallet, network chart, pool chain income): the next
/// indexer answers when the first is down or sends something unreadable.
struct BlockbookFallbackTests {
    /// Answers by host: down.* → 503 (the gateway while our index lags), junk.* → 200 with a
    /// body that isn't the expected JSON, anything else → a Blockbook status.
    final class HostStub: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".fallback.test") == true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let host = request.url?.host ?? ""
            let (status, body): (Int, String) = host.hasPrefix("down.") ? (503, #"{"error":"node unhealthy"}"#)
                : host.hasPrefix("junk.") ? (200, "<html>maintenance</html>")
                : (200, #"{"blockbook":{"bestHeight":\#(host.hasPrefix("own.") ? 130651 : 130650)}}"#)
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private struct Status: Decodable { struct BB: Decodable { let bestHeight: Int }; let blockbook: BB }
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [HostStub.self]
        return URLSession(configuration: c)
    }()
    private func tip(_ bases: [String]) async throws -> Int {
        try await BlockbookClient(bases: bases).get("/api/v2/", session: session) {
            try JSONDecoder().decode(Status.self, from: $0).blockbook.bestHeight
        }
    }

    @Test func firstChoiceAnswersWhenUp() async throws {
        #expect(try await tip(["https://own.a.fallback.test", "https://official.a.fallback.test"]) == 130651)
    }

    @Test func aLaggingOwnIndexFallsBackAndIsBenched() async throws {
        let down = "https://down.b.fallback.test", up = "https://official.b.fallback.test"
        #expect(try await tip([down, up]) == 130650)
        // The 503 benches it: the next reads go to the official one first.
        #expect(await BackendHealth.shared.order([down, up]) == [up, down])
    }

    @Test func anUnreadableAnswerFallsBackButIsNotBenched() async throws {
        let junk = "https://junk.c.fallback.test", up = "https://official.c.fallback.test"
        #expect(try await tip([junk, up]) == 130650)
        #expect(await BackendHealth.shared.order([junk, up]) == [junk, up])
    }

    @Test func aParseRejectionFallsBackButIsNotBenched() async throws {
        // The chart and chain income throw their own errors (even URLError) for a body they
        // can't use; the indexer still answered, so it must stay first in line.
        let picky = "https://own.f.fallback.test", up = "https://official.f.fallback.test"
        let tip = try await BlockbookClient(bases: [picky, up]).get("/api/v2/", session: session) { d -> Int in
            let t = try JSONDecoder().decode(Status.self, from: d).blockbook.bestHeight
            if t == 130651 { throw URLError(.cannotParseResponse) }
            return t
        }
        #expect(tip == 130650)
        #expect(await BackendHealth.shared.order([picky, up]) == [picky, up])
    }

    @Test func allDownIsAnError() async {
        await #expect(throws: (any Error).self) {
            try await tip(["https://down.d.fallback.test", "https://down.e.fallback.test"])
        }
    }
}

/// 交易详情 / 交易查询: reading Blockbook's tx JSON, and which indexer's copy is shown.
struct TxDetailTests {
    /// Trimmed from node.pearlhub.net's /api/v2/tx/ for block 119565's tx (2026-10-20).
    static let spendJSON = #"""
    {"txid":"998578dbea941fbe90fbc5335c314300bf07af568230d0239f29127688ad4e3e","version":1,
     "vin":[{"txid":"f5485c65df7be27b89b812291adccc150f8b5c713f86dfc0a807ce8fd94710e8","vout":323,"n":0,
             "addresses":["prl1pv3put8fvt4z5uq54sj9lt6vk40ya3c60sph75gwjl3qxyfsk06ysl8yyve"],"isAddress":true,"value":"299051973"}],
     "vout":[{"value":"9108041","n":0,"hex":"51208a9f","addresses":["prl1p320jfqcr3d4xg7uway6djlq73a25j6rlatfwprx5nk088aguyv0sw5at54"],"isAddress":true},
             {"value":"289849563","n":1,"hex":"512053e7","addresses":["prl1p20n3ysh8uq97v5vhsvtqrp2txaw0jtl3cuc9y7aqkfkj3svnc5qs6gu3u3"],"isAddress":true}],
     "blockHash":"1d3b6ebcd854ee2a3ddcb33168a9d9f65a4a75570753ea9a386131c548856c84","blockHeight":119565,
     "confirmations":11094,"blockTime":1790474020,"size":205,"vsize":154,
     "value":"298957604","valueIn":"299051973","fees":"94369","hex":"\#(TxFixtures.oneInputHex)"}
    """#
    /// Block 130600's coinbase: a payout plus the OP_RETURN witness commitment.
    static let coinbaseJSON = #"""
    {"txid":"c30dee257593b1acc114d82090902fa60ef9f5270f7b04d2e24f3e3ef4adf43c","version":2,
     "vin":[{"sequence":4294967295,"n":0,"isAddress":false,"coinbase":"0328fe01"}],
     "vout":[{"value":"223962677061","n":0,"hex":"5120e31e","addresses":["prl1puv0gqv4x0wd0ylwz086y3sqrg4a6umza9r08aecehjrmdqq7mctsmqaqsh"],"isAddress":true},
             {"value":"0","n":1,"hex":"6a24aa21a9ed","addresses":[],"isAddress":false}],
     "blockHeight":130600,"confirmations":59,"blockTime":1792474569,"value":"223962677061","valueIn":"0","fees":"0"}
    """#
    static let mempoolJSON = #"""
    {"txid":"998578dbea941fbe90fbc5335c314300bf07af568230d0239f29127688ad4e3e","vin":[],"vout":[],
     "blockHeight":-1,"confirmations":0,"blockTime":1792480000,"value":"0","fees":"94369"}
    """#
    private static let spendTxid = "998578dbea941fbe90fbc5335c314300bf07af568230d0239f29127688ad4e3e"
    private static let sender = "prl1pv3put8fvt4z5uq54sj9lt6vk40ya3c60sph75gwjl3qxyfsk06ysl8yyve"
    private static let change = "prl1p20n3ysh8uq97v5vhsvtqrp2txaw0jtl3cuc9y7aqkfkj3svnc5qs6gu3u3"

    private func spend() throws -> TxDetail {
        try #require(TxDetail.parse(Data(Self.spendJSON.utf8), txid: Self.spendTxid))
    }

    @Test func txidFromInputOrExplorerLink() {
        let id = Self.spendTxid
        #expect(TxDetail.parseTxid(id) == id)
        #expect(TxDetail.parseTxid("  \(id.uppercased())\n") == id)
        #expect(TxDetail.parseTxid("https://blockbook.pearlresearch.ai/tx/\(id)") == id)
        #expect(TxDetail.parseTxid("https://blockbook.pearlresearch.ai/tx/\(id)?x=1") == id)
        #expect(TxDetail.parseTxid(String(id.dropLast())) == nil)
        #expect(TxDetail.parseTxid(id + "0") == nil)
        #expect(TxDetail.parseTxid("https://example.com/tx/\(id)ff") == nil)
        #expect(TxDetail.parseTxid(String(repeating: "g", count: 64)) == nil)
        // Fullwidth digits are hex digits to Character.isHexDigit; not to a txid.
        #expect(TxDetail.parseTxid(String(repeating: "１", count: 64)) == nil)
    }

    @Test func readsASpend() throws {
        let tx = try spend()
        #expect(tx.confirmations == 11094 && tx.confirmed && tx.height == 119565)
        #expect(tx.time == Date(timeIntervalSince1970: 1790474020))
        #expect(tx.valueSat == 298_957_604 && tx.feeSat == 94_369 && !tx.coinbase)
        #expect(tx.inputs == [.init(address: Self.sender, sat: 299_051_973, isData: false)])
        #expect(tx.outputs.map(\.sat) == [9_108_041, 289_849_563])
        // The signed hex is this very tx, so 重新广播 may send it.
        #expect(RawTx(hex: try #require(tx.hex))?.txid == tx.txid)
    }

    @Test func readsACoinbase() throws {
        let id = "c30dee257593b1acc114d82090902fa60ef9f5270f7b04d2e24f3e3ef4adf43c"
        let tx = try #require(TxDetail.parse(Data(Self.coinbaseJSON.utf8), txid: id))
        #expect(tx.coinbase && tx.inputs.isEmpty && tx.hex == nil)
        #expect(tx.outputs[1] == .init(address: nil, sat: 0, isData: true))
    }

    @Test func aMempoolTxHasNoBlock() throws {
        let tx = try #require(TxDetail.parse(Data(Self.mempoolJSON.utf8), txid: Self.spendTxid))
        #expect(!tx.confirmed && tx.height == nil && tx.time != nil)
    }

    @Test func anotherTxidOrGarbageIsNoAnswer() {
        #expect(TxDetail.parse(Data(Self.spendJSON.utf8), txid: String(repeating: "0", count: 64)) == nil)
        #expect(TxDetail.parse(Data("<html>".utf8), txid: Self.spendTxid) == nil)
    }

    @Test func ownRowsFirstAndTheNet() throws {
        let tx = try spend()
        let own: Set = [Self.sender, Self.change]
        #expect(TxDetail.ownFirst(tx.outputs, own: own).map(\.address) == [Self.change, tx.outputs[0].address])
        // Paid 299 051 973 in, got 289 849 563 change back: −(payment + fee).
        #expect(tx.net(for: own) == 289_849_563 - 299_051_973)
        #expect(tx.net(for: ["prl1someoneelse"]) == nil)
    }

    @Test func theCopyFurthestAlongWinsTiesGoToOurs() throws {
        let mined = try spend()
        let pending = try #require(TxDetail.parse(Data(Self.mempoolJSON.utf8), txid: Self.spendTxid))
        typealias C = BlockbookClient.TxCopy
        // 2026-10-20: the official indexer kept a mined tx at 0 confirmations.
        #expect(BlockbookClient.outcome([C.found(pending), C.found(mined)]) == .found(mined))
        #expect(BlockbookClient.outcome([C.unknown, C.found(pending)]) == .found(pending))
        // One saying "not found" while the other is down (ours 503s while it catches up).
        #expect(BlockbookClient.outcome([C.unknown, C.missing]) == .notFound)
        #expect(BlockbookClient.outcome([C.unknown, C.unknown]) == .failed)
        let other = TxDetail(txid: mined.txid, confirmations: mined.confirmations, height: 1, time: nil, valueSat: 0,
                             feeSat: 0, coinbase: false, inputs: [], outputs: [], hex: nil)
        #expect(TxDetail.best([mined, other]) == mined)
    }
}

/// Broadcast through stubbed indexers: who answers first, and what a refusal before any node means.
struct BroadcastStubTests {
    /// By host: slow.* accepts after 3 s, ok.* accepts at once, key.* is our gateway refusing
    /// the app key, nope.* is a node's verdict.
    final class SendStub: URLProtocol, @unchecked Sendable {
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".send.test") == true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        private var cancelled = false
        override func startLoading() {
            let host = request.url?.host ?? ""
            let txid = String(repeating: "ab", count: 32)
            let (delay, status, body): (Double, Int, String) =
                host.hasPrefix("slow.") ? (3, 200, #"{"result":"\#(txid)"}"#)
                : host.hasPrefix("ok.") ? (0, 200, #"{"result":"\#(txid)"}"#)
                : host.hasPrefix("key.") ? (0, 401, #"{"error":"unauthorized"}"#)
                : (0, 400, #"{"error":"-26: mempool min fee not met"}"#)
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                guard !cancelled else { return }
                let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() { cancelled = true }
    }
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [SendStub.self]
        return URLSession(configuration: c)
    }()

    @Test func theFirstAcceptanceIsTheAnswer() async throws {
        let start = Date()
        let txid = try await BlockbookClient(bases: ["https://slow.a.send.test", "https://ok.a.send.test"], session: session).broadcast("00")
        #expect(txid == String(repeating: "ab", count: 32))
        // Not held up by the slow one (3 s).
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func aRefusedKeyDoesNotHideTheOtherNodesVerdict() async {
        do {
            _ = try await BlockbookClient(bases: ["https://key.b.send.test", "https://nope.b.send.test"], session: session).broadcast("00")
            Issue.record("expected a refusal")
        } catch BlockbookClient.BroadcastError.rejected(let m) {
            #expect(m.hasPrefix("-26:"))
        } catch { Issue.record("\(error)") }
    }
}
