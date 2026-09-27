import Foundation

// MARK: - AlphaPool (pearl.alphapool.tech) — per miner
//   GET /api/miner/{address} → hashrate / balance / workers (+ payment history, unused)

/// Only the fields the card reads. The payload also carries the full payment list, a
/// per-block history and a hashrate series (~250 KB for an active miner) — undeclared, so a
/// null in one of their rows can't fail the decode of the numbers we do show.
struct AlphaPoolMinerPayload: Decodable, Sendable {
    struct Worker: Decodable, Sendable {
        let name: String?
        let hashrate_live: String?
        let hashrate_1h: String?
        let hashrate: String?      // 24h estimate (Σ workers == estHash24h)
        let online: Bool?
        let time: Double?          // unix seconds of the rig's last share
    }
    let estHash1hRaw: Double?
    let estHash24hRaw: Double?
    let balance_prl: Double?
    let total_paid_prl: Double?
    let last_seen: Double?         // 0 = never mined here
    let workers: [Worker]?
}

enum AlphaPoolSource: PoolMinerSource {
    static let base = "https://pearl.alphapool.tech"

    static func miner(_ id: String, scope: PoolScope) async throws -> PoolMinerStats? {
        guard let addr = pathComponent(id) else { return nil }
        let d = try await PoolHTTP.get(base + "/api/miner/\(addr)", timeout: scope.timeout)
        return try parse(d, now: Date().timeIntervalSince1970)
    }

    /// AlphaPool answers 200 for ANY address — a stranger gets `last_seen: 0`, no workers and
    /// zero money — so "not mining here" is decided from the payload, as for Kryptex.
    static func parse(_ data: Data, now: Double) throws -> PoolMinerStats? {
        let m = try PoolHTTP.decode(AlphaPoolMinerPayload.self, from: data)
        let rigs = m.workers ?? []
        let seen = (m.last_seen ?? 0) > 0 || !rigs.isEmpty || (m.balance_prl ?? 0) > 0
            || (m.total_paid_prl ?? 0) > 0 || (m.estHash24hRaw ?? 0) > 0
        guard seen else { return nil }
        var s = PoolMinerStats()
        s.windows = [.live, .hour, .day]
        s.rates = [.hour: m.estHash1hRaw ?? 0, .day: m.estHash24hRaw ?? 0]
        s.pending = m.balance_prl ?? 0
        s.paid = m.total_paid_prl ?? 0
        s.workers = rigs.map {
            WatchWorker(name: $0.name ?? "—",
                        online: $0.online ?? ($0.time.map { now - $0 < 600 } ?? false),
                        rates: [.live: parseHashrate($0.hashrate_live ?? ""),
                                .hour: parseHashrate($0.hashrate_1h ?? ""),
                                .day:  parseHashrate($0.hashrate ?? "")])
        }
        return s
    }
}
