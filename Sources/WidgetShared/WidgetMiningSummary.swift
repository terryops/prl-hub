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
        var targets = Set<String>()
        let unique = pools.filter { targets.insert("\($0.kind)|\($0.address)").inserted }
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

    var hashrateText: String { hashrate.map(formatHashrate) ?? "—" }
    var workersText: String {
        guard let online, let total else { return "—" }
        return "\(online)/\(total)"
    }
}

extension WidgetSnapshot {
    /// A slow refresh must not resurrect removed monitors, overwrite newer app
    /// figures, or replace a user's renamed label with the pre-fetch label.
    @discardableResult
    mutating func applyPoolRefresh(_ results: [(Int, WidgetFetch.PoolLive?)],
                                   from initial: WidgetSnapshot, at: Date) -> Bool {
        guard poolsAt == initial.poolsAt,
              pools.map({ "\($0.kind)|\($0.address)" }) == initial.pools.map({ "\($0.kind)|\($0.address)" })
        else { return false }
        var refreshed = Set<Int>()
        for (index, live) in results {
            guard pools.indices.contains(index), let live,
                  live.hashrateRaw.isFinite, live.hashrateRaw >= 0,
                  live.online >= 0, live.total >= live.online else { continue }
            pools[index].hashrate = live.hashrate
            pools[index].hashrateRaw = live.hashrateRaw
            pools[index].online = live.online
            pools[index].total = live.total
            refreshed.insert(index)
        }
        guard !refreshed.isEmpty else { return false }
        // Only a complete refresh makes the aggregate current. Failed monitors
        // retain both their old values and the aggregate's original timestamp.
        if refreshed.count == pools.count { poolsAt = at }
        updatedAt = max(updatedAt, at)
        return true
    }
}
