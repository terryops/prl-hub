#if canImport(ActivityKit) && os(iOS)
import Foundation
import Testing
@testable import Pearl

// 锁屏盯盘 against the 2026-10-27 Android audit (docs/bugfixes-2026-10-27.md, L01–L12 in
// prl-hub-android): activity sessions and the worker registration, with a fake
// ActivityKit, a fake worker and a throwaway UserDefaults suite. Nothing here touches
// the network, the real activity or the app's own defaults.

private typealias State = PriceActivityAttributes.ContentState

/// Holds async work until released.
@MainActor
private final class Gate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        open = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

/// The worker's `live` table, as far as the app can change it.
@MainActor
private final class FakeWorker {
    /// Tokens the worker would push to.
    var rows: Set<String> = []
    /// "PUT <token>" / "DELETE <token>", in the order they were sent.
    private(set) var log: [String] = []
    /// A request held on the wire until its gate opens (first one per key only).
    var holds: [String: Gate] = [:]
    /// Requests that answer 500.
    var failing: Set<String> = []

    func handle(_ req: URLRequest) async -> Int? {
        let token = req.url?.lastPathComponent ?? ""
        let key = "\(req.httpMethod ?? "") \(token)"
        log.append(key)
        if let gate = holds.removeValue(forKey: key) { await gate.wait() }
        if failing.contains(key) { return 500 }
        if req.httpMethod == "PUT" { rows.insert(token) } else { rows.remove(token) }
        return 200
    }

    func count(_ key: String) -> Int { log.filter { $0 == key }.count }
}

@MainActor
private final class FakeActivity: PriceActivityHandle {
    let id: String
    var state: State
    var pushToken: String?
    private(set) var updates: [State] = []
    private(set) var ended = false
    /// Holds end() after iOS has reported the activity gone (as the state stream can).
    var endGate: Gate?
    private var onToken: (@MainActor @Sendable (String) -> Void)?
    private var onGone: (@MainActor @Sendable () -> Void)?

    init(id: String, state: State = State(usd: 0.5, change1h: nil, change24h: nil, at: 1_800_000_000),
         pushToken: String? = nil) {
        self.id = id
        self.state = state
        self.pushToken = pushToken
    }

    func update(_ state: State, staleDate: Date) async {
        updates.append(state)
        self.state = state
    }

    func redraw() async {}

    func end() async {
        ended = true
        onGone?()
        if let endGate { await endGate.wait() }
    }

    func observe(token: @escaping @MainActor @Sendable (String) -> Void,
                 gone: @escaping @MainActor @Sendable () -> Void) -> [Task<Void, Never>] {
        onToken = token
        onGone = gone
        return []   // no cancellation: a late callback has to be ignored by the app itself
    }

    /// iOS issues (or rotates) the push token.
    func issue(_ token: String) {
        pushToken = token
        onToken?(token)
    }

    /// The user swipes it away / iOS ends it.
    func dismiss() {
        ended = true
        onGone?()
    }
}

@MainActor
private final class Harness {
    let suite = "audit-live-\(UUID().uuidString)"
    let defaults: UserDefaults
    let worker = FakeWorker()
    var pro = true
    var readingGate: Gate?
    private(set) var readings = 0
    private(set) var requested: [FakeActivity] = []
    var alive: [FakeActivity] = []
    private(set) var sleeps: [Duration] = []
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var registrar: LiveRegistrar?

    init() { defaults = UserDefaults(suiteName: suite)! }

    func cleanup() { defaults.removePersistentDomain(forName: suite) }

    func makeRegistrar(_ d: UserDefaults) -> LiveRegistrar {
        let worker = self.worker
        let r = LiveRegistrar(defaults: d,
                              send: { await worker.handle($0) },
                              sleep: { [unowned self] in self.sleeps.append($0) },
                              now: { [unowned self] in self.now },
                              proJWS: { nil })
        registrar = r
        return r
    }

