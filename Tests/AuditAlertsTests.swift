import Foundation
import Testing
@testable import Pearl

/// 价格提醒 / 掉线提醒: the device record on the worker (PUT / DELETE /v1/devices/:token).
/// The Android audit of 2026-10-27 (P01–P02) found requests overtaking each other there;
/// these check the iOS side against a fake worker — no network, no real push token.
@MainActor
struct AuditAlertsTests {
    private let tokenA = String(repeating: "aa", count: 32)
    private let tokenB = String(repeating: "bb", count: 32)
    private let tokenC = String(repeating: "cc", count: 32)
    private var dataA: Data { Data(repeating: 0xaa, count: 32) }
    private var dataB: Data { Data(repeating: 0xbb, count: 32) }

    private func makeStore(_ setup: (UserDefaults) -> Void = { _ in }) throws -> (PriceAlertStore, FakeWorker, UserDefaults, String) {
        let suite = "AuditAlertsTests." + UUID().uuidString
        let d = try #require(UserDefaults(suiteName: suite))
        d.set(tokenA, forKey: "alerts.apnsToken")
        setup(d)
        let store = PriceAlertStore(defaults: d)
        let worker = FakeWorker()
        store.transport = { try await worker.send($0) }
        return (store, worker, d, suite)
    }

    private func finish(_ worker: FakeWorker, _ d: UserDefaults, _ suite: String) async {
        worker.answer = { _ in .ok }
        worker.releaseAll()
        _ = await eventually { worker.inFlight == 0 }
        d.removePersistentDomain(forName: suite)
    }

    /// A PUT the worker is still handling is already there: a newer one must not overtake
    /// it (cancelling only stopped the app listening). Before the fix the second PUT went
    /// out 0.4 s later while the first was still held — two in flight.
    @Test func aNewerPutWaitsForTheOneStillOnTheWorker() async throws {
        let (store, worker, d, suite) = try makeStore()
        worker.answer = { _ in .hold }
        store.contentChanged(prompt: false)
        #expect(await eventually { worker.calls.count == 1 })
        worker.answer = { _ in .ok }
        store.contentChanged(prompt: false)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(worker.calls.count == 1)
        #expect(worker.maxInFlight == 1)
        worker.release()
        #expect(await eventually { worker.calls.count >= 2 && worker.inFlight == 0 })
        #expect(worker.maxInFlight == 1)
        #expect(worker.calls.allSatisfy { $0.method == "PUT" && $0.path == "/v1/devices/" + tokenA })
        await finish(worker, d, suite)
    }

    /// A rotated token: its record is deleted only after the PUT to it has been answered,
    /// a DELETE that couldn't get through stays owed, and a token the system hands back
    /// (A → B → A) is never deleted. Before the fix the DELETE went out at once (racing the
    /// PUT) and was forgotten if it failed.
    @Test func aRotatedTokensRecordGoesAfterItsPutAndStaysOwedUntilAnswered() async throws {
        let (store, worker, d, suite) = try makeStore()
        worker.answer = { _ in .hold }
        store.contentChanged(prompt: false)
        #expect(await eventually { worker.calls.count == 1 })
        worker.answer = { $0.httpMethod == "DELETE" ? .offline : .ok }
        store.didRegister(tokenData: dataB)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(worker.calls.count == 1)
        #expect(d.stringArray(forKey: "alerts.staleTokens") == [tokenA])

        worker.release()
        #expect(await eventually {
            worker.inFlight == 0 && worker.calls.contains { $0.method == "PUT" && $0.path == "/v1/devices/" + tokenB }
        })
        #expect(worker.maxInFlight == 1)
        let deleteA = try #require(worker.calls.firstIndex { $0.method == "DELETE" && $0.path == "/v1/devices/" + tokenA })
        #expect(deleteA > 0)   // after the PUT to A
        #expect(d.stringArray(forKey: "alerts.staleTokens") == [tokenA])   // offline: still owed

        worker.answer = { _ in .ok }
        let before = worker.calls.count
        store.didRegister(tokenData: dataA)
        #expect(await eventually {
            worker.inFlight == 0 && (d.stringArray(forKey: "alerts.staleTokens") ?? []).isEmpty
                && worker.calls[before...].contains { $0.method == "PUT" && $0.path == "/v1/devices/" + tokenA }
        })
        let later = worker.calls[before...]
        #expect(later.contains { $0.method == "DELETE" && $0.path == "/v1/devices/" + tokenB })
        #expect(!later.contains { $0.method == "DELETE" && $0.path == "/v1/devices/" + tokenA })
        #expect(store.token == tokenA)
        await finish(worker, d, suite)
    }

    /// A DELETE still owed from an earlier run goes at launch — never one for the token
    /// in use now. (Before the fix nothing remembered it.)
    @Test func aRecordStillOwedFromAnEarlierRunIsForgottenAtLaunch() async throws {
        let owed = [tokenA, tokenC], current = tokenC
        let (store, worker, d, suite) = try makeStore { pre in
            pre.set(current, forKey: "alerts.apnsToken")
            pre.set(false, forKey: "alerts.pushHere")   // nothing else to send
            pre.set(owed, forKey: "alerts.staleTokens")
        }
        store.launch()
        #expect(await eventually { worker.inFlight == 0 && (d.stringArray(forKey: "alerts.staleTokens") ?? []).isEmpty })
        #expect(worker.calls.map { "\($0.method) \($0.path)" } == ["DELETE /v1/devices/" + tokenA])
        #expect(store.token == tokenC)
        await finish(worker, d, suite)
    }

    /// P03: the system failing to hand over a token is not the worker forgetting this
    /// device — the known record still gets the switch-off.
    @Test func aFailedTokenRequestKeepsTheWayToSwitchOff() async throws {
        let (store, worker, d, suite) = try makeStore()
        store.didFailToRegister(URLError(.notConnectedToInternet))
        #expect(store.token == tokenA)
        store.setPushHere(false)
        #expect(await eventually { !worker.calls.isEmpty && worker.inFlight == 0 })
        let put = try #require(worker.calls.first)
        #expect(put.method == "PUT" && put.path == "/v1/devices/" + tokenA)
        #expect((put.body?["rules"] as? [Any])?.isEmpty == true)
        #expect((put.body?["watches"] as? [Any])?.isEmpty == true)
        await finish(worker, d, suite)
    }
}

/// Stands in for the worker: records each request, can hold one open (the worker
/// still handling it) or fail it as if offline.
@MainActor
private final class FakeWorker {
    enum Answer { case ok, hold, offline }
    struct Call {
        let method: String
        let path: String
        let body: [String: Any]?
    }

    private(set) var calls: [Call] = []
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    var answer: (URLRequest) -> Answer = { _ in .ok }

    func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        let body = req.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        calls.append(Call(method: req.httpMethod ?? "GET", path: req.url?.path ?? "", body: body))
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer { inFlight -= 1 }
        switch answer(req) {
        case .ok: break
        case .hold: await withCheckedContinuation { held.append($0) }
        case .offline: throw URLError(.notConnectedToInternet)
        }
        let url = req.url ?? PriceAlertStore.endpoint
        let reply = req.httpMethod == "PUT" ? #"{"rules":[],"watches":[]}"# : #"{"ok":true}"#
        return (Data(reply.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    /// Let the oldest held request answer.
    func release() { if !held.isEmpty { held.removeFirst().resume() } }
    func releaseAll() { while !held.isEmpty { release() } }
}

@MainActor
private func eventually(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > end { return false }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return true
}
