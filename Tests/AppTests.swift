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

/// iCloud sync is a Pro feature: what a free install changes is queued, and uploaded
/// rather than overwritten when Pro unlocks.
struct CloudSyncQueueTests {
    @Test func onlyARealEditOnASyncedInstallIsQueued() {
        let baseline: [String: Any] = ["prl.elec": 0.5, "pool.watches": Data([1, 2])]
        #expect(CloudSync.shouldQueue(hasSynced: true, baseline: baseline, key: "prl.elec", local: 0.8))
        #expect(CloudSync.shouldQueue(hasSynced: true, baseline: baseline, key: "pool.watches", local: Data([1, 2, 3])))
        // A value saved for the first time, and one removed.
        #expect(CloudSync.shouldQueue(hasSynced: true, baseline: baseline, key: "wallet.contacts", local: Data([9])))
        #expect(CloudSync.shouldQueue(hasSynced: true, baseline: baseline, key: "prl.elec", local: nil))
        // The price tick rewrites the mining prefs as they were.
        #expect(!CloudSync.shouldQueue(hasSynced: true, baseline: baseline, key: "prl.elec", local: 0.5))
        #expect(!CloudSync.shouldQueue(hasSynced: true, baseline: baseline, key: "wallet.name", local: nil))
        // A new install holds defaults, not edits: its first sync adopts the cloud.
        #expect(!CloudSync.shouldQueue(hasSynced: false, baseline: baseline, key: "prl.elec", local: 0.8))
        #expect(!CloudSync.shouldQueue(hasSynced: true, baseline: nil, key: "prl.elec", local: 0.8))
    }

    @Test func anInstallThatWasHereBeforeStartsQueueing() {
        let name = "cloud-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        d.set(0.5, forKey: "prl.elec")
        CloudSync.adoptDefault(in: d, launches: 7)
        #expect(d.bool(forKey: CloudSync.syncedKey))
        #expect(d.dictionary(forKey: CloudSync.baselineKey)?["prl.elec"] as? Double == 0.5)
        // Decided once: a later call (the count has grown) changes nothing.
        d.set(0.9, forKey: "prl.elec")
        CloudSync.adoptDefault(in: d, launches: 8)
        #expect(d.dictionary(forKey: CloudSync.baselineKey)?["prl.elec"] as? Double == 0.5)

        let fresh = "cloud-\(UUID().uuidString)"
        let f = UserDefaults(suiteName: fresh)!
        defer { f.removePersistentDomain(forName: fresh) }
        CloudSync.adoptDefault(in: f, launches: 0)
        #expect(f.object(forKey: CloudSync.syncedKey) as? Bool == false)
        #expect(f.dictionary(forKey: CloudSync.baselineKey) == nil)
    }

    @Test func queuedKeysGoUpExceptThoseTheAccountOwns() {
        let plan = CloudSync.flushPlan(pending: ["pool.watches", "prl.elec", "no.longer.synced"]) { $0 == "pool.watches" }
        #expect(plan.upload == ["prl.elec"])
        #expect(plan.keep == ["pool.watches"])
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
        r.fired = 1_700_000_000                              // one-shot: fired, so off until switched on
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
        #expect(edited.fired == nil && edited.ack == nil && edited.isOn)
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
        #expect(edited == old)
        #expect(!edited.isOn)
    }
}

@MainActor
struct PriceAlertEditorTests {
    @Test(arguments: [PriceAlertRule.Kind.above, .below])
    func unchangedTargetKeepsDirectionAfterPriceCrosses(_ kind: PriceAlertRule.Kind) throws {
        var old = PriceAlertRule(kind: kind, value: 1.20)
        old.fired = 1_700_000_000
        old.lastFired = Date(timeIntervalSince1970: 1_700_000_000)
        old.deferred = false
        old.changedAt = 1_699_999_000
        let current = kind == .above ? 1.50 : 0.90

        let draft = try #require(AlertEditorSheet.priceRule(for: 1.20, current: current, existing: old))
        #expect(draft.kind == kind)
        let saved = old.applyingEdit(draft)
        #expect(saved == old)
        #expect(!saved.isOn)
        #expect(saved.wire == old.wire)
        #expect(saved.cloud == old.cloud)
    }

    @Test(arguments: [PriceAlertRule.Kind.above, .below])
    func frequencyEditKeepsDirectionAndFiringAfterPriceCrosses(_ kind: PriceAlertRule.Kind) throws {
        var old = PriceAlertRule(kind: kind, value: 1.20)
        old.fired = 1_700_000_000
        old.lastFired = Date(timeIntervalSince1970: 1_700_000_000)
        let current = kind == .above ? 1.50 : 0.90
        var draft = try #require(AlertEditorSheet.priceRule(for: 1.20, current: current, existing: old))
        draft.repeats = true

        let saved = old.applyingEdit(draft)
        #expect(saved.kind == kind)
        #expect(saved.isRepeating && saved.isOn)
        #expect(saved.fired == old.fired && saved.lastFired == old.lastFired)
        #expect(saved.ack == old.fired)
        #expect(saved.wire.kind == kind)
    }

