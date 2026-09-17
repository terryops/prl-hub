import SwiftUI
import StoreKit

/// Public places the app points people to.
enum AppLinks {
    static let telegram = URL(string: "https://t.me/prl_hub")!
    static let github = URL(string: "https://github.com/terryops/prl-hub")!
}

// MARK: - App Store 评分提醒
//
// Apple's prompt makes this a question of WHEN, not how: the system shows it at most three
// times a year per user, silently swallows calls it considers too frequent, and never reports
// back whether anything appeared. So the app's whole job is to ask only at a moment where the
// answer is likely to be "yes", and never to ask twice for the same reason.
//
// The gates: at least 3 launches, at least 3 days since the first one, at most once per app
// VERSION, and never within 120 days of the last ask. The moment itself is a 我的监控 refresh
// that actually returned a miner's rigs (see PoolView) — the user just watched their hardware
// report in, which is the app working, rather than a cold launch where nothing has happened.
//
// Because the system prompt can't be counted on to appear, 设置 → 关于 also carries a manual
// "为 Pearl Hub 评分" row that opens the App Store review sheet directly.
enum ReviewPrompt {
    /// App Store adam id for com.prl.wizard (Pearl Hub - Wallet and Mining).
    static let appStoreID = "6777132941"

    private static let launchesKey = "review.launchCount"
    private static let firstLaunchKey = "review.firstLaunch"      // unix seconds
    private static let lastAskedKey = "review.lastAsked"          // unix seconds
    private static let askedVersionKey = "review.askedVersion"    // MARKETING_VERSION

    private static let minLaunches = 3
    private static let minDaysInstalled: Double = 3
    private static let minDaysBetweenAsks: Double = 120

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Count this launch. Cheap and idempotent per process — call it once from the root view.
    static func registerLaunch() {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: launchesKey) + 1, forKey: launchesKey)
        if d.double(forKey: firstLaunchKey) <= 0 {
            d.set(Date().timeIntervalSince1970, forKey: firstLaunchKey)
        }
    }

    /// Launches counted so far (also gates the donation prompt).
    static var launchCount: Int { UserDefaults.standard.integer(forKey: launchesKey) }

    /// Days since the first counted launch; 0 before it is recorded.
    static var daysSinceFirstLaunch: Double {
        let first = UserDefaults.standard.double(forKey: firstLaunchKey)
        return first > 0 ? (Date().timeIntervalSince1970 - first) / 86400 : 0
    }

    /// Whether asking now is reasonable. Deliberately conservative: a prompt the user dismisses
    /// is one of the three the system will show them this year, spent for nothing.
    static var isEligible: Bool {
        let d = UserDefaults.standard
        guard d.integer(forKey: launchesKey) >= minLaunches else { return false }
        let now = Date().timeIntervalSince1970
        let first = d.double(forKey: firstLaunchKey)
        guard first > 0, now - first >= minDaysInstalled * 86400 else { return false }
        // Once per version: a user who declined on 1.8 shouldn't be asked again until there is
        // genuinely something new to like.
        guard d.string(forKey: askedVersionKey) != appVersion else { return false }
        let last = d.double(forKey: lastAskedKey)
        return last <= 0 || now - last >= minDaysBetweenAsks * 86400
    }

    /// Record that the prompt was requested. (Requested, not shown — the system never says.)
    static func markAsked() {
        let d = UserDefaults.standard
        d.set(Date().timeIntervalSince1970, forKey: lastAskedKey)
        d.set(appVersion, forKey: askedVersionKey)
    }

    /// Deep link that opens the App Store page with the review sheet already up. Used by the
    /// manual 设置 row, where the user has explicitly asked to leave a review, so the system
    /// prompt's rate limiting must not be able to swallow it.
    static var writeReviewURL: URL? {
        URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
    }
}

extension View {
    /// Ask for a rating the first time `whenSucceeded` becomes true in this session, provided
    /// every gate in `ReviewPrompt.isEligible` is satisfied.
    ///
    /// The short delay keeps the prompt from landing on top of the animation that just told
    /// the user their rigs are online — the sheet should arrive as a beat after the good news,
    /// not as an interruption of it.
    func reviewPrompt(whenSucceeded trigger: Bool) -> some View {
        modifier(ReviewPromptModifier(trigger: trigger))
    }
}

private struct ReviewPromptModifier: ViewModifier {
    let trigger: Bool
    @Environment(\.requestReview) private var requestReview
    /// Once per view lifetime, so a value that flickers true→false→true (a refresh landing
    /// between fetches) can't queue a second request.
    @State private var asked = false

    func body(content: Content) -> some View {
        content
            .onChange(of: trigger) { _, now in ask(now) }
            .onAppear { ask(trigger) }
    }

    private func ask(_ now: Bool) {
        guard now, !asked, ReviewPrompt.isEligible else { return }
        asked = true
        ReviewPrompt.markAsked()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            requestReview()
        }
    }
}
