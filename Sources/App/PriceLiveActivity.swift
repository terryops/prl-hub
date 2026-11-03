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
    typealias State = PriceActivityAttributes.ContentState

    /// What the activity is built from: ActivityKit, the app-wide price and the worker
    /// in the app; fakes in the tests (Tests/AuditLiveActivityTests.swift).
    struct Dependencies {
        var defaults: UserDefaults = .standard
        var isPro: @MainActor () -> Bool = { ProStore.shared.isPro }
        var enabled: @MainActor () -> Bool = { ActivityAuthorizationInfo().areActivitiesEnabled }
        /// The price to open an activity with.
        var reading: @MainActor () async -> State? = { await PriceLiveActivity.currentReading() }
        var request: @MainActor (PriceActivityAttributes, State) throws -> any PriceActivityHandle = { attributes, state in
            SystemPriceActivity(try Activity<PriceActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: state, staleDate: Date(timeIntervalSince1970: state.at + 15 * 60)),
                pushType: .token))
        }
        /// Activities still on screen (a relaunch re-attaches to one).
        var alive: @MainActor () -> [any PriceActivityHandle] = {
            Activity<PriceActivityAttributes>.activities
                .filter { $0.activityState == .active || $0.activityState == .stale }
                .map { SystemPriceActivity($0) }
        }
        var registrar: @MainActor (UserDefaults) -> LiveRegistrar = { LiveRegistrar(defaults: $0) }
        /// Follow the app-wide price, the 1h / 24h figures and the Pro state (off in tests).
        var followsApp = true
    }

    private let deps: Dependencies
    private let defaults: UserDefaults
    private let registrar: LiveRegistrar
    private var activity: (any PriceActivityHandle)?
    private var watchers: [Task<Void, Never>] = []
    private var priceSub: AnyCancellable?
    private var proSub: AnyCancellable?
    private var changeTask: Task<Void, Never>?
    /// The state this app last showed. The activity's own can be newer (a worker push),
    /// or lag behind an update still on its way in.
    private var last: State?
    /// Bumped by every start and stop. A start still waiting for its price gives up
    /// once it no longer matches: stopped meanwhile, or started again (two taps).
    private var epoch = 0

    private static let activityKey = "live.activityID"
    private static let startedKey = "live.startedAt"

    init(_ deps: Dependencies = Dependencies()) {
        self.deps = deps
        defaults = deps.defaults
        registrar = deps.registrar(deps.defaults)
        let d = defaults
        // Re-attach to an activity that survived an app relaunch — a stale one too
        // (no update for 15 min, e.g. the phone was offline): it's still on screen and
        // the worker still pushes to it. Left unattached, the toggle read "off" and
        // turning it on started a second activity. Extra copies are ended.
        let alive = deps.alive()
        let saved = d.string(forKey: Self.activityKey)
        if let keep = alive.first(where: { $0.id == saved }) ?? alive.first {
            for extra in alive where extra.id != keep.id {
                Task { await extra.end() }
            }
            if keep.id != saved { d.removeObject(forKey: Self.startedKey) }
            d.set(keep.id, forKey: Self.activityKey)
            attach(keep)
        } else {
            // Its activity ended while the app wasn't running: stop the worker pushing.
            registrar.unregister()
        }
        registrar.flush()   // DELETEs an earlier launch couldn't get through
        // Pro lapsed (refund): take the activity down.
        if deps.followsApp {
            proSub = ProStore.shared.$isPro.removeDuplicates().sink { [weak self] isPro in
                if !isPro { Task { await self?.stop() } }
            }
        }
    }

    func start() async {
        error = nil
        epoch &+= 1
        let mine = epoch
        guard deps.isPro(), activity == nil else { return }
        guard deps.enabled() else {
            error = Loc("实时活动已在系统设置中关闭：设置 → Pearl Hub → 实时活动。")
            return
        }
        let state = await deps.reading()
        // Stopped, started again or Pro gone while the price loaded: this start is void —
        // going on put an activity up after 停止, or a second one beside the first.
        guard mine == epoch, activity == nil, deps.isPro() else { return }
        guard let state else {
            error = Loc("暂时拿不到价格，请稍后再试。")
            return
        }
        let attrs = PriceActivityAttributes(title: Loc("PRL 实时价格"), label1h: Loc("1小时"), label24h: Loc("24小时"),
                                            style: PriceActivityAttributes.Style(rawValue: styleRaw) ?? .full)
        do {
            let a = try deps.request(attrs, state)
            defaults.set(a.id, forKey: Self.activityKey)
            defaults.set(Date().timeIntervalSince1970, forKey: Self.startedKey)
            last = state
            attach(a)
        } catch {
            self.error = Loc("无法开启锁屏盯盘：%@", error.localizedDescription)
        }
    }

    func stop() async {
        epoch &+= 1
        guard let a = activity else { return }
        // Let go before ending it: a start while end() is still running gets a session
        // of its own, which this stop used to tear down once end() returned.
        detach(a.id)
        await a.end()
    }

    /// Foreground hook: retry a token registration / withdrawal that never got through.
    func foreground() {
        registrar.flush()
        guard activity != nil, registrar.pending, let token = registrar.token else { return }
        registrar.register(token, startedAt: startedAt)
    }

    /// Ask the surviving activity to redraw after a theme / icon change, preserving
    /// the price's original timestamp and staleness deadline.
    func refreshAppearance() {
        guard let a = activity else { return }
        Task { await a.redraw() }
    }

    /// The price to open an activity with: the app-wide one (refreshed first) at the time
    /// it was fetched — after a failed refresh that's the cached price, which mustn't
    /// pass for one from just now.
    static func currentReading() async -> State? {
        let m = PRLPriceManager.shared
        await m.refreshIfStale()
        let quote = await AlertQuote.fetch()
        if let usd = m.usd {
            return State(usd: usd, change1h: quote?.change1h, change24h: quote?.change24h,
                         at: (m.lastUpdated ?? Date()).timeIntervalSince1970)
        }
        guard let q = quote else { return nil }
        return State(usd: q.usd, change1h: q.change1h, change24h: q.change24h,
                     at: (q.at ?? Date()).timeIntervalSince1970)
    }

    /// The state to show after a reading from the app, or nil to leave the activity as
    /// it is. A price only replaces one at least as recent — the activity may already
    /// show a worker push the app never saw, and at launch the app's cached price can
    /// be hours old — and keeps its own time instead of being stamped "now". The 1h /
    /// 24h figures come from the latest quote and don't make the price any newer.
    nonisolated static func merged(_ shown: State, usd: Double? = nil, at: Double? = nil,
                                   change1h: Double?? = nil, change24h: Double?? = nil) -> State? {
        var s = shown
        if let usd, let at, at >= shown.at { s.usd = usd; s.at = at }
        if let change1h { s.change1h = change1h }
        if let change24h { s.change24h = change24h }
        return s == shown ? nil : s
    }

    private var startedAt: Double? {
        let v = defaults.double(forKey: Self.startedKey)
        return v > 0 ? v : nil
    }

    private func attach(_ a: any PriceActivityHandle) {
        watchers.forEach { $0.cancel() }
        activity = a
        running = true
        let id = a.id
        watchers = a.observe(
            token: { [weak self] token in self?.tokenChanged(token, of: id) },
            gone: { [weak self] in self?.detach(id) })
        // A registration a relaunch interrupted (or a token the stream won't repeat).
        if let token = a.pushToken, token != registrar.token || registrar.pending {
            registrar.register(token, startedAt: startedAt)
        }
        guard deps.followsApp else { return }
        // Foreground: push every new app-wide price straight into the activity.
        priceSub = PRLPriceManager.shared.$usd.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] usd in Task { await self?.appPriceChanged(usd) } }
        // …and refresh the 1h / 24h figures once a minute while the app is up.
        changeTask = Task { [weak self] in
            while !Task.isCancelled {
                if let q = await AlertQuote.fetch() { await self?.show(change1h: q.change1h, change24h: q.change24h) }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    /// Let go of activity `id` (ended, dismissed or stopped). Anything still arriving
    /// for an activity let go of earlier is ignored: it mustn't end a newer session.
    private func detach(_ id: String) {
        guard activity?.id == id else { return }
        watchers.forEach { $0.cancel() }; watchers = []
        changeTask?.cancel(); changeTask = nil
        priceSub = nil
        activity = nil
        last = nil
        running = false
        registrar.unregister()
        defaults.removeObject(forKey: Self.activityKey)
        defaults.removeObject(forKey: Self.startedKey)
    }

    private func tokenChanged(_ token: String, of id: String) {
        guard activity?.id == id else { return }
        registrar.register(token, startedAt: startedAt)
    }

    /// A new app-wide price (Trade tab ticker, a refresh), at the time it was fetched.
    private func appPriceChanged(_ usd: Double) async {
        await show(usd: usd, at: (PRLPriceManager.shared.lastUpdated ?? Date()).timeIntervalSince1970)
    }

    /// Put a reading from the app on the activity, unless it's older than what's shown.
    func show(usd: Double? = nil, at: Double? = nil, change1h: Double?? = nil, change24h: Double?? = nil) async {
        guard let a = activity else { return }
        let current = a.state
        let shown = last.map { $0.at >= current.at ? $0 : current } ?? current
        guard let s = Self.merged(shown, usd: usd, at: at, change1h: change1h, change24h: change24h) else { return }
        last = s
        await a.update(s, staleDate: Date(timeIntervalSince1970: s.at + 15 * 60))
    }
    #else
    func start() async {}
    func stop() async {}
    func foreground() {}
    func refreshAppearance() {}
    #endif
}

#if canImport(ActivityKit) && os(iOS)
/// One 锁屏盯盘 activity, as PriceLiveActivity uses it: ActivityKit's in the app
/// (SystemPriceActivity), a fake in the tests.
@MainActor
protocol PriceActivityHandle: AnyObject, Sendable {
    var id: String { get }
    /// What it shows now — a worker push included.
    var state: PriceActivityAttributes.ContentState { get }
    /// Its push token (hex), once iOS has issued one.
    var pushToken: String? { get }
    func update(_ state: PriceActivityAttributes.ContentState, staleDate: Date) async
    /// Draw again as is (theme / icon change): same price, same stale date.
    func redraw() async
    func end() async
    /// Report every push token and the activity going away (ended / dismissed); the
    /// returned tasks are cancelled when the app lets go of it.
    func observe(token: @escaping @MainActor @Sendable (String) -> Void,
                 gone: @escaping @MainActor @Sendable () -> Void) -> [Task<Void, Never>]
}

@MainActor
final class SystemPriceActivity: PriceActivityHandle {
    private let activity: Activity<PriceActivityAttributes>

    init(_ activity: Activity<PriceActivityAttributes>) { self.activity = activity }

    var id: String { activity.id }
    var state: PriceActivityAttributes.ContentState { activity.content.state }
    var pushToken: String? { activity.pushToken.map(Self.hex) }

    func update(_ state: PriceActivityAttributes.ContentState, staleDate: Date) async {
        await activity.update(.init(state: state, staleDate: staleDate))
    }

    func redraw() async { await activity.update(activity.content) }

    func end() async { await activity.end(nil, dismissalPolicy: .immediate) }

    func observe(token: @escaping @MainActor @Sendable (String) -> Void,
                 gone: @escaping @MainActor @Sendable () -> Void) -> [Task<Void, Never>] {
        let a = activity
        return [
            Task { for await data in a.pushTokenUpdates { token(Self.hex(data)) } },
            Task { for await state in a.activityStateUpdates where state == .ended || state == .dismissed { gone() } },
        ]
    }

    nonisolated static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// The worker side of 锁屏盯盘: the activity push token the worker pushes to.
///
/// PUTs and DELETEs go out one at a time, in the order they were made, so a DELETE
/// never overtakes a PUT still on the wire — that left the worker pushing to an ended
/// activity for the rest of its 8 h. A registration superseded mid-flight (stopped, a
/// rotated token) can't mark the current one done. A DELETE that fails is kept and
/// retried (foreground, next launch) until the worker would have dropped the row anyway.
@MainActor
final class LiveRegistrar {
    typealias Send = @MainActor @Sendable (URLRequest) async -> Int?
    typealias Sleep = @MainActor @Sendable (Duration) async -> Void

    /// The registered token (hex), persisted so a relaunch can resend or withdraw it.
    private(set) var token: String?
    /// `token` hasn't had an OK from the worker yet.
    private(set) var pending: Bool
    /// Tokens still to DELETE → when they were withdrawn (Unix seconds).
    private(set) var withdrawn: [String: Double]

    private let defaults: UserDefaults
    private let send: Send
    private let sleep: Sleep
    private let now: @MainActor () -> Date
    private let proJWS: @MainActor () -> String?
    private var generation = 0
    private var retries: Task<Void, Never>?
    private var tail: Task<Bool, Never>?
    private var deleting: Set<String> = []

    static let tokenKey = "live.token"
    static let pendingKey = "live.pending"
    static let withdrawnKey = "live.withdrawn"
    /// The worker forgets a live row 12 h after its activity started (LIVE_KEEP).
    static let withdrawFor: TimeInterval = 12 * 3600
    /// Waits before each retry of a failed PUT: one attempt plus four retries.
    static let retryDelays = [5, 10, 20, 40]

    init(defaults: UserDefaults = .standard,
         send: @escaping Send = { await LiveRegistrar.viaWorker($0) },
         sleep: @escaping Sleep = { try? await Task.sleep(for: $0) },
         now: @escaping @MainActor () -> Date = { Date() },
         proJWS: @escaping @MainActor () -> String? = { ProStore.shared.jws }) {
        self.defaults = defaults
        self.send = send
        self.sleep = sleep
        self.now = now
        self.proJWS = proJWS
        token = defaults.string(forKey: Self.tokenKey)
        pending = token != nil && defaults.bool(forKey: Self.pendingKey)
        withdrawn = defaults.dictionary(forKey: Self.withdrawnKey) as? [String: Double] ?? [:]
    }

    /// (Re)register `token`, retrying with backoff; a different token registered before
    /// is withdrawn (a rotated token).
    func register(_ token: String, startedAt: Double?) {
        if let old = self.token, old != token { withdraw(old) }
        self.token = token
        pending = true
        withdrawn[token] = nil
        save()
        generation &+= 1
        let g = generation
        retries?.cancel()
        retries = Task {
            for attempt in 0...Self.retryDelays.count {
                if attempt > 0 { await self.sleep(.seconds(Self.retryDelays[attempt - 1])) }
                guard self.generation == g, !Task.isCancelled else { return }
                let ok = await self.enqueue {
                    // Superseded while queued behind another request: nothing to send.
                    guard self.generation == g else { return false }
                    return await self.put(token, startedAt: startedAt)
                }.value
                guard self.generation == g else { return }
                if ok { self.pending = false; self.save(); return }
            }
        }
    }

    /// Stop the worker pushing to the registered token (its activity is gone).
    func unregister() {
        generation &+= 1
        retries?.cancel(); retries = nil
        guard let t = token else { return }
        token = nil
        pending = false
        withdraw(t)
    }

    /// Send every DELETE still owed; the ones the worker has dropped by now are let go.
    func flush() {
        let cutoff = now().timeIntervalSince1970 - Self.withdrawFor
        withdrawn = withdrawn.filter { $0.value > cutoff }
        save()
        for t in withdrawn.keys.sorted() where !deleting.contains(t) {
            deleting.insert(t)
            enqueue {
                let done: Bool
                if self.token == t {
                    done = true   // registered again meanwhile; its PUT is queued after this
                } else {
                    done = await self.delete(t)
                }
                self.deleting.remove(t)
                if done { self.withdrawn[t] = nil; self.save() }
                return done
            }
        }
    }

    /// Wait until nothing is retrying or on the wire (tests).
    func settle() async {
        while true {
            let r = retries, t = tail
            await r?.value
            _ = await t?.value
            if r == retries && t == tail { return }
        }
    }

    private func withdraw(_ t: String) {
        if withdrawn[t] == nil { withdrawn[t] = now().timeIntervalSince1970 }
        save()
        flush()
    }

    /// Run `op` after every request made before it.
    @discardableResult
    private func enqueue(_ op: @escaping @MainActor @Sendable () async -> Bool) -> Task<Bool, Never> {
        let previous = tail
        let task = Task {
            _ = await previous?.value
            return await op()
        }
        tail = task
        return task
    }

    /// PUT the token to the worker. `started_at` lets it stop pushing once iOS has
    /// ended the activity (8 h) even when the token rotated; `pro_jws` lets it verify
    /// the Pro purchase itself.
    private func put(_ token: String, startedAt: Double?) async -> Bool {
        var body: [String: Any] = [
            "env": PriceAlertStore.apnsEnvironment,
            "topic": Bundle.main.bundleIdentifier ?? "com.prl.wizard",
        ]
        if let startedAt, startedAt > 0 { body["started_at"] = Int(startedAt) }
        if let jws = proJWS() { body["pro_jws"] = jws }
        var req = URLRequest(url: PriceAlertStore.endpoint.appendingPathComponent("live/\(token)"))
        req.httpMethod = "PUT"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return await send(req) == 200
    }

    private func delete(_ token: String) async -> Bool {
        var req = URLRequest(url: PriceAlertStore.endpoint.appendingPathComponent("live/\(token)"))
        req.httpMethod = "DELETE"
        req.timeoutInterval = 15
        guard let status = await send(req) else { return false }
        // 400: not a token the worker would ever have stored; retrying can't help.
        return (200..<300).contains(status) || status == 400 || status == 404
    }

    private func save() {
        if let token { defaults.set(token, forKey: Self.tokenKey) } else { defaults.removeObject(forKey: Self.tokenKey) }
        if pending { defaults.set(true, forKey: Self.pendingKey) } else { defaults.removeObject(forKey: Self.pendingKey) }
        if withdrawn.isEmpty { defaults.removeObject(forKey: Self.withdrawnKey) } else { defaults.set(withdrawn, forKey: Self.withdrawnKey) }
    }

    static func viaWorker(_ req: URLRequest) async -> Int? {
        guard let (_, resp) = try? await WebLinkStore.shared.data(for: req) else { return nil }
        return (resp as? HTTPURLResponse)?.statusCode
    }
}
#endif
