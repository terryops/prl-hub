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
        #expect(edited.changedAt ?? 0 > old.changedAt ?? 0)   // wins the iCloud merge
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

struct PriceAlertSyncTests {
    private func rule(_ id: String, _ kind: PriceAlertRule.Kind = .above, _ value: Double = 1.2,
                      enabled: Bool = true, at: TimeInterval, fired: TimeInterval? = nil) -> PriceAlertRule {
        var r = PriceAlertRule(id: id, kind: kind, value: value, enabled: enabled, changedAt: at)
        r.lastFired = fired.map { Date(timeIntervalSince1970: $0) }
        return r
    }

    private func cloud(_ rules: [PriceAlertRule], removed: [String: TimeInterval] = [:]) -> CloudAlerts {
        CloudAlerts(rules: rules.map(\.cloud), removed: removed)
    }

    @Test func newerCopyWinsPerRule() {
        let local = [rule("a", at: 100, fired: 50), rule("b", at: 300)]
        let remote = cloud([rule("a", enabled: false, at: 200), rule("b", enabled: false, at: 250)])
        let m = PriceAlertSync.merge(local: local, removed: [:], cloud: remote, incoming: true)
        #expect(m.rules.map(\.id) == ["a", "b"])
        #expect(!m.rules[0].enabled)                   // cloud newer
        #expect(m.rules[0].changedAt == 200)
        #expect(m.rules[0].lastFired == Date(timeIntervalSince1970: 50))   // same condition: this device's fired state stays
        #expect(m.rules[1].enabled)                    // local newer
    }

    @Test func tieGoesToCloud() {
        let m = PriceAlertSync.merge(local: [rule("a", at: 100)],
                                     removed: [:], cloud: cloud([rule("a", enabled: false, at: 100)]), incoming: false)
        #expect(!m.rules[0].enabled)
    }

    @Test func changedConditionFromCloudDropsFiredState() {
        var r = rule("a", at: 100, fired: 90)
        r.deferred = true
        let m = PriceAlertSync.merge(local: [r], removed: [:], cloud: cloud([rule("a", .below, 0.9, at: 200)]), incoming: true)
        #expect(m.rules[0].kind == .below && m.rules[0].value == 0.9)
        #expect(m.rules[0].lastFired == nil)
        #expect(m.rules[0].deferred == nil)
    }

    @Test func unionOfAddsKeepsOrder() {
        let local = [rule("a", at: 100), rule("c", .below, 0.5, at: 300)]
        let remote = cloud([rule("b", .move, 5, at: 200), rule("a", at: 100)])
        #expect(PriceAlertSync.merge(local: local, removed: [:], cloud: remote, incoming: true).rules.map(\.id) == ["b", "a", "c"])
        #expect(PriceAlertSync.merge(local: local, removed: [:], cloud: remote, incoming: false).rules.map(\.id) == ["a", "c", "b"])
    }

    @Test func tombstoneDeletesOlderRuleOnly() {
        let local = [rule("a", at: 100), rule("b", at: 500)]
        let remote = cloud([], removed: ["a": 200, "b": 400])
        let m = PriceAlertSync.merge(local: local, removed: [:], cloud: remote, incoming: true)
        #expect(m.rules.map(\.id) == ["b"])            // b was switched after the delete elsewhere
        #expect(m.removed == ["a": 200, "b": 400])
        // A local deletion keeps a cloud copy from coming back.
        let back = PriceAlertSync.merge(local: [], removed: ["a": 200], cloud: cloud([rule("a", at: 100)]), incoming: true)
        #expect(back.rules.isEmpty)
    }

    @Test func incomingDropsLocalOnlyDuplicate() {
        let local = [rule("mine", .above, 1.5, at: 100), rule("other", .below, 0.8, at: 100)]
        let remote = cloud([rule("theirs", .above, 1.5, at: 50)])
        let m = PriceAlertSync.merge(local: local, removed: [:], cloud: remote, incoming: true)
        #expect(m.rules.map(\.id) == ["theirs", "other"])
        #expect(m.removed.isEmpty)                     // not a deletion: nothing to tell other devices
        // A local add of the same condition is the user's call.
        #expect(PriceAlertSync.merge(local: local, removed: [:], cloud: remote, incoming: false).rules.count == 3)
    }

    @Test func noCloudCopyLeavesLocalAlone() {
        let local = [rule("a", at: 100)]
        #expect(PriceAlertSync.merge(local: local, removed: ["x": 1], cloud: nil, incoming: true)
                == .init(rules: local, removed: ["x": 1]))
    }

    @Test func tombstonesAreCapped() {
        let many = Dictionary(uniqueKeysWithValues: (0..<250).map { ("id\($0)", TimeInterval($0)) })
        let m = PriceAlertSync.merge(local: [], removed: many, cloud: CloudAlerts(), incoming: false)
        #expect(m.removed.count == PriceAlertSync.maxTombstones)
        #expect(m.removed["id249"] != nil && m.removed["id0"] == nil)   // the oldest go first
    }

    @Test func encodingIsStable() {
        let a = CloudAlerts(rules: [rule("a", at: 1).cloud], removed: ["x": 1, "y": 2, "z": 3])
        #expect(a.encoded() == CloudAlerts.decode(a.encoded())?.encoded())
        #expect(CloudAlerts.decode(a.encoded()) == a)
    }

    /// Fired on both devices, switched back on at the phone: the Mac's copy fired
    /// (and was never shown there), yet re-sending with the phone's switch-on time
    /// lets the worker turn it back on.
    @Test func reEnableOnOneDeviceReachesTheOther() {
        var phone = [rule("a", enabled: false, at: 1_000, fired: 1_000)]
        let mac = [rule("a", at: 100)]                 // stale: still shows on, lastFired unknown
        // Phone switches it back on and uploads.
        phone[0].enabled = true
        phone[0].changedAt = 2_000
        let m = PriceAlertSync.merge(local: mac, removed: [:], cloud: cloud(phone), incoming: true)
        #expect(m.rules[0].enabled && m.rules[0].changedAt == 2_000)
        #expect(m.rules[0].seenFired == 2_000)         // ≥ the Mac server's own last_fired (≈1 000)
        // A switched-off rule never claims more than it saw.
        #expect(rule("b", enabled: false, at: 3_000, fired: 1_000).seenFired == 1_000)
    }
}
