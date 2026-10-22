import SwiftUI
import Combine

// ============================================================
// 掉线提醒 (remote push)
// ------------------------------------------------------------
// The app can't watch a pool while it is closed, so — as with
// price alerts — the checking runs on the worker (repo alerts/,
// src/watch.js): it asks the pool about each registered monitor
// every 3 minutes and pushes once a worker has been offline for
// the time the user chose (10 minutes to 2 hours) — and, if the
// user asked for it, once more if the worker is still offline
// some time after that push (30 minutes to 4 hours).
//
// It is opt-in per monitor, and switching it on is what sends
// that monitor's pool and payout address (for F2Pool, the key of
// its read-only page) to the worker. Monitors without an alert
// send nothing.
//
// This store holds only WHAT to watch: the choice (monitor id →
// minutes), which lives in `pool.alerts`, and the reminder (monitor
// id → minutes after the first push) in `pool.alertsAgain`; both
// follow the user over iCloud. Getting it to the worker is PriceAlertStore's job — it
// owns this device's one record there (APNs token, permission,
// 推送时段, the Mac's 本机推送 switch, retries) and sends the
// monitors along with the price alerts in the same request.
// ============================================================

/// One monitor as the worker gets it.
struct OfflineAlertWire: Equatable {
    var id: String
    var pool: String
    /// Payout address, or the key of F2Pool's read-only page.
    var addr: String
    /// F2Pool only: the account name the page was shared under.
    var acct: String?
    /// The monitor's name, for the push text.
    var label: String
    /// Seconds offline before the push.
    var after: Int
    /// Seconds after that push to remind once if the worker is still offline; 0 = never.
    var again: Int = 0

    var payload: [String: Any] {
        var o: [String: Any] = ["id": id, "pool": pool, "addr": addr, "label": label, "after": after]
        if let acct { o["acct"] = acct }
        // Only when set: a worker from before reminders reads a missing one as none anyway.
        if again > 0 { o["again"] = again }
        return o
    }

    /// The worker's list for these monitors: the ones that are running, have an alert and
    /// carry an identifier the worker accepts (it refuses the whole list over one bad entry).
    static func list(watches: [PoolWatch], minutes: [UUID: Int], again: [UUID: Int] = [:],
                     max: Int = OfflineAlertStore.maxWatches) -> [OfflineAlertWire] {
        var out: [OfflineAlertWire] = []
        for w in watches where w.isEnabled {
            guard out.count < max, let m = minutes[w.id], OfflineAlertStore.choices.contains(m) else { continue }
            let r = again[w.id].flatMap { OfflineAlertStore.againChoices.contains($0) ? $0 : nil } ?? 0
            var item = OfflineAlertWire(id: w.id.uuidString, pool: w.pool.rawValue, addr: "",
                                        label: String(w.displayName.prefix(40)), after: m * 60, again: r * 60)
            if w.pool.isAddressBased {
                guard let a = normalizeWatchAddress(w.pool, w.address) else { continue }
                item.addr = a
            } else {
                guard let ref = F2PoolRef(w.address), ref.key.count <= 64 else { continue }
                item.addr = ref.key
                let name = ref.account
                if !name.isEmpty, name.count <= 64, !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
                    item.acct = name
                }
            }
            out.append(item)
        }
        return out
    }
}

@MainActor
final class OfflineAlertStore: ObservableObject {
    static let shared = OfflineAlertStore()

    /// The thresholds on offer, in minutes. The pools themselves take about ten minutes
    /// to notice a worker has stopped, so nothing shorter would mean anything.
    nonisolated static let choices = [10, 15, 30, 60, 90, 120]
    /// The reminder's delays on offer, in minutes after the first push.
    nonisolated static let againChoices = [30, 60, 120, 240]
    /// The worker's cap on monitors per device.
    nonisolated static let maxWatches = 20
    /// iCloud-synced (CloudSync): monitor id → minutes.
    nonisolated static let key = "pool.alerts"
    /// iCloud-synced: monitor id → minutes after the first push. A key of its own, so
    /// builds from before reminders read `pool.alerts` exactly as they always did.
    nonisolated static let againKey = "pool.alertsAgain"