    /// A PriceLiveActivity on this harness — a fresh one is an app relaunch.
    func live() -> PriceLiveActivity {
        var deps = PriceLiveActivity.Dependencies()
        deps.defaults = defaults
        deps.isPro = { [unowned self] in self.pro }
        deps.enabled = { true }
        deps.reading = { [unowned self] in
            self.readings += 1
            if let gate = self.readingGate { await gate.wait() }
            return State(usd: 0.5, change1h: 1, change24h: 2, at: self.now.timeIntervalSince1970)
        }
        deps.request = { [unowned self] _, state in
            let a = FakeActivity(id: "A\(self.requested.count + 1)", state: state)
            self.requested.append(a)
            return a
        }
        deps.alive = { [unowned self] in self.alive }
        deps.registrar = { [unowned self] in self.makeRegistrar($0) }
        deps.followsApp = false
        return PriceLiveActivity(deps)
    }

    func settle() async { await registrar?.settle() }

    /// Let queued main-actor work run until `condition` holds (or give up).
    func until(_ condition: () -> Bool) async {
        var n = 0
        while !condition() && n < 500 { await Task.yield(); n += 1 }
    }

    var withdrawn: [String: Double] {
        defaults.dictionary(forKey: LiveRegistrar.withdrawnKey) as? [String: Double] ?? [:]
    }
}

@MainActor
struct AuditLiveActivityTests {
    // MARK: sessions (L04 / L05)

    /// L05: 停止 while start() still waits for its price used to be ignored (no activity
    /// yet) — the activity then went up anyway.
    @Test func stopWhileStartLoadsThePriceWins() async {
        let h = Harness(); defer { h.cleanup() }
        let gate = Gate(); h.readingGate = gate
        let live = h.live()
        let starting = Task { await live.start() }
        await h.until { h.readings == 1 }
        await live.stop()
        gate.release()
        await starting.value
        #expect(h.requested.isEmpty)
        #expect(!live.running)
    }

    /// L05: two starts in flight (a double tap on 锁屏盯盘 in the Trade tab, which has no
    /// busy state) used to put up two activities.
    @Test func twoStartsInFlightMakeOneActivity() async {
        let h = Harness(); defer { h.cleanup() }
        let gate = Gate(); h.readingGate = gate
        let live = h.live()
        let first = Task { await live.start() }
        let second = Task { await live.start() }
        await h.until { h.readings == 2 }
        gate.release()
        await first.value
        await second.value
        #expect(h.requested.count == 1)
        #expect(live.running)
    }

    /// L05: Pro gone (refund) while the price loads: no activity.
    @Test func proLapsingWhileStartLoadsCancelsIt() async {
        let h = Harness(); defer { h.cleanup() }
        let gate = Gate(); h.readingGate = gate
        let live = h.live()
        let starting = Task { await live.start() }
        await h.until { h.readings == 1 }
        h.pro = false
        gate.release()
        await starting.value
        #expect(h.requested.isEmpty)
    }

    /// L04: the old activity's end (and its "ended" state) arriving after a new session
    /// started — a style change is stop + start — used to detach the new one: left on
    /// screen, toggle off, its token withdrawn.
    @Test func lateEndOfTheOldActivityLeavesTheNewSessionAlone() async throws {
        let h = Harness(); defer { h.cleanup() }
        let live = h.live()
        await live.start()
        let a = try #require(h.requested.first)
        a.issue("aa01")
        await h.settle()
        let endGate = Gate(); a.endGate = endGate
        let stopping = Task { await live.stop() }
        await h.until { a.ended }
        await live.start()
        try #require(h.requested.count == 2)
        let b = h.requested[1]
        b.issue("bb01")
        endGate.release()
        await stopping.value
        a.dismiss()       // and once more, late
        a.issue("aa02")   // a token from an activity let go of registers nothing
        await h.settle()
        #expect(live.running)
        #expect(!b.ended)
        #expect(h.worker.rows == ["bb01"])
        #expect(h.worker.count("PUT aa02") == 0)
    }

    // MARK: content (L02)

