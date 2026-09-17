import Foundation

// AlphaPool (pearl.alphapool.tech) — open mining-pool API.
//   GET /api/miner/{address}  → this miner's hashrate / balance / workers / payments / series
//   GET /api/stats            → pool + network + chain stats

struct PoolWorker: Decodable, Identifiable {
    let name: String
    let hashrate_live: String?
    let hashrate_1h: String?
    let hashrate: String?      // 24h estimate (Σ workers == estHash24h)
    let online: Bool?
    let time: Int?
    var id: String { name }
}

struct PoolPayment: Decodable, Identifiable {
    let ts: Int
    let amount_grain: Int64?
    let txid: String?
    let status: String?
    let block_height: Int?
    var id: String { "\(ts)-\(txid ?? "")-\(block_height ?? 0)" }
    /// PRL = grain / 1e8.
    var amountPRL: Double { Double(amount_grain ?? 0) / 1e8 }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
}

struct PoolHashPoint: Decodable, Identifiable {
    let ts: Int
    let hashrate: Double  // H/s
    var id: Int { ts }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
    var thps: Double { hashrate / 1e12 }
}

struct PoolDayPay: Decodable, Identifiable {
    let day: String
    let amount_prl: Double
    var id: String { day }
}

struct PoolMiner: Decodable {
    let address: String
    let shares24h: Int?
    let estHash1h: String?
    let estHash24h: String?
    let estHash1hRaw: Double?
    let estHash24hRaw: Double?
    let mode: String?
    let is_solo: Bool?
    let balance_prl: Double?
    let total_paid_prl: Double?
    let last_seen: Int?
    let workers: [PoolWorker]?
    let payments: [PoolPayment]?
    let hashrate_series: [PoolHashPoint]?
    let payments_by_day: [PoolDayPay]?
}

struct PoolStats: Decodable {
    struct Pool: Decodable {
        let hashrate: String?
        let hashrate1h: String?
        let miners24h: Int?
        let workers: Int?
        let blocks24h: Int?
        let ttfLabel: String?
        let payouts24h: Double?
    }
    struct Coin: Decodable {
        let network_hash: String?
        let reward: Double?
        let symbol: String?
        let ttfLabel: String?
        let difficulty: Double?
    }
    struct RecentBlock: Decodable {
        let time: Int?
        let status: String?   // "immature" / "matured" / "orphan"
    }
    let pool: Pool?
    let coins: [Coin]?
    let feePercent: Double?
    let recentBlocks: [RecentBlock]?
}

struct PoolClient {
    let base = "https://pearl.alphapool.tech"

    private func get<T: Decodable>(_ path: String, as: T.Type, timeout: TimeInterval = 25) async throws -> T {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        // A manual / pull-to-refresh must fetch live data, never replay a cached
        // body — otherwise the miner numbers never move and refresh looks broken.
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(poolBrowserUA, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "AlphaPool", code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: Loc("矿池服务繁忙，请稍后重试")])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// The miner endpoint can be slow / 5xx under load — retry several times with
    /// a short escalating backoff so a transient blip recovers instead of showing
    /// "查询失败".
    func miner(_ address: String) async throws -> PoolMiner {
        var lastErr: Error?
        for attempt in 0..<5 {
            do { return try await get("/api/miner/\(address)", as: PoolMiner.self, timeout: 20) }
            catch {
                lastErr = error
                if attempt < 4 { try? await Task.sleep(for: .milliseconds(400 + attempt * 400)) }
            }
        }
        throw lastErr ?? NSError(domain: "AlphaPool", code: -1)
    }

    func stats() async throws -> PoolStats { try await get("/api/stats", as: PoolStats.self) }
}
