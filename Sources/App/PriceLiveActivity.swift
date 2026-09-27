import SwiftUI
import Combine
#if canImport(ActivityKit) && os(iOS)
// Activity isn't marked Sendable; every use here stays on the main actor.
@preconcurrency import ActivityKit
#endif

// ============================================================
// 锁屏盯盘 — live PRL price on the Lock Screen / Dynamic Island (Pro)
// ------------------------------------------------------------
// The user starts it from the Trade tab or the price-alerts page.
// While the app runs, every new app-wide price (PRLPriceManager,
// refreshed every 5 s on the Trade tab) updates the activity
// directly. For the rest of the time the activity's push token is
// registered with the price-alert worker, which pushes an update
// whenever its once-a-minute price moves. iOS ends an activity after
// 8 hours; the user can stop it any time.
// ============================================================

@MainActor
final class PriceLiveActivity: ObservableObject {
    static let shared = PriceLiveActivity()

    /// An activity is currently showing.
    @Published private(set) var running = false
    /// Why the last start failed (Live Activities off in Settings, …).
    @Published var error: String?

    /// Which presentation carries the price — see PriceActivityAttributes.Style.
    /// Raw value so the property exists on macOS too (no ActivityKit there).
    /// A style is fixed for an activity's lifetime, so changing it while one is
    /// running restarts it.
    @Published var styleRaw: String = UserDefaults.standard.string(forKey: "live.style") ?? "full" {
        didSet {
            guard styleRaw != oldValue else { return }
            UserDefaults.standard.set(styleRaw, forKey: "live.style")
            #if canImport(ActivityKit) && os(iOS)
            if running { Task { await stop(); await start() } }
            #endif
        }
    }

    /// Live Activities exist on iPhone only (iOS 16.1+, Dynamic Island on newer models).
    static var supported: Bool {
        #if canImport(ActivityKit) && os(iOS)
        return true
        #else
        return false
        #endif
    }

    #if canImport(ActivityKit) && os(iOS)
    private var activity: Activity<PriceActivityAttributes>?
    private var watchers: [Task<Void, Never>] = []
    private var priceSub: AnyCancellable?
    private var proSub: AnyCancellable?
    private var changeTask: Task<Void, Never>?
    private var last = PriceActivityAttributes.ContentState(usd: 0, change1h: nil, change24h: nil, at: 0)
    /// Activity push token (hex) registered with the worker. Persisted (with the
    /// activity's id and start time) so a relaunch can re-send it with the right
    /// start, or withdraw it once its activity is gone.
    private var registeredToken: String?
    /// The last registration attempt never got an OK; retried on foreground.
    private var registrationPending = false
    private var registerTask: Task<Void, Never>?

    private static let tokenKey = "live.token"
    private static let activityKey = "live.activityID"
    private static let startedKey = "live.startedAt"

    init() {
        let d = UserDefaults.standard
        registeredToken = d.string(forKey: Self.tokenKey)
        // Re-attach to an activity that survived an app relaunch — a stale one too
        // (no update for 15 min, e.g. the phone was offline): it's still on screen and
        // the worker still pushes to it. Left unattached, the toggle read "off" and
        // turning it on started a second activity. Extra copies are ended.
        let alive = Activity<PriceActivityAttributes>.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
        if let keep = alive.first(where: { $0.id == d.string(forKey: Self.activityKey) }) ?? alive.first {
            for extra in alive where extra.id != keep.id {
                Task { await extra.end(nil, dismissalPolicy: .immediate) }
            }
            if keep.id != d.string(forKey: Self.activityKey) { d.removeObject(forKey: Self.startedKey) }
            d.set(keep.id, forKey: Self.activityKey)
            attach(keep)
        } else if let orphan = registeredToken {
            // Its activity ended while the app wasn't running: stop the worker pushing.
            unregister(token: orphan)
        }
        // Pro lapsed (refund): take the activity down.
        proSub = ProStore.shared.$isPro.removeDuplicates().sink { [weak self] isPro in
            if !isPro { Task { await self?.stop() } }
        }
    }

