import Foundation
import Testing
@testable import Pearl

struct WidgetMiningSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pool(_ address: String, rate: Double = 1e9, online: Int = 2, total: Int = 3) -> WidgetPool {
        WidgetPool(label: "Rig \(address)", kind: "AlphaPool", address: address,
                   hashrate: formatHashrate(rate), hashrateRaw: rate, online: online, total: total)
    }

    @Test func sumsMonitorsWithoutCountingDuplicateTargetsTwice() {
        let summary = WidgetMiningSummary([pool("a"), pool("b", rate: 2e9, online: 3, total: 4), pool("a")])
        #expect(summary.monitorCount == 2 && summary.knownCount == 2)
        #expect(summary.hashrate == 3e9)
        #expect(summary.hashrateText == "3.00 GH/s")
        #expect(summary.workersText == "5/7")
    }

    @Test func missingStatsDoNotLookLikeLostHashrateOrOfflineWorkers() {
        var unknown = pool("b", rate: 0, online: 0, total: 0)
        unknown.hashrate = "—"
        let partial = WidgetMiningSummary([pool("a"), unknown])
        #expect(partial.monitorCount == 2 && partial.knownCount == 1)
        #expect(partial.hashrate == nil && partial.online == nil && partial.total == nil)
        #expect(partial.hashrateText == "—" && partial.workersText == "—")
        #expect(WidgetMiningSummary([]).monitorCount == 0)
    }

    @Test func actualOfflineWorkersStillShowZeroHashrate() {
        let summary = WidgetMiningSummary([pool("a", rate: 0, online: 0, total: 3)])
        #expect(summary.hashrateText == "0 H/s")
        #expect(summary.workersText == "0/3")
        #expect(WidgetMiningSummary([pool("a", rate: .nan)]).hashrate == nil)
    }

    @Test func completeRefreshUpdatesTheStampButPartialFailureKeepsOldValues() {
        var initial = WidgetSnapshot()
        initial.pools = [pool("a"), pool("b")]
        initial.poolsAt = now - 1800
        let live = WidgetFetch.PoolLive(hashrate: "2.00 GH/s", hashrateRaw: 2e9, online: 3, total: 3)
        var snap = initial
        let partial = snap.applyPoolRefresh([(0, live), (1, nil)], from: initial, at: now)
        #expect(partial)
        #expect(snap.pools[0].hashrateRaw == 2e9 && snap.pools[1].hashrateRaw == 1e9)
        #expect(snap.poolsAt == initial.poolsAt)
        snap = initial
        let complete = snap.applyPoolRefresh([(0, live), (1, live)], from: initial, at: now)
        #expect(complete && snap.poolsAt == now)
        snap = initial
        let failed = snap.applyPoolRefresh([(0, nil), (1, nil)], from: initial, at: now)
        #expect(!failed && snap.pools == initial.pools && snap.poolsAt == initial.poolsAt)
    }

    @Test func lateResultsPreserveRemovalNewerDataAndRenames() {
        var initial = WidgetSnapshot()
        initial.pools = [pool("a")]
        initial.poolsAt = now - 1800
        let live = WidgetFetch.PoolLive(hashrate: "2.00 GH/s", hashrateRaw: 2e9, online: 3, total: 3)
        var snap = initial
        snap.pools = []
        let removed = snap.applyPoolRefresh([(0, live)], from: initial, at: now)
        #expect(!removed && snap.pools.isEmpty)
        snap = initial
        snap.poolsAt = now
        let newer = snap.applyPoolRefresh([(0, live)], from: initial, at: now + 1)
        #expect(!newer && snap.pools[0].hashrateRaw == 1e9)
        snap = initial
        snap.pools[0].address = "different"
        let changedTarget = snap.applyPoolRefresh([(0, live)], from: initial, at: now)
        #expect(!changedTarget && snap.pools[0].address == "different")
        snap = initial
        snap.pools[0].label = "New name"
        let renamed = snap.applyPoolRefresh([(0, live)], from: initial, at: now)
        #expect(renamed && snap.pools[0].label == "New name")
    }
}