    @Test(arguments: [PriceAlertRule.Kind.above, .below])
    func unchangedTargetCanBeSavedAtCurrentPrice(_ kind: PriceAlertRule.Kind) throws {
        let old = PriceAlertRule(kind: kind, value: 1.20)
        for current in [1.20, 1.204] {
            let draft = try #require(AlertEditorSheet.priceRule(for: 1.20, current: current, existing: old))
            #expect(old.applyingEdit(draft) == old)
        }
    }

    @Test(arguments: [PriceAlertRule.Kind.above, .below])
    func unchangedTargetKeepsDirectionWithoutQuote(_ kind: PriceAlertRule.Kind) throws {
        let old = PriceAlertRule(kind: kind, value: 1.20)
        let draft = try #require(AlertEditorSheet.priceRule(for: 1.20, current: nil, existing: old))
        #expect(old.applyingEdit(draft) == old)
    }

    @Test func changedTargetUsesCurrentPriceAndRearms() throws {
        var old = PriceAlertRule(kind: .above, value: 1.20)
        old.fired = 1_700_000_000
        for (target, kind) in [(1.10, PriceAlertRule.Kind.below), (1.60, .above)] {
            let draft = try #require(AlertEditorSheet.priceRule(for: target, current: 1.50, existing: old))
            let saved = old.applyingEdit(draft)
            #expect(saved.id == old.id && saved.kind == kind && saved.value == target)
            #expect(saved.fired == nil && saved.isOn)
        }
        #expect(AlertEditorSheet.priceRule(for: 1.50, current: 1.50, existing: old) == nil)
    }

    @Test func newPriceRulesStillInferDirectionAndRoundTargets() throws {
        let up = try #require(AlertEditorSheet.priceRule(for: 1.504, current: 1.20, existing: nil))
        #expect(up.kind == .above && up.value == 1.50)
        let down = try #require(AlertEditorSheet.priceRule(for: 0.904, current: 1.20, existing: nil))
        #expect(down.kind == .below && down.value == 0.90)
        #expect(AlertEditorSheet.priceRule(for: 1.20, current: 1.204, existing: nil) == nil)
    }

    @Test func convertingMoveRuleInfersPriceDirection() throws {
        let old = PriceAlertRule(kind: .move, value: 10, window: 3600)
        let draft = try #require(AlertEditorSheet.priceRule(for: 10, current: 12, existing: old))
        #expect(draft.kind == .below && draft.window == 0)
        #expect(AlertEditorSheet.priceRule(for: 10, current: 10, existing: old) == nil)
    }

    @Test(arguments: [0.0, -1.0, 0.004, 1_000_000.0, Double.infinity, Double.nan])
    func invalidTargetsRemainInvalid(_ target: Double) {
        #expect(AlertEditorSheet.priceRule(for: target, current: 1.20, existing: nil) == nil)
    }
}

