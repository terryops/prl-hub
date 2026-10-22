import Foundation
import CryptoKit

// Account configuration merge; credentials and wallet secrets never enter this model.

/// PKCE keeps a callback intercepted by another app from becoming a session.
enum AccountPKCE {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func random() -> String { encode(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }) }
    static func challenge(_ verifier: String) -> String { encode(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func code(_ url: URL, state: String) -> String? {
        guard url.scheme == "prlhub", url.host == "account", url.path.isEmpty,
              let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              q.filter({ $0.name == "state" }).count == 1, q.first(where: { $0.name == "state" })?.value == state,
              q.filter({ $0.name == "code" }).count == 1, let code = q.first(where: { $0.name == "code" })?.value,
              code.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else { return nil }
        return code
    }
}

/// The wire format has explicit allowlists. Unknown local fields never enter the account.
enum AccountConfig {
    static func clean(_ config: [String: Any]) -> [String: Any] {
        let fields = ["lang", "monitors", "wallets", "rules", "window", "settingsUpdated", "calculator", "contacts", "autoRefresh", "monitorOrder", "secondary", "theme", "devices", "fleetSettings"]
        func pick(_ value: [String: Any], _ keys: [String]) -> [String: Any] { value.filter { keys.contains($0.key) } }
        var out = pick(config, fields)
        for (field, keys) in [("monitors", ["pool", "addr", "acct", "label", "alert", "after", "paused"]), ("wallets", ["addr", "label"]), ("rules", ["kind", "value", "window", "enabled", "seen_fired", "repeat"]), ("contacts", ["name", "address", "note"]), ("devices", ["name", "gpu", "count", "rented", "hoursPerDay", "customPearl", "rentDaily", "rentCurrency", "rentFX", "sourceKey"])] {
            out[field] = ((out[field] as? [[String: Any]]) ?? []).map { pick($0, $0["deleted"] as? Bool == true ? ["id", "updated", "deleted"] : ["id", "updated", "deleted"] + keys) }
        }
        if let c = out["calculator"] as? [String: Any] { out["calculator"] = pick(c, ["gpu", "count", "th", "watts", "hardware", "hours", "fee", "electricity", "rent", "rented", "rentCoversPower", "growth", "price", "yield", "networkHash"]) }
        if let w = out["window"] as? [String: Any] { out["window"] = pick(w, ["start", "end", "tz"]) }
        if let o = out["monitorOrder"] as? [String: Any] { out["monitorOrder"] = pick(o, ["ids", "updated"]) }
        if let f = out["fleetSettings"] as? [String: Any] {
            var clean = pick(f, ["powerBudgetW", "powerBudgetEnabled", "syncWPerTH", "selfDilution", "fxManual", "manualFX", "rentEnabled", "growthMode", "sortKey", "selectedGPU"])
            clean["rents"] = ((f["rents"] as? [String: [String: Any]]) ?? [:]).mapValues { pick($0, ["daily", "currency", "fx"]) }
            out["fleetSettings"] = clean
        }
        return out
    }
}

/// Each identity has its own native cache as well as its shared configuration.
/// Alert runtime copies must switch with alerts.sync instead of being merged
/// from the account that was previously open on this device.
enum AccountPreferences {
    static var keys: Set<String> {
        WebLinkStore.watchedKeys.union(["alerts.rules", "alerts.removed", "alerts.unsynced"])
    }
    static func snapshot(_ uid: String?, defaults d: UserDefaults = .standard) {
        d.set(Dictionary(uniqueKeysWithValues: keys.compactMap { key in d.object(forKey: key).map { (key, $0) } }),
              forKey: "account.prefs." + (uid ?? "guest"))
    }
    static func restore(_ uid: String?, defaults d: UserDefaults = .standard) {
        let values = d.dictionary(forKey: "account.prefs." + (uid ?? "guest")) ?? [:]
        for key in keys {
            if let value = values[key] { d.set(value, forKey: key) }
            else { d.removeObject(forKey: key) }
        }
    }
    /// At launch: make the live preferences those of whoever is signed in (`uid`; nil for
    /// nobody), keeping the previous identity's as its own. `willChange` runs first, so the
    /// stores can save what they are still holding. Returns whether they changed hands.
    @discardableResult
    static func adopt(_ uid: String?, defaults d: UserDefaults = .standard, willChange: () -> Void = {}) -> Bool {
        defer { d.removeObject(forKey: "account.pendingPrefs") }
        let previous = d.string(forKey: "account.current")
        if let uid {
            defer { d.set(uid, forKey: "account.current") }
            // Recover a terminated account switch before any live preferences can sync.
            if d.string(forKey: "account.pendingPrefs") == uid { willChange(); restore(uid, defaults: d); return true }
            guard previous != uid else { return false }
            willChange(); snapshot(previous, defaults: d); restore(uid, defaults: d)
            return true
        }
        guard let previous else { return false }
        // The session is gone (a backup restored onto a new phone leaves the Keychain
        // behind) but the live preferences are still that account's. Keep them as its own
        // before going back to the guest's: signing in again would otherwise restore the
        // copy from the first login, and the merge would upload everything added since as
        // deleted.
        willChange(); snapshot(previous, defaults: d); restore(nil, defaults: d)
        d.removeObject(forKey: "account.current")
        return true
    }
}


/// One monitor as the web configuration holds it (web/src/types.ts `Monitor`).
struct WebMonitor: Codable, Equatable {
    var pool: String
    /// Payout address, or the key of F2Pool's read-only page.
    var addr: String
    /// F2Pool only: the account name the page was shared under.
    var acct: String?
    var label: String
    /// 掉线提醒 on.
    var alert: Bool
    /// Seconds offline before the push.
    var after: Int
    var paused: Bool

    /// The same monitor with the same settings. The threshold only counts while the alert is on.
    func matches(_ o: WebMonitor) -> Bool {
        sameTarget(as: o) && (acct ?? "") == (o.acct ?? "") && label == o.label
            && alert == o.alert && paused == o.paused && (!alert || after == o.after)
    }

    func sameTarget(as o: WebMonitor) -> Bool { pool == o.pool && addr == o.addr }

    /// What the web gets for one of the app's monitors; nil when the web would refuse it
    /// (it validates every entry and rejects the whole configuration over one bad one).
    init?(_ w: PoolWatch, minutes: Int?) {
        pool = w.pool.rawValue
        if w.pool.isAddressBased {
            guard let a = normalizeWatchAddress(w.pool, w.address) else { return nil }
            addr = a
        } else {
            guard let ref = F2PoolRef(w.address), Self.isKey(ref.key) else { return nil }
            addr = ref.key
            let name = ref.account
            if !name.isEmpty, name.count <= 64 { acct = name }
        }
        label = String(w.displayName.prefix(40))
        let m = minutes.flatMap { OfflineAlertStore.choices.contains($0) ? $0 : nil }
        alert = m != nil
        after = (m ?? OfflineAlertStore.choices[0]) * 60
        paused = !w.isEnabled
    }

    /// One entry of the web's `monitors`; nil for a tombstone or anything this build can't show.
    init?(json o: [String: Any]) {
        guard let pool = o["pool"] as? String, PoolKind(rawValue: pool) != nil,
              let addr = o["addr"] as? String, let label = o["label"] as? String,
              let alert = o["alert"] as? Bool else { return nil }
        let after = (o["after"] as? NSNumber)?.intValue ?? OfflineAlertStore.choices[0] * 60
        if alert, !OfflineAlertStore.choices.contains(where: { $0 * 60 == after }) { return nil }
        self.pool = pool
        self.addr = addr
        self.acct = (o["acct"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        self.label = label
        self.alert = alert
        self.after = after
        self.paused = o["paused"] as? Bool ?? false
        guard watch(id: UUID()) != nil else { return nil }
    }

    /// This monitor as one of the app's, under `id`.
    func watch(id: UUID) -> PoolWatch? {
        guard let kind = PoolKind(rawValue: pool) else { return nil }
        let address: String
        if kind.isAddressBased {
            guard let a = normalizeWatchAddress(kind, addr) else { return nil }
            address = a
        } else {
            guard Self.isKey(addr) else { return nil }
            var c = URLComponents()
            c.scheme = "https"
            c.host = "www.f2pool.com"
            c.path = "/mining-user-prl/\(addr)"
            if let acct, !acct.isEmpty { c.queryItems = [URLQueryItem(name: "user_name", value: acct)] }
            guard let url = c.string, let a = normalizeWatchAddress(kind, url) else { return nil }
            address = a
        }
        var w = PoolWatch(id: id, pool: kind, address: address)
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != kind.label { w.alias = name }
        if paused { w.enabled = false }
        return w
    }

    /// Minutes for 掉线提醒, or nil when it is off.
    var minutes: Int? { alert ? after / 60 : nil }

    fileprivate func write(into o: inout [String: Any]) {
        o["pool"] = pool
        o["addr"] = addr
        o["acct"] = acct
        o["label"] = label
        o["alert"] = alert
        o["after"] = after
        o["paused"] = paused
    }

    /// The web's rule for an F2Pool key: 16–64 lowercase hex.
    private static func isKey(_ s: String) -> Bool {
        (16...64).contains(s.utf8.count) && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// What the app holds, as the merge reads it.
struct WebLinkLocal: Equatable {
    /// In card order.
    var watches: [PoolWatch]
    /// 掉线提醒: monitor → minutes.
    var minutes: [UUID: Int]
    /// The price alerts as iCloud has them; nil when this build can't read the stored copy
    /// (a later version wrote it), and the alerts are then left alone on both sides.
    var alerts: CloudAlerts?
    var window: PushWindow?
}

/// What both sides agreed on at the last sync. Kept on this device only.
struct WebLinkBase: Codable, Equatable {
    var shared: WebSharedBase?
    struct Monitor: Codable, Equatable {
        /// The app's monitor this web entry stands for.
        var local: UUID
        var content: WebMonitor
        var updated: Int64
    }
    /// Web id → the monitor.
    var monitors: [String: Monitor] = [:]
    /// Web ids in card order, and the stamp that order carried.
    var order: [String] = []
    var orderUpdated: Int64 = 0
    /// false until the first sync: `window` nil then means "never compared", not "all day".
    var windowKnown = false
    var window: PushWindow?
}

struct WebLinkOutcome {
    /// What the app should hold afterwards (its `alerts` is not used: see `alerts`).
    var local: WebLinkLocal
    /// The web's alert changes, as an iCloud copy for PriceAlertStore to merge; nil = none.
    var alerts: CloudAlerts?
    /// The web configuration afterwards.
    var config: [String: Any]
    /// Whether `config` differs from what the server has.
    var upload: Bool
    var base: WebLinkBase
}

enum WebLinkMerge {
    /// The web's cap on monitors, and on price alerts (web/src/store.ts `normalizeConfig`).
    /// One entry over and it refuses the whole configuration, so the app never adds past it.
    static let maxLive = 20

    /// A fresh configuration, for a code no browser has saved anything under yet. The web
    /// insists on the three lists being there.
    static func emptyConfig(lang: String) -> [String: Any] {
        ["lang": lang, "monitors": [Any](), "wallets": [Any](), "rules": [Any](), "window": NSNull(), "settingsUpdated": 0]
    }

    /// `remote`: the decrypted configuration, nil when the server has none. `now`: unix ms.
    static func merge(local: WebLinkLocal, base: WebLinkBase, remote: [String: Any]?,
                      timeZone: String, lang: String, now: Int64) -> WebLinkOutcome {
        var config = remote ?? emptyConfig(lang: lang)
        var out = WebLinkOutcome(local: local, alerts: nil, config: config, upload: false, base: base)

        let m = monitors(local: local, base: base, remote: list(config["monitors"]),
                         remoteOrder: order(config["monitorOrder"]), now: now)
        out.local.watches = m.watches
        out.local.minutes = m.minutes
        out.base.monitors = m.base
        out.base.order = m.order
        out.base.orderUpdated = m.orderUpdated
        if m.changed {
            config["monitors"] = m.remote
            out.upload = true
        }
        if m.uploadOrder {
            config["monitorOrder"] = ["ids": m.order, "updated": m.orderUpdated] as [String: Any]
            out.upload = true
        }

        if let alerts = local.alerts {
            let r = rules(local: alerts, remote: list(config["rules"]), now: now)
            out.alerts = r.incoming
            if r.changed {
                config["rules"] = r.remote
                out.upload = true
            }
        }

        let theirs = window(config["window"])
        let changedHere = base.windowKnown ? local.window != base.window : local.window != nil
        if changedHere, local.window.map({ webAccepts($0) }) ?? true {
            if theirs != local.window {
                if let w = local.window {
                    config["window"] = ["start": w.start, "end": w.end, "tz": timeZone] as [String: Any]
                } else {
                    config["window"] = NSNull()
                }
                // The web keeps one stamp for its settings; a newer one makes this change win there.
                config["settingsUpdated"] = max(now, int(config["settingsUpdated"]) + 1)
                out.upload = true
            }
        } else if !changedHere {
            out.local.window = theirs
        }
        out.base.window = out.local.window
        out.base.windowKnown = true

        out.config = config
        return out
    }

    // MARK: monitors

    struct Monitors {
        var watches: [PoolWatch]
        var minutes: [UUID: Int]
        var remote: [[String: Any]]
        var changed = false
        var base: [String: WebLinkBase.Monitor] = [:]
        var order: [String] = []
        var orderUpdated: Int64 = 0
        var uploadOrder = false
    }

    private struct Entry {
        var raw: [String: Any]
        var updated: Int64
        var deleted: Bool
        /// nil for a tombstone, and for a live entry this build can't show.
        var monitor: WebMonitor?
        /// A live entry this build can't read: left exactly as it is, on both sides.
        var opaque: Bool { !deleted && monitor == nil }
    }

    static func monitors(local: WebLinkLocal, base: WebLinkBase, remote: [[String: Any]],
                         remoteOrder: (ids: [String], updated: Int64)?, now: Int64) -> Monitors {
        var out = Monitors(watches: local.watches, minutes: local.minutes, remote: remote)
        var entries: [String: Entry] = [:]
        var position: [String: Int] = [:]
        for (i, o) in remote.enumerated() {
            guard let id = o["id"] as? String, entries[id] == nil else { continue }
            let deleted = o["deleted"] as? Bool ?? false
            entries[id] = Entry(raw: o, updated: int(o["updated"]), deleted: deleted,
                                monitor: deleted ? nil : WebMonitor(json: o))
            position[id] = i
        }
        var live = entries.values.filter { !$0.deleted }.count

        // Which web entry each of the app's monitors stands for.
        var webID: [UUID: String] = [:]
        var claimed = Set<String>()
        let here = Set(local.watches.map(\.id))
        for (id, b) in base.monitors.sorted(by: { $0.key < $1.key }) where here.contains(b.local) && webID[b.local] == nil {
            webID[b.local] = id
            claimed.insert(id)
        }
        // One the web made keeps the web's spelling of its id (lowercase; the app's are uppercase).
        for id in remote.compactMap({ $0["id"] as? String }) where !claimed.contains(id) {
            guard let u = UUID(uuidString: id), here.contains(u), webID[u] == nil else { continue }
            webID[u] = id
            claimed.insert(id)
        }
        // The same monitor set up on both sides before they were linked is one monitor.
        var twins = Set<UUID>()
        for w in local.watches where webID[w.id] == nil {
            guard let mine = WebMonitor(w, minutes: local.minutes[w.id]) else { continue }
            let twin = remote.compactMap { $0["id"] as? String }.first {
                !claimed.contains($0) && entries[$0]?.monitor?.sameTarget(as: mine) == true
            }
            guard let twin else { continue }
            webID[w.id] = twin
            claimed.insert(twin)
            twins.insert(w.id)
        }
        for w in local.watches where webID[w.id] == nil { webID[w.id] = w.id.uuidString }

        func put(_ id: String, _ m: WebMonitor, stamp: Int64) -> Bool {
            let wasLive = entries[id].map { !$0.deleted } ?? false
            if !wasLive {
                guard live < maxLive else { return false }
                live += 1
            }
            var o = entries[id]?.raw ?? [:]
            o["id"] = id
            o["updated"] = stamp
            o["deleted"] = nil
            m.write(into: &o)
            if let i = position[id] { out.remote[i] = o } else { position[id] = out.remote.count; out.remote.append(o) }
            out.changed = true
            return true
        }

        /// Whether another of the app's monitors already watches what `w` would.
        func taken(_ w: PoolWatch) -> Bool {
            out.watches.contains { $0.id != w.id && $0.pool == w.pool && $0.address == w.address }
        }

        func adopt(_ m: WebMonitor, for id: UUID) -> Bool {
            guard let i = out.watches.firstIndex(where: { $0.id == id }), let w = m.watch(id: id), !taken(w) else { return false }
            out.watches[i].pool = w.pool
            out.watches[i].address = w.address
            out.watches[i].alias = w.alias
            // A monitor that was never paused has no `enabled` key at all: keep it that way.
            if m.paused { out.watches[i].enabled = false } else if out.watches[i].enabled == false { out.watches[i].enabled = nil }
            out.minutes[id] = m.minutes
            return true
        }

        for w in local.watches {
            guard let id = webID[w.id] else { continue }
            let known = base.monitors[id].flatMap { $0.local == w.id ? $0 : nil }
            let theirs = entries[id]
            guard var mine = WebMonitor(w, minutes: local.minutes[w.id]), theirs?.opaque != true else {
                out.base[id] = known     // nothing to compare: neither changed nor deleted
                continue
            }
            var stamp = now
            if let known {
                stamp = known.content.matches(mine) ? known.updated : max(now, known.updated + 1)
            } else if twins.contains(w.id), let t = theirs?.monitor, !t.matches(mine) {
                // Never compared before: keep what either side had set up.
                if !w.hasAlias { mine.label = t.label }
                if t.alert, !mine.alert { mine.alert = true; mine.after = t.after }
                stamp = max(now, (theirs?.updated ?? 0) + 1)
                _ = adopt(mine, for: w.id)
            }
            if let theirs, !theirs.deleted, let t = theirs.monitor {
                if t.matches(mine) {
                    out.base[id] = .init(local: w.id, content: t, updated: theirs.updated)
                } else if stamp > theirs.updated {
                    if put(id, mine, stamp: stamp) { out.base[id] = .init(local: w.id, content: mine, updated: stamp) }
                } else if adopt(t, for: w.id) {
                    out.base[id] = .init(local: w.id, content: t, updated: theirs.updated)
                } else {
                    out.base[id] = known
                }
            } else if let theirs, theirs.deleted, stamp <= theirs.updated {
                out.watches.removeAll { $0.id == w.id }
                out.minutes[w.id] = nil
            } else if put(id, mine, stamp: stamp) {
                out.base[id] = .init(local: w.id, content: mine, updated: stamp)
            }
        }

        // Deleted here since the last sync.
        for (id, b) in base.monitors.sorted(by: { $0.key < $1.key }) where !here.contains(b.local) {
            guard let theirs = entries[id], !theirs.deleted, let t = theirs.monitor else { continue }
            let stamp = max(now, b.updated + 1)
            if stamp > theirs.updated {
                if let i = position[id] { out.remote[i] = ["id": id, "updated": stamp, "deleted": true] }
                live -= 1
                out.changed = true
            } else if let w = t.watch(id: b.local), !taken(w) {
                // Changed on the web after it was deleted here: it comes back.
                out.watches.append(w)
                out.minutes[b.local] = t.minutes
                webID[b.local] = id
                out.base[id] = .init(local: b.local, content: t, updated: theirs.updated)
            }
        }

        // Added on the web.
        let mapped = Set(webID.values)
        for id in remote.compactMap({ $0["id"] as? String }) where !mapped.contains(id) && base.monitors[id] == nil {
            guard let e = entries[id], let t = e.monitor else { continue }
            let uuid = UUID(uuidString: id).flatMap { u in out.watches.contains { $0.id == u } ? nil : u } ?? UUID()
            guard let w = t.watch(id: uuid), !taken(w) else { continue }
            out.watches.append(w)
            out.minutes[uuid] = t.minutes
            webID[uuid] = id
            out.base[id] = .init(local: uuid, content: t, updated: e.updated)
        }

        // Card order: one value, the later change wins.
        let before = local.watches.compactMap { webID[$0.id] }
        let wasKnown = Set(base.order), isHere = Set(before)
        let reordered = before.filter(wasKnown.contains) != base.order.filter(isHere.contains)
        // The app only has an order to send when the cards were rearranged here, or — the
        // first time — when it brought monitors of its own and the web has no order yet.
        var mine = base.orderUpdated
        var rearranged = reordered
        if base.order.isEmpty {
            mine = remoteOrder == nil ? now : 0
            rearranged = !local.watches.isEmpty
        } else if reordered {
            mine = max(now, base.orderUpdated + 1)
        }
        if let theirs = remoteOrder, theirs.updated >= mine {
            let rank = Dictionary(theirs.ids.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
            out.watches = out.watches.enumerated().sorted { a, b in
                let ra = webID[a.element.id].flatMap { rank[$0] } ?? Int.max
                let rb = webID[b.element.id].flatMap { rank[$0] } ?? Int.max
                return ra != rb ? ra < rb : a.offset < b.offset
            }.map(\.element)
            out.orderUpdated = theirs.updated
        } else {
            out.orderUpdated = mine
        }
        out.order = out.watches.compactMap { webID[$0.id] }.filter { out.base[$0] != nil }
        if let theirs = remoteOrder, theirs.updated >= mine {} else if rearranged, !out.order.isEmpty, remoteOrder?.ids != out.order {
            out.uploadOrder = true
        }
        return out
    }

    // MARK: price alerts

    struct Rules {
        /// The alerts as iCloud should now have them, when the web changed any.
        var incoming: CloudAlerts?
        var remote: [[String: Any]]
        var changed = false
    }

    private struct RuleEntry {
        var raw: [String: Any]
        var updated: Int64
        var deleted: Bool
        var kind: PriceAlertRule.Kind?
        var value = 0.0
        var window = 0
        var enabled = false
        var repeats = false
        /// Worker time of the latest firing the web has seen.
        var seen = 0.0
        var opaque: Bool { !deleted && kind == nil }
    }

    /// Whether the alert is live: a one-shot alert that fired is off until it is switched back on.
    static func isOn(_ r: CloudAlertRule) -> Bool { r.enabled && (r.repeats == true || r.fired <= r.ack) }

    /// The web's stamp for this rule. A firing switches it off there like a change would,
    /// so an alert that is off because it fired counts as changed at that firing.
    static func stamp(_ r: CloudAlertRule) -> Int64 {
        ms(max(r.changedAt, r.repeats != true && r.fired > r.ack ? r.fired : 0))
    }

    static func rules(local: CloudAlerts, remote: [[String: Any]], now: Int64) -> Rules {
        var out = Rules(remote: remote)
        var blob = local
        var touched = false
        var entries: [String: RuleEntry] = [:]
        var position: [String: Int] = [:]
        for (i, o) in remote.enumerated() {
            guard let id = o["id"] as? String, entries[id] == nil else { continue }
            var e = RuleEntry(raw: o, updated: int(o["updated"]), deleted: o["deleted"] as? Bool ?? false)
            if !e.deleted, let kind = (o["kind"] as? String).flatMap(PriceAlertRule.Kind.init(rawValue:)),
               let value = (o["value"] as? NSNumber)?.doubleValue, let enabled = o["enabled"] as? Bool {
                e.kind = kind
                e.value = value
                e.window = (o["window"] as? NSNumber)?.intValue ?? 0
                e.enabled = enabled
                e.repeats = o["repeat"] as? Bool ?? false
                e.seen = (o["seen_fired"] as? NSNumber)?.doubleValue ?? 0
            }
            entries[id] = e
            position[id] = i
        }
        var live = entries.values.filter { !$0.deleted }.count

        func put(_ r: CloudAlertRule) {
            guard webAccepts(r) else { return }
            let wasLive = entries[r.id].map { !$0.deleted } ?? false
            if !wasLive {
                guard live < maxLive else { return }
                live += 1
            }
            var o = entries[r.id]?.raw ?? [:]
            o["id"] = r.id
            o["updated"] = stamp(r)
            o["deleted"] = nil
            o["kind"] = r.kind.rawValue
            o["value"] = r.value
            o["window"] = r.window
            o["enabled"] = isOn(r)
            o["repeat"] = r.repeats == true
            o["seen_fired"] = Int(max(r.ack, r.fired, entries[r.id]?.seen ?? 0))
            if let i = position[r.id] { out.remote[i] = o } else { position[r.id] = out.remote.count; out.remote.append(o) }
            out.changed = true
        }

        func bury(_ id: String, stamp: Int64) {
            guard let i = position[id] else { return }
            out.remote[i] = ["id": id, "updated": stamp, "deleted": true]
            live -= 1
            out.changed = true
        }

        func fromWeb(_ id: String, _ e: RuleEntry, after previous: TimeInterval = 0) -> CloudAlertRule? {
            guard let kind = e.kind else { return nil }
            return CloudAlertRule(id: id, kind: kind, value: e.value, window: e.window, enabled: e.enabled,
                                  changedAt: max(Double(e.updated) / 1000, previous, 1), fired: 0, ack: 0, repeats: e.repeats)
        }

        for r in local.rules {
            guard let e = entries[r.id] else { put(r); continue }
            if e.opaque { continue }
            if e.deleted {
                if stamp(r) > e.updated { put(r); continue }
                blob.rules.removeAll { $0.id == r.id }
                blob.removed[r.id] = max(Double(e.updated) / 1000, r.changedAt)
                touched = true
                continue
            }
            let same = e.kind == r.kind && e.value == r.value && e.window == r.window
            let sameFrequency = e.repeats == (r.repeats == true)
            if same, sameFrequency, e.enabled == isOn(r) { continue }
            if stamp(r) > e.updated { put(r); continue }
            // The web's copy is the later one. It reaches the app as another device's would.
            var c = r
            if !same {
                guard let edited = fromWeb(r.id, e, after: r.changedAt) else { continue }
                c = edited          // another condition is another alert: its firings don't carry over
            } else if !sameFrequency {
                c.repeats = e.repeats
                c.enabled = e.enabled
                c.ack = max(r.ack, r.fired, e.seen)
                c.changedAt = max(Double(e.updated) / 1000, r.changedAt)
            } else if e.enabled {
                c.enabled = true    // switched back on there: every firing so far has been seen
                c.ack = max(r.ack, r.fired, e.seen)
                c.changedAt = max(Double(e.updated) / 1000, r.changedAt)
            } else if !e.repeats, e.seen > max(r.ack, r.fired) {
                c.fired = e.seen    // it fired there: off here too, without the user having touched it
            } else {
                c.enabled = false
                c.changedAt = max(Double(e.updated) / 1000, r.changedAt)
            }
            guard c != r, let i = blob.rules.firstIndex(where: { $0.id == r.id }) else { continue }
            blob.rules[i] = c
            touched = true
        }

        // Deleted here.
        let mine = Set(local.rules.map(\.id))
        for (id, t) in local.removed.sorted(by: { $0.key < $1.key }) where !mine.contains(id) {
            guard let e = entries[id], !e.deleted, !e.opaque else { continue }
            if ms(t) >= e.updated {
                bury(id, stamp: ms(t))
            } else if let back = fromWeb(id, e) {
                blob.rules.append(back)     // changed on the web after it was deleted here
                touched = true
            }
        }

        // Added on the web. The same condition set up on both sides is one alert: the app's
        // copy stays (it carries the firings), the web's goes.
        for id in remote.compactMap({ $0["id"] as? String }) where !mine.contains(id) && local.removed[id] == nil {
            guard let e = entries[id], !e.deleted, let added = fromWeb(id, e) else { continue }
            if local.rules.contains(where: { $0.kind == added.kind && $0.value == added.value && $0.window == added.window && ($0.repeats == true) == (added.repeats == true) }) {
                bury(id, stamp: max(now, e.updated + 1))
                continue
            }
            guard blob.rules.count < maxLive else { continue }
            blob.rules.append(added)
            touched = true
        }

        if touched { out.incoming = blob }
        return out
    }

    /// web/src/store.ts `ruleOK`.
    private static func webAccepts(_ r: CloudAlertRule) -> Bool {
        guard r.id.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil, r.value.isFinite else { return false }
        switch r.kind {
        case .move: return r.value >= 0.5 && r.value < 1000.01 && [300, 3600, 86400].contains(r.window)
        case .above, .below: return r.value >= 0.01 && r.value < 1e6 && r.window == 0
        }
    }

    // MARK: reading the configuration

    private static func webAccepts(_ w: PushWindow) -> Bool {
        (0..<1440).contains(w.start) && (0..<1440).contains(w.end) && w.start != w.end
    }

    private static func window(_ v: Any?) -> PushWindow? {
        guard let o = v as? [String: Any], let s = (o["start"] as? NSNumber)?.intValue,
              let e = (o["end"] as? NSNumber)?.intValue else { return nil }
        let w = PushWindow(start: s, end: e)
        return webAccepts(w) ? w : nil
    }

    private static func order(_ v: Any?) -> (ids: [String], updated: Int64)? {
        guard let o = v as? [String: Any], let ids = o["ids"] as? [String] else { return nil }
        return (ids, int(o["updated"]))
    }

    private static func list(_ v: Any?) -> [[String: Any]] { v as? [[String: Any]] ?? [] }

    private static func int(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }

    /// Unix seconds → the web's milliseconds, rounded UP: a stamp sent to the web must never
    /// read as older than the change it stands for.
    private static func ms(_ t: TimeInterval) -> Int64 { Int64((t * 1000).rounded(.up)) }
}

// Non-secret settings shared by the browser and native app. The baseline is local
// to the link, so only an actual native edit creates a newer web timestamp.
struct WebSharedBase: Codable, Equatable {
    var items: [String: [String: Data]] = [:]
    var settings: [String: Data] = [:]
}
struct WebSharedResult {
    var config: [String: Any]
    var base: WebSharedBase
    var native: [String: Any]
    var upload: Bool
}
enum WebSharedMerge {
    enum Invalid: Error { case config }
    static func encoded(_ value: Any) -> Data {
        if let data = value as? Data { return data }
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
    }
    static let paths = [
        "lang": "app.language", "secondary": "currency.secondary", "theme": "ui.appearance", "autoRefresh": "prl.auto",
        "fleetSettings.selectedGPU": "prl.selected", "calculator.electricity": "prl.elec", "calculator.fee": "prl.fee", "calculator.growth": "prl.diffGrowth",
        "calculator.price": "prl.price", "calculator.yield": "prl.pu", "calculator.networkHash": "prl.neth",
        "calculator.rentCoversPower": "prl.rentCovers", "fleetSettings.powerBudgetW": "prl.budget",
        "fleetSettings.powerBudgetEnabled": "prl.budgetEnabled",
        "fleetSettings.syncWPerTH": "prl.syncW", "fleetSettings.selfDilution": "prl.selfDilution",
        // The rate itself (prl.fx → fleetSettings.manualFX) stays on the device, as it does
        // with iCloud: it is 1 USD in THIS device's currency, so two devices in different
        // currencies overwrote each other's, and a pinned rate priced the other one ~8× off.
        "fleetSettings.fxManual": "prl.fxManual",
        "fleetSettings.rentEnabled": "prl.rentEnabled", "fleetSettings.growthMode": "prl.live",
        "fleetSettings.rents": "prl.rents", "fleetSettings.sortKey": "prl.sort"
    ]
    static var nativeKeys: Set<String> { Set(paths.values).union(["prl.devices", "prl.rentCcy", "prl.rentFX", "wallet.contacts"]) }
    static func value(_ path: String, in config: [String: Any]) -> Any? {
        let parts = path.split(separator: ".").map(String.init)
        return parts.count == 1 ? config[path] : (config[parts[0]] as? [String: Any])?[parts[1]]
    }
    static func put(_ path: String, _ value: Any, into config: inout [String: Any]) {
        let parts = path.split(separator: ".").map(String.init)
        if parts.count == 1 { config[path] = value }
        else { var section = config[parts[0]] as? [String: Any] ?? [:]; section[parts[1]] = value; config[parts[0]] = section }
    }
    static func supported(_ row: [String: Any], section: String) -> Bool {
        guard let id = row["id"] as? String, UUID(uuidString: id) != nil else { return false }
        if row["deleted"] as? Bool == true { return true }
        guard let name = row["name"] as? String else { return false }
        if section == "contacts" {
            return name.count <= 1024 && (row["address"] as? String).map { $0.range(of: "^(t)?prl1[0-9a-z]{20,100}$", options: .regularExpression) != nil } == true
                && (row["note"] == nil || row["note"] is String)
        }
        guard let gpu = row["gpu"] as? String, let count = row["count"] as? Int,
              let hours = row["hoursPerDay"] as? Double, row["rented"] is Bool else { return false }
        guard name.count <= 128 && gpu.count <= 64 && (1...256).contains(count) && hours.isFinite && (0...24).contains(hours) else { return false }
        for key in ["customPearl", "rentDaily"] where row[key] != nil && !(row[key] is NSNull) {
            guard let n = row[key] as? Double, n.isFinite, (0...1e12).contains(n) else { return false }
        }
        if let v = row["rentFX"], !(v is NSNull), !((v as? Double).map { $0.isFinite && $0 > 0 } ?? false) { return false }
        return true
    }
    static func content(_ row: [String: Any], section: String) -> [String: Any] {
        let keys = section == "contacts" ? ["name", "address", "note"] : ["name", "gpu", "count", "rented", "hoursPerDay", "customPearl", "rentDaily", "rentCurrency", "rentFX", "sourceKey"]
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, row[$0] ?? (section == "contacts" && $0 == "note" ? "" : NSNull())) })
    }
    static func merge(local: [String: Any], remote: [String: Any], base previous: WebSharedBase?, now: Int64) throws -> WebSharedResult {
        var config = remote, base = previous ?? WebSharedBase(), native: [String: Any] = [:], upload = false
        for section in ["devices", "contacts"] {
            guard let mine = local[section] as? [[String: Any]] else { continue } // unknown native schema: leave it alone
            if config[section] != nil && !(config[section] is [[String: Any]]) { throw Invalid.config }
            var rows = config[section] as? [[String: Any]] ?? []
            for row in rows {
                if let n = row["updated"] as? NSNumber {
                    guard n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue < 9_007_199_254_740_991, n.doubleValue.rounded(.down) == n.doubleValue else { throw Invalid.config }
                }
            }
            let ids = rows.compactMap { ($0["id"] as? String)?.lowercased() }
            guard ids.count == Set(ids).count else { throw Invalid.config }
            let old = base.items[section] ?? [:]
            var present = Set<String>()
            for var row in mine where supported(row, section: section) {
                var id = (row["id"] as! String).lowercased()
                if section == "contacts", let twin = rows.first(where: { $0["deleted"] as? Bool != true && $0["address"] as? String == row["address"] as? String }), let twinID = twin["id"] as? String, old[id] == nil, UUID(uuidString: twinID) != nil {
                    id = twinID.lowercased(); row["id"] = twinID
                }
                present.insert(id)
                let index = rows.firstIndex { ($0["id"] as? String)?.lowercased() == id }
                let changed = old[id].map { $0 != encoded(content(row, section: section)) } ?? (index == nil)
                if changed {
                    var next = index.map { rows[$0] } ?? [:]
                    for (key, value) in content(row, section: section) { next[key] = value }
                    next["id"] = index.flatMap { rows[$0]["id"] as? String } ?? row["id"]
                    next.removeValue(forKey: "deleted")
                    next["updated"] = max(now, (next["updated"] as? NSNumber)?.int64Value ?? 0) + 1
                    if let index { rows[index] = next } else { rows.append(next) }
                    upload = true
                }
            }
            for id in old.keys where !present.contains(id) {
                if let i = rows.firstIndex(where: { ($0["id"] as? String)?.lowercased() == id }), rows[i]["deleted"] as? Bool != true {
                    if let prior = old[id].flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }), prior["deleted"] as? Bool == true,
                       ((rows[i]["updated"] as? NSNumber)?.int64Value ?? 0) > ((prior["updated"] as? NSNumber)?.int64Value ?? 0) { continue }
                    rows[i]["deleted"] = true; rows[i]["updated"] = max(now, (rows[i]["updated"] as? NSNumber)?.int64Value ?? 0) + 1; upload = true
                }
            }
            let adopted = rows.filter { supported($0, section: section) && $0["deleted"] as? Bool != true }
            native[section] = adopted
            base.items[section] = Dictionary(uniqueKeysWithValues: rows.filter { supported($0, section: section) }.map {
                (($0["id"] as! String).lowercased(), encoded($0["deleted"] as? Bool == true ? ["deleted": true, "updated": $0["updated"] ?? 0] : content($0, section: section)))
            })
            config[section] = rows
        }
        if let mine = local["wallets"] as? [[String: Any]] {
            if config["wallets"] != nil && !(config["wallets"] is [[String: Any]]) { throw Invalid.config }
            let w = wallets(mine, remote: config["wallets"] as? [[String: Any]] ?? [], base: base.items["wallets"] ?? [:], now: now)
            config["wallets"] = w.rows; base.items["wallets"] = w.base
            upload = upload || w.changed
        }
        for path in paths.keys.sorted() {
            let mine = local[path], theirs = value(path, in: config), agreed = base.settings[path]
            // One setting that can't be shared must not stop the rest. A value here that the
            // account can't hold (a language that follows the system, a slider parked outside
            // the range) stays out of the sync both ways; one on the account this build can't
            // read is left there and not adopted.
            if let mine, !validSetting(path, mine) { continue }
            let changed = mine.map { value in agreed.map { $0 != encoded(value) } ?? (theirs == nil) } ?? false
            if changed, let mine {
                put(path, mine, into: &config); native[path] = mine; base.settings[path] = encoded(mine); upload = true
            } else if let theirs {
                guard validSetting(path, theirs) else { continue }
                native[path] = theirs; base.settings[path] = encoded(theirs)
            } else if let mine { native[path] = mine; base.settings[path] = encoded(mine) }
        }
        if upload {
            if let n = config["settingsUpdated"] as? NSNumber {
                guard n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue < 9_007_199_254_740_991, n.doubleValue.rounded(.down) == n.doubleValue else { throw Invalid.config }
            }
            config["settingsUpdated"] = max(now, (config["settingsUpdated"] as? NSNumber)?.int64Value ?? 0) + 1
        }
        return WebSharedResult(config: config, base: base, native: native, upload: upload)
    }
    // MARK: wallets

    /// The web's cap on watch addresses (web/src/store.ts `normalizeConfig`); one more and it
    /// refuses the whole configuration.
    static let maxWallets = 10

    /// The app's wallets as entries of the web's 钱包 page (read-only watch addresses): the
    /// mainnet receive address at index 0 under the wallet's name. The id comes from the
    /// address, so the same wallet on a phone and a Mac is one entry and two different
    /// wallets never share one. Wallets without a cached mainnet address are left out.
    static func walletRows(_ records: [WalletRecord]) -> [[String: Any]] {
        var seen = Set<String>()
        return records.compactMap { r in
            guard let addr = r.addresses[WalletNetwork.mainnet.rawValue], addr.range(of: "^prl1[0-9a-z]{20,100}$", options: .regularExpression) != nil,
                  seen.insert(addr).inserted else { return nil }
            let digest = SHA256.hash(data: Data(addr.utf8)).map { String(format: "%02x", $0) }.joined()
            var label = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty { label = "Pearl Wallet" }
            // The web counts UTF-16 units; drop whole characters until it fits.
            while label.utf16.count > 40 { label.removeLast() }
            return ["id": "w-" + digest.prefix(32), "addr": addr, "label": label]
        }
    }

    /// One way only: the web's own watch addresses never become wallets here, and an entry
    /// renamed or removed there stays that way until the wallet itself changes here.
    /// `base`: id → what this device last sent.
    static func wallets(_ mine: [[String: Any]], remote: [[String: Any]], base old: [String: Data], now: Int64)
        -> (rows: [[String: Any]], base: [String: Data], changed: Bool) {
        var rows = remote, base: [String: Data] = [:], changed = false
        let isLive = { (row: [String: Any]) in row["deleted"] as? Bool != true }
        let stamp = { (row: [String: Any]) in max(now, (row["updated"] as? NSNumber)?.int64Value ?? 0) + 1 }
        var live = rows.filter(isLive).count
        for row in mine {
            guard let id = row["id"] as? String, let addr = row["addr"] as? String, let label = row["label"] as? String else { continue }
            let content = encoded(["addr": addr, "label": label])
            if old[id] == content { base[id] = content; continue }
            let index = rows.firstIndex { $0["id"] as? String == id }
            // The web already watches this address under an entry of its own: no twin.
            if rows.contains(where: { isLive($0) && $0["addr"] as? String == addr && $0["id"] as? String != id }) { continue }
            let wasLive = index.map { isLive(rows[$0]) } ?? false
            if !wasLive && live >= maxWallets { continue }   // full: try again on a later sync
            var next = index.map { rows[$0] } ?? [:]
            next["id"] = id; next["addr"] = addr; next["label"] = label
            next.removeValue(forKey: "deleted")
            next["updated"] = stamp(next)
            if let index { rows[index] = next } else { rows.append(next) }
            if !wasLive { live += 1 }
            base[id] = content; changed = true
        }
        // A wallet removed here leaves a tombstone for the entry it put there.
        for id in old.keys where base[id] == nil {
            guard let i = rows.firstIndex(where: { $0["id"] as? String == id }), isLive(rows[i]) else { continue }
            rows[i] = ["id": id, "deleted": true, "updated": stamp(rows[i])]
            changed = true
        }
        return (rows, base, changed)
    }

    static func read(_ d: UserDefaults) -> [String: Any] {
        var local: [String: Any] = [:]
        let rates = d.data(forKey: "currency.rates").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Double] } ?? [:]
        let rentCode = rentCurrency(d)
        let savedRentRate = d.double(forKey: "prl.rentFX")
        let rentRate = rentCode == "USD" ? 1 : rates[rentCode] ?? (savedRentRate > 0 ? savedRentRate : d.double(forKey: "prl.fx") > 0 ? d.double(forKey: "prl.fx") : 7.2)
        let live = d.object(forKey: "prl.live") == nil || d.bool(forKey: "prl.live")
        for section in ["devices", "contacts"] {
            let key = section == "devices" ? "prl.devices" : "wallet.contacts"
            if let data = d.data(forKey: key) {
                guard var rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { continue }
                if section == "devices" {
                    for i in rows.indices {
                        if rows[i]["rentDaily"] != nil && rows[i]["rentCurrency"] == nil { rows[i]["rentCurrency"] = rentCode; rows[i]["rentFX"] = rentRate }
                    }
                }
                local[section] = rows
            } else { local[section] = [[String: Any]]() }
        }
        if let data = d.data(forKey: "wallet.list") {
            if let records = try? JSONDecoder().decode([WalletRecord].self, from: data) { local["wallets"] = walletRows(records) }
        } else { local["wallets"] = [[String: Any]]() }
        // Following the system language is this device's own choice: say so (a value the
        // account can't hold), or the merge would see no language here and adopt the
        // account's, turning "follow the system" off again on every sync.
        if (d.string(forKey: "app.language") ?? "system") == "system" { local["lang"] = NSNull() }
        for (path, key) in paths {
            guard let raw = d.object(forKey: key) else { continue }
            if path == "lang", raw as? String == "system" { continue }
            if path == "fleetSettings.sortKey" {
                if let raw = raw as? String, let sort = SortKey(rawValue: raw) { local[path] = sort.accountValue }
            }
            else if path == "calculator.fee" { local[path] = d.double(forKey: key) * 100 }
            else if path == "calculator.networkHash" { local[path] = live ? NSNull() : d.double(forKey: key) * 1e18 }
            else if path == "calculator.price" || path == "calculator.yield" { local[path] = live ? NSNull() : raw }
            else if path == "calculator.growth", live { continue }
            else if path == "fleetSettings.growthMode" { local[path] = d.bool(forKey: key) ? "auto" : "manual" }
            else if path == "fleetSettings.rents", let data = raw as? Data, let rents = try? JSONSerialization.jsonObject(with: data) as? [String: Double] {
                local[path] = rents.mapValues { ["daily": $0, "currency": rentCode, "fx": rentRate] as [String: Any] }
            } else { local[path] = raw }
        }
        return local
    }
    static func rentCurrency(_ d: UserDefaults) -> String {
        if let saved = d.string(forKey: "prl.rentCcy"), saved.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil { return saved }
        if d.string(forKey: "currency.secondary") == "" { return "USD" }
        if let saved = d.string(forKey: "currency.secondary"), saved.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil { return saved }
        let defaults = ["zh-Hans": "CNY", "zh-Hant": "TWD", "ru": "RUB", "vi": "VND", "id": "IDR", "ja": "JPY", "ko": "KRW", "fr": "EUR", "de": "EUR", "it": "EUR", "pt-BR": "BRL", "tr": "TRY", "hi": "INR", "th": "THB"]
        let language = d.string(forKey: "app.language") ?? "system"
        if language == "system" || language == "es" {
            let region = Locale.current.currency?.identifier ?? "USD"
            return ["CNY", "TWD", "HKD", "RUB", "VND", "IDR", "EUR", "JPY", "KRW", "GBP", "SGD", "AUD", "CAD", "BRL", "TRY", "INR", "THB", "USD"].contains(region) ? region : "USD"
        }
        return defaults[language] ?? "USD"
    }
    static func validSetting(_ path: String, _ value: Any) -> Bool {
        if ["calculator.price", "calculator.yield", "calculator.networkHash"].contains(path), value is NSNull { return true }
        if ["autoRefresh", "calculator.rentCoversPower", "fleetSettings.powerBudgetEnabled", "fleetSettings.selfDilution", "fleetSettings.fxManual", "fleetSettings.rentEnabled"].contains(path) { return value is Bool }
        if path == "lang" { return (value as? String).map { ["en", "ru", "zh-Hans", "zh-Hant", "vi", "id", "es", "pt-BR", "fr", "de", "it", "tr", "ja", "ko", "hi", "th"].contains($0) } ?? false }
        if path == "theme" { return (value as? String).map { ["system", "light", "dark"].contains($0) } ?? false }
        if path == "secondary" { return (value as? String).map { $0 == "" || $0 == "__auto__" || $0.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil } ?? false }
        if path == "fleetSettings.growthMode" { return (value as? String).map { ["auto", "manual"].contains($0) } ?? false }
        if path == "fleetSettings.sortKey" { return (value as? String).flatMap { SortKey(accountValue: $0) } != nil }
        if path == "fleetSettings.selectedGPU" { return (value as? String).map { $0.count <= 64 } ?? false }
        if path == "fleetSettings.rents" {
            guard let rents = value as? [String: [String: Any]] else { return false }
            return rents.values.allSatisfy { rent in
                guard let daily = rent["daily"] as? Double, daily.isFinite, daily >= 0, rent["currency"] is String else { return false }
                return rent["fx"].map { $0 is NSNull || (($0 as? Double).map { $0.isFinite && $0 > 0 } ?? false) } ?? true
            }
        }
        let bounds: [String: ClosedRange<Double>] = ["calculator.electricity": 0...1000, "calculator.fee": 0...100, "calculator.growth": -98...10000, "calculator.price": 0.000000001...1e9, "calculator.yield": 0.000000001...1e9, "calculator.networkHash": 0.000000001...1e30, "fleetSettings.powerBudgetW": 500...30000, "fleetSettings.syncWPerTH": 0...5]
        return (value as? Double).map { $0.isFinite && (bounds[path]?.contains($0) ?? false) } ?? false
    }
    static func apply(_ values: [String: Any], to d: UserDefaults, dryRun: Bool = false) throws -> [String] {
        var writes: [(String, Any)] = []
        for section in ["devices", "contacts"] {
            if let rows = values[section] as? [[String: Any]] {
                let key = section == "devices" ? "prl.devices" : "wallet.contacts"
                // Keep future native fields; the app's Codable stores can ignore them.
                var old = d.data(forKey: key).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
                let foreign = old.filter { !supported($0, section: section) }
                old = rows.map { row in var out = row; out.removeValue(forKey: "updated"); out.removeValue(forKey: "deleted"); return out } + foreign
                writes.append((key, try JSONSerialization.data(withJSONObject: old, options: .sortedKeys)))
            }
        }
        let rates = d.data(forKey: "currency.rates").flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Double] } ?? [:]
        // Keep incoming rents in their source currency. The app converts them for
        // display, so a simultaneous language/currency change cannot reprice rent
        // using this device's old preferences or stale FX table.
        for (path, key) in paths {
            guard let value = values[path] else { continue }
            guard validSetting(path, value) else { throw Invalid.config }
            if path == "fleetSettings.rents", let rents = value as? [String: [String: Any]] {
                var converted: [String: Double] = [:]
                let firstRent = rents.keys.sorted().first.flatMap { rents[$0] }
                let rentCode = firstRent?["currency"] as? String ?? rentCurrency(d)
                let sourceRate = firstRent?["fx"] as? Double
                let targetRate = rentCode == "USD" ? 1 : rates[rentCode] ?? sourceRate ?? 1
                guard targetRate.isFinite && targetRate > 0 else { throw Invalid.config }
                for (name, rent) in rents {
                    guard let daily = rent["daily"] as? Double, daily >= 0, daily.isFinite, let code = rent["currency"] as? String,
                          let rate = code == "USD" ? 1 : rates[code] ?? rent["fx"] as? Double, rate.isFinite, rate > 0 else { throw Invalid.config }
                    converted[name] = daily / rate * targetRate
                }
                writes.append((key, try JSONSerialization.data(withJSONObject: converted, options: .sortedKeys)))
                writes.append(("prl.rentCcy", rentCode)); writes.append(("prl.rentFX", targetRate))
            } else if path == "fleetSettings.sortKey", let raw = value as? String, let sort = SortKey(accountValue: raw) { writes.append((key, sort.rawValue))
            } else if path == "calculator.fee", let n = value as? Double, (0...100).contains(n) { writes.append((key, n / 100)) }
            else if path == "calculator.networkHash", let n = value as? Double, n > 0, n.isFinite { writes.append((key, n / 1e18)) }
            else if path == "fleetSettings.growthMode", let mode = value as? String, ["auto", "manual"].contains(mode) { writes.append((key, mode == "auto")) }
            else if value is NSNull { continue }
            else if value is String || value is NSNumber { writes.append((key, value)) }
            else { throw Invalid.config }
        }
        // Validate everything before mutating any store.
        var changed: [String] = []
        for (key, value) in writes where d.object(forKey: key).map({ encoded($0) }) != encoded(value) {
            if !dryRun { d.set(value, forKey: key) }; changed.append(key)
        }
        return changed
    }
}
