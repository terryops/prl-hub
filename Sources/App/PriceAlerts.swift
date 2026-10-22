import SwiftUI
import Combine
import UserNotifications
import Security
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// ============================================================
// PRL price alerts (remote push)
// ------------------------------------------------------------
// The app itself can't watch the price while it's closed, so the
// checking runs server-side: a Cloudflare Worker (repo alerts/)
// polls the price every minute and pushes through APNs. The app
// only registers this device's APNs token plus its alert rules;
// nothing about the wallet ever leaves the device.
//
// Rules live locally (UserDefaults) and are the source of truth:
// every change re-sends the whole set with PUT, which the worker
// diffs so unchanged rules keep their fired/armed state. The
// token can rotate, so each launch re-registers and re-syncs.
// By default a pushed alert switches itself off on the server;
// the app adopts that from every reply. Users can opt each rule
// into repeating notifications after its condition resets.
//
// 推送时段 (1.16): pushes can be limited to a daily window of local
// time (default: all day). An alert that fires outside it is queued
// by the worker and pushed at the next window start.
//
// The rules and the window also sync over iCloud to the user's other
// devices (PriceAlertSync.swift); each device registers on its own.
//
// This store also owns the device's ONE record on the worker — the
// APNs token, the permission, the window, the Mac's 本机推送 switch,
// retries — and the same PUT carries the 掉线提醒 monitors
// (OfflineAlertStore) next to the price rules.
// ============================================================

/// Daily push window in local time: [start, end) in minutes after midnight;
/// end < start runs past midnight (e.g. 22:00–02:00).
struct PushWindow: Codable, Equatable {
    var start: Int
    var end: Int

    static let `default` = PushWindow(start: 8 * 60, end: 23 * 60)

    func contains(minute m: Int) -> Bool {
        start < end ? (m >= start && m < end) : (m >= start || m < end)
    }

    /// "08:00" in the user's clock style, in the in-app language ("8:00 AM" / "上午8:00").
    static func timeText(_ minutes: Int) -> String {
        let d = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        return d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(LocBundleHolder.shared.locale))
    }
}

