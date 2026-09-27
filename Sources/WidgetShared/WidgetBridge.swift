import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - App → widget bridge
//
// The app calls these to patch the shared snapshot and nudge WidgetKit to refresh.
// Each method writes only the fields it owns (read-modify-write) so the wallet and
// pool stores update independently without clobbering each other. Main-actor: every
// caller is a @MainActor store, and the reload throttle below keeps state.
//
// Reloads are cheap to ask for but not to serve: each one re-runs the widget's
// timeline, which self-fetches whatever the app hasn't published recently. So the
// home widget reloads at most once a minute (trailing), and a price-only change —
// the Trade tab publishes one every 5 s — reloads just the Lock Screen price widget
// right away; the home widget picks the price up on its next throttled reload.

@MainActor
enum WidgetBridge {
    static let homeKind = "PRLHubWidget"
    static let lockKind = "PRLHubLockWidget"

    /// How long a published figure counts as current: widget reloads inside this
    /// window reuse it instead of fetching their own.
    nonisolated static let freshFor: TimeInterval = 120
    /// Re-stamp an unchanged figure at most this often (each stamp rewrites the App
    /// Group JSON); well inside `freshFor`, so a steady app keeps the widget fetch-free.
    nonisolated static let restampAfter: TimeInterval = 60

    /// Wallet store published a fresh balance / transaction list. `changePRL` is the
    /// stranded internal-chain change folded into `balancePRL`; it's mirrored so the
    /// widget's xpub-only self-refresh can add it back instead of understating holdings.
    /// The label arguments are unused — the widget now looks its labels up in its own
    /// copy of the string tables — and kept only so existing call sites compile.
    static func updateWallet(name: String, balancePRL: Double, changePRL: Double,
                             xpub: String?, network: String, recentTx: [WidgetTx],
                             labelBalance: String = "", labelRecentTx: String = "", labelNoTx: String = "",
                             languageCode: String? = nil) {
        var s = WidgetStore.load()
        let before = s
        let now = Date()
        s.walletName = name
        s.balancePRL = balancePRL
        s.changePRL = changePRL
        if let xpub, !xpub.isEmpty { s.xpub = xpub }
        s.network = network
        s.recentTx = recentTx
        if let languageCode { s.languageCode = languageCode }
        s.hasWallet = true
        // publishOverlay() fires several times per chain poll (and the post-send /
        // recovery loops poll every ~3s); only persist + nudge WidgetKit when a
        // displayed field actually changed, so identical re-publishes don't burn the
        // system's timeline-reload budget or rewrite the App Group for nothing.
        let dataChanged = s.balancePRL != before.balancePRL || s.changePRL != before.changePRL
            || s.xpub != before.xpub || s.network != before.network
            || s.recentTx != before.recentTx || !before.hasWallet
        let labelsChanged = s.walletName != before.walletName || s.languageCode != before.languageCode
        if dataChanged || isStale(before.walletAt, now: now) { s.walletAt = now }
        guard dataChanged || labelsChanged || s.walletAt != before.walletAt else { return }
        // Only new figures move the freshness stamp: a rename or language switch re-publishes
        // the same (possibly hours-old) balance, which must not read as just refreshed.
        if dataChanged { s.updatedAt = now }
        WidgetStore.save(s)
        if dataChanged || labelsChanged { reloadHome() }
    }

    /// The open wallet was removed or replaced: drop its xpub, balance and transfers so the
    /// widget stops fetching and showing them. The next wallet's first publish fills it in.
    static func clearWallet() {
        var s = WidgetStore.load()
        guard s.hasWallet || s.xpub != nil else { return }
        s.hasWallet = false
        s.xpub = nil
        s.walletName = WidgetSnapshot().walletName
        s.balancePRL = 0
        s.changePRL = 0
        s.recentTx = []
        s.walletAt = nil
        WidgetStore.save(s)
        reloadHome()
    }

