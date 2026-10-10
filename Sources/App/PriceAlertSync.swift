import Foundation

// ============================================================
// Price alerts over iCloud
// ------------------------------------------------------------
// The alert rules (and the 推送时段) follow the user to their other
// devices through CloudSync (iCloud key-value store). Each device
// still registers its own APNs token with the worker, so an alert
// pushes to every device that has notifications on.
//
// The rules merge one by one instead of the whole list winning:
// each carries `changedAt`, the time of its last user change (added,
// edited, switched) or of the firing that switched it off, and the
// newer copy wins; a deletion leaves a tombstone. lastFired/deferred
// stay per device — they describe this device's own server record.
// ============================================================

/// One rule as stored in iCloud: what the user set up, none of this device's server state.
struct CloudAlertRule: Codable, Equatable {
    var id: String
    var kind: PriceAlertRule.Kind
    var value: Double
    var window: Int
    var enabled: Bool
    /// Unix seconds; 0 for a rule saved before sync existed.
    var changedAt: TimeInterval
}

/// The `alerts.sync` blob CloudSync mirrors to iCloud.
struct CloudAlerts: Codable, Equatable {
    var rules: [CloudAlertRule] = []
    /// Deleted rule id → when it was deleted (unix seconds).
    var removed: [String: TimeInterval] = [:]

    var isEmpty: Bool { rules.isEmpty && removed.isEmpty }

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

extension PriceAlertRule {
    var cloud: CloudAlertRule {
        CloudAlertRule(id: id, kind: kind, value: value, window: window, enabled: enabled, changedAt: changedAt ?? 0)
    }

    init(cloud c: CloudAlertRule) {
        self.init(id: c.id, kind: c.kind, value: c.value, window: c.window, enabled: c.enabled, changedAt: c.changedAt)
    }

    func hasSameCondition(as other: PriceAlertRule) -> Bool {
        kind == other.kind && value == other.value && window == other.window
    }

    /// This device's rule taken over by a newer copy from another device. A changed
    /// condition is a new alert, so this device's fired state goes (the worker resets it too).
    func adopting(_ c: CloudAlertRule) -> PriceAlertRule {
        var r = self
        let sameCondition = kind == c.kind && value == c.value && window == c.window
        r.kind = c.kind; r.value = c.value; r.window = c.window
        r.enabled = c.enabled
        r.changedAt = c.changedAt
        if !sameCondition { r.lastFired = nil; r.deferred = nil }
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
    /// `changedAt` wins (a tie goes to iCloud, so every device settles on the same
    /// copy); a tombstone at least as new as the rule deletes it.
    ///
    /// `incoming`: the iCloud copy just arrived from another device. Its order
    /// wins, and a rule only this device has whose condition matches one of
    /// iCloud's is dropped — the same alert set up on two devices before they
    /// synced. For a local edit the local order stands and nothing is dropped.
    static func merge(local: [PriceAlertRule], removed: [String: TimeInterval],
                      cloud: CloudAlerts?, incoming: Bool) -> Merged {
        guard let cloud else { return Merged(rules: local, removed: removed) }
        var gone = removed.merging(cloud.removed, uniquingKeysWith: max)
        let mine = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let theirs = Dictionary(cloud.rules.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func resolve(_ id: String) -> PriceAlertRule? {
            let r: PriceAlertRule
            switch (mine[id], theirs[id]) {
            case let (l?, c?): r = c.changedAt >= (l.changedAt ?? 0) ? l.adopting(c) : l
            case let (l?, nil): r = l
            case let (nil, c?): r = PriceAlertRule(cloud: c)
            case (nil, nil): return nil
            }
            if let t = gone[id], t >= (r.changedAt ?? 0) { return nil }
            return r
        }

        let order = incoming ? cloud.rules.map(\.id) + local.map(\.id) : local.map(\.id) + cloud.rules.map(\.id)
        var seen = Set<String>()
        var rules = order.filter { seen.insert($0).inserted }.compactMap(resolve)
        if incoming {
            let shared = rules.filter { theirs[$0.id] != nil }
            rules.removeAll { r in theirs[r.id] == nil && shared.contains { $0.hasSameCondition(as: r) } }
        }
        if gone.count > maxTombstones {
            gone = Dictionary(uniqueKeysWithValues: gone.sorted { $0.value > $1.value }.prefix(maxTombstones).map { ($0.key, $0.value) })
        }
        return Merged(rules: rules, removed: gone)
    }
}