struct PriceAlertFrequencyTests {
    @Test func oldSavedAlertsDefaultToOneShot() throws {
        let data = Data(#"{"id":"old","kind":"above","value":1.2,"window":0,"enabled":true,"fired":1000}"#.utf8)
        let r = try JSONDecoder().decode(PriceAlertRule.self, from: data)
        #expect(!r.isRepeating && !r.isOn && !r.wire.repeats)
        let cloudData = Data(#"{"rules":[{"id":"old","kind":"above","value":1.2,"window":0,"enabled":true,"changedAt":0,"fired":1000,"ack":0}],"removed":{}}"#.utf8)
        let oldCloud = try #require(CloudAlerts.decode(cloudData)?.rules.first)
        #expect(!PriceAlertRule(cloud: oldCloud).isRepeating)
    }

    @Test func repeatingAlertsStayOnAfterFiringAndStillRespectTheSwitch() throws {
        var r = PriceAlertRule(kind: .move, value: 5, window: 300, repeats: true, fired: 1000)
        #expect(r.isOn && r.wire.on && r.wire.repeats)
        let saved = try JSONDecoder().decode(PriceAlertRule.self, from: JSONEncoder().encode(r))
        #expect(saved.isRepeating && saved.isOn)
        r.enabled = false
        #expect(!r.isOn && !r.wire.on)
    }

    @Test func changingFrequencyKeepsHistoryAndAcknowledgesTheLastFiring() {
        let old = PriceAlertRule(kind: .above, value: 1.2, fired: 1000)
        let repeating = old.applyingEdit(PriceAlertRule(kind: .above, value: 1.2, repeats: true))
        #expect(repeating.id == old.id && repeating.isRepeating && repeating.isOn)
        #expect(repeating.fired == 1000 && repeating.ack == 1000)
        let once = repeating.applyingEdit(PriceAlertRule(kind: .above, value: 1.2))
        #expect(!once.isRepeating && once.isOn && once.fired == 1000 && once.ack == 1000)
        #expect(once.changedAt ?? 0 > repeating.changedAt ?? 0)
    }

    @Test func frequencyFollowsTheNewerUserEditAcrossDevices() {
        let local = PriceAlertRule(id: "r", kind: .above, value: 1.2, changedAt: 100, fired: 1000)
        let other = PriceAlertRule(id: "r", kind: .above, value: 1.2, repeats: true, changedAt: 200, fired: 1100)
        let merged = PriceAlertSync.merge(local: [local], removed: [:], cloud: CloudAlerts(rules: [other.cloud]), incoming: true)
        #expect(merged.rules.first?.isRepeating == true && merged.rules.first?.isOn == true)
        #expect(merged.rules.first?.fired == 1100)
    }
}

struct PriceAlertSyncTests {
    private func rule(_ id: String, _ kind: PriceAlertRule.Kind = .above, _ value: Double = 1.2,
                      enabled: Bool = true, at: TimeInterval?, fired: TimeInterval? = nil,
                      ack: TimeInterval? = nil, lastFired: TimeInterval? = nil) -> PriceAlertRule {
        var r = PriceAlertRule(id: id, kind: kind, value: value, enabled: enabled, changedAt: at, fired: fired, ack: ack)
        r.lastFired = lastFired.map { Date(timeIntervalSince1970: $0) }
        return r
    }

    private func cloud(_ rules: [PriceAlertRule], removed: [String: TimeInterval] = [:]) -> CloudAlerts {
        CloudAlerts(rules: rules.map(\.cloud), removed: removed)
    }

    private func merge(_ local: [PriceAlertRule], _ remote: CloudAlerts?, removed: [String: TimeInterval] = [:],
                       incoming: Bool = true) -> PriceAlertSync.Merged {
        PriceAlertSync.merge(local: local, removed: removed, cloud: remote, incoming: incoming)
    }

    @Test func newerUserChangeWinsPerRule() {
        let m = merge([rule("a", at: 100, lastFired: 50), rule("b", at: 300)],
                      cloud([rule("a", enabled: false, at: 200), rule("b", enabled: false, at: 250)]))
        #expect(m.rules.map(\.id) == ["a", "b"])
        #expect(!m.rules[0].enabled && m.rules[0].changedAt == 200)    // cloud newer
        #expect(m.rules[0].lastFired == Date(timeIntervalSince1970: 50)) // same condition: this device's record stays
        #expect(m.rules[1].enabled)                                      // local newer
    }

    @Test func tieGoesToCloudWithTheLaterFiring() {
        let m = merge([rule("a", at: 100, fired: 700)], cloud([rule("a", enabled: false, at: 100, fired: 500)]), incoming: false)
        #expect(!m.rules[0].enabled)
        #expect(m.rules[0].fired == 700)
    }

    /// Review #1: a rule that fires in the tick it was added (the worker stamps the
    /// tick's start, before the add) stays off — no phone clock is compared.
    @Test func freshRuleFiringStaysOff() {
        let r = rule("a", at: 2_000, fired: 1_990)
        #expect(!r.isOn)
        #expect(r.wire.on == false)
    }

    /// Fired on both devices in the same tick, switched back on at the phone: the
    /// Mac's own copy of that firing is covered, and its worker is told so.
    @Test func reEnableElsewhereCoversTheSameFiring() {
        let phone = rule("a", at: 2_000, fired: 1_000, ack: 1_000)       // switched back on
        let m = merge([rule("a", at: 100, lastFired: 1_000)], cloud([phone]))
        #expect(m.rules[0].isOn)
        #expect(m.rules[0].wire.seen == 1_000)                           // ≥ the Mac worker's last_fired
    }

    @Test func laterFiringOnAnotherDeviceStaysOff() {
        let m = merge([rule("a", at: 100, lastFired: 1_060)], cloud([rule("a", at: 2_000, fired: 1_000, ack: 1_000)]))
        #expect(!m.rules[0].isOn)
        #expect(m.rules[0].fired == 1_060)                               // folded in, goes up to iCloud
    }

    /// Review #3: a clock that runs behind still stamps its own change after the copy it changes.
    @Test func slowClockKeepsItsOwnChange() {
        let ahead = Date().timeIntervalSince1970 + 120
        var r = rule("a", enabled: false, at: ahead)
        r.enabled = true
        r.changedAt = PriceAlertRule.stamp(after: ahead)
        #expect(merge([r], cloud([rule("a", enabled: false, at: ahead)]), incoming: false).rules[0].enabled)
    }

    /// Review #4: a firing never outranks a deletion.
    @Test func firingNeverBringsADeletedRuleBack() {
        let m = merge([rule("a", enabled: false, at: 100, fired: 900, lastFired: 900)], cloud([], removed: ["a": 200]))
        #expect(m.rules.isEmpty)
    }

    @Test func changedConditionFromCloudDropsFiredState() {
        var r = rule("a", at: 100, lastFired: 90)
        r.deferred = true
        let m = merge([r], cloud([rule("a", .below, 0.9, at: 200)]))
        #expect(m.rules[0].kind == .below && m.rules[0].value == 0.9)
        #expect(m.rules[0].lastFired == nil && m.rules[0].deferred == nil && m.rules[0].fired == nil)
        #expect(m.rules[0].isOn)
    }

    @Test func unionOfAddsKeepsOrder() {
        let local = [rule("a", at: 100), rule("c", .below, 0.5, at: 300)]
        let remote = cloud([rule("b", .move, 5, at: 200), rule("a", at: 100)])
        #expect(merge(local, remote).rules.map(\.id) == ["b", "a", "c"])
        #expect(merge(local, remote, incoming: false).rules.map(\.id) == ["a", "c", "b"])
    }

    @Test func tombstoneDeletesOlderRuleOnly() {
        let m = merge([rule("a", at: 100), rule("b", at: 500)], cloud([], removed: ["a": 200, "b": 400]))
        #expect(m.rules.map(\.id) == ["b"])            // b was switched after the delete elsewhere
        #expect(m.removed == ["a": 200, "b": 400])
        // A local deletion keeps a cloud copy from coming back.
        #expect(merge([], cloud([rule("a", at: 100)]), removed: ["a": 200]).rules.isEmpty)
    }

    /// Review #7: only rules saved before sync are folded into iCloud's copy of the same alert.
    @Test func incomingDropsOnlyPreSyncDuplicates() {
        let local = [rule("legacy", .above, 1.5, at: nil), rule("new", .below, 0.8, at: 300), rule("other", .move, 5, at: nil)]
        let remote = cloud([rule("theirs", .above, 1.5, at: 50), rule("theirs2", .below, 0.8, enabled: false, at: 60)])
        let m = merge(local, remote)
        #expect(m.rules.map(\.id) == ["theirs", "theirs2", "new", "other"])
        #expect(m.removed.isEmpty)                     // not a deletion: nothing to tell other devices
        #expect(merge(local, remote, incoming: false).rules.count == 5)
    }

    @Test func legacyRulesKeepTheirOnOff() {
        let firedOff = rule("a", enabled: false, at: nil, lastFired: 1_000).migratedFromLegacy()
        #expect(!firedOff.isOn && firedOff.fired == 1_000)
        let reEnabled = rule("b", enabled: true, at: nil, lastFired: 1_000).migratedFromLegacy()
        #expect(reEnabled.isOn && reEnabled.ack == 1_000)
        let fresh = rule("c", at: 5).migratedFromLegacy()
        #expect(fresh == rule("c", at: 5))
    }

    @Test func noCloudCopyLeavesLocalAlone() {
        let local = [rule("a", at: 100)]
        #expect(merge(local, nil, removed: ["x": 1]) == .init(rules: local, removed: ["x": 1]))
    }

    @Test func tombstonesAreCapped() {
        let many = Dictionary(uniqueKeysWithValues: (0..<250).map { ("id\($0)", TimeInterval($0)) })
        let m = merge([], CloudAlerts(), removed: many, incoming: false)
        #expect(m.removed.count == PriceAlertSync.maxTombstones)
        #expect(m.removed["id249"] != nil && m.removed["id0"] == nil)   // the oldest go first
    }

    @Test func encodingIsStable() {
        let a = CloudAlerts(rules: [rule("a", at: 1, fired: 5, ack: 3).cloud], removed: ["x": 1, "y": 2, "z": 3])
        #expect(a.encoded() == CloudAlerts.decode(a.encoded())?.encoded())
        #expect(CloudAlerts.decode(a.encoded()) == a)
        // A kind this version doesn't know makes the whole copy unreadable (review #5: left alone).
        let future = String(data: a.encoded()!, encoding: .utf8)!.replacingOccurrences(of: "\"above\"", with: "\"volume\"")
        #expect(CloudAlerts.decode(future.data(using: .utf8)) == nil)
    }
}