    /// L02: the app's price only replaces the shown one when it's at least as recent,
    /// and keeps its own time (the cached price at launch can be hours old).
    @Test func olderAppPriceNeverReplacesANewerPush() {
        let pushed = State(usd: 0.50, change1h: 1, change24h: 2, at: 2000)
        #expect(PriceLiveActivity.merged(pushed, usd: 0.45, at: 1500) == nil)
        let newer = PriceLiveActivity.merged(pushed, usd: 0.47, at: 2100)
        #expect(newer == State(usd: 0.47, change1h: 1, change24h: 2, at: 2100))
        // 1h / 24h figures update without making the price look newer.
        let changes = PriceLiveActivity.merged(pushed, change1h: .some(3), change24h: .some(nil))
        #expect(changes == State(usd: 0.50, change1h: 3, change24h: nil, at: 2000))
        #expect(PriceLiveActivity.merged(pushed, change1h: .some(1)) == nil)
    }

    /// L02 end to end: re-attached at launch to an activity the worker kept updating, the
    /// app's cached price used to go on top stamped "now".
    @Test func relaunchKeepsTheWorkersNewerPrice() async {
        let h = Harness(); defer { h.cleanup() }
        let a = FakeActivity(id: "A1", state: State(usd: 0.50, change1h: 1, change24h: 2, at: 2000))
        h.alive = [a]
        h.defaults.set("A1", forKey: "live.activityID")
        let live = h.live()
        #expect(live.running)
        await live.show(usd: 0.45, at: 1500)
        #expect(a.updates.isEmpty)
        await live.show(usd: 0.47, at: 2100)
        #expect(a.updates == [State(usd: 0.47, change1h: 1, change24h: 2, at: 2100)])
    }

    // MARK: worker registration (L06–L12)

    /// L06 / L12: a registration that never got through before the app was killed is sent
    /// again at relaunch (the pending flag used to live in memory only).
    @Test func relaunchResendsARegistrationThatNeverGotThrough() async {
        let h = Harness(); defer { h.cleanup() }
        h.defaults.set("aa01", forKey: LiveRegistrar.tokenKey)
        h.defaults.set(true, forKey: LiveRegistrar.pendingKey)
        h.defaults.set("A1", forKey: "live.activityID")
        h.alive = [FakeActivity(id: "A1", pushToken: "aa01")]
        let live = h.live()
        await h.settle()
        #expect(live.running)
        #expect(h.worker.rows == ["aa01"])
        #expect(h.registrar?.pending == false)
        #expect(h.defaults.object(forKey: LiveRegistrar.pendingKey) == nil)
    }

    /// L06 / L07: a token issued after the start registers; a rotated one replaces it.
    @Test func lateAndRotatedTokensReplaceTheRegistration() async throws {
        let h = Harness(); defer { h.cleanup() }
        let live = h.live()
        await live.start()
        let a = try #require(h.requested.first)
        a.issue("aa01")
        await h.settle()
        #expect(h.worker.rows == ["aa01"])
        a.issue("aa02")
        await h.settle()
        #expect(h.worker.rows == ["aa02"])
        #expect(h.registrar?.token == "aa02")
    }

    /// L08 / L09: a rotated token while the old PUT is still on the wire — the old PUT
    /// used to land after its DELETE (row left behind) and, answering OK, cleared the new
    /// token's "pending" so a failed new registration was never retried.
    @Test func supersededPutCantClearTheNewTokensPending() async throws {
        let h = Harness(); defer { h.cleanup() }
        let live = h.live()
        await live.start()
        let a = try #require(h.requested.first)
        let gate = Gate(); h.worker.holds["PUT aa01"] = gate
        a.issue("aa01")
        await h.until { h.worker.log == ["PUT aa01"] }
        h.worker.failing = ["PUT aa02"]
        a.issue("aa02")
        gate.release()
        await h.settle()
        #expect(h.worker.rows.isEmpty)
        #expect(Array(h.worker.log.prefix(2)) == ["PUT aa01", "DELETE aa01"])
        #expect(h.registrar?.token == "aa02")
        #expect(h.registrar?.pending == true)
        #expect(h.defaults.bool(forKey: LiveRegistrar.pendingKey))
    }

