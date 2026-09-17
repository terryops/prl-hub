import Foundation

// MARK: - miningpoolstats.stream — one source of truth for every PRL pool
//
// Each pool's own API answers only for itself, in its own units, over its own window — so a
// table built from five of them compares five different measurements, and a pool with no
// public API (F2Pool) can't appear at all. miningpoolstats crawls them all onto one basis,
// so this is what the 矿池总览 is built from. (Kryptex DOES publish an API — see Kryptex.swift,
// which corrects this feed's fee/scheme for that row rather than replacing the row.)
//
// Transport: the page's own. `data/pearl.js` is 403 unless `?t=` carries a timestamp the site
// has actually published — a current epoch, 0, or a value a minute off all bounce — so the
// page is fetched first for `var last_time = "…"` and that exact value is echoed back. (No
// Referer needed; a browser UA is.)
struct MiningPoolStatsClient {
    private static let page = "https://miningpoolstats.stream/pearl"
    private static let data = "https://data.miningpoolstats.stream/data/pearl.js"

    private func get(_ url: URL, timeout: TimeInterval = 20) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(poolBrowserUA, forHTTPHeaderField: "User-Agent")
        let (d, r) = try await URLSession.shared.data(for: req)
        guard let code = (r as? HTTPURLResponse)?.statusCode, code == 200 else {
            throw URLError(.badServerResponse)
        }
        return d
    }

    func fetch() async throws -> MPSCoin {
        guard let pageURL = URL(string: Self.page) else { throw URLError(.badURL) }
        let html = String(data: try await get(pageURL), encoding: .utf8) ?? ""
        guard let m = html.range(of: #"var last_time\s*=\s*"(\d+)""#, options: .regularExpression),
              let t = html[m].split(separator: "\"").dropFirst().first else {
            throw URLError(.cannotParseResponse)   // page layout changed → caller falls back
        }
        guard var c = URLComponents(string: Self.data) else { throw URLError(.badURL) }
        c.queryItems = [URLQueryItem(name: "t", value: String(t))]
        guard let url = c.url else { throw URLError(.badURL) }
        return try JSONDecoder().decode(MPSCoin.self, from: try await get(url))
    }
}

/// One pool's row. `miners`/`workers` use -1 for "not published"; `blocks_1000` is how many of
/// the last 1000 NETWORK blocks this pool found — the sample every measured figure rests on.
///
/// Every number is a FlexDouble because this feed genuinely mixes JSON types across sibling
/// rows — `lastblocktime` arrives as an int for 8 pools and a STRING for 13, `hashrate` as int
/// or float, `fee` as either. A plain `Double?` throws typeMismatch on the first such row and
/// takes the whole payload with it, which would silently drop the section back to the
/// five-pool fallback. Only fields actually used are declared: an undeclared field can't break
/// the decode, so unused ones are liability with no upside.
struct MPSPool: Decodable {
    let url: String?
    let pool_id: String?
    let hashrate: FlexDouble?
    let miners: FlexDouble?
    let workers: FlexDouble?
    let fee: FlexDouble?
    let feetype: String?          // "PPLNS" · "PPS%3" · "PPS+%2|SOLO%1"
    let blocks_1000: FlexDouble?

    var hps: Double { hashrate?.value ?? 0 }
    /// -1 is the feed's "not published" sentinel — surface it as nil, not as a miner count.
    var minerCount: Int? { (miners?.value).flatMap { $0 >= 0 ? Int($0) : nil } }
    var workerCount: Int? { (workers?.value).flatMap { $0 >= 0 ? Int($0) : nil } }
    var blocksIn1000: Int { Int(blocks_1000?.value ?? 0) }
}

struct MPSSupply: Decodable { let emission24: FlexDouble? }

struct MPSCoin: Decodable {
    /// One malformed row must cost that row, not the table. (Same trick as PoolStore's
    /// MaybeWatch: decode each element leniently, drop the nils.)
    private struct MaybePool: Decodable {
        let pool: MPSPool?
        init(from decoder: Decoder) { pool = try? MPSPool(from: decoder) }
    }

    let data: [MPSPool]
    /// Explorer-reported network hashrate. Runs ~40% ABOVE what the pools' block production
    /// implies (36.8 vs 26.4 EH/s when checked), which would put every pool's share ~40% low
    /// and make the "其他/独立" slice fictitious — so `network` below does NOT use it.
    let hashrate: FlexDouble?
    /// Network hashrate implied by block times. THIS is the figure each pool's hashrate share
    /// agrees with: Kryptex 20.4% of hashrate ↔ 20.0% of the last 1000 blocks, HeroMiners
    /// 13.3% ↔ 14.7%, and so on down the table.
    let nethash_estimat: FlexDouble?
    let poolshash: FlexDouble?
    let block_time_average: FlexDouble?
    let supply: MPSSupply?

    enum CodingKeys: String, CodingKey {
        case data, hashrate, nethash_estimat, poolshash, block_time_average, supply
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decode([MaybePool].self, forKey: .data).compactMap(\.pool)
        hashrate = try? c.decode(FlexDouble.self, forKey: .hashrate)
        nethash_estimat = try? c.decode(FlexDouble.self, forKey: .nethash_estimat)
        poolshash = try? c.decode(FlexDouble.self, forKey: .poolshash)
        block_time_average = try? c.decode(FlexDouble.self, forKey: .block_time_average)
        supply = try? c.decode(MPSSupply.self, forKey: .supply)
    }

    /// Network hashrate on the basis the block data agrees with; never below the pools' own sum.
    var network: Double {
        max(nethash_estimat?.value ?? 0, poolshash?.value ?? 0)
    }
    /// Seconds per block, as actually mined (the 180s target is not what the chain does).
    var blockTime: Double {
        let t = block_time_average?.value ?? 0
        return t > 0 ? t : 180
    }
    var blocksPerDay: Double { 86400 / blockTime }
    /// PRL per block, derived from the last 24h of actual emission ÷ blocks in a day.
    var rewardPerBlock: Double { (supply?.emission24?.value ?? 0) / max(blocksPerDay, 1) }
    /// Days the 1000-block sample spans (≈2.5 at a 213s block). The measurement window for
    /// every 出块/天 and 收益/PH figure — wider than 24h, so a lucky day can't fake a winner.
    var sampleDays: Double { 1000 * blockTime / 86400 }
}
