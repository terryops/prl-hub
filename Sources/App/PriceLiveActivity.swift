import SwiftUI
import Combine
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
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
    /// Activity push token (hex) registered with the worker.
    private var registeredToken: String?

    init() {
        // Re-attach to an activity that survived an app relaunch.
        if let existing = Activity<PriceActivityAttributes>.activities.first(where: { $0.activityState == .active }) {
            attach(existing)
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

    private func attach(_ a: Activity<PriceActivityAttributes>) {
        activity = a
        running = true
        last = a.content.state
        watchers = [
            Task { [weak self] in
                for await data in a.pushTokenUpdates {
                    await self?.register(token: data.map { String(format: "%02x", $0) }.joined())
                }
            },
            Task { [weak self] in
                for await state in a.activityStateUpdates where state == .ended || state == .dismissed {
                    await self?.detach()
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
        priceSub = nil
        activity = nil
        running = false
        if let t = registeredToken { unregister(token: t) }
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

    private func register(token: String) async {
        if let old = registeredToken, old != token { unregister(token: old) }
        registeredToken = token
        var req = URLRequest(url: PriceAlertStore.endpoint.appendingPathComponent("live/\(token)"))
        req.httpMethod = "PUT"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "env": PriceAlertStore.apnsEnvironment,
            "topic": Bundle.main.bundleIdentifier ?? "com.prl.wizard",
        ])
        _ = try? await URLSession.shared.data(for: req)
    }

    private func unregister(token: String) {
        if registeredToken == token { registeredToken = nil }
        var req = URLRequest(url: PriceAlertStore.endpoint.appendingPathComponent("live/\(token)"))
        req.httpMethod = "DELETE"
        URLSession.shared.dataTask(with: req).resume()
    }
    #else
    func start() async {}
    func stop() async {}
    #endif
}