    /// L09: 停止 while the PUT is on the wire — the DELETE waits for it instead of
    /// overtaking it and leaving the worker pushing to an ended activity.
    @Test func deleteWaitsForThePutOnTheWire() async throws {
        let h = Harness(); defer { h.cleanup() }
        let live = h.live()
        await live.start()
        let a = try #require(h.requested.first)
        let gate = Gate(); h.worker.holds["PUT aa01"] = gate
        a.issue("aa01")
        await h.until { h.worker.log == ["PUT aa01"] }
        await live.stop()
        for _ in 0..<50 { await Task.yield() }
        #expect(h.worker.log == ["PUT aa01"])
        gate.release()
        await h.settle()
        #expect(h.worker.log == ["PUT aa01", "DELETE aa01"])
        #expect(h.worker.rows.isEmpty)
        #expect(a.ended)
    }

    /// L10: a failed DELETE used to be forgotten (token already cleared). It's kept, sent
    /// again on foreground and at the next launch.
    @Test func failedDeleteIsRetriedOnForegroundAndRelaunch() async throws {
        let h = Harness(); defer { h.cleanup() }
        let live = h.live()
        await live.start()
        let a = try #require(h.requested.first)
        a.issue("aa01")
        await h.settle()
        h.worker.failing = ["DELETE aa01"]
        await live.stop()
        await h.settle()
        #expect(h.worker.rows == ["aa01"])
        #expect(h.withdrawn["aa01"] != nil)
        live.foreground()   // still failing
        await h.settle()
        #expect(h.worker.count("DELETE aa01") == 2)
        #expect(h.withdrawn["aa01"] != nil)

        h.worker.failing = []
        let relaunched = h.live()   // the app was killed; the activity is gone
        await h.settle()
        #expect(!relaunched.running)
        #expect(h.worker.rows.isEmpty)
        #expect(h.withdrawn.isEmpty)
    }

    /// L10: a withdrawal older than the worker keeps rows (12 h) is let go, not retried.
    @Test func withdrawalsPastTheWorkersKeepAreDropped() async {
        let h = Harness(); defer { h.cleanup() }
        h.defaults.set(["aa09": h.now.timeIntervalSince1970 - 13 * 3600,
                        "aa08": h.now.timeIntervalSince1970 - 3600], forKey: LiveRegistrar.withdrawnKey)
        _ = h.live()
        await h.settle()
        #expect(h.worker.log == ["DELETE aa08"])
        #expect(h.withdrawn.isEmpty)
    }

    /// L11: one attempt plus four retries after 5 / 10 / 20 / 40 s — it used to make four
    /// requests in all and then still wait out the last 40 s.
    @Test func putRetriesFourTimesWithoutATrailingWait() async throws {
        let h = Harness(); defer { h.cleanup() }
        h.worker.failing = ["PUT aa01"]
        let live = h.live()
        await live.start()
        let a = try #require(h.requested.first)
        a.issue("aa01")
        await h.settle()
        #expect(h.worker.count("PUT aa01") == 5)
        #expect(h.sleeps == [.seconds(5), .seconds(10), .seconds(20), .seconds(40)])
        #expect(h.registrar?.pending == true)
        h.worker.failing = []
        live.foreground()
        await h.settle()
        #expect(h.worker.rows == ["aa01"])
        #expect(h.registrar?.pending == false)
    }

    /// L12: the activity ended while the app wasn't running → the registration is
    /// withdrawn at launch; an activity swiped away while running → withdrawn at once.
    @Test func endedActivitiesWithdrawTheirRegistration() async throws {
        let h = Harness(); defer { h.cleanup() }
        h.worker.rows = ["aa01"]
        h.defaults.set("aa01", forKey: LiveRegistrar.tokenKey)
        let live = h.live()
        await h.settle()
        #expect(h.worker.rows.isEmpty)
        #expect(h.defaults.string(forKey: LiveRegistrar.tokenKey) == nil)

        await live.start()
        let a = try #require(h.requested.first)
        a.issue("bb01")
        await h.settle()
        #expect(h.worker.rows == ["bb01"])
        a.dismiss()
        await h.settle()
        #expect(!live.running)
        #expect(h.worker.rows.isEmpty)
        #expect(h.defaults.string(forKey: "live.activityID") == nil)
    }
}
#endif
