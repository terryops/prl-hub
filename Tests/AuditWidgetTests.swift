import Foundation
import Testing
@testable import Pearl

/// iOS side of the Android widget-cache fixes (docs/bugfixes-2026-10-27.md, G01–G16 in the
/// prl-hub-android repo). Pure snapshot logic only: nothing here touches the real App Group,
/// WidgetCenter or the network.
struct AuditWidgetTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pool(_ address: String, label: String? = nil, kind: String = "AlphaPool",
                      rate: Double = 1e9, online: Int = 2, total: Int = 3) -> WidgetPool {
        WidgetPool(label: label ?? "Rig \(address)", kind: kind, address: address,
                   hashrate: rate > 0 ? formatHashrate(rate) : "—", hashrateRaw: rate,
                   online: online, total: total)
    }

    private let live = WidgetFetch.PoolLive(hashrate: "5.00 GH/s", hashrateRaw: 5e9, online: 4, total: 4)

    // MARK: G01 / G04 — identity is (pool, address), never the label or the second

    @Test func sameLabelOnAnotherAddressIsAnotherTarget() {
        var initial = WidgetSnapshot()
        initial.pools = [pool("a", label: "Rig")]
        initial.poolsAt = now - 600
        var snap = initial
        // Same label, same pool, re-pointed within the same second: the late result is for "a".
        snap.pools[0].address = "b"
        let lateForOldTarget = snap.applyPoolRefresh([(0, live)], from: initial, at: now)
        #expect(!lateForOldTarget)
        #expect(snap.pools[0].hashrateRaw == 1e9)

        // The app's publish only carries figures over for the same target, not the same name.
        var app = WidgetSnapshot()
        app.pools = [pool("a", label: "Rig", rate: 7e9)]
        _ = app.publishAppPools([pool("b", label: "Rig", rate: 0, online: 0, total: 0)], current: [], now: now)
        #expect(app.pools[0].address == "b" && app.pools[0].hashrateRaw == 0 && app.pools[0].hashrate == "—")
    }

    // MARK: G03 / G05 — a failed app read keeps the last good figures and doesn't look fresh

    @Test func failedAppReadKeepsTheWidgetsNewerFiguresWithoutMarkingThemFresh() {
        var snap = WidgetSnapshot()
        snap.pools = [pool("a"), pool("b", rate: 3e9, online: 5, total: 5)]   // e.g. a widget refresh
        snap.poolsAt = now - 900
        snap.updatedAt = now - 900
        // The app read "a" (new figures) but "b" failed: its card has nothing → "—"/0/0.
        let published = [pool("a", rate: 2e9), pool("b", rate: 0, online: 0, total: 0)]
        let partial = snap.publishAppPools(published, current: [0], now: now)
        #expect(partial == .changed)
        #expect(snap.pools[0].hashrateRaw == 2e9)
        #expect(snap.pools[1].hashrateRaw == 3e9 && snap.pools[1].online == 5)   // was wiped to 0/0
        #expect(snap.poolsAt == now - 900)                                        // was stamped `now`
        #expect(snap.updatedAt == now)                                            // "a" is new
        #expect(snap.poolsRev == 1)

        let complete = snap.publishAppPools([pool("a", rate: 2e9), pool("b", rate: 4e9)], current: [0, 1], now: now + 60)
        #expect(complete == .changed && snap.poolsAt == now + 60 && snap.pools[1].hashrateRaw == 4e9)
    }

    @Test func renameReorderOrRemovalIsNotNewData() {
        var snap = WidgetSnapshot()
        snap.pools = [pool("a"), pool("b")]
        snap.poolsAt = now - 900
        snap.updatedAt = now - 900
        // A rename publishes the app's in-memory copy, which may be older than the widget's.
        var renamed = pool("a", label: "New name", rate: 9e9)
        renamed.online = 0
        let rename = snap.publishAppPools([renamed, pool("b", rate: 9e9)], current: [], now: now)
        #expect(rename == .changed)
        #expect(snap.pools[0].label == "New name" && snap.pools[0].hashrateRaw == 1e9 && snap.pools[0].online == 2)
        #expect(snap.poolsAt == now - 900 && snap.updatedAt == now - 900)
        // Removal: same rule.
        let removal = snap.publishAppPools([pool("b", rate: 9e9)], current: [], now: now)
        #expect(removal == .changed)
        #expect(snap.pools.map(\.address) == ["b"] && snap.pools[0].hashrateRaw == 1e9)
        #expect(snap.poolsAt == now - 900 && snap.updatedAt == now - 900)
        // Nothing current and nothing changed: no write at all.
        let nothingNew = snap.publishAppPools([pool("b", rate: 9e9)], current: [], now: now)
        #expect(nothingNew == .unchanged)
    }

    // MARK: G06 — price / fiat publishes leave the pool figures and their clock alone

    @Test func pricePublishDoesNotTouchPoolCache() {
        var snap = WidgetSnapshot()
        snap.pools = [pool("a")]
        snap.poolsAt = now - 900
        snap.poolsRev = 3
        _ = snap.publishAppPrice(0.5, at: now, now: now)
        _ = snap.applyMarketQuote(WidgetMarketQuote(usd: 0.6, change1h: nil, change24h: nil, at: now + 1), now: now + 1)
        #expect(snap.pools == [pool("a")] && snap.poolsAt == now - 900 && snap.poolsRev == 3)
    }

    // MARK: G07 — the clock set back

    @Test func stampsFromTheFutureDoNotFreezeRefreshes() {
        let ahead = now + 86_400          // written while the clock was a day ahead
        #expect(WidgetBridge.valid(ahead, now: now) == nil)
        #expect(WidgetBridge.valid(now + 30, now: now) == now + 30)          // small skew still counts
        #expect(WidgetBridge.isStale(ahead, now: now, maxAge: WidgetBridge.freshFor))   // was "fresh" for a day

        var t = WidgetReloadThrottle(interval: 60)
        #expect(t.request(at: ahead) == .reloadNow)
        #expect(t.request(at: now) == .reloadNow)                            // was .schedule(ahead + 60)
        #expect(t.request(at: now + 5) == .schedule(at: now + 60))

        var snap = WidgetSnapshot()
        snap.prlUsd = 0.4
        snap.prlUsdAt = ahead
        let priceAfterRollback = snap.applyPrice((usd: 0.5, at: now), now: now)
        #expect(priceAfterRollback)              // was rejected as "older"
        #expect(snap.prlUsd == 0.5 && snap.prlUsdAt == now)

        snap.marketQuote = WidgetMarketQuote(usd: 0.4, change1h: nil, change24h: nil, at: ahead)
        snap.prlUsdAt = ahead
        let quoteAfterRollback = snap.applyMarketQuote(WidgetMarketQuote(usd: 0.55, change1h: 1, change24h: 2, at: now), now: now)
        #expect(quoteAfterRollback)
        #expect(snap.prlUsd == 0.55 && snap.marketQuote?.at == now)

        snap.prlUsdAt = ahead
        let app = snap.publishAppPrice(0.56, at: now, now: now)
        #expect(app.changed && app.restamp && snap.prlUsdAt == now)

        snap.pools = [pool("a")]
        snap.poolsAt = ahead
        let restamp = snap.publishAppPools([pool("a")], current: [0], now: now)
        #expect(restamp == .restamp(reloadQuoteMining: true))
        #expect(snap.poolsAt == now)
    }

    // MARK: G09 / G10 — out-of-order refreshes and lost writes

    @Test func olderOfTwoOverlappingRefreshesCannotLandLast() {
        var initial = WidgetSnapshot()
        initial.pools = [pool("a"), pool("b")]
        initial.poolsAt = now - 900
        initial.xpub = "xpub-test"
        initial.walletAt = now - 900
        var snap = initial
        // Two widgets read `initial`; the newer request finishes first and saves. It is partial
        // ("b" failed), so `poolsAt` stays put — which is all the old guard compared.
        let newer = WidgetFetch.PoolLive(hashrate: "6.00 GH/s", hashrateRaw: 6e9, online: 4, total: 4)
        let newerPartial = snap.applyPoolRefresh([(0, newer), (1, nil)], from: initial, at: now)
        #expect(newerPartial)
        #expect(snap.poolsAt == initial.poolsAt)
        let newerWallet = snap.applyWalletRefresh(balance: 12, from: initial)
        #expect(newerWallet)
        // The older one lands afterwards: rejected (before, it overwrote both).
        let older = WidgetFetch.PoolLive(hashrate: "1.00 GH/s", hashrateRaw: 1e9, online: 1, total: 4)
        let olderPools = snap.applyPoolRefresh([(0, older)], from: initial, at: now + 5)
        #expect(!olderPools)
        let olderWallet = snap.applyWalletRefresh(balance: 10, from: initial)
        #expect(!olderWallet)
        #expect(snap.pools[0].hashrateRaw == 6e9 && snap.balancePRL == 12)
    }

    @Test func appWalletWriteRejectsAnInFlightWidgetBalance() {
        var initial = WidgetSnapshot()
        initial.xpub = "xpub-test"
        initial.changePRL = 1
        var snap = initial
        snap.walletRev = 1                    // the app wrote (same walletAt: a label-only publish)
        let afterAppWrite = snap.applyWalletRefresh(balance: 10, from: initial)
        #expect(!afterAppWrite)
        snap = initial
        snap.xpub = nil                       // wallet removed meanwhile
        let afterRemoval = snap.applyWalletRefresh(balance: 10, from: initial)
        #expect(!afterRemoval && snap.balancePRL == 0)
        snap = initial
        let nanBalance = snap.applyWalletRefresh(balance: .nan, from: initial)
        #expect(!nanBalance)
        let good = snap.applyWalletRefresh(balance: 10, from: initial)
        #expect(good && snap.balancePRL == 11)
    }

    @Test func lockedUpdateKeepsEveryConcurrentWrite() throws {
        let name = "com.prl.wizard.tests.audit-widget-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        nonisolated(unsafe) let store = defaults
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<40 {
                WidgetStore.update(in: store) { s in
                    s.poolsRev = (s.poolsRev ?? 0) + 1
                    return true
                }
            }
        }
        #expect(WidgetStore.load(from: defaults).poolsRev == 320)
    }

    @Test func unstampedMirrorPriceNeverReplacesAStampedOne() {
        var snap = WidgetSnapshot()
        snap.prlUsd = 0.62
        snap.prlUsdAt = now - 10              // a widget fetched this after the app's copy
        let mirror = snap.publishAppPrice(0.50, at: nil, now: now)
        #expect(!mirror.changed && !mirror.restamp && snap.prlUsd == 0.62 && snap.prlUsdAt == now - 10)
        let older = snap.publishAppPrice(0.50, at: now - 30, now: now)
        #expect(!older.changed && !older.restamp && snap.prlUsd == 0.62)    // was: value replaced, stamp kept
        var empty = WidgetSnapshot()
        let first = empty.publishAppPrice(0.50, at: nil, now: now)
        #expect(first.changed && empty.prlUsd == 0.50 && empty.prlUsdAt == nil)
    }

    // MARK: G14 — empty or garbled answers are "unknown", never a real zero

    @Test func emptyPoolAnswersMeanUnknownNotZero() throws {
        let empty = Data("{}".utf8)
        #expect(try AlphaPoolSource.parse(empty, now: 0) == nil)
        #expect(try LuckyPoolSource.parse(empty, now: 0) == nil)
        #expect(try HeroMinersSource.parse(empty, now: 0) == nil)
        #expect(try JetskiSource.parse(empty, now: 0) == nil)
        #expect(try PearlHashSource.parse(empty, poolHashrate: 0) == nil)
        #expect(KryptexSource.stats(KryptexMiner(workers: [], balance: nil, payouts: nil)) == nil)
        #expect(PearlFortuneSource.live(try PoolHTTP.decode(PFEnvelope<PFConnections>.self, from: empty).data) == nil)
        #expect(F2PoolSource.stats(try PoolHTTP.decode(F2WorkersResp.self, from: empty), revenue: nil, paid: 0) == nil)
        // Wrong types fail the decode (→ the widget keeps its figures) instead of reading 0.
        #expect(throws: (any Error).self) { try AlphaPoolSource.parse(Data(#"{"workers":"x"}"#.utf8), now: 0) }
    }

    @Test func nonFiniteOrNegativeRatesNeverReachATotal() throws {
        #expect(parseHashrate("nan TH/s") == 0 && parseHashrate("inf TH/s") == 0)
        #expect(parseHashrate("-5 TH/s") == 0 && parseHashrate("1e400 H/s") == 0)
        #expect(parseHashrate("2.5 TH/s") == 2.5e12)
        let flex = try JSONDecoder().decode([FlexDouble].self, from: Data(#"["nan","inf","1,234.5",null]"#.utf8))
        #expect(flex.map(\.value) == [0, 0, 1234.5, 0])

        var initial = WidgetSnapshot()
        initial.pools = [pool("a")]
        var snap = initial
        let broken = WidgetFetch.PoolLive(hashrate: "x", hashrateRaw: .infinity, online: 5, total: 2)
        let brokenApplied = snap.applyPoolRefresh([(0, broken)], from: initial, at: now)
        #expect(!brokenApplied)
        #expect(snap.pools == initial.pools)
    }

    @Test func malformedXpubBalanceKeepsTheLastOne() {
        #expect(WidgetFetch.xpubBalancePRL([:]) == nil)
        #expect(WidgetFetch.xpubBalancePRL(["balance": "abc"]) == nil)       // was 0
        #expect(WidgetFetch.xpubBalancePRL(["balance": true]) == nil)
        #expect(WidgetFetch.xpubBalancePRL(["balance": "100", "unconfirmedBalance": [String: Any]()]) == nil)
        #expect(WidgetFetch.xpubBalancePRL(["balance": "100000000", "unconfirmedBalance": "-50000000"]) == 0.5)
        #expect(WidgetFetch.xpubBalancePRL(["balance": "200000000"]) == 2)
    }

    // MARK: G15 — Blockbook confirmations / amounts

    @Test func utxoConfirmationsMustBeIntegers() throws {
        func decode(_ confirmations: String) throws -> [BlockbookClient.UTXO] {
            let json = #"[{"txid":"aa","vout":0,"value":"100","confirmations":"# + confirmations + "}]"
            return try JSONDecoder().decode([BlockbookClient.UTXO].self, from: Data(json.utf8))
        }
        #expect(try decode("3").first?.confirmations == 3)
        for bad in [#""5""#, "true", "{}", "1.5", "1e20"] {
            #expect(throws: (any Error).self, "confirmations \(bad)") { try decode(bad) }
        }
        #expect(BlockbookClient.strictPRL("100000000") == 1)
        #expect(BlockbookClient.strictPRL("-50000000") == Decimal(string: "-0.5"))
        for bad in ["", "abc", "12abc", "1.5", " 1"] { #expect(BlockbookClient.strictPRL(bad) == nil, "\(bad)") }
    }

    // MARK: G16 — duplicate targets

    @Test func duplicateTargetsCountOnce() {
        let pools = [pool("a"), pool("b", rate: 2e9), pool("a", label: "Same rigs again"), pool("a", kind: "Kryptex")]
        let unique = WidgetMiningSummary.uniqueTargets(pools)
        #expect(unique.map(\.target) == ["AlphaPool|a", "AlphaPool|b", "Kryptex|a"])
        #expect(unique.reduce(0) { $0 + $1.total } == 9)
    }
}
