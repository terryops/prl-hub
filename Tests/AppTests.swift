import Foundation
import Testing
@testable import Pearl

struct CloudSyncSeedTests {
    @Test func seedsOnlyIntoAnEmptyCloudSlot() {
        #expect(CloudSync.shouldSeed(local: "Rig A", cloud: nil, tombstone: nil))
        #expect(CloudSync.shouldSeed(local: Data([1]), cloud: nil, tombstone: nil))
        #expect(CloudSync.shouldSeed(local: 0.5, cloud: nil, tombstone: nil))
    }

    @Test func cloudValueOrTombstoneWins() {
        // A newer edit from another device must not be overwritten by this device's copy.
        #expect(!CloudSync.shouldSeed(local: "old", cloud: "new", tombstone: nil))
        #expect(!CloudSync.shouldSeed(local: "same", cloud: "same", tombstone: nil))
        // A deletion elsewhere must not be resurrected.
        #expect(!CloudSync.shouldSeed(local: "old", cloud: nil, tombstone: 1_700_000_000.0))
    }

    @Test func neverSeedsEmptyValues() {
        #expect(!CloudSync.shouldSeed(local: nil, cloud: nil, tombstone: nil))
        #expect(!CloudSync.shouldSeed(local: "", cloud: nil, tombstone: nil))
        #expect(!CloudSync.shouldSeed(local: Data(), cloud: nil, tombstone: nil))
    }
}

struct WidgetReloadThrottleTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func firstRequestReloadsNow() {
        var t = WidgetReloadThrottle(interval: 60)
        #expect(t.request(at: t0) == .reloadNow)
    }

    @Test func burstBecomesOneTrailingReload() {
        var t = WidgetReloadThrottle(interval: 60)
        _ = t.request(at: t0)
        #expect(t.request(at: t0 + 5) == .schedule(at: t0 + 60))
        // Everything until that reload runs coalesces into it.
        #expect(t.request(at: t0 + 10) == .none)
        #expect(t.request(at: t0 + 59) == .none)
        t.fire(at: t0 + 60)
        #expect(t.request(at: t0 + 61) == .schedule(at: t0 + 120))
    }

    @Test func quietPeriodReloadsNow() {
        var t = WidgetReloadThrottle(interval: 60)
        _ = t.request(at: t0)
        #expect(t.request(at: t0 + 60) == .reloadNow)
        #expect(t.request(at: t0 + 200) == .reloadNow)
    }

    @Test func staleness() {
        #expect(WidgetBridge.isStale(nil, now: t0))
        #expect(!WidgetBridge.isStale(t0 - 30, now: t0))
        #expect(WidgetBridge.isStale(t0 - 60, now: t0))
        #expect(!WidgetBridge.isStale(t0 - 100, now: t0, maxAge: WidgetBridge.freshFor))
        #expect(WidgetBridge.isStale(t0 - 120, now: t0, maxAge: WidgetBridge.freshFor))
    }
}

struct PriceAlertEditTests {
    private func fired(_ kind: PriceAlertRule.Kind, _ value: Double, window: Int = 0) -> PriceAlertRule {
        var r = PriceAlertRule(kind: kind, value: value, window: window)
        r.enabled = false                                    // one-shot: switched itself off
        r.lastFired = Date(timeIntervalSince1970: 1_700_000_000)
        r.deferred = false
        return r
    }

    @Test func changedConditionRearms() {
        let old = fired(.above, 1.20)
        let edited = old.applyingEdit(PriceAlertRule(kind: .above, value: 1.50))
        #expect(edited.id == old.id)
        #expect(edited.value == 1.50)
        #expect(edited.enabled)
        #expect(edited.lastFired == nil)
        #expect(edited.deferred == nil)
    }

    @Test func changedWindowRearms() {
        let old = fired(.move, 10, window: 3600)
        let edited = old.applyingEdit(PriceAlertRule(kind: .move, value: 10, window: 300))
        #expect(edited.enabled)
        #expect(edited.lastFired == nil)
    }

    @Test func unchangedConditionKeepsState() {
        let old = fired(.below, 0.90)
        let edited = old.applyingEdit(PriceAlertRule(kind: .below, value: 0.90))
        #expect(edited.id == old.id)
        #expect(!edited.enabled)
        #expect(edited.lastFired == old.lastFired)
    }
}