    func start() async {
        error = nil
        guard ProStore.shared.isPro, activity == nil else { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            error = Loc("实时活动已在系统设置中关闭：设置 → Pearl Hub → 实时活动。")
            return
        }
        await PRLPriceManager.shared.refreshIfStale()
        let quote = await AlertQuote.fetch()
        guard let usd = PRLPriceManager.shared.usd ?? quote?.usd else {
            error = Loc("暂时拿不到价格，请稍后再试。")
            return
        }
        let state = PriceActivityAttributes.ContentState(
            usd: usd, change1h: quote?.change1h, change24h: quote?.change24h,
            at: Date().timeIntervalSince1970)
        let attrs = PriceActivityAttributes(title: Loc("PRL 实时价格"), label1h: Loc("1小时"), label24h: Loc("24小时"),
                                            style: PriceActivityAttributes.Style(rawValue: styleRaw) ?? .full)
        do {
            let a = try Activity.request(attributes: attrs,
                                         content: .init(state: state, staleDate: Date().addingTimeInterval(15 * 60)),
                                         pushType: .token)
            UserDefaults.standard.set(a.id, forKey: Self.activityKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.startedKey)
            last = state
            attach(a)
        } catch {
            self.error = Loc("无法开启锁屏盯盘：%@", error.localizedDescription)
        }
    }

    func stop() async {
        guard let a = activity else { return }
        await a.end(nil, dismissalPolicy: .immediate)
        detach()
    }

    /// Foreground hook: retry a token registration that never got through.
    func foreground() {
        guard activity != nil, registrationPending, let token = registeredToken else { return }
        scheduleRegister(token: token)
    }

    private func attach(_ a: Activity<PriceActivityAttributes>) {
        activity = a
        running = true
        last = a.content.state
        watchers = [
            Task { [weak self] in
                for await data in a.pushTokenUpdates {
                    self?.scheduleRegister(token: data.map { String(format: "%02x", $0) }.joined())
                }
            },
            Task { [weak self] in
                for await state in a.activityStateUpdates where state == .ended || state == .dismissed {
                    self?.detach()
                }
            },
        ]
        // Foreground: push every new app-wide price straight into the activity.
        priceSub = PRLPriceManager.shared.$usd.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] usd in Task { await self?.push(usd: usd) } }
        // …and refresh the 1h / 24h figures once a minute while the app is up.
        changeTask = Task { [weak self] in
            while !Task.isCancelled {
                if let q = await AlertQuote.fetch() { await self?.push(change1h: q.change1h, change24h: q.change24h) }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func detach() {
        watchers.forEach { $0.cancel() }; watchers = []
        changeTask?.cancel(); changeTask = nil
        registerTask?.cancel(); registerTask = nil
        priceSub = nil
        activity = nil
        running = false
        if let t = registeredToken { unregister(token: t) }
        UserDefaults.standard.removeObject(forKey: Self.activityKey)
        UserDefaults.standard.removeObject(forKey: Self.startedKey)
    }

    private func push(usd: Double? = nil, change1h: Double?? = nil, change24h: Double?? = nil) async {
        guard let a = activity else { return }
        var s = last
        if let usd { s.usd = usd }
        if let change1h { s.change1h = change1h }
        if let change24h { s.change24h = change24h }
        s.at = Date().timeIntervalSince1970
        guard s.usd != last.usd || s.change1h != last.change1h || s.change24h != last.change24h else { return }
        last = s
        await a.update(.init(state: s, staleDate: Date().addingTimeInterval(15 * 60)))
    }

    // MARK: worker

    /// (Re)register `token`, retrying a few times with backoff; a rotated token
    /// supersedes the one still retrying.
    private func scheduleRegister(token: String) {
        if let old = registeredToken, old != token { unregister(token: old) }
        registeredToken = token
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        registrationPending = true
        registerTask?.cancel()
        registerTask = Task { [weak self] in
            for attempt in 0..<4 {
                guard let self, !Task.isCancelled else { return }
                if await self.putLive(token: token) { self.registrationPending = false; return }
                try? await Task.sleep(for: .seconds(5 << attempt))   // 5, 10, 20, 40 s
            }
        }
    }

    /// PUT the token to the worker. `started_at` lets it stop pushing once iOS has
    /// ended the activity (8 h) even when the token rotated; `pro_jws` lets it verify
    /// the Pro purchase itself.
    private func putLive(token: String) async -> Bool {
        var body: [String: Any] = [
            "env": PriceAlertStore.apnsEnvironment,
            "topic": Bundle.main.bundleIdentifier ?? "com.prl.wizard",
        ]
        let started = UserDefaults.standard.double(forKey: Self.startedKey)
        if started > 0 { body["started_at"] = Int(started) }
        if let jws = ProStore.shared.jws { body["pro_jws"] = jws }
        var req = URLRequest(url: PriceAlertStore.endpoint.appendingPathComponent("live/\(token)"))
        req.httpMethod = "PUT"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func unregister(token: String) {
        if registeredToken == token {
            registeredToken = nil
            registrationPending = false
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        }
        var req = URLRequest(url: PriceAlertStore.endpoint.appendingPathComponent("live/\(token)"))
        req.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: req).resume()
    }
    #else
    func start() async {}
    func stop() async {}
    func foreground() {}
    #endif
}
