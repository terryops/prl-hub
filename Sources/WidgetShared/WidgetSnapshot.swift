import Foundation

// MARK: - Cross-process widget snapshot
//
// The app writes this to the shared App Group container; the home-screen widgets
// read it. Two widgets consume it:
//   • Wallet widget  — balance (+ fiat) + recent transfers.
//   • Mining widget  — every pool watch's hashrate / online workers (2+).
//
// It carries INPUTS the widgets self-refresh with (xpub/network, each pool's
// kind+address) and the last VALUES the app computed (immediate display + the
// fallback used whenever a self-fetch fails). No SPEND authority crosses: an
// account xpub and public mining addresses reveal balances/hashrate only, and an
// F2Pool watch's read-only page URL — the one identifier here that is a capability
// rather than a public fact — grants read-only stats and is revocable on f2pool.
// The mnemonic / Keychain stay in the app process.

struct WidgetTx: Codable, Equatable {
    var received: Bool       // true = incoming, false = outgoing
    var amount: Double       // PRL, always positive
    var time: Date
}

struct WidgetPool: Codable, Equatable {
    var label: String        // user alias or pool name
    var kind: String         // PoolKind.rawValue (e.g. "AlphaPool")
    var address: String      // public mining address — or, for F2Pool, its read-only page URL
    var hashrate: String     // formatted REAL-TIME (瞬时) hashrate, e.g. "1.23 GH/s"
    var hashrateRaw: Double  // raw real-time H/s (Σ per-worker live)
    var online: Int          // online workers
    var total: Int           // total workers
}

struct WidgetSnapshot: Codable {
    // Wallet
    var xpub: String?
    var network: String = "mainnet"        // WalletNetwork.rawValue
    var walletName: String = "Pearl Wallet"
    var balancePRL: Double = 0
    // Internal-chain change the xpub scan misses (the stranded-change total). The app
    // publishes it separately so the widget's own xpub-only self-refresh can add it
    // back — fetching just the xpub would otherwise understate holdings on any wallet
    // whose change stranded on the internal chain. balancePRL already includes it when
    // the app writes; the widget recombines bal(xpub) + changePRL on self-refresh.
    var changePRL: Double = 0
    var hasWallet: Bool = false
    var recentTx: [WidgetTx] = []
    /// When the app last published the wallet figures (even unchanged ones). A widget
    /// reload within a couple of minutes of that reuses them instead of re-fetching,
    /// and a slow self-fetch never overwrites figures the app wrote while it ran.
    var walletAt: Date?

    // Fiat
    var prlUsd: Double = 0                  // 1 PRL → USD   (0 = unknown)
    /// When prlUsd was fetched (by the app or a widget). Optional so snapshots saved
    /// before this field existed still decode. Lets a widget reuse the app's
    /// just-fetched price instead of fetching its own, slightly different one.
    var prlUsdAt: Date?
    /// The user's secondary currency (设置 → 货币) with the app's cached rate; nil when
    /// they show USD only (or the rate hasn't loaded yet).
    var fiat: WidgetFiat?

    // Mining (every watch)
    var pools: [WidgetPool] = []
    /// When the app last published the pool figures — same role as `walletAt`.
    var poolsAt: Date?

    // The app's resolved UI language as an .lproj code ("en", "zh-Hant", …). The
    // widget looks its labels up in that table and points its date / relative-time
    // formatters at it, so it follows the app rather than the device language.
    // Optional so a snapshot written before this field existed still decodes.
    var languageCode: String? = nil

    // Pro unlocks the home-screen / desktop widget. The app publishes its StoreKit-
    // verified status here; nil = not published yet (the widget then asks StoreKit).
    var isPro: Bool? = nil

    var updatedAt: Date = .distantPast
}

/// The one in-app purchase (Pearl Hub Pro) — checked by the app and the widget alike.
enum ProProduct {
    static let id = "com.prl.wizard.pro"
}

/// Secondary fiat for the widget's "≈ $33.08 · ¥224.53" line.
struct WidgetFiat: Codable, Equatable {
    var code: String         // ISO 4217, e.g. "CNY"
    var symbol: String       // e.g. "¥", "NT$"
    var decimals: Int
    var rate: Double         // 1 USD → this currency
}

// MARK: - Shared App Group store

enum WidgetStore {
    /// Must match the App Group capability on both the app and the widget target.
    static let appGroup = "group.com.prl.wizard"
    // v3: pool hashrate switched from the 24h estimate to the real-time (瞬时) rate;
    // bump so a stale v2 snapshot is ignored rather than briefly showing the old key set.
    private static let key = "widget.snapshot.v3"

    // One instance per process instead of a new one on every access (UserDefaults
    // is thread-safe, just not marked Sendable).
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: appGroup)

    static func load() -> WidgetSnapshot {
        guard let data = defaults?.data(forKey: key),
              let snap = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return WidgetSnapshot() }
        return snap
    }

    static func save(_ snap: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        defaults?.set(data, forKey: key)
    }
}