struct PriceAlertRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case above, below, move }

    var id = UUID().uuidString
    var kind: Kind
    /// USD for above/below, percent for move.
    var value: Double
    /// move only: 300, 3600 or 86400 seconds.
    var window: Int = 0
    /// Switched on by the user (synced). Whether it is live right now: `isOn`.
    var enabled = true
    /// nil in older saved rules: reminders default to one-shot.
    var repeats: Bool?
    /// Last time the server pushed this rule to THIS device (from the worker's reply).
    var lastFired: Date?
    /// Fired during quiet hours; the push waits for the next window start
    /// (from the worker's reply). Optional so older saved rules still decode.
    var deferred: Bool?
    /// Unix seconds of the last user change (added, edited, switched, deleted — here
    /// or on another device). Decides which copy wins in the iCloud merge; a firing
    /// never moves it. nil for rules saved before sync existed.
    var changedAt: TimeInterval?
    /// Latest firing of this condition on any of the user's devices — the worker's
    /// clock, never the phone's. Synced, merged by max.
    var fired: TimeInterval?
    /// Firings up to this worker time had been seen when the user last switched the
    /// rule on. Synced.
    var ack: TimeInterval?

    /// Repeating alerts remain on after firing; one-shot alerts stay off until
    /// switched back on. Only worker timestamps are compared.
    var isRepeating: Bool { repeats == true }
    var isOn: Bool { enabled && (isRepeating || (fired ?? 0) <= (ack ?? 0)) }

    /// When the alert last went out, on any device.
    var lastPushed: Date? { fired.map { Date(timeIntervalSince1970: $0) } ?? lastFired }

    func hasSameCondition(kind k: Kind, value v: Double, window w: Int) -> Bool {
        kind == k && value == v && window == w
    }

    func hasSameCondition(as other: PriceAlertRule) -> Bool {
        hasSameCondition(kind: other.kind, value: other.value, window: other.window)
    }

    /// A stamp for a user change to a rule last changed at `previous`: now, but
    /// always after `previous`, so a clock that runs behind another device's (or the
    /// copy it is editing) can't lose its own change in the merge.
    static func stamp(after previous: TimeInterval?) -> TimeInterval {
        max(Date().timeIntervalSince1970, (previous ?? 0) + 0.001)
    }

    /// This rule as edited to `edited`'s condition, keeping its id. A changed
    /// condition is a new alert: switched on, fired state cleared (the worker resets
    /// it too) — an edited one-shot alert that had fired used to stay off. An
    /// unchanged condition keeps its on/off and fired state.
    func applyingEdit(_ edited: PriceAlertRule) -> PriceAlertRule {
        if hasSameCondition(as: edited) {
            guard isRepeating != edited.isRepeating else { return self }
            var r = self
            r.repeats = edited.isRepeating
            // Keep the threshold's disarmed/cooldown state on the worker. Changing
            // the frequency enables future crossings without sending a duplicate.
            r.enabled = true
            r.ack = max(ack ?? 0, fired ?? 0)
            r.changedAt = Self.stamp(after: changedAt)
            return r
        }
        var r = edited
        r.id = id
        r.enabled = true
        r.lastFired = nil
        r.deferred = nil
        r.fired = nil
        r.ack = nil
        r.changedAt = Self.stamp(after: changedAt)
        return r
    }

    /// A rule saved before sync (one-shot state kept in `enabled` alone), in the
    /// fired/ack terms: same on/off as it had.
    func migratedFromLegacy() -> PriceAlertRule {
        guard fired == nil, let t = lastFired?.timeIntervalSince1970 else { return self }
        var r = self
        r.fired = t
        if enabled, ack == nil { r.ack = t }
        return r
    }

    /// What the worker gets for this rule. `seen_fired` is `ack`, a worker timestamp:
    /// the worker only lets a fired rule back on for an app that has seen that firing
    /// — here or on another device, where the user switched it back on.
    var wire: Wire {
        Wire(id: id, kind: kind, value: value, window: window, on: isOn,
             seen: Int(max(ack ?? 0, lastFired?.timeIntervalSince1970 ?? 0)), repeats: isRepeating)
    }

    struct Wire: Equatable {
        var id: String
        var kind: Kind
        var value: Double
        var window: Int
        var on: Bool
        var seen: Int
        var repeats = false

        fileprivate var payload: [String: Any] {
            ["id": id, "kind": kind.rawValue, "value": value, "window": window, "enabled": on, "seen_fired": seen, "repeat": repeats]
        }
    }
}

/// The worker's own price + moves — the numbers the alerts actually trigger on:
/// SafeTrade's ticker (relayed by alerts/safetrade-push/), or, while that relay
/// is down, the median of CoinEx / BigONE / WhatToMine (alerts/src/price.js).
struct AlertQuote: Equatable {
    var usd: Double
    /// "safetrade" or "median".
    var source: String?
    var change5m: Double?
    var change1h: Double?
    var change24h: Double?
    /// When the worker stored this price (its cron writes one per minute).
    var at: Date?

    /// Fresh enough to show as the current price: the worker keeps answering with
    /// its last stored row even if its cron has stopped, so check the age.
    var isFresh: Bool { at.map { Date().timeIntervalSince($0) < 300 } ?? false }

