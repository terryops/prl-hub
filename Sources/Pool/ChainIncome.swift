import Foundation

// MARK: - On-chain income per mining address
//
// The one implementation behind 我的监控's 链上到账 rows and the monitor's 日净利 · 链上实收.
// They used to query Blockbook separately: the cards per WATCH (an address watched on two
// pools was fetched twice), three requests each every 60s, counting a transfer between two of
// the user's own mining addresses as income; the dashboard per address, one request after
// another, excluding those transfers — so one address could show two different "income"
// figures on two tabs, and a failed lookup read as a hard 0 PRL.
//
// Now: keyed by ADDRESS, concurrent requests for the same address share one fetch, results are
// cached briefly, every recent figure excludes self-transfers the same way, and a failure is
// nil ("—"), never 0.

@MainActor
final class ChainIncome {
    static let shared = ChainIncome()

    /// External income (PRL) over the last 24h / 7 days.
    struct Recent: Equatable, Sendable {
        let h24: Double
        let d7: Double
    }

    /// One balance-history entry at 1-second grouping (≈ one tx), in sat. Both legs are net of
    /// `sentToSelf`: Blockbook reports GROSS legs — a send-with-change has sent = all inputs and
    /// received = the change paid back to self — so netting both by sentToSelf leaves what
    /// actually arrived / left.
    struct Leg: Sendable, Equatable {
        let t: Int
        let recv: Double
        let sent: Double
    }

    private var legsCache: [String: (at: Date, legs: [Leg])] = [:]
    private var legsInflight: [String: Task<[Leg]?, Never>] = [:]
    private var totalCache: [String: (at: Date, prl: Double)] = [:]
    private var totalInflight: [String: Task<Double?, Never>] = [:]
    /// Just under the screens' 60s refresh: each tick re-reads the chain, but the watch cards
    /// and the dashboard refreshing in the same minute share one fetch.
    private static let legsTTL: TimeInterval = 50
    /// The lifetime total is a 5-year history — it moves by one payout at a time, and the
    /// recent rows already show those, so it is re-read every 10 minutes (or on pull-to-refresh).
    private static let totalTTL: TimeInterval = 600

    /// 近24h / 近7天 external income for each address, excluding transfers between any two of
    /// `addresses` (the user's own mining addresses). An address whose history couldn't be
    /// read is absent from the result — the caller shows "—", not 0.
    func recent(_ addresses: [String], force: Bool = false) async -> [String: Recent] {
        let addrs = Array(Set(addresses))
        let tasks = addrs.map { ($0, legsTask($0, force: force)) }   // all in flight at once
        var legs: [String: [Leg]] = [:]
        for (a, t) in tasks { if let l = await t.value { legs[a] = l } }
        let since24h = Int(Date().timeIntervalSince1970) - 86_400
        var out: [String: Recent] = [:]
        for (a, mine) in legs {
            let others = addrs.filter { $0 != a }.compactMap { legs[$0] }
            out[a] = Recent(h24: Self.external(mine.filter { $0.t >= since24h }, others: others),
                            d7: Self.external(mine, others: others))
        }
        return out
    }

    /// Lifetime received (PRL, net of change) per address; absent where the lookup failed. At
    /// daily grouping a transfer between two own addresses can't be told apart from income, so
    /// unlike `recent` this total does not exclude them.
    func lifetime(_ addresses: [String], force: Bool = false) async -> [String: Double] {
        let tasks = Array(Set(addresses)).map { ($0, totalTask($0, force: force)) }
        var out: [String: Double] = [:]
        for (a, t) in tasks { if let v = await t.value { out[a] = v } }
        return out
    }

    /// 日均 for 每 P·天: the 7-day income divided by the days actually mined, estimated from the
    /// 24h share (d7/d24). A steadily-mining address gives d7/d24 ≈ 7 (→ the intended /7
    /// smoothing); an address that resumed only a day or two ago gives ≈ 1, so it isn't
    /// under-reported up to ~7×. No 7-day figure → the 24h one.
    nonisolated static func dailyAverage(h24: Double, d7: Double) -> Double {
        guard d7 > 0 else { return h24 }
        let days = h24 > 0 ? min(7, max(1, d7 / h24)) : 7
        return d7 / days
    }

