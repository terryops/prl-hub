import Foundation

// ============================================================
// Price alerts over iCloud
// ------------------------------------------------------------
// The alert rules (and the 推送时段) follow the user to their other
// devices through CloudSync (iCloud key-value store). Each device
// registers its own APNs token with the worker, so an alert pushes to
// every device that has notifications on (a Mac can opt out:
// PriceAlertStore.pushHere).
//
// Rules merge one by one instead of the whole list winning:
//  • user changes (add, edit, switch, delete) carry `changedAt`; the
//    newer copy wins and a deletion leaves a tombstone. Stamps always
//    move forward from the copy being changed, so a slow clock can't
//    undo its own change.
//  • firings are worker timestamps: `fired` merges by max, `ack` is what
//    the user had seen when they last switched the rule on. A firing
//    never outranks a user change, so it can't bring a deleted rule back.
// lastFired/deferred stay per device — this device's own server record.
// ============================================================

/// One rule as stored in iCloud: what the user set up plus when it last fired,
/// none of this device's own server state.
struct CloudAlertRule: Codable, Equatable {
    var id: String
    var kind: PriceAlertRule.Kind
    var value: Double
    var window: Int
    var enabled: Bool
    /// Unix seconds; 0 for a rule saved before sync existed.
    var changedAt: TimeInterval
    /// Worker time of the latest firing on any device; 0 = none.
    var fired: TimeInterval
    /// Worker time the user had seen when they last switched it on; 0 = none.
    var ack: TimeInterval
    /// Optional for alerts saved before continuous reminders were available.
    var repeats: Bool?
}

/// The `alerts.sync` blob CloudSync mirrors to iCloud.
struct CloudAlerts: Codable, Equatable {
    var rules: [CloudAlertRule] = []
    /// Deleted rule id → when it was deleted (unix seconds).
    var removed: [String: TimeInterval] = [:]

    var isEmpty: Bool { rules.isEmpty && removed.isEmpty }

    /// nil when `data` is nil or can't be read — e.g. a later version added an alert
    /// kind this one doesn't know. The caller must then leave the iCloud copy alone.
    static func decode(_ data: Data?) -> CloudAlerts? {
        data.flatMap { try? JSONDecoder().decode(CloudAlerts.self, from: $0) }
    }

    /// Sorted keys, so the same content always encodes to the same bytes and
    /// CloudSync.push can tell it is already current.
    func encoded() -> Data? {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return try? e.encode(self)
    }
}

private func nonZero(_ t: TimeInterval) -> TimeInterval? { t > 0 ? t : nil }

extension PriceAlertRule {
    var cloud: CloudAlertRule {
        CloudAlertRule(id: id, kind: kind, value: value, window: window, enabled: enabled,
                       changedAt: changedAt ?? 0, fired: fired ?? 0, ack: ack ?? 0, repeats: repeats)
    }

    init(cloud c: CloudAlertRule) {
        self.init(id: c.id, kind: c.kind, value: c.value, window: c.window, enabled: c.enabled,
                  repeats: c.repeats, changedAt: c.changedAt, fired: nonZero(c.fired), ack: nonZero(c.ack))
    }

    /// This device's rule taken over by a newer copy from another device. A changed
    /// condition is a new alert, so this device's fired state goes (the worker resets it too).
    func adopting(_ c: CloudAlertRule) -> PriceAlertRule {
        var r = self
        if !hasSameCondition(kind: c.kind, value: c.value, window: c.window) { r.lastFired = nil; r.deferred = nil }
        r.kind = c.kind; r.value = c.value; r.window = c.window
        r.enabled = c.enabled
        r.repeats = c.repeats
        r.changedAt = c.changedAt
        r.fired = nonZero(c.fired)
        r.ack = nonZero(c.ack)
        return r
    }
}

enum PriceAlertSync {
    /// Tombstones kept; a device that stayed offline past this many deletions
    /// could bring an old rule back.
    static let maxTombstones = 200

    struct Merged: Equatable {
        var rules: [PriceAlertRule]
        var removed: [String: TimeInterval]
    }

    /// Merge this device's rules with the iCloud copy. Per rule the newer
    /// `changedAt` wins; at the same `changedAt` iCloud's copy is taken (so every
    /// device settles on it) with the later firing of the two. This device's own
    /// firings are folded in either way. A tombstone at least as new as the rule
    /// deletes it.
    ///
    /// `incoming`: the iCloud copy just arrived from another device. Its order
    /// wins, and a rule saved before sync that only this device has is dropped when
    /// iCloud holds the same condition — the same alert set up on both devices
    /// before they synced. For a local edit the local order stands.
    static func merge(local: [PriceAlertRule], removed: [String: TimeInterval],
                      cloud: CloudAlerts?, incoming: Bool) -> Merged {
        guard let cloud else { return Merged(rules: local, removed: removed) }
        var gone = removed.merging(cloud.removed, uniquingKeysWith: max)
        let mine = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let theirs = Dictionary(cloud.rules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func resolve(_ id: String) -> PriceAlertRule? {
            var r: PriceAlertRule
            switch (mine[id], theirs[id]) {
            case let (l?, c?):
                let lc = l.changedAt ?? 0
                if c.changedAt > lc { r = l.adopting(c) }
                else if c.changedAt < lc { r = l }
                else {
                    r = l.adopting(c)
                    r.fired = nonZero(max(l.fired ?? 0, c.fired))
                    r.ack = nonZero(max(l.ack ?? 0, c.ack))
                }
            case let (l?, nil): r = l
            case let (nil, c?): r = PriceAlertRule(cloud: c)
            case (nil, nil): return nil
            }
            r.fired = nonZero(max(r.fired ?? 0, r.lastFired?.timeIntervalSince1970 ?? 0))
            if let t = gone[id], t >= (r.changedAt ?? 0) { return nil }
            return r
        }

        let order = incoming ? cloud.rules.map(\.id) + local.map(\.id) : local.map(\.id) + cloud.rules.map(\.id)
        var seen = Set<String>()
        var rules = order.filter { seen.insert($0).inserted }.compactMap(resolve)
        if incoming {
            let shared = rules.filter { theirs[$0.id] != nil }
            rules.removeAll { r in
                theirs[r.id] == nil && (r.changedAt ?? 0) <= 0 && shared.contains { $0.hasSameCondition(as: r) && $0.isRepeating == r.isRepeating }
            }
        }
        if gone.count > maxTombstones {
            gone = Dictionary(uniqueKeysWithValues: gone.sorted { $0.value > $1.value }.prefix(maxTombstones).map { ($0.key, $0.value) })
        }
        return Merged(rules: rules, removed: gone)
    }
}
