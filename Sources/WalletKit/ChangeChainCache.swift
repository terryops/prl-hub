import Foundation

/// The persisted half of the stranded-change tracker (see `WalletStore.refreshChangeChain`),
/// one per wallet + network, in UserDefaults under `<prefix><network>.<field>`.
struct ChangeChainCache: Equatable {
    /// Change addresses confirmed ours by trial-signing.
    var owned: Set<String> = []
    /// Candidates confirmed NOT ours (external recipients) — never re-tested.
    var foreign: Set<String> = []
    /// Unclassified candidates whose output (from a CONFIRMED tx) was already spent: there
    /// is nothing left on them to test or to recover.
    var empty: Set<String> = []
    /// Owned addresses that are fully spent, their spends merged and deeply confirmed — the
    /// per-load refresh skips them; a forced scan (the recovery screen) still re-checks them.
    var retired: Set<String> = []
    /// Change-chain spends of retired addresses that the xpub history can't show, kept so
    /// they stay in the tx list without re-fetching each retired address every load.
    var archive: [WalletTx] = []
    /// Every confirmed send mined at or below this block has had its outputs classified, so
    /// discovery only needs to look at newer blocks.
    var scanHeight: Int?
    /// Last scanned change balance, so the first publish after launch already includes it.
    var balance: WalletBalance?

    /// Owned addresses still worth watching on every load.
    var active: Set<String> { owned.subtracting(retired) }

    static let fields = ["owned", "foreign", "balance", "ver", "empty", "retired", "archive", "scanHeight"]

    /// Bump when the ownership-oracle logic changes so cached classifications (which may
    /// have wrongly tagged small owned change as foreign) are dropped and re-tested once.
    static let version = 2

    static func load(prefix: String, network: WalletNetwork) -> ChangeChainCache {
        let d = UserDefaults.standard
        let k = { (field: String) in "\(prefix)\(network.rawValue).\(field)" }
        // Drop a stale-versioned cache (the prior oracle could mis-tag small owned change
        // as foreign): start empty so every candidate is re-tested once with the new oracle.
        guard d.integer(forKey: k("ver")) == version else {
            for f in fields { d.removeObject(forKey: k(f)) }
            d.set(version, forKey: k("ver"))
            return ChangeChainCache()
        }
        func set(_ field: String) -> Set<String> { Set((d.array(forKey: k(field)) as? [String]) ?? []) }
        var c = ChangeChainCache()
        c.owned = set("owned")
        c.foreign = set("foreign")
        c.empty = set("empty")
        c.retired = set("retired").intersection(c.owned)
        c.archive = d.data(forKey: k("archive")).flatMap { try? JSONDecoder().decode([WalletTx].self, from: $0) } ?? []
        c.scanHeight = d.object(forKey: k("scanHeight")) as? Int
        if let cached = d.array(forKey: k("balance")) as? [String], cached.count == 2,
           let total = Decimal(string: cached[0]), let available = Decimal(string: cached[1]) {
            c.balance = WalletBalance(total: total, available: available)
        }
        return c
    }

    func save(prefix: String, network: WalletNetwork) {
        let d = UserDefaults.standard
        let k = { (field: String) in "\(prefix)\(network.rawValue).\(field)" }
        d.set(Array(owned), forKey: k("owned"))
        d.set(Array(foreign), forKey: k("foreign"))
        d.set(Array(empty), forKey: k("empty"))
        d.set(Array(retired), forKey: k("retired"))
        if archive.isEmpty { d.removeObject(forKey: k("archive")) }
        else if let data = try? JSONEncoder().encode(archive) { d.set(data, forKey: k("archive")) }
        if let scanHeight { d.set(scanHeight, forKey: k("scanHeight")) } else { d.removeObject(forKey: k("scanHeight")) }
        if let balance { d.set(["\(balance.total)", "\(balance.available)"], forKey: k("balance")) }
        d.set(Self.version, forKey: k("ver"))
    }

    /// Forget a wallet's caches on every network (wallet removed).
    static func remove(prefix: String) {
        let d = UserDefaults.standard
        for n in WalletNetwork.allCases {
            for f in fields { d.removeObject(forKey: "\(prefix)\(n.rawValue).\(f)") }
        }
    }
}
