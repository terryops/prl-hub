import Foundation
import Testing
@testable import Pearl

struct HashrateFormatTests {
    @Test func formatsOneWayForAppAndWidget() {
        #expect(formatHashrate(270.123e12) == "270.12 TH/s")
        #expect(formatHashrate(1.5e18) == "1.50 EH/s")
        #expect(formatHashrate(52_000) == "52.00 kH/s")
        #expect(formatHashrate(0) == "0 H/s")
    }

    @Test func parsesWhatEitherSideWrites() {
        #expect(parseHashrate("240.30 TH/s") == 240.30e12)
        #expect(parseHashrate("1,234.56 TH/s") == 1234.56e12)
        #expect(parseHashrate("52 KH/s") == 52e3)     // the old widget spelling
        #expect(parseHashrate("52 kH/s") == 52e3)
        #expect(parseHashrate("7") == 7)
        #expect(parseHashrate("—") == 0)
        #expect(close(parseHashrate(formatHashrate(123.45e15)), 123.45e15))
    }

    @Test func flexDoubleReadsGroupedStrings() throws {
        struct Box: Decodable { let a: FlexDouble; let b: FlexDouble; let c: FlexDouble; let d: FlexDouble }
        let box = try JSONDecoder().decode(Box.self, from: Data(#"{"a":"1,234.5","b":2,"c":null,"d":{"x":1}}"#.utf8))
        #expect(box.a.value == 1234.5)
        #expect(box.b.value == 2)
        #expect(box.c.value == 0)
        #expect(box.d.value == 0)
    }
}

/// Retry policy + HTTP status semantics, over a stubbed URLSession.shared. Serialized: the stub
/// registry is global.
@Suite(.serialized)
struct PoolRequestTests {
    init() {
        URLProtocol.registerClass(StubURLProtocol.self)
        StubURLProtocol.reset()
    }

    private let alpha = "pearl.alphapool.tech/api/miner/prl1pk4y24f9qm3pvuzus8qncgpfyuxv79f2xwtfhdmmyfu5k5emurg0shvwtrz"
    private let alphaAddr = "prl1pk4y24f9qm3pvuzus8qncgpfyuxv79f2xwtfhdmmyfu5k5emurg0shvwtrz"

    @Test func transientClassification() {
        #expect(PoolHTTP.isTransient(PoolHTTPError.status(503)))
        #expect(PoolHTTP.isTransient(PoolHTTPError.status(429)))
        #expect(PoolHTTP.isTransient(URLError(.timedOut)))
        #expect(PoolHTTP.isTransient(URLError(.networkConnectionLost)))
        #expect(!PoolHTTP.isTransient(PoolHTTPError.status(400)))
        #expect(!PoolHTTP.isTransient(PoolHTTPError.status(404)))
        #expect(!PoolHTTP.isTransient(URLError(.cancelled)))
        #expect(!PoolHTTP.isTransient(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: ""))))
    }

    /// A 400 is AlphaPool's definitive "can't parse that address" — asked once, not 15 times.
    @Test func definitiveFailureIsNotRetried() async {
        StubURLProtocol.stub(alpha, [.init(status: 400, body: Data())])
        let d = await fetchWatchData(PoolWatch(pool: .alphaPool, address: alphaAddr))
        #expect(StubURLProtocol.hits(alpha) == 1)
        #expect(d?.found == false)
        #expect(d?.error != nil)
    }

    @Test func transientFailureIsRetriedThenSucceeds() async throws {
        let idle = try Fixture.data("alphapool_miner_idle.json")
        StubURLProtocol.stub(alpha, [.init(status: 503, body: Data()), .init(status: 502, body: Data()),
                                     .init(status: 200, body: idle)])
        let d = await fetchWatchData(PoolWatch(pool: .alphaPool, address: alphaAddr))
        #expect(StubURLProtocol.hits(alpha) == 3)
        #expect(d?.found == true)
        #expect(d?.error == nil)
    }

    @Test func retriesStopAtTheWatchDeadline() async {
        StubURLProtocol.stub(alpha, [.init(status: 503, body: Data())])
        let start = Date()
        let d = await fetchWatchData(PoolWatch(pool: .alphaPool, address: alphaAddr), deadline: 0.3)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(d?.error != nil)
    }

    /// Lucky Pool: 404 is "never mined here"; a 5xx is 查询失败 — they used to look the same.
    @Test func luckyPoolTellsNotFoundFromBusy() async throws {
        let path = "pearl.luckypool.io/api/stats_address"
        StubURLProtocol.stub(path, [.init(status: 404, body: Data(#"{"error":"Address not found"}"#.utf8))])
        #expect(try await LuckyPoolSource.miner(alphaAddr, scope: .full) == nil)

        StubURLProtocol.stub(path, [.init(status: 503, body: Data())])
        await #expect(throws: PoolHTTPError.status(503)) {
            _ = try await LuckyPoolSource.miner(alphaAddr, scope: .full)
        }
    }

    /// PearlHash's 404 is its own "never mined here".
    @Test func pearlHash404IsNotFound() async throws {
        StubURLProtocol.stub("pearlhash.xyz/api/account/\(alphaAddr)", [.init(status: 404, body: Data())])
        StubURLProtocol.stub("pearlhash.xyz/api/stats", [.init(status: 200, body: try Fixture.data("pearlhash_stats.json"))])
        #expect(try await PearlHashSource.miner(alphaAddr, scope: .full) == nil)
    }

    /// The widget's scope reads the rig endpoint alone: Kryptex balance / payouts untouched.
    @Test func liveScopeSkipsMoneyEndpoints() async throws {
        let k = "prl1p5ga7tw6vy5rjr59wewzq3u4sp064muwssdglatxdj3wrz0yzqamshydnnk"
        StubURLProtocol.stub("prl-api.kryptex.network/api/v3/miner/workers/\(k)",
                             [.init(status: 200, body: try Fixture.data("kryptex_workers.json"))])
        StubURLProtocol.stub("prl-api.kryptex.network/api/v1/miner/balance/\(k)",
                             [.init(status: 200, body: try Fixture.data("kryptex_balance.json"))])
        let s = try #require(try await KryptexSource.miner(k, scope: .live))
        #expect(StubURLProtocol.hits("prl-api.kryptex.network/api/v1/miner/balance/\(k)") == 0)
        #expect(s.pending == 0)
        #expect(close(s.liveRate, 6_805_439_436_915_416))

        let live = try #require(await WidgetFetch.poolLive(kind: "Kryptex", address: k))
        #expect(live.hashrate == formatHashrate(6_805_439_436_915_416))
        #expect(live.online == 1 && live.total == 1)
    }
}
