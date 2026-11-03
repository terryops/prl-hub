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
    static let quoteKind = "PRLHubQuoteWidget"
    static let change1hKind = "PRLHubChange1hWidget"
    static let change24hKind = "PRLHubChange24hWidget"
    static let quoteMiningKind = "PRLHubQuoteMiningWidget"

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
        // An in-flight widget balance fetch started before this write must not land on it.
        s.walletRev = (s.walletRev ?? 0) &+ 1
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
        s.walletRev = (s.walletRev ?? 0) &+ 1
        WidgetStore.save(s)
        reloadHome()
    }

    /// Pool store published its watches — the full set (empty clears mining). `current`: the
    /// indices whose figures were just read (nil = all of them); the rest keep what the widget
    /// already shows for that target. See `WidgetSnapshot.publishAppPools`.
    static func updatePools(_ pools: [WidgetPool], current: Set<Int>? = nil) {
        let now = Date()
        var result = WidgetSnapshot.PoolsPublish.unchanged
        WidgetStore.update { s in
            result = s.publishAppPools(pools, current: current ?? Set(pools.indices), now: now)
            return result != .unchanged
        }
        switch result {
        case .unchanged: break
        case .restamp(let reloadQuote): if reloadQuote { reloadQuoteMining() }
        case .changed: reloadHome(); reloadQuoteMining()
        }
    }

    /// A fresh PRL price (only overwrites with a good value, never 0/unknown).
    /// `prlUsdAt` is when it was fetched; pass it only for a genuinely fresh value —
    /// the widgets reuse a recent one instead of fetching their own. The secondary
    /// currency comes from `updateFiat`.
    static func updatePrice(prlUsd: Double?, prlUsdAt: Date? = nil) {
        var s = WidgetStore.load()
        let (changed, restamp) = s.publishAppPrice(prlUsd, at: prlUsdAt, now: Date())
        guard changed || restamp else { return }
        WidgetStore.save(s)
        guard changed else { return }            // unchanged price → no reload (15–60 s polls)
        reloadLock()
        reloadHome()
    }

    /// Publish rolling changes even when the spot price itself has not moved.
    static func updateMarketQuote(_ quote: WidgetMarketQuote) {
        guard quote.isFresh() else { return }
        var s = WidgetStore.load()
        let before = s
        guard s.applyMarketQuote(quote) else { return }
        if before.prlUsd != s.prlUsd { s.updatedAt = max(valid(s.updatedAt) ?? .distantPast, quote.at) }
        WidgetStore.save(s)
        if before.marketQuote?.isFresh(maxAge: WidgetMarketQuote.staleAfter) != true
            || before.marketQuote?.change1h != quote.change1h
            || before.marketQuote?.change24h != quote.change24h || before.prlUsd != s.prlUsd {
            reloadLock()
        }
        if before.prlUsd != s.prlUsd { reloadHome() }
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

    /// Pro status changed (or is published for the first time). The home widget is a
    /// Pro feature, so it reloads at once — past the throttle — to lock or unlock.
    static func updatePro(_ isPro: Bool) {
        var s = WidgetStore.load()
        guard s.isPro != isPro else { return }
        s.isPro = isPro
        WidgetStore.save(s)
        reload(kind: homeKind)
    }

    /// Appearance changes refresh immediately, independently of the data throttle.
    @discardableResult
    static func updateAppearance(palette: String, icon: String, mode: String) -> Bool {
        guard WidgetAppearance(palette: palette, icon: icon, mode: mode).save() else { return false }
        reload(kind: homeKind)
        reloadLock()
        return true
    }

    /// No stamp, one at least `maxAge` old, or one from the future (see `valid`).
    nonisolated static func isStale(_ at: Date?, now: Date, maxAge: TimeInterval = restampAfter) -> Bool {
        valid(at, now: now).map { now.timeIntervalSince($0) >= maxAge } ?? true
    }

    /// How far ahead of the clock a stamp may sit (a server timestamp a little ahead of
    /// ours, an NTP nudge) and still count.
    nonisolated static let clockSkew: TimeInterval = 60

    /// The stamp, unless it lies further in the future than `clockSkew` — which only
    /// happens when the clock was set back after it was written. Such a stamp would read
    /// as "just now" until the clock caught up: every refresh skipped as unnecessary and
    /// every newer figure rejected as older.
    nonisolated static func valid(_ at: Date?, now: Date = Date()) -> Date? {
        guard let at, at.timeIntervalSince(now) <= clockSkew else { return nil }
        return at
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

    /// All Lock Screen variants share the app's price and rolling-change snapshot.
    static func reloadLock() {
        #if os(iOS)
        for kind in [lockKind, quoteKind, change1hKind, change24hKind, quoteMiningKind] { reload(kind: kind) }
        #endif
    }

    private static func reloadQuoteMining() {
        #if os(iOS)
        reload(kind: quoteMiningKind)
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
        // `now < last`: the clock was set back. Waiting for `last + interval` could take
        // days, and every request until then would coalesce into that one reload.
        if let last, now >= last, now.timeIntervalSince(last) < interval {
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

extension WidgetSnapshot {
    /// The app's spot price. `at` is its fetch time; pass it only for a genuinely fresh value.
    /// A price without one (a mirror of the app's cached value) never replaces a stamped price —
    /// it may be older than one a widget fetched since — and never inherits that stamp either.
    mutating func publishAppPrice(_ usd: Double?, at: Date?, now: Date) -> (changed: Bool, restamp: Bool) {
        guard let v = usd, v.isFinite, v > 0 else { return (false, false) }
        let stamped = WidgetBridge.valid(prlUsdAt, now: max(now, at ?? now))
        guard let at else {
            guard stamped == nil, v != prlUsd else { return (false, false) }
            prlUsd = v
            prlUsdAt = nil
            updatedAt = now
            return (true, false)
        }
        guard at > (stamped ?? .distantPast) else { return (false, false) }
        let changed = v != prlUsd
        prlUsd = v
        prlUsdAt = at
        if changed { updatedAt = now }
        return (changed, true)
    }
}