    /// Monitor id → minutes offline before the push. No entry = no alert.
    @Published private(set) var minutes: [UUID: Int] = [:]
    /// Monitor id → minutes after the push to remind once more. No entry = no reminder.
    /// Kept while the alert is off (it only counts with one), so switching the alert
    /// back on brings it back.
    @Published private(set) var again: [UUID: Int] = [:]
    /// The user's monitors, as stored (PoolStore owns them; this is a read-only copy).
    @Published private(set) var watches: [PoolWatch] = []
    /// Monitors the pool says it doesn't know (a mistyped address, a revoked F2Pool link):
    /// there is nothing for the worker to watch.
    @Published private(set) var missing: Set<UUID> = []
    /// Monitors whose pool hasn't answered the worker for a while (down, or refusing it):
    /// nothing can be noticed until it does.
    @Published private(set) var stale: Set<UUID> = []

    /// Choices this build can't use (a threshold a newer version added), kept verbatim
    /// and written back on every save — dropping them would delete them from iCloud
    /// for the newer devices too.
    private var foreign: [String: Int] = [:]
    private var foreignAgain: [String: Int] = [:]
    private var cloudSub: AnyCancellable?

    /// What the worker should watch for this user: the monitors that are running and
    /// have an alert. PriceAlertStore sends it (or nothing, without Pro).
    private(set) var wire: [OfflineAlertWire] = []

    /// How many monitors have an alert that is actually running.
    var activeCount: Int { wire.count }

    /// Whether any of the user's monitors has an alert chosen (running or not).
    var hasAnyAlert: Bool { watches.contains { minutes[$0.id] != nil } }