    /// Pool store refreshed — replace the full set of watches (empty clears mining).
    static func updatePools(_ pools: [WidgetPool]) {
        var s = WidgetStore.load()
        let now = Date()
        if s.pools == pools {
            // Unchanged: only keep the "just published" stamp current (no reload).
            guard isStale(s.poolsAt, now: now) else { return }
            s.poolsAt = now
            WidgetStore.save(s)
            return
        }
        s.pools = pools
        s.poolsAt = now
        s.updatedAt = now
        WidgetStore.save(s)
        reloadHome()
    }

    /// A fresh PRL price (only overwrites with a good value, never 0/unknown).
    /// `prlUsdAt` is when it was fetched; pass it only for a genuinely fresh value —
    /// the widgets reuse a recent one instead of fetching their own. `usdCny` is
    /// ignored: the secondary currency now comes from `updateFiat`.
    static func updatePrice(prlUsd: Double?, usdCny: Double? = nil, prlUsdAt: Date? = nil) {
        var s = WidgetStore.load()
        var changed = false
        if let v = prlUsd, v > 0, v != s.prlUsd { s.prlUsd = v; changed = true }
        let restamp = prlUsdAt.map { at in (prlUsd ?? 0) > 0 && at > (s.prlUsdAt ?? .distantPast) } ?? false
        if restamp { s.prlUsdAt = prlUsdAt }
        // A price written without its fetch time (e.g. a disk-cached one) must not
        // inherit the previous value's fresh stamp — widgets would reuse it as new.
        else if changed, prlUsdAt == nil, s.prlUsdAt != nil { s.prlUsdAt = nil }
        guard changed || restamp else { return }
        if changed { s.updatedAt = Date() }
        WidgetStore.save(s)
        guard changed else { return }            // unchanged price → no reload (15–60 s polls)
        reloadLock()
        reloadHome()
    }

    /// The secondary currency or its rate changed (nil = show USD only).
    static func updateFiat(_ fiat: WidgetFiat?) {
        var s = WidgetStore.load()
        guard s.fiat != fiat else { return }
        s.fiat = fiat
        WidgetStore.save(s)
        reloadHome()
    }

    /// The app's resolved UI language changed (or is being published for the first
    /// time) — both widgets draw localized text.
    static func updateLanguage(_ code: String) {
        var s = WidgetStore.load()
        guard s.languageCode != code else { return }
        s.languageCode = code
        WidgetStore.save(s)
        reloadLock()
        reloadHome()
    }

    /// No stamp, or one at least `maxAge` old.
    nonisolated static func isStale(_ at: Date?, now: Date, maxAge: TimeInterval = restampAfter) -> Bool {
        at.map { now.timeIntervalSince($0) >= maxAge } ?? true
    }

    // MARK: reloads

    private static var homeThrottle = WidgetReloadThrottle(interval: 60)

    /// Reload the home-screen / desktop widget now, or once the throttle window
    /// has passed (at most one pending reload).
    static func reloadHome() {
        switch homeThrottle.request(at: Date()) {
        case .reloadNow:
            reload(kind: homeKind)
        case .schedule(let at):
            Task {
                try? await Task.sleep(for: .seconds(max(0, at.timeIntervalSinceNow)))
                homeThrottle.fire(at: Date())
                reload(kind: homeKind)
            }
        case .none:
            break
        }
    }

    /// The Lock Screen widget shows only the price, which the app hands it in the
    /// snapshot — reloading it costs no network, so it follows the price directly.
    static func reloadLock() {
        #if os(iOS)
        reload(kind: lockKind)
        #endif
    }

    private static func reload(kind: String) {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        #endif
    }
}

/// At most one reload per `interval`: an early request becomes a single trailing
/// reload at the end of the window, and requests while one is pending coalesce.
struct WidgetReloadThrottle {
    enum Action: Equatable { case reloadNow, schedule(at: Date), none }

    let interval: TimeInterval
    private(set) var last: Date?
    private(set) var pending: Date?

    init(interval: TimeInterval) { self.interval = interval }

    mutating func request(at now: Date) -> Action {
        if pending != nil { return .none }
        if let last, now.timeIntervalSince(last) < interval {
            let at = last.addingTimeInterval(interval)
            pending = at
            return .schedule(at: at)
        }
        last = now
        return .reloadNow
    }

    /// The scheduled reload ran.
    mutating func fire(at now: Date) {
        pending = nil
        last = now
    }
}
