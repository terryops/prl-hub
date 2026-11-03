import Foundation

/// Compact totals across enabled monitors. An address watched twice on the same
/// pool must not double-count its hashrate or workers.
struct WidgetMiningSummary {
    let monitorCount: Int
    let knownCount: Int
    let hashrate: Double?
    let online: Int?
    let total: Int?

    init(_ pools: [WidgetPool]) {
        let unique = Self.uniqueTargets(pools)
        let known = unique.filter {
            $0.hashrateRaw.isFinite && $0.hashrateRaw >= 0 && $0.online >= 0 && $0.total >= $0.online
                && ($0.hashrateRaw > 0 || $0.total > 0 || (!$0.hashrate.isEmpty && $0.hashrate != "—"))
        }
        monitorCount = unique.count
        knownCount = known.count
        // A partial subtotal would look like lost hashrate. Show unknown totals
        // until all monitors have data, with the available count in the footer.
        let complete = !unique.isEmpty && known.count == unique.count
        hashrate = complete ? known.reduce(0) { $0 + $1.hashrateRaw } : nil
        online = complete ? known.reduce(0) { $0 + $1.online } : nil
        total = complete ? known.reduce(0) { $0 + $1.total } : nil
    }

    /// First watch of each (pool, address) — the rest would count the same rigs again.
    static func uniqueTargets(_ pools: [WidgetPool]) -> [WidgetPool] {
        var targets = Set<String>()
        return pools.filter { targets.insert($0.target).inserted }
    }

    var hashrateText: String { hashrate.map(formatHashrate) ?? "—" }
    var workersText: String {
        guard let online, let total else { return "—" }
        return "\(online)/\(total)"
    }
}

extension WidgetPool {
    /// What the figures belong to. The label is only a name: two watches can share it.
    var target: String { "\(kind)|\(address)" }

    fileprivate func sameFigures(as other: WidgetPool) -> Bool {
        hashrate == other.hashrate && hashrateRaw == other.hashrateRaw
            && online == other.online && total == other.total
    }

    fileprivate mutating func takeFigures(from other: WidgetPool) {
        hashrate = other.hashrate; hashrateRaw = other.hashrateRaw
        online = other.online; total = other.total
    }
}

extension WidgetFetch.PoolLive {
    /// A pool answer the widget may show: finite, non-negative, no more online than listed.
    var isValid: Bool { hashrateRaw.isFinite && hashrateRaw >= 0 && online >= 0 && total >= online }
}

extension WidgetSnapshot {
    /// A slow refresh must not resurrect removed monitors, overwrite newer app
    /// figures, or replace a user's renamed label with the pre-fetch label.
    @discardableResult
    mutating func applyPoolRefresh(_ results: [(Int, WidgetFetch.PoolLive?)],
                                   from initial: WidgetSnapshot, at: Date) -> Bool {
        // Anyone's write since this fetch started (the app, or another widget's refresh that
        // finished first) wins: this result may be the older one.
        guard poolsAt == initial.poolsAt, poolsRev == initial.poolsRev,
              pools.map(\.target) == initial.pools.map(\.target)
        else { return false }
        var refreshed = Set<Int>()
        for (index, live) in results {
            guard pools.indices.contains(index), let live, live.isValid else { continue }
            pools[index].hashrate = live.hashrate
            pools[index].hashrateRaw = live.hashrateRaw
            pools[index].online = live.online
            pools[index].total = live.total
            refreshed.insert(index)
        }
        guard !refreshed.isEmpty else { return false }
        poolsRev = (poolsRev ?? 0) &+ 1
        // Only a complete refresh makes the aggregate current. Failed monitors
        // retain both their old values and the aggregate's original timestamp.
        if refreshed.count == pools.count { poolsAt = at }
        updatedAt = max(WidgetBridge.valid(updatedAt, now: at) ?? .distantPast, at)
        return true
    }

    /// The widget's own xpub balance. Same rule as the pools: only onto the wallet it was
    /// fetched for, and only if nobody wrote the wallet figures since the fetch started.
    @discardableResult
    mutating func applyWalletRefresh(balance: Double, from initial: WidgetSnapshot) -> Bool {
        guard balance.isFinite, balance >= 0, let xpub = initial.xpub, xpub == self.xpub,
              network == initial.network, walletAt == initial.walletAt, walletRev == initial.walletRev
        else { return false }
        // The xpub scan misses stranded internal-chain change; add back what the app published.
        balancePRL = balance + changePRL
        walletRev = (walletRev ?? 0) &+ 1
        return true
    }

    /// A price fetched (or reused) by a widget: newest observation wins. A stamp from the
    /// future (measured from the later of the clock and this price's own time) means the clock
    /// was set back since — it must not block every newer price.
    @discardableResult
    mutating func applyPrice(_ price: (usd: Double, at: Date), now: Date = Date()) -> Bool {
        guard price.usd.isFinite, price.usd > 0,
              price.at > (WidgetBridge.valid(prlUsdAt, now: max(now, price.at)) ?? .distantPast) else { return false }
        prlUsd = price.usd
        prlUsdAt = price.at
        return true
    }

    enum PoolsPublish: Equatable { case unchanged, restamp(reloadQuoteMining: Bool), changed }

    /// The app's watch list. `current` = indices whose figures the app has just read; every
    /// other watch keeps the figures the snapshot already holds for that target (the app's last
    /// good read, or a newer widget refresh) instead of being overwritten with a failed fetch's
    /// "—" or an old in-memory copy — and a target the snapshot doesn't know yet reads "—"
    /// until its first read. Only a publish where every watch is current makes the pool
    /// figures fresh again.
    mutating func publishAppPools(_ incoming: [WidgetPool], current: Set<Int>, now: Date) -> PoolsPublish {
        var next = incoming
        for i in next.indices where !current.contains(i) {
            if let old = pools.first(where: { $0.target == next[i].target }) {
                next[i].takeFigures(from: old)
            } else {
                next[i].takeFigures(from: WidgetPool(label: "", kind: "", address: "", hashrate: "—",
                                                     hashrateRaw: 0, online: 0, total: 0))
            }
        }
        let complete = next.indices.allSatisfy(current.contains)
        if pools == next {
            // Unchanged: only keep the "just published" stamp current (no reload).
            guard complete, WidgetBridge.isStale(poolsAt, now: now) else { return .unchanged }
            let wasStale = WidgetBridge.isStale(poolsAt, now: now, maxAge: WidgetMarketQuote.staleAfter)
            poolsAt = now
            poolsRev = (poolsRev ?? 0) &+ 1
            return .restamp(reloadQuoteMining: wasStale)
        }
        // New figures move the freshness stamp; a rename, reorder or removal doesn't.
        let newFigures = current.contains { i in
            guard next.indices.contains(i) else { return false }
            return pools.first { $0.target == next[i].target }.map { !$0.sameFigures(as: next[i]) } ?? true
        }
        pools = next
        poolsRev = (poolsRev ?? 0) &+ 1
        if complete { poolsAt = now }
        if newFigures { updatedAt = now }
        return .changed
    }
}