    init() {
        let d = UserDefaults.standard
        (minutes, foreign) = Self.split(d.data(forKey: Self.key))
        (again, foreignAgain) = Self.split(d.data(forKey: Self.againKey), choices: Self.againChoices)
        watches = PoolStore.storedWatches()
        wire = OfflineAlertWire.list(watches: watches, minutes: minutes, again: again).sorted { $0.id < $1.id }
        cloudSub = NotificationCenter.default.publisher(for: .cloudSyncDidUpdate).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cloudDidUpdate() }
    }

    // MARK: choices

    func threshold(for id: UUID) -> Int? { minutes[id] }

    /// "10 分钟", "2 小时": how a threshold or a reminder's delay reads.
    nonisolated static func durationText(_ minutes: Int) -> String {
        minutes >= 60 && minutes % 60 == 0 ? Loc("%d 小时", minutes / 60) : Loc("%d 分钟", minutes)
    }

    /// One monitor's alert in words, with its reminder if it has one.
    nonisolated static func summary(minutes: Int, again: Int?) -> String {
        guard let again else { return Loc("矿机离线满 %@时通知", durationText(minutes)) }
        return Loc("离线满 %1$@时通知，%2$@后再提醒一次", durationText(minutes), durationText(again))
    }

    /// The reminder for one monitor, while its alert is on.
    func reminder(for id: UUID) -> Int? { minutes[id] == nil ? nil : again[id] }

    /// Whether another monitor can still be given an alert (the worker's cap). Counts
    /// the monitors that exist: a choice left behind by one deleted on an older version
    /// (or lost to iCloud) must not use up a slot.
    var canAddMore: Bool { watches.filter { minutes[$0.id] != nil }.count < Self.maxWatches }

    /// The user's choice for one monitor; nil switches its alert off.
    func set(_ id: UUID, minutes m: Int?) {
        guard minutes[id] != m || foreign[id.uuidString] != nil else { return }
        if let m {
            guard Self.choices.contains(m), minutes[id] != nil || canAddMore else { return }
            minutes[id] = m
        } else {
            minutes[id] = nil
        }
        // The user has now decided for this monitor: a value kept aside for it (one a
        // newer version chose, which this build can't show) must not be written back.
        foreign[id.uuidString] = nil
        save()
        // Switching one on is the moment to ask for notifications: it is clear what for.
        contentChanged(prompt: m != nil)
    }

    /// The reminder for one monitor; nil switches it off.
    func setReminder(_ id: UUID, minutes m: Int?) {
        guard again[id] != m || foreignAgain[id.uuidString] != nil else { return }
        if let m {
            guard Self.againChoices.contains(m), minutes[id] != nil else { return }
        }
        again[id] = m
        foreignAgain[id.uuidString] = nil
        saveAgain()
        contentChanged(prompt: false)
    }

    /// A monitor was deleted: its alert goes with it. (PoolStore saves right after,
    /// and `watchesChanged` tells the worker.)
    func forget(_ id: UUID) {
        if again[id] != nil || foreignAgain[id.uuidString] != nil {
            again[id] = nil
            foreignAgain[id.uuidString] = nil
            saveAgain()
        }
        guard minutes[id] != nil || foreign[id.uuidString] != nil else { return }
        minutes[id] = nil
        foreign[id.uuidString] = nil
        save()
    }

    /// PoolStore saved its monitors (added, edited, paused, renamed, reordered).
    func watchesChanged() {
        let w = PoolStore.storedWatches()
        guard w != watches else { return }     // a save that changed nothing we show or send
        watches = w
        contentChanged(prompt: false)
    }

    /// Choices or monitors changed on another device.
    private func cloudDidUpdate() {
        let (m, rest) = Self.split(UserDefaults.standard.data(forKey: Self.key))
        let (r, restAgain) = Self.split(UserDefaults.standard.data(forKey: Self.againKey), choices: Self.againChoices)
        let w = PoolStore.storedWatches()
        foreign = rest
        foreignAgain = restAgain
        guard m != minutes || r != again || w != watches else { return }
        minutes = m
        again = r
        watches = w
        contentChanged(prompt: false)
    }

    /// Rebuild what the worker should watch and, if that changed, have PriceAlertStore
    /// bring the device's record in line. `prompt`: it may ask for notification
    /// permission — only when the user just did something here.
    private func contentChanged(prompt: Bool) {
        // In a fixed order: the worker doesn't care how the cards are arranged, so
        // dragging two alerting monitors around is not a change worth a request.
        let list = OfflineAlertWire.list(watches: watches, minutes: minutes, again: again).sorted { $0.id < $1.id }
        guard list != wire else { return }
        wire = list
        PriceAlertStore.shared.contentChanged(prompt: prompt)
    }

    private func save() {
        Self.store(minutes, foreign: foreign, key: Self.key)
        CloudSync.push(Self.key)
    }

    private func saveAgain() {
        Self.store(again, foreign: foreignAgain, key: Self.againKey)
        CloudSync.push(Self.againKey)
    }

    /// Write one of the two maps as stored: what this build uses plus what it kept aside.
    nonisolated static func store(_ map: [UUID: Int], foreign: [String: Int], key: String, defaults d: UserDefaults = .standard) {
        var raw = foreign
        for (id, m) in map { raw[id.uuidString] = m }
        if raw.isEmpty { d.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(raw) { d.set(data, forKey: key) }
    }

    /// Stored choices → the ones this build can use.
    nonisolated static func decode(_ data: Data?) -> [UUID: Int] { split(data).known }

    /// Stored choices → (usable, the rest as stored). The rest is kept, never shown.
    /// `choices`: the values on offer — the thresholds, or for `againKey` the reminders.
    nonisolated static func split(_ data: Data?, choices: [Int] = choices) -> (known: [UUID: Int], foreign: [String: Int]) {
        guard let data, let raw = try? JSONDecoder().decode([String: Int].self, from: data) else { return ([:], [:]) }
        var known: [UUID: Int] = [:], rest: [String: Int] = [:]
        for (k, v) in raw {
            if let id = UUID(uuidString: k), choices.contains(v) { known[id] = v } else { rest[k] = v }
        }
        return (known, rest)
    }

    // MARK: the worker's view

    /// The `watches` part of the worker's reply (PriceAlertStore hands it over): which
    /// monitors the pool can't find, and which it can't be asked about right now.
    func adopt(_ list: [[String: Any]]) {
        var gone: Set<UUID> = [], quiet: Set<UUID> = []
        for w in list {
            guard let id = (w["id"] as? String).flatMap(UUID.init(uuidString:)) else { continue }
            if w["missing"] as? Bool == true { gone.insert(id) }
            if w["stale"] as? Bool == true { quiet.insert(id) }
        }
        if gone != missing { missing = gone }
        if quiet != stale { stale = quiet }
    }
}
