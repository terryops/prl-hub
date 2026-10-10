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
// One exception: an alert that was pushed switches itself off on
// the server (one-shot, opted into with `oneshot`); the app adopts
// that from every reply and only re-enables it when the user
// switches it back on.
//
// 推送时段 (1.16): pushes can be limited to a daily window of local
// time (default: all day). An alert that fires outside it is queued
// by the worker and pushed at the next window start.
//
// The rules and the window also sync over iCloud to the user's other
// devices (PriceAlertSync.swift); each device registers on its own.
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
    var enabled = true
    /// Last time the server pushed this rule (from the worker's reply).
    var lastFired: Date?
    /// Fired during quiet hours; the push waits for the next window start
    /// (from the worker's reply). Optional so older saved rules still decode.
    var deferred: Bool?
    /// Unix seconds of the last user change (added, edited, switched — here or on
    /// another device) or of the firing that switched it off. Decides which copy
    /// wins in the iCloud merge. nil for rules saved before sync existed.
    var changedAt: TimeInterval?

    /// This rule as edited to `edited`'s condition, keeping its id. A changed
    /// condition is a new alert: switched on, fired state cleared (the worker resets
    /// it too) — an edited one-shot alert that had fired used to stay off. An
    /// unchanged condition keeps its on/off and fired state.
    func applyingEdit(_ edited: PriceAlertRule) -> PriceAlertRule {
        var r = edited
        r.id = id
        if kind == edited.kind && value == edited.value && window == edited.window {
            r.enabled = enabled
            r.lastFired = lastFired
            r.deferred = deferred
            r.changedAt = changedAt
        } else {
            r.enabled = true
            r.lastFired = nil
            r.deferred = nil
            r.changedAt = Date().timeIntervalSince1970
        }
        return r
    }

    /// Wire format the worker expects (lastFired is server-owned). `seen_fired`
    /// echoes the server's own last_fired: the worker only lets a fired rule be
    /// switched back on by an app that has seen that firing (and so showed the
    /// rule as off). A rule switched on at `changedAt` has had every earlier firing
    /// seen — possibly on another device, which is why this device's own copy may
    /// never have shown it — so that time counts as seen too.
    fileprivate var payload: [String: Any] {
        ["id": id, "kind": kind.rawValue, "value": value, "window": window, "enabled": enabled,
         "seen_fired": seenFired]
    }

    var seenFired: Int { Int(max(lastFired?.timeIntervalSince1970 ?? 0, enabled ? changedAt ?? 0 : 0)) }
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

    nonisolated static let endpoint = URL(string: "https://prl.tools.video/v1")!
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

    private static let rulesKey = "alerts.rules"
    /// iCloud copy of the rules (CloudSync mirrors it); merged into `rules`, never read directly.
    static let syncKey = "alerts.sync"
    /// Deleted rule ids → when, so a deletion also reaches the other devices.
    private static let removedKey = "alerts.removed"
    static let windowKey = "alerts.window"
    private var removed: [String: TimeInterval] = [:]
    /// Time zone the worker last got with the window — re-sent after travel.
    private var sentTimeZone: String?
    private static let tokenKey = "alerts.apnsToken"
    private var syncTask: Task<Void, Never>?
    /// Bumped on every local edit. A server reply is only adopted if no edit
    /// happened while it was in flight — otherwise a slow reply (e.g. a GET that
    /// raced a toggle's PUT) would put back the state from before the edit.
    private var localVersion = 0
    private var languageSub: AnyCancellable?
    private var proSub: AnyCancellable?
    private var jwsSub: AnyCancellable?
    private var cloudSub: AnyCancellable?

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.rulesKey),
           let r = try? JSONDecoder().decode([PriceAlertRule].self, from: data) { rules = r }
        if let data = d.data(forKey: Self.removedKey),
           let r = try? JSONDecoder().decode([String: TimeInterval].self, from: data) { removed = r }
        token = d.string(forKey: Self.tokenKey)
        window = Self.savedWindow()
        // Rules saved before iCloud sync: stage them as this device's iCloud copy, so
        // CloudSync.start uploads them if iCloud has none yet — or, if another device
        // got there first, pulls that copy in and we merge.
        if d.data(forKey: Self.syncKey) == nil, !rules.isEmpty,
           let data = CloudAlerts(rules: rules.map(\.cloud)).encoded() {
            d.set(data, forKey: Self.syncKey)
        }
        cloudSub = NotificationCenter.default.publisher(for: .cloudSyncDidUpdate)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cloudDidUpdate() }
        // The push copy is localized server-side, so a language switch (here or
        // synced from another device) must re-send the rules with the new code.
        languageSub = LocalizationManager.shared.$language.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.languageChanged() }
        // Alerts are a Pro feature: losing Pro (refund) empties the server copy,
        // (re)gaining it re-registers — local rules are kept either way.
        proSub = ProStore.shared.$isPro.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.proChanged() }
        // The signed purchase arrived after registering (StoreKit answered late, or a
        // purchase on another device): hand it to the worker.
        jwsSub = ProStore.shared.$jws.dropFirst().removeDuplicates()
            .sink { [weak self] jws in if jws != nil { self?.jwsChanged() } }
    }

    // MARK: rules

    func add(_ rule: PriceAlertRule) {
        var r = rule
        r.changedAt = Date().timeIntervalSince1970
        rules.append(r)
        rulesChanged()
    }

    /// Replace an edited rule (same id). Its fired/armed state resets server-side
    /// because kind/value/window changed. The edit is re-applied to the stored copy:
    /// the editor's snapshot may predate the alert firing or a change synced in.
    func update(_ rule: PriceAlertRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let r = rules[i].applyingEdit(rule)
        guard r != rules[i] else { return }
        rules[i] = r
        rulesChanged()
    }

    func remove(at offsets: IndexSet) {
        let now = Date().timeIntervalSince1970
        for i in offsets { removed[rules[i].id] = now }
        rules.remove(atOffsets: offsets)
        rulesChanged()
    }

    func remove(_ rule: PriceAlertRule) {
        guard rules.contains(where: { $0.id == rule.id }) else { return }
        removed[rule.id] = Date().timeIntervalSince1970
        rules.removeAll { $0.id == rule.id }
        rulesChanged()
    }

    func setEnabled(_ rule: PriceAlertRule, _ on: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }), rules[i].enabled != on else { return }
        rules[i].enabled = on
        rules[i].changedAt = Date().timeIntervalSince1970
        rulesChanged()
    }

    /// Set (or clear, for all day) the push window. The server keeps queued
    /// alerts; with the window widened they go out on the next tick.
    func setWindow(_ w: PushWindow?) {
        guard w != window else { return }
        window = w
        if let w, let d = try? JSONEncoder().encode(w) { UserDefaults.standard.set(d, forKey: Self.windowKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.windowKey) }
        CloudSync.push(Self.windowKey)
        localVersion += 1
        if !rules.isEmpty { scheduleSync() }
    }

    private static func savedWindow() -> PushWindow? {
        UserDefaults.standard.data(forKey: windowKey).flatMap { try? JSONDecoder().decode(PushWindow.self, from: $0) }
    }

    private func rulesChanged() {
        localVersion += 1
        persist()
        reconcile(incoming: false)
        if rules.isEmpty || !ProStore.shared.isPro { scheduleSync() } else { Task { await ensureRegistered() } }
    }

    // MARK: iCloud

    /// Rules or the window changed on another device.
    private func cloudDidUpdate() {
        var changed = reconcile(incoming: true)
        let w = Self.savedWindow()
        if w != window { window = w; if !rules.isEmpty { changed = true } }
        guard changed else { return }
        localVersion += 1   // a server reply already in flight predates this
        // Never prompt for notifications here: this device's user didn't just ask for
        // an alert. launch() / the alerts page ask when it's their move.
        if rules.isEmpty || !ProStore.shared.isPro { scheduleSync() } else { Task { await ensureRegistered(prompt: false) } }
    }

    /// Merge the rules with the iCloud copy, keep the result and upload it if iCloud
    /// is behind. Returns whether anything the worker sees changed.
    @discardableResult
    private func reconcile(incoming: Bool) -> Bool {
        let d = UserDefaults.standard
        let cloud = CloudAlerts.decode(d.data(forKey: Self.syncKey))
        if incoming && cloud == nil { return false }
        let merged = PriceAlertSync.merge(local: rules, removed: removed, cloud: cloud, incoming: incoming)
        let changed = merged.rules.map(\.cloud) != rules.map(\.cloud)
        if merged.rules != rules { rules = merged.rules; persist() }
        if merged.removed != removed {
            removed = merged.removed
            if let data = try? JSONEncoder().encode(removed) { d.set(data, forKey: Self.removedKey) }
        }
        let out = CloudAlerts(rules: rules.map(\.cloud), removed: removed)
        if out != cloud, !(cloud == nil && out.isEmpty), let data = out.encoded() {
            d.set(data, forKey: Self.syncKey)
            CloudSync.push(Self.syncKey)
        }
        return changed
    }

    private func proChanged() {
        guard !rules.isEmpty else { return }
        if ProStore.shared.isPro { Task { await ensureRegistered() } } else { scheduleSync() }
    }

    private func jwsChanged() {
        guard !rules.isEmpty, ProStore.shared.isPro, token != nil else { return }
        scheduleSync()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(d, forKey: Self.rulesKey) }
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

    /// Launch hook: re-register only if the user has alerts (never prompt otherwise).
    func launch() {
        guard !rules.isEmpty, ProStore.shared.isPro else { return }
        Task { await ensureRegistered() }
    }

    func didRegister(tokenData: Data) {
        let hex = tokenData.map { String(format: "%02x", $0) }.joined()
        if let old = token, old != hex { forget(token: old) }
        token = hex
        UserDefaults.standard.set(hex, forKey: Self.tokenKey)
        scheduleSync()
    }

    func didFailToRegister(_ error: Error) {
        syncState = .failed(error.localizedDescription)
    }

    /// Foreground hook: pick up a permission change made in system Settings and
    /// retry a sync that failed earlier (e.g. offline when a rule was added).
    func foreground() {
        guard !rules.isEmpty, ProStore.shared.isPro else { return }
        Task {
            await refreshAuthorization()
            if case .failed = syncState { await ensureRegistered() }
            else if token == nil { await ensureRegistered() }
            // Crossed a time zone: the window is in local time, so re-send it.
            else if window != nil, let sent = sentTimeZone, sent != TimeZone.current.identifier { scheduleSync() }
            else { await refresh() }   // alerts that fired while away are now off
        }
    }

    /// Language changed → the push copy must follow, so re-send.
    func languageChanged() { if !rules.isEmpty { scheduleSync() } }

    // MARK: server sync

    private func scheduleSync() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            // Coalesce bursts (toggling several rules in a row) into one PUT.
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func sync() async {
        guard let token else { return }
        syncState = .syncing
        let sent = localVersion
        let tz = TimeZone.current.identifier
        var body: [String: Any] = [
            "window": window.map { ["start": $0.start, "end": $0.end, "tz": tz] as [String: Any] } ?? NSNull(),
            "oneshot": true,
            "env": Self.apnsEnvironment,
            "topic": Bundle.main.bundleIdentifier ?? "com.prl.wizard",
            "lang": Self.pushLanguage,
            "rules": ProStore.shared.isPro ? rules.prefix(Self.maxRules).map(\.payload) : [],
        ]
        // The signed Pro purchase, so the worker can check the entitlement itself.
        if ProStore.shared.isPro, let jws = ProStore.shared.jws { body["pro_jws"] = jws }
        var req = URLRequest(url: Self.endpoint.appendingPathComponent("devices/\(token)"))
        req.httpMethod = "PUT"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                syncState = .failed(Loc("服务器暂时不可用，稍后自动重试"))
                return
            }
            if sent == localVersion { adoptServerState(data, fromPut: true) }   // else a newer PUT is on its way
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
        guard let token, ProStore.shared.isPro, !rules.isEmpty, syncState != .syncing else { return }
        let asked = localVersion
        var req = URLRequest(url: Self.endpoint.appendingPathComponent("devices/\(token)"))
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              asked == localVersion, syncState != .syncing else { return }
        adoptServerState(data, fromPut: false)
    }

    /// Copy the server's last-fired times onto the local rules, and switch off the
    /// ones it pushed (one-shot) since they were last switched on. Any other on/off
    /// difference means the server is behind a change made here or synced in from
    /// another device — that is re-sent (after a GET; a PUT reply is what we just sent).
    private func adoptServerState(_ data: Data, fromPut: Bool) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = o["rules"] as? [[String: Any]] else { return }
        var listed: Set<String> = []
        var fired: [String: Date] = [:]
        var enabled: [String: Bool] = [:]
        var deferred: [String: Bool] = [:]
        for r in list {
            guard let id = r["id"] as? String else { continue }
            listed.insert(id)
            if let t = r["last_fired"] as? Double { fired[id] = Date(timeIntervalSince1970: t) }
            if let e = r["enabled"] as? Bool { enabled[id] = e }
            if let q = r["deferred"] as? Bool { deferred[id] = q }
        }
        var changed = false, firedOff = false, behind = false
        for i in rules.indices {
            let id = rules[i].id
            // Rules the server doesn't list (Pro lapsed, not synced yet) keep their local
            // state — including when they last fired.
            guard listed.contains(id) else { continue }
            if rules[i].lastFired != fired[id] { rules[i].lastFired = fired[id]; changed = true }
            if let q = deferred[id], rules[i].deferred != q { rules[i].deferred = q; changed = true }
            guard let e = enabled[id], e != rules[i].enabled else { continue }
            if !e, let t = fired[id]?.timeIntervalSince1970, t > rules[i].changedAt ?? 0 {
                rules[i].enabled = false
                rules[i].changedAt = t
                firedOff = true
            } else {
                behind = true
            }
        }
        if changed || firedOff { persist() }
        // The switch-off shows on the other devices too — unless one of them switched
        // the rule back on later, which the merge keeps and the server must hear.
        if firedOff, reconcile(incoming: false) { behind = true; localVersion += 1 }
        if behind && (!fromPut || firedOff) { scheduleSync() }
    }

    /// A rotated token: drop the stale server record so it doesn't linger.
    private func forget(token old: String) {
        var req = URLRequest(url: Self.endpoint.appendingPathComponent("devices/\(old)"))
        req.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: req).resume()
    }

    enum TestResult { case sent, failed(String) }

    func sendTest() async -> TestResult {
        guard let token else { return .failed(Loc("尚未获得推送权限")) }
        await sync()   // make sure the worker knows this device before asking it to push
        var req = URLRequest(url: Self.endpoint.appendingPathComponent("devices/\(token)/test"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
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

    /// The app's resolved UI language, one of the worker's six.
    static var pushLanguage: String {
        let supported = ["en", "ru", "zh-Hans", "zh-Hant", "vi", "id"]
        if let code = LocBundleHolder.shared.languageCode, supported.contains(code) { return code }
        let pref = Bundle.main.preferredLocalizations.first ?? "en"
        if supported.contains(pref) { return pref }
        if pref.hasPrefix("zh") { return pref.contains("Hant") || pref.contains("TW") || pref.contains("HK") ? "zh-Hant" : "zh-Hans" }
        return supported.first { pref.hasPrefix($0) } ?? "en"
    }
}
