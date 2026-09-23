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
// ============================================================

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

    /// Wire format the worker expects (lastFired is server-owned). `seen_fired`
    /// echoes the server's own last_fired: the worker only lets a fired rule be
    /// switched back on by an app that has seen that firing (and so showed the
    /// rule as off) — no phone-clock comparison involved.
    fileprivate var payload: [String: Any] {
        ["id": id, "kind": kind.rawValue, "value": value, "window": window, "enabled": enabled,
         "seen_fired": Int(lastFired?.timeIntervalSince1970 ?? 0)]
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

    static func fetch() async -> AlertQuote? {
        var req = URLRequest(url: PriceAlertStore.endpoint.appendingPathComponent("price"))
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usd = o["usd"] as? Double else { return nil }
        return AlertQuote(usd: usd, source: o["source"] as? String, change5m: o["change5m"] as? Double,
                          change1h: o["change1h"] as? Double, change24h: o["change24h"] as? Double)
    }
}

@MainActor
final class PriceAlertStore: ObservableObject {
    static let shared = PriceAlertStore()

    static let endpoint = URL(string: "https://prl.tools.video/v1")!

    enum SyncState: Equatable { case idle, syncing, synced(Date), failed(String) }

    @Published private(set) var rules: [PriceAlertRule] = []
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var syncState: SyncState = .idle
    /// Hex APNs device token, once the system has handed one over.
    @Published private(set) var token: String?

    private static let rulesKey = "alerts.rules"
    private static let tokenKey = "alerts.apnsToken"
    private var syncTask: Task<Void, Never>?
    /// Bumped on every local edit. A server reply is only adopted if no edit
    /// happened while it was in flight — otherwise a slow reply (e.g. a GET that
    /// raced a toggle's PUT) would put back the state from before the edit.
    private var localVersion = 0
    private var languageSub: AnyCancellable?
    private var proSub: AnyCancellable?

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.rulesKey),
           let r = try? JSONDecoder().decode([PriceAlertRule].self, from: d) { rules = r }
        token = UserDefaults.standard.string(forKey: Self.tokenKey)
        // The push copy is localized server-side, so a language switch (here or
        // synced from another device) must re-send the rules with the new code.
        languageSub = LocalizationManager.shared.$language.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.languageChanged() }
        // Alerts are a Pro feature: losing Pro (refund) empties the server copy,
        // (re)gaining it re-registers — local rules are kept either way.
        proSub = ProStore.shared.$isPro.dropFirst().removeDuplicates()
            .sink { [weak self] _ in self?.proChanged() }
    }

    // MARK: rules

    func add(_ rule: PriceAlertRule) { rules.append(rule); rulesChanged() }

    /// Replace an edited rule (same id). Its fired/armed state resets server-side
    /// because kind/value/window changed.
    func update(_ rule: PriceAlertRule) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[i] = rule
        rulesChanged()
    }

    func remove(at offsets: IndexSet) { rules.remove(atOffsets: offsets); rulesChanged() }

    func remove(_ rule: PriceAlertRule) { rules.removeAll { $0.id == rule.id }; rulesChanged() }

    func setEnabled(_ rule: PriceAlertRule, _ on: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }), rules[i].enabled != on else { return }
        rules[i].enabled = on
        rulesChanged()
    }

    private func rulesChanged() {
        localVersion += 1
        persist()
        if rules.isEmpty || !ProStore.shared.isPro { scheduleSync() } else { Task { await ensureRegistered() } }
    }

    private func proChanged() {
        guard !rules.isEmpty else { return }
        if ProStore.shared.isPro { Task { await ensureRegistered() } } else { scheduleSync() }
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(rules) { UserDefaults.standard.set(d, forKey: Self.rulesKey) }
    }

    // MARK: permission + registration

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Ask for notification permission (first time only) and register with APNs.
    /// The token arrives asynchronously via the app delegate → `didRegister`.
    func ensureRegistered() async {
        await refreshAuthorization()
        if authorization == .notDetermined {
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
        let body: [String: Any] = [
            "oneshot": true,
            "env": Self.apnsEnvironment,
            "topic": Bundle.main.bundleIdentifier ?? "com.prl.wizard",
            "lang": Self.pushLanguage,
            "rules": ProStore.shared.isPro ? rules.map(\.payload) : [],
        ]
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
            if sent == localVersion { adoptServerState(data) }   // else a newer PUT is on its way
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
        adoptServerState(data)
    }

    /// Copy the server's last-fired times and on/off state onto the local rules.
    /// The server's `enabled` already folds in what we last sent, plus the
    /// one-shot switch-off of rules it pushed.
    private func adoptServerState(_ data: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = o["rules"] as? [[String: Any]] else { return }
        var fired: [String: Date] = [:]
        var enabled: [String: Bool] = [:]
        for r in list {
            guard let id = r["id"] as? String else { continue }
            if let t = r["last_fired"] as? Double { fired[id] = Date(timeIntervalSince1970: t) }
            if let e = r["enabled"] as? Bool { enabled[id] = e }
        }
        var changed = false
        for i in rules.indices {
            let id = rules[i].id
            if rules[i].lastFired != fired[id] { rules[i].lastFired = fired[id]; changed = true }
            // Rules the server doesn't list (Pro lapsed, not synced yet) keep their local state.
            if let e = enabled[id], rules[i].enabled != e { rules[i].enabled = e; changed = true }
        }
        if changed { persist() }
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