    // MARK: coalesced fetches

    private func legsTask(_ a: String, force: Bool) -> Task<[Leg]?, Never> {
        if let running = legsInflight[a] { return running }
        if !force, let c = legsCache[a], Date().timeIntervalSince(c.at) < Self.legsTTL {
            let legs = c.legs
            return Task { legs }
        }
        let t = Task { [weak self] () -> [Leg]? in
            let legs = await Self.fetchLegs(a, days: 7)
            self?.legsInflight[a] = nil
            if let legs { self?.legsCache[a] = (Date(), legs) }
            return legs
        }
        legsInflight[a] = t
        return t
    }

    private func totalTask(_ a: String, force: Bool) -> Task<Double?, Never> {
        if let running = totalInflight[a] { return running }
        if !force, let c = totalCache[a], Date().timeIntervalSince(c.at) < Self.totalTTL {
            let prl = c.prl
            return Task { prl }
        }
        let t = Task { [weak self] () -> Double? in
            let prl = await Self.fetchLifetime(a)
            self?.totalInflight[a] = nil
            if let prl { self?.totalCache[a] = (Date(), prl) }
            return prl
        }
        totalInflight[a] = t
        return t
    }

    // MARK: Blockbook

    private nonisolated static func balanceHistory(_ addr: String, from: Int, to: Int,
                                                   groupBy: Int) async -> [[String: Any]]? {
        guard var comps = URLComponents(string: "https://blockbook.pearlresearch.ai/api/v2/balancehistory/\(addr)")
        else { return nil }
        comps.queryItems = [.init(name: "from", value: String(from)),
                            .init(name: "to", value: String(to)),
                            .init(name: "groupBy", value: String(groupBy))]
        guard let url = comps.url,
              let d = try? await PoolHTTP.get(url, timeout: 25) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]]
    }

    /// Per-tx legs over the trailing `days`; nil when the lookup failed (≠ an empty history).
    nonisolated static func fetchLegs(_ addr: String, days: Double) async -> [Leg]? {
        let now = Int(Date().timeIntervalSince1970)
        guard let arr = await balanceHistory(addr, from: now - Int(days * 86_400), to: now + 60, groupBy: 1)
        else { return nil }
        return legs(arr)
    }

    nonisolated static func legs(_ arr: [[String: Any]]) -> [Leg] {
        arr.map {
            let recv   = Double(($0["received"]   as? String) ?? "0") ?? 0
            let sent   = Double(($0["sent"]       as? String) ?? "0") ?? 0
            let toSelf = Double(($0["sentToSelf"] as? String) ?? "0") ?? 0
            return Leg(t: ($0["time"] as? Int) ?? 0, recv: max(0, recv - toSelf), sent: max(0, sent - toSelf))
        }
    }

    /// Lifetime (≈5 years) received, net of change, at daily grouping.
    nonisolated static func fetchLifetime(_ addr: String) async -> Double? {
        let now = Int(Date().timeIntervalSince1970)
        guard let arr = await balanceHistory(addr, from: now - 5 * 365 * 86_400, to: now + 60, groupBy: 86_400)
        else { return nil }
        return legs(arr).reduce(0) { $0 + $1.recv } / 1e8
    }

    /// External income (PRL): received minus any chunk that matches another own address's send
    /// at the same timestamp (an inter-address transfer — not real income).
    nonisolated static func external(_ legs: [Leg], others: [[Leg]]) -> Double {
        var ext = 0.0
        for leg in legs where leg.recv > 0 {
            let isTransfer = others.contains { ob in
                ob.contains { $0.t == leg.t && $0.sent > 0 && abs($0.sent - leg.recv) <= max(2_000_000, leg.recv * 0.02) }
            }
            if !isTransfer { ext += leg.recv }
        }
        return ext / 1e8
    }
}