    static func fetch() async -> AlertQuote? {
        var req = URLRequest(url: PriceAlertStore.endpoint.appendingPathComponent("price"))
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usd = o["usd"] as? Double else { return nil }
        return AlertQuote(usd: usd, source: o["source"] as? String, change5m: o["change5m"] as? Double,
                          change1h: o["change1h"] as? Double, change24h: o["change24h"] as? Double,
                          at: (o["ts"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }
}

@MainActor
final class PriceAlertStore: ObservableObject {
    static let shared = PriceAlertStore()
    private let defaults: UserDefaults

    nonisolated static let endpoint = URL(string: "https://pearlhub.net/v1")!
    /// The worker's cap on rules per device.
    static let maxRules = 20

    enum SyncState: Equatable { case idle, syncing, synced(Date), failed(String) }

    @Published private(set) var rules: [PriceAlertRule] = []
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var syncState: SyncState = .idle
    /// Hex APNs device token, once the system has handed one over.
    @Published private(set) var token: String?
    /// 推送时段; nil = all day (the default).
    @Published private(set) var window: PushWindow?
    /// Whether THIS device gets the pushes (a per-device switch, shown on the Mac).
    /// Off: the worker forgets this device; the rules still sync and can be edited here.
    @Published private(set) var pushHere: Bool

    private static let rulesKey = "alerts.rules"
    /// iCloud copy of the rules (CloudSync mirrors it); merged into `rules`, never read directly.
    nonisolated static let syncKey = "alerts.sync"
    /// Deleted rule ids → when, so a deletion also reaches the other devices.
    private static let removedKey = "alerts.removed"
    nonisolated static let windowKey = "alerts.window"
    private static let pushHereKey = "alerts.pushHere"
    private var removed: [String: TimeInterval] = [:]
    /// Time zone the worker last got with the window — re-sent after travel.
    private var sentTimeZone: String?
    private static let tokenKey = "alerts.apnsToken"
    private static let unsyncedKey = "alerts.unsynced"
    /// A change the worker hasn't confirmed yet. Survives a relaunch, so one made
    /// offline — above all removing the last alert, after which nothing here would
    /// otherwise look worth sending — still reaches the worker later.
    private var unsynced: Bool {
        didSet { if unsynced != oldValue { defaults.set(unsynced, forKey: Self.unsyncedKey) } }
    }
    private var syncTask: Task<Void, Never>?
    private var windowPushTask: Task<Void, Never>?
    /// Bumped on every local edit. A server reply is only adopted if no edit
    /// happened while it was in flight — otherwise a slow reply (e.g. a GET that
    /// raced a toggle's PUT) would put back the state from before the edit.
    private var localVersion = 0
    private var languageSub: AnyCancellable?
    private var proSub: AnyCancellable?
    private var jwsSub: AnyCancellable?
    private var accountProSub: AnyCancellable?
    private var cloudSub: AnyCancellable?
    private var configurationOwner: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        configurationOwner = d.string(forKey: "account.current")
        if let data = d.data(forKey: Self.rulesKey),
           let r = try? JSONDecoder().decode([PriceAlertRule].self, from: data) { rules = r.map { $0.migratedFromLegacy() } }
        if let data = d.data(forKey: Self.removedKey),
           let r = try? JSONDecoder().decode([String: TimeInterval].self, from: data) { removed = r }
        token = d.string(forKey: Self.tokenKey)
        window = Self.savedWindow(defaults)
        pushHere = d.object(forKey: Self.pushHereKey) as? Bool ?? true
        unsynced = d.bool(forKey: Self.unsyncedKey)
        if d.data(forKey: Self.syncKey) == nil {
            // Rules saved before iCloud sync: stage them as this device's iCloud copy, so
            // CloudSync.start uploads them if iCloud has none yet — or, if another device
            // got there first, pulls that copy in and we merge.
            if !rules.isEmpty, let data = CloudAlerts(rules: rules.map(\.cloud)).encoded() {
                d.set(data, forKey: Self.syncKey)
            }
        } else {
            // CloudSync may have pulled before this store existed (its notification then
            // went unheard): merge whatever it left.
            reconcile(incoming: true)
        }
        cloudSub = NotificationCenter.default.publisher(for: .cloudSyncDidUpdate)
            .sink { [weak self] _ in self?.cloudDidUpdate() }
        // The push copy is localized server-side, so a language switch (here or
        // synced from another device) must re-send the rules with the new code.
        languageSub = LocalizationManager.shared.$language.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.languageChanged() }
        // Alerts are a Pro feature: losing Pro (refund) empties the server copy,
        // (re)gaining it re-registers — local rules are kept either way.
        proSub = ProStore.shared.$isPro.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.proChanged() }
        // The signed purchase arrived after registering (StoreKit answered late, or a
        // purchase on another device): hand it to the worker.
        jwsSub = ProStore.shared.$jws.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.jwsChanged() }
        accountProSub = ProStore.shared.$hasAccountPro.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.jwsChanged() }
    }

    // MARK: rules

    func add(_ rule: PriceAlertRule) {
        var r = rule
        r.changedAt = PriceAlertRule.stamp(after: nil)
        rules.append(r)
        rulesChanged()
    }

    /// Save a condition or frequency edit. An unchanged edit saves nothing: the
    /// stored copy may have fired or changed on another device since the editor opened.
    /// A changed condition is a new alert: its fired/armed state resets, server-side too.
    func update(_ edited: PriceAlertRule, from original: PriceAlertRule) {
        guard !edited.hasSameCondition(as: original) || edited.isRepeating != original.isRepeating,
              let i = rules.firstIndex(where: { $0.id == original.id }) else { return }
        let r = rules[i].applyingEdit(edited)
        guard r != rules[i] else { return }
        rules[i] = r
        rulesChanged()
    }

    func remove(at offsets: IndexSet) {
        for i in offsets { removed[rules[i].id] = PriceAlertRule.stamp(after: rules[i].changedAt) }
        rules.remove(atOffsets: offsets)
        rulesChanged()
    }

    func remove(_ rule: PriceAlertRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        remove(at: IndexSet(integer: i))
    }

    /// The user's switch. Switching on also marks every firing so far as seen.
    func setEnabled(_ rule: PriceAlertRule, _ on: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }), rules[i].isOn != on else { return }
        rules[i].enabled = on
        if on { rules[i].ack = max(rules[i].ack ?? 0, rules[i].fired ?? 0) }
        rules[i].changedAt = PriceAlertRule.stamp(after: rules[i].changedAt)
        rulesChanged()
    }

    /// Set (or clear, for all day) the push window. The server keeps queued
    /// alerts; with the window widened they go out on the next tick.
    func setWindow(_ w: PushWindow?) {
        guard w != window else { return }
        window = w
        if let w, let d = try? JSONEncoder().encode(w) { defaults.set(d, forKey: Self.windowKey) }
        else { defaults.removeObject(forKey: Self.windowKey) }
        // Upload once the time picker settles, not on every step of it.
        windowPushTask?.cancel()
        windowPushTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            CloudSync.push(Self.windowKey)
        }
        localVersion += 1
        if hasContent && pushHere { scheduleSync() }
    }

    /// Turn this device's pushes on or off. Off sends the worker an empty rule list,
    /// which drops this device's record.
    func setPushHere(_ on: Bool) {
        guard on != pushHere else { return }
        pushHere = on
        defaults.set(on, forKey: Self.pushHereKey)
        localVersion += 1
        if on { followOnServer(prompt: true) } else { scheduleSync() }
    }

    // MARK: what this device registers

    /// The 掉线提醒 monitors ride on the same device record. (Not touched from init:
    /// the two singletons would wait on each other.)
    private var offline: OfflineAlertStore { .shared }

    /// Whether there is anything here to push for — price alerts or 掉线提醒.
    private var hasContent: Bool { !rules.isEmpty || !offline.wire.isEmpty }

    /// 掉线提醒 changed what it wants watched (a choice, a monitor edited, iCloud).
    func contentChanged(prompt: Bool) {
        localVersion += 1
        followOnServer(prompt: prompt)
    }

    private static func savedWindow(_ defaults: UserDefaults) -> PushWindow? {
        defaults.data(forKey: windowKey).flatMap { try? JSONDecoder().decode(PushWindow.self, from: $0) }
    }

    private func rulesChanged() {
        localVersion += 1
        persist()
        reconcile(incoming: false)
        followOnServer(prompt: true)
    }

    /// Bring this device's server record in line with the rules. `prompt`: may ask
    /// for notification permission — only when the user just did something here.
    private func followOnServer(prompt: Bool) {
        guard pushHere else { return }
        if !hasContent || !ProStore.shared.isPro { scheduleSync() } else { Task { await ensureRegistered(prompt: prompt) } }
    }

    // MARK: iCloud

    /// Rules or the window changed on another device.
    func cloudDidUpdate() {
        let d = defaults, owner = defaults.string(forKey: "account.current")
        let switched = owner != configurationOwner
        if switched {
            configurationOwner = owner
            syncTask?.cancel(); windowPushTask?.cancel()
            localVersion += 1
            rules = d.data(forKey: Self.rulesKey).flatMap { try? JSONDecoder().decode([PriceAlertRule].self, from: $0) } ?? []
            removed = d.data(forKey: Self.removedKey).flatMap { try? JSONDecoder().decode([String: TimeInterval].self, from: $0) } ?? [:]
            unsynced = d.bool(forKey: Self.unsyncedKey)
            syncState = .idle; sentTimeZone = nil
        }
        var changed = reconcile(incoming: true)
        let w = Self.savedWindow(defaults)
        if w != window { window = w; if hasContent { changed = true } }
        guard changed || switched else { return }
        localVersion += 1   // a server reply already in flight predates this
        followOnServer(prompt: false)
    }

    /// Merge the rules with the iCloud copy, keep the result and upload it if iCloud
    /// is behind. Returns whether anything the worker sees changed.
    @discardableResult
    private func reconcile(incoming: Bool) -> Bool {
        let d = defaults
        let raw = d.data(forKey: Self.syncKey)
        let cloud = CloudAlerts.decode(raw)
        // Written by a newer version this one can't read: leave it alone rather than
        // overwrite it with only what this device knows.
        if raw != nil && cloud == nil { return false }
        if incoming && cloud == nil { return false }
        let merged = PriceAlertSync.merge(local: rules, removed: removed, cloud: cloud, incoming: incoming)
        let changed = merged.rules.map(\.wire) != rules.map(\.wire)
        if merged.rules != rules || merged.removed != removed {
            rules = merged.rules
            removed = merged.removed
            persist()
        }
        let out = CloudAlerts(rules: rules.map(\.cloud), removed: removed)
        if out != cloud, !(cloud == nil && out.isEmpty), let data = out.encoded() {
            d.set(data, forKey: Self.syncKey)
            CloudSync.push(Self.syncKey)
        }
        return changed
    }

    private func proChanged() {
        guard hasContent, pushHere else { return }
        // StoreKit settles the entitlement at every launch: never prompt from here.
        if ProStore.shared.isPro { Task { await ensureRegistered(prompt: false) } } else { scheduleSync() }
    }

    private func jwsChanged() {
        guard hasContent, ProStore.shared.isPro, pushHere, token != nil else { return }
        scheduleSync()
    }

    private func persist() {
        let d = defaults
        if let data = try? JSONEncoder().encode(rules) { d.set(data, forKey: Self.rulesKey) }
        if let data = try? JSONEncoder().encode(removed) { d.set(data, forKey: Self.removedKey) }
    }

    // MARK: permission + registration

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Ask for notification permission (first time only, unless `prompt` is off) and
    /// register with APNs. The token arrives asynchronously via the app delegate → `didRegister`.
    func ensureRegistered(prompt: Bool = true) async {
        await refreshAuthorization()
        if prompt, authorization == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorization()
        }
        guard authorization == .authorized || authorization == .provisional else {
            scheduleSync()   // still keep the server copy of the rules current
            return
        }
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
        if token != nil { scheduleSync() }
    }

    /// Launch hook: re-register if the user has alerts. Never prompts — the rules may
    /// have come from another device; the alerts page asks.
    func launch() {
        if hasContent, ProStore.shared.isPro, pushHere { Task { await ensureRegistered(prompt: false) } }
        else if unsynced { scheduleSync() }   // e.g. the last alert was removed while offline
    }

    /// An alerts page opened (价格提醒 or 掉线提醒): the one place to ask for
    /// notifications for alerts that synced in from another device.
    func pageOpened() async {
        guard hasContent, ProStore.shared.isPro, pushHere, authorization == .notDetermined else { return }
        await ensureRegistered()
    }

    func didRegister(tokenData: Data) {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        let changed = token != hex
        if let old = token, changed { forget(token: old) }
        token = hex
        defaults.set(hex, forKey: Self.tokenKey)
        // Only a new token needs sending: with the old one still valid, ensureRegistered has
        // already scheduled the sync it wanted. Syncing here as well sent every change twice
        // whenever the system answered late — and switching a dozen 掉线提醒 monitors in a
        // row would then run into the worker's write limit.
        if changed { scheduleSync() }
    }

    func didFailToRegister(_ error: Error) {
        syncState = .failed(error.localizedDescription)
    }

    /// Foreground hook: pick up a permission change made in system Settings and
    /// retry a sync that failed earlier (e.g. offline when a rule was added).
    func foreground() {
        guard hasContent, ProStore.shared.isPro, pushHere else {
            if unsynced { scheduleSync() }   // nothing left here, but the worker hasn't heard
            return
        }
        Task {
            await refreshAuthorization()
            if case .failed = syncState { await ensureRegistered(prompt: false) }
            else if token == nil { await ensureRegistered(prompt: false) }
            // Crossed a time zone: the window is in local time, so re-send it.
            else if window != nil, let sent = sentTimeZone, sent != TimeZone.current.identifier { scheduleSync() }
            else if unsynced { scheduleSync() }
            else { await refresh() }   // alerts that fired while away are now off
        }
    }

    /// Language changed → the push copy must follow, so re-send.
    func languageChanged() { if hasContent && pushHere { scheduleSync() } }

    // MARK: server sync

    private func scheduleSync() {
        unsynced = true
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            // Coalesce bursts (toggling several rules in a row) into one PUT.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    /// What goes to the worker: live alerts first, so the cap never drops one of
    /// those for a switched-off one (rules merged from several devices can pass it).
    private var wireRules: [PriceAlertRule.Wire] {
        guard ProStore.shared.isPro, pushHere else { return [] }
        let all = rules.map(\.wire)
        return Array((all.filter(\.on) + all.filter { !$0.on }).prefix(Self.maxRules))
    }

    /// The 掉线提醒 monitors for the worker. nil = say nothing about them (the worker
    /// keeps what it has): authorization requires a signed Apple purchase or a
    /// verified account purchase. Either can arrive after initial registration.
    private var wireWatches: [OfflineAlertWire]? {
        guard ProStore.shared.isPro, pushHere else { return [] }
        let list = offline.wire
        return list.isEmpty || ProStore.shared.jws != nil || ProStore.shared.hasAccountPro ? list : nil
    }

    /// The device record as the worker's PUT /v1/devices/:token takes it (alerts/src/index.js
    /// putDevice; Tests/Fixtures/alerts_put_body.json is checked against both ends).
    /// `watches` nil = say nothing about the 掉线提醒 monitors; the worker keeps what it has.
    nonisolated static func registrationBody(rules: [PriceAlertRule.Wire], watches: [OfflineAlertWire]?,
                                             window: PushWindow?, timeZone: String, env: String, topic: String,
                                             lang: String, proJWS: String?) -> [String: Any] {
        var body: [String: Any] = [
            "window": window.map { ["start": $0.start, "end": $0.end, "tz": timeZone] as [String: Any] } ?? NSNull(),
            "oneshot": true,
            "env": env,
            "topic": topic,
            "lang": lang,
            "rules": rules.map(\.payload),
        ]
        if let watches { body["watches"] = watches.map(\.payload) }
        if let proJWS { body["pro_jws"] = proJWS }
        return body
    }

    func sync() async {
        guard let token else { return }
        syncState = .syncing
        let sent = localVersion
        let tz = TimeZone.current.identifier
        let body = Self.registrationBody(
            rules: wireRules, watches: wireWatches, window: window, timeZone: tz, env: Self.apnsEnvironment,
            topic: Bundle.main.bundleIdentifier ?? "com.prl.wizard", lang: Self.pushLanguage,
            // The signed Pro purchase, so the worker can check the entitlement itself.
            proJWS: ProStore.shared.isPro ? ProStore.shared.jws : nil)
        var req = URLRequest(url: Self.endpoint.appendingPathComponent("devices/\(token)"))
        req.httpMethod = "PUT"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await WebLinkStore.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                syncState = .failed(Loc("服务器暂时不可用，稍后自动重试"))
                return
            }
            if sent == localVersion {       // else a newer PUT is on its way
                unsynced = false
                adoptServerState(data, fromPut: true)
            }
            sentTimeZone = tz
            syncState = .synced(Date())
        } catch {
            if (error as? URLError)?.code == .cancelled { return }
            syncState = .failed(Loc("无法连接提醒服务器，请检查网络"))
        }
    }

    /// Pull the server's view of this device's rules without re-sending them —
    /// picks up alerts that fired (and so switched themselves off) meanwhile.
    func refresh() async {
        guard let token, ProStore.shared.isPro, pushHere, hasContent, syncState != .syncing else { return }
        let asked = localVersion
        var req = URLRequest(url: Self.endpoint.appendingPathComponent("devices/\(token)"))
        req.timeoutInterval = 10
        guard let (data, resp) = try? await WebLinkStore.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              asked == localVersion, syncState != .syncing else { return }
        adoptServerState(data, fromPut: false)
    }

    /// Take this device's firings from the server's reply. A firing newer than what
    /// the user had seen switches the alert off (`isOn`) — on every device, through
    /// iCloud. Any other on/off difference means the server is behind a change made
    /// here or synced in; a GET re-sends (a PUT reply already reflects what we sent).
    private func adoptServerState(_ data: Data, fromPut: Bool) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = o["rules"] as? [[String: Any]] else { return }
        if let watches = o["watches"] as? [[String: Any]] { offline.adopt(watches) }
        var byID: [String: [String: Any]] = [:]
        for r in list { if let id = r["id"] as? String { byID[id] = r } }
        var changed = false, firedMore = false, behind = false
        for i in rules.indices {
            // Rules the server doesn't list (Pro lapsed, not synced yet), or lists with
            // another condition (an edit not sent yet), keep their local state.
            guard let s = byID[rules[i].id],
                  let kind = (s["kind"] as? String).flatMap(PriceAlertRule.Kind.init(rawValue:)),
                  let value = s["value"] as? Double,
                  rules[i].hasSameCondition(kind: kind, value: value, window: s["window"] as? Int ?? 0)
            else { continue }
            let last = (s["last_fired"] as? Double).map { Date(timeIntervalSince1970: $0) }
            if rules[i].lastFired != last { rules[i].lastFired = last; changed = true }
            if let q = s["deferred"] as? Bool, rules[i].deferred != q { rules[i].deferred = q; changed = true }
            if let t = last?.timeIntervalSince1970, t > rules[i].fired ?? 0 { rules[i].fired = t; firedMore = true }
            if let e = s["enabled"] as? Bool, e != rules[i].isOn { behind = true }
        }
        if changed || firedMore { persist() }
        // Tell the other devices; the merge may also bring in a newer switch-on.
        if firedMore, reconcile(incoming: false) { localVersion += 1; behind = true }
        if behind && (!fromPut || firedMore) { scheduleSync() }
    }

    /// A rotated token: drop the stale server record so it doesn't linger.
    private func forget(token old: String) {
        var req = URLRequest(url: Self.endpoint.appendingPathComponent("devices/\(old)"))
        req.httpMethod = "DELETE"
        Task { _ = try? await WebLinkStore.shared.data(for: req) }
    }

    enum TestResult { case sent, failed(String) }

    func sendTest() async -> TestResult {
        guard let token else { return .failed(Loc("尚未获得推送权限")) }
        await sync()   // make sure the worker knows this device before asking it to push
        var req = URLRequest(url: Self.endpoint.appendingPathComponent("devices/\(token)/test"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        guard let (_, resp) = try? await WebLinkStore.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else {
            return .failed(Loc("无法连接提醒服务器，请检查网络"))
        }
        switch code {
        case 200: return .sent
        case 429: return .failed(Loc("操作太频繁，请一分钟后再试"))
        default: return .failed(Loc("测试通知发送失败，请稍后再试"))
        }
    }

    // MARK: environment

    /// Which APNs environment issued this build's token. Only a hint — the
    /// worker retries the other environment on BadDeviceToken.
    static var apnsEnvironment: String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #elseif os(iOS)
        // App Store / TestFlight builds ship without embedded.mobileprovision.
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let text = String(data: raw, encoding: .isoLatin1),
              let key = text.range(of: "<key>aps-environment</key>"),
              let open = text.range(of: "<string>", range: key.upperBound..<text.endIndex),
              let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex)
        else { return "production" }
        return text[open.upperBound..<close.lowerBound] == "development" ? "sandbox" : "production"
        #else
        guard let task = SecTaskCreateFromSelf(nil),
              let v = SecTaskCopyValueForEntitlement(task, "com.apple.developer.aps-environment" as CFString, nil) as? String
        else { return "production" }
        return v == "development" ? "sandbox" : "production"
        #endif
    }

    /// The app's resolved UI language, one of the worker's (alerts/src/i18n.js `LANGS`,
    /// which mirrors `AppLanguage`).
    static var pushLanguage: String {
        let supported = AppLanguage.allCases.compactMap(\.lprojCode)
        if let code = LocBundleHolder.shared.languageCode, supported.contains(code) { return code }
        let pref = Bundle.main.preferredLocalizations.first ?? "en"
        if supported.contains(pref) { return pref }
        if pref.hasPrefix("zh") { return pref.contains("Hant") || pref.contains("TW") || pref.contains("HK") ? "zh-Hant" : "zh-Hans" }
        // "pt-PT" → "pt-BR", "es-419" → "es": the same language under another region.
        let base = pref.split(separator: "-").first.map(String.init) ?? pref
        return supported.first { $0 == base || $0.hasPrefix(base + "-") } ?? "en"
    }
}
