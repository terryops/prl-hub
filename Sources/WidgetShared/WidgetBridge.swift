import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

// MARK: - App → widget bridge
//
// The app calls these to patch the shared snapshot and nudge WidgetKit to refresh.
// Each method writes only the fields it owns (read-modify-write) so the wallet and
// pool stores update independently without clobbering each other. Plain static
// funcs (no actor isolation): UserDefaults and WidgetCenter are both safe off-main,
// and the call sites already run on @MainActor stores.

enum WidgetBridge {
    /// Wallet store published a fresh balance / transaction list. `changePRL` is the
    /// stranded internal-chain change folded into `balancePRL`; it's mirrored so the
    /// widget's xpub-only self-refresh can add it back instead of understating holdings.
    static func updateWallet(name: String, balancePRL: Double, changePRL: Double,
                             xpub: String?, network: String, recentTx: [WidgetTx],
                             labelBalance: String, labelRecentTx: String, labelNoTx: String,
                             languageCode: String? = nil) {
        var s = WidgetStore.load()
        let before = s
        s.walletName = name
        s.balancePRL = balancePRL
        s.changePRL = changePRL
        if let xpub, !xpub.isEmpty { s.xpub = xpub }
        s.network = network
        s.recentTx = recentTx
        s.labelBalance = labelBalance
        s.labelRecentTx = labelRecentTx
        s.labelNoTx = labelNoTx
        s.languageCode = languageCode
        s.hasWallet = true
        // publishOverlay() fires several times per chain poll (and the post-send /
        // recovery loops poll every ~3s); only persist + nudge WidgetKit when a
        // displayed field actually changed, so identical re-publishes don't burn the
        // system's timeline-reload budget or rewrite the App Group for nothing.
        let dataChanged = s.balancePRL != before.balancePRL || s.changePRL != before.changePRL
            || s.xpub != before.xpub || s.network != before.network
            || s.recentTx != before.recentTx || !before.hasWallet
        let labelsChanged = s.walletName != before.walletName
            || s.labelBalance != before.labelBalance
            || s.labelRecentTx != before.labelRecentTx || s.labelNoTx != before.labelNoTx
            || s.languageCode != before.languageCode
        guard dataChanged || labelsChanged else { return }
        // Only new figures move the freshness stamp: a rename or language switch re-publishes
        // the same (possibly hours-old) balance, which must not read as just refreshed.
        if dataChanged { s.updatedAt = Date() }
        WidgetStore.save(s)
        reload()
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
        WidgetStore.save(s)
        reload()
    }

    /// Pool store refreshed — replace the full set of watches (empty clears mining).
    static func updatePools(_ pools: [WidgetPool]) {
        var s = WidgetStore.load()
        guard s.pools != pools else { return }   // skip the reload when nothing changed
        s.pools = pools
        s.updatedAt = Date()
        WidgetStore.save(s)
        reload()
    }

    /// Fresh fiat rates (only overwrite a good value, never with 0/unknown).
    static func updatePrice(prlUsd: Double?, usdCny: Double?) {
        var s = WidgetStore.load()
        var changed = false
        if let v = prlUsd, v > 0, v != s.prlUsd { s.prlUsd = v; changed = true }
        if let v = usdCny, v > 0, v != s.usdCny { s.usdCny = v; changed = true }
        guard changed else { return }            // unchanged price → no reload (60s poll)
        s.updatedAt = Date()
        WidgetStore.save(s)
        reload()
    }

    static func reload() {
        #if canImport(WidgetKit)
        // WidgetCenter is available on both iOS and macOS — nudge whichever
        // platform's home-screen / desktop widget is installed.
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
