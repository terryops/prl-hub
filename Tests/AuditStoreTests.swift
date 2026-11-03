import Foundation
import Testing
@testable import Pearl

// 2026-10-27 Android audit, iOS side: purchases, account sync and system prompts
// (docs/bugfixes-2026-10-27.md in prl-hub-android, B01–B10 / E01–E05). Nothing here touches
// StoreKit, the network, the Keychain or a real UserDefaults key.

@MainActor private final class ReviewCalls { var log: [String] = [] }

/// B09 / B10: the rating request waits a beat after the good news. Leaving the app (or the
/// screen) meanwhile must cost nothing — before, the version's ask and the 120-day pause were
/// recorded first, then the system silently dropped the request from the background.
@MainActor
struct ReviewAskTests {
    private func ask(after delay: Duration = .zero, active: Bool = true, eligible: Bool = true,
                     _ calls: ReviewCalls) async -> Bool {
        await ReviewPrompt.ask(after: delay, active: { active }, eligible: { eligible },
                               record: { calls.log.append("record") }, request: { calls.log.append("request") })
    }

    @Test func backgroundedDuringTheBeatRecordsNothing() async {
        let calls = ReviewCalls()
        #expect(await ask(active: false, calls) == false)
        #expect(calls.log.isEmpty)
    }

    @Test func calledOffDuringTheBeatRecordsNothing() async {
        let calls = ReviewCalls()
        let task = Task { @MainActor in
            await ReviewPrompt.ask(after: .seconds(30), active: { true }, eligible: { true },
                                   record: { calls.log.append("record") }, request: { calls.log.append("request") })
        }
        task.cancel()
        #expect(await task.value == false)
        #expect(calls.log.isEmpty)
    }

    @Test func gatesAreReadAgainAfterTheBeat() async {
        // Another screen asked meanwhile: this version's ask is spent.
        let calls = ReviewCalls()
        #expect(await ask(eligible: false, calls) == false)
        #expect(calls.log.isEmpty)
    }

    @Test func inFrontItIsRecordedThenRequested() async {
        let calls = ReviewCalls()
        #expect(await ask(calls))
        #expect(calls.log == ["record", "request"])
    }
}

/// B06: an offered App Store purchase is re-offered only an hour after the worker's verdict.
/// A request that never got one (offline, a 5xx) must be retried on the next sync instead.
struct PurchaseOfferRetryTests {
    @Test func workerVerdictsWaitTheHour() {
        #expect(WebLinkStore.offerAnswered(WebLinkStore.Failure.refused))      // bad receipt, stale sign-in
        #expect(WebLinkStore.offerAnswered(WebLinkStore.Failure.conflict))     // linked to another account
        #expect(WebLinkStore.offerAnswered(WebLinkStore.Failure.requiresPro))
    }

    @Test func noAnswerIsOfferedAgain() {
        #expect(!WebLinkStore.offerAnswered(WebLinkStore.Failure.server))
        #expect(!WebLinkStore.offerAnswered(WebLinkStore.Failure.network))
        #expect(!WebLinkStore.offerAnswered(URLError(.notConnectedToInternet)))
        #expect(!WebLinkStore.offerAnswered(URLError(.timedOut)))
        #expect(!WebLinkStore.offerAnswered(CancellationError()))
    }
}

/// The new-version lookup's 6-hour pause must not stall when the clock is set back
/// (the same rule as G07 for the widget's retry gate).
@MainActor
struct UpdateCheckDueTests {
    private let now: TimeInterval = 1_800_000_000

    @Test func waitsSixHoursBetweenAnswers() {
        #expect(UpdateChecker.isDue(lastChecked: 0, now: now))                 // never checked
        #expect(!UpdateChecker.isDue(lastChecked: now - 3600, now: now))
        #expect(UpdateChecker.isDue(lastChecked: now - 6 * 3600, now: now))
    }

    @Test func aStampFromTheFutureIsDue() {
        // Checked while the clock ran a day ahead; now it is right again.
        #expect(UpdateChecker.isDue(lastChecked: now + 86400, now: now))
        #expect(UpdateChecker.isDue(lastChecked: now + 1, now: now))
    }
}
