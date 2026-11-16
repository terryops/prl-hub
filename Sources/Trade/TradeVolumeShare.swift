import SwiftUI
import Combine
import Charts

// MARK: - Global 24h Trading Volume Share & Liquidity Pools

struct MarketVenue: Codable, Identifiable, Equatable {
    let id: String
    let venue: String
    let pair: String
    let kind: String               // "cex" | "pool"
    let chain: String?
    let priceUsd: Double?
    let volumeUsd24h: Double
    let liquidityUsd: Double?
    var share: Double
    let tradeUrl: String?
    let inAppExchange: String?     // "safetrade" | "gate" | nil

    var isPool: Bool { kind == "pool" }
}

struct MarketsSnapshot: Codable, Equatable {
    let updatedAt: String?
    let totalVolumeUsd24h: Double
    let cexVolumeUsd24h: Double
    let poolVolumeUsd24h: Double
    let items: [MarketVenue]

    init(updatedAt: String?, totalVolumeUsd24h: Double, cexVolumeUsd24h: Double,
         poolVolumeUsd24h: Double, items: [MarketVenue]) {
        self.updatedAt = updatedAt
        self.totalVolumeUsd24h = totalVolumeUsd24h
        self.cexVolumeUsd24h = cexVolumeUsd24h
        self.poolVolumeUsd24h = poolVolumeUsd24h
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case updatedAt, ts, totalVolumeUsd24h, cexVolumeUsd24h, poolVolumeUsd24h, items, rows
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let up = try c.decodeIfPresent(String.self, forKey: .updatedAt) {
            updatedAt = up
        } else if let ts = try c.decodeIfPresent(Double.self, forKey: .ts) {
            updatedAt = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ts))
        } else {
            updatedAt = nil
        }
        let decodedTotal = try c.decode(Double.self, forKey: .totalVolumeUsd24h)
        let decodedCex = try c.decode(Double.self, forKey: .cexVolumeUsd24h)
        let decodedPool = try c.decode(Double.self, forKey: .poolVolumeUsd24h)
        let rawList: [MarketVenue]
        if let list = try c.decodeIfPresent([MarketVenue].self, forKey: .items) {
            rawList = list
        } else {
            rawList = try c.decode([MarketVenue].self, forKey: .rows)
        }
        let filtered = rawList.filter { !TradeMarketsClient.isExcludedVenue(id: $0.id, venue: $0.venue) }
        if filtered.count != rawList.count {
            let total = filtered.reduce(0) { $0 + $1.volumeUsd24h }
            let cex = filtered.filter { !$0.isPool }.reduce(0) { $0 + $1.volumeUsd24h }
            let pool = filtered.filter { $0.isPool }.reduce(0) { $0 + $1.volumeUsd24h }
            totalVolumeUsd24h = total
            cexVolumeUsd24h = cex
            poolVolumeUsd24h = pool
            items = filtered.map { item in
                var copy = item
                copy.share = total > 0 ? item.volumeUsd24h / total : 0
                return copy
            }
        } else {
            totalVolumeUsd24h = decodedTotal
            cexVolumeUsd24h = decodedCex
            poolVolumeUsd24h = decodedPool
            items = rawList
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try c.encode(totalVolumeUsd24h, forKey: .totalVolumeUsd24h)
        try c.encode(cexVolumeUsd24h, forKey: .cexVolumeUsd24h)
        try c.encode(poolVolumeUsd24h, forKey: .poolVolumeUsd24h)
        try c.encode(items, forKey: .items)
    }
}

struct MarketVolumeSlice: Identifiable, Equatable {
    let id: String
    let name: String
    let volumeUsd: Double
    let share: Double
    let isPool: Bool

    static func build(from items: [MarketVenue], total: Double) -> [MarketVolumeSlice] {
        guard total > 0, !items.isEmpty else { return [] }
        var grouped: [String: (vol: Double, isPool: Bool)] = [:]
        for item in items where item.volumeUsd24h > 0 {
            let cur = grouped[item.venue] ?? (0, item.isPool)
            grouped[item.venue] = (cur.vol + item.volumeUsd24h, cur.isPool && item.isPool)
        }
        let sorted = grouped.map { ($0.key, $0.value.vol, $0.value.isPool) }
            .sorted { $0.1 > $1.1 }
        var out: [MarketVolumeSlice] = []
        var tail = 0.0
        for (idx, entry) in sorted.enumerated() {
            let s = entry.1 / total
            if idx >= 7 || s < 0.015 {
                tail += entry.1
                continue
            }
            out.append(MarketVolumeSlice(id: entry.0, name: entry.0, volumeUsd: entry.1, share: s, isPool: entry.2))
        }
        if tail / total > 0.002 {
            out.append(MarketVolumeSlice(id: "_other", name: Loc("其他"), volumeUsd: tail, share: tail / total, isPool: false))
        }
        return out
    }

    static func hitTest(
        at point: CGPoint,
        in plotFrame: CGRect,
        innerRadius: CGFloat,
        slices: [MarketVolumeSlice]
    ) -> MarketVolumeSlice? {
        guard !slices.isEmpty, plotFrame.width > 0, plotFrame.height > 0 else { return nil }
        let maxRadius = min(plotFrame.width, plotFrame.height) / 2
        guard maxRadius > innerRadius else { return nil }
        let dx = point.x - plotFrame.midX
        let dy = point.y - plotFrame.midY
        let distance = hypot(dx, dy)
        guard distance >= innerRadius - 2, distance <= maxRadius + 2 else { return nil }

        let totalVolume = slices.reduce(0.0) { $0 + max(0, $1.volumeUsd) }
        guard totalVolume > 0 else { return nil }

        // SectorMark starts at 12 o'clock (0 rad) and sweeps clockwise.
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let target = Double(angle / (2 * .pi)) * totalVolume

        var cumulative = 0.0
        for slice in slices {
            let vol = max(0, slice.volumeUsd)
            guard vol > 0 else { continue }
            cumulative += vol
            if target <= cumulative {
                return slice
            }
        }
        return slices.last { $0.volumeUsd > 0 }
    }
}

enum TradeMarketsClient {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    private static let knownContracts: [String: String] = [
        "prl.omft.near": "PEARL",
        "17208628f84f5d6ad33f0da3bbbeb27ffcb398eac501a31bd6ad2011e36133a1": "USDC",
        "a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48.factory.bridge.near": "USDC.e",
        "dac17f958d2ee523a2206206994597c13d831ec7.factory.bridge.near": "USDT.e",
        "usdt.tether-token.near": "USDT",
        "eth-0xdac17f958d2ee523a2206206994597c13d831ec7.omft.near": "USDT",
        "sol-c800a4bd850783ccb82c2b2c7e84175443606352.omft.near": "USDT",
        "tron-d28a265909efecdcee7c5028585214ea0b96f015.omft.near": "USDT",
        "eth-0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48.omft.near": "USDC",
        "sol-5ce3bf3a31af18be40ba30f721101b4341690186.omft.near": "USDC",
        "base-0x833589fcd6edb6e08f4c7c32d4f71b54bda02913.omft.near": "USDC",
        "arb-0xaf88d065e77c8cc2239327c5edb3a432268e5831.omft.near": "USDC",
        "sol.omft.near": "SOL",
        "btc.omft.near": "BTC",
        "nbtc.bridge.near": "BTC",
        "eth.omft.near": "ETH",
        "aurora": "ETH",
        "zec.omft.near": "ZEC",
        "tlr.omft.near": "TLR",
        "eth-0x0f38f1ce6277bdd61ad13df59ef4d77dbdbacdc8.omft.near": "TLR",
        "eth-0x0f38f1ce62776d4a0038bc6cac66877a5687383b.omft.near": "TLR",
        "qtc.omft.near": "QTC",
        "eth-0x0520280f6b2d39efbd49be01e1c4a5ac9ef3a2ab.omft.near": "QTC",
        "doge.omft.near": "DOGE",
        "xrp.omft.near": "XRP",
        "wrap.near": "wNEAR",
    ]

    static let excludedVenues: Set<String> = [
        "bigone", "ourbit", "lbank", "margin-trade"
    ]

    static func isExcludedVenue(id: String, venue: String) -> Bool {
        let prefix = id.split(separator: ":").first.map { String($0).lowercased() } ?? ""
        if excludedVenues.contains(prefix) { return true }
        let normName = venue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-")
        return excludedVenues.contains(normName)
    }

    private static let poolIdentifiers: Set<String> = [
        "near-intents", "near_intents", "rhea-finance", "rhea_finance", "ref-finance", "ref_finance",
        "uniswap", "raydium", "orca", "pancakeswap"
    ]

    private static func normalizeVenue(identifier rawId: String, name rawName: String)
        -> (id: String, name: String, isPool: Bool, chain: String?, fallbackURL: String?) {
        let mId = rawId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch mId {
        case "safe_trade", "safetrade", "safe-trade":
            return ("safetrade", "SafeTrade", false, nil, TradeExchange.safetrade.webTradeURL.absoluteString)
        case "gate", "gate-io", "gate_io":
            return ("gate", "Gate", false, nil, TradeExchange.gate.webTradeURL.absoluteString)
        case "bigone":
            return ("bigone", "BigONE", false, nil, "https://big.one/trade/PEARL-USDT")
        case "gdax", "coinbase", "coinbase_exchange":
            return ("coinbase", "Coinbase Exchange", false, nil, "https://www.coinbase.com/advanced-trade/spot/PEARL-USD")
        case "coinex":
            return ("coinex", "CoinEx", false, nil, "https://www.coinex.com/en/exchange/pearl-usdt")
        case "kraken":
            return ("kraken", "Kraken", false, nil, "https://pro.kraken.com/app/trade/PEARL-USD")
        case "lbank":
            return ("lbank", "LBank", false, nil, "https://www.lbank.com/trade/pearl_usdt")
        case "ourbit":
            return ("ourbit", "Ourbit", false, nil, "https://www.ourbit.com/exchange/PRL_USDT")
        case "margin-trade-spot", "margin_trade", "margin-trade":
            return ("margin-trade", "Margin Trade", false, nil, "https://margin.trade/trade")
        case "ref_finance", "ref-finance", "rhea-finance", "rhea_finance":
            return ("rhea-finance", "Rhea Finance", true, "near", "https://app.rhea.finance/")
        case "near-intents", "near_intents":
            return ("near-intents", "Near Intents", true, "near", "https://app.near-intents.org/")
        default:
            let cleanId = mId.replacingOccurrences(of: "_", with: "-")
            let displayName = rawName.isEmpty ? cleanId : rawName
            let combined = "\(cleanId) \(displayName.lowercased())"
            let pool = poolIdentifiers.contains(mId) || poolIdentifiers.contains(cleanId)
                || ["swap", "dex", "rhea", "ref", "intents", "amm", "pool"].contains(where: { combined.contains($0) })
            return (cleanId.isEmpty ? "unknown" : cleanId, displayName, pool, pool ? "dex" : nil, nil)
        }
    }

    static func cleanSymbol(_ raw: String?) -> String {
        guard let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let known = knownContracts[trimmed.lowercased()] { return known }
        let lower = trimmed.lowercased()
        if lower.hasSuffix(".omft.near") {
            let prefix = String(lower.dropLast(".omft.near".count))
            if prefix.hasPrefix("eth-0xdac17") { return "USDT" }
            if prefix.hasPrefix("eth-0xa0b86") { return "USDC" }
            if !prefix.contains("-"), prefix.count <= 10 { return prefix.uppercased() == "PRL" ? "PEARL" : prefix.uppercased() }
        }
        if trimmed.count > 16 { return String(trimmed.prefix(6)).uppercased() + "…" }
        return trimmed
    }

    static func fetch() async throws -> MarketsSnapshot {
        if let url = URL(string: "https://pearlhub.net/v1/markets"),
           let (data, resp) = try? await session.data(from: url),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let snap = try? JSONDecoder().decode(MarketsSnapshot.self, from: data),
           !snap.items.isEmpty {
            return snap
        }
        return try await fetchDirectFallback()
    }

    /// Direct client-side aggregation when `/v1/markets` is unreachable or not yet deployed.
    static func fetchDirectFallback() async throws -> MarketsSnapshot {
        async let cgData: Data? = get("https://api.coingecko.com/api/v3/coins/pearl-2/tickers")
        async let gateData: Data? = get("https://api.gateio.ws/api/v4/spot/tickers?currency_pair=PEARL_USDT")
        async let dexData: Data? = get("https://api.dexscreener.com/latest/dex/tokens/prl.omft.near")

        let cg = await cgData
        let gate = await gateData
        let dex = await dexData
        return buildFallbackSnapshot(coingeckoData: cg, gateData: gate, dexScreenerData: dex)
    }

    private static func get(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString),
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    static func buildFallbackSnapshot(coingeckoData: Data?, gateData: Data?, dexScreenerData: Data?) -> MarketsSnapshot {
        var byKey: [String: MarketVenue] = [:]

        func dbl(_ any: Any?) -> Double? {
            if let n = any as? NSNumber { return n.doubleValue.isFinite ? n.doubleValue : nil }
            if let s = any as? String, let v = Double(s), v.isFinite { return v }
            return nil
        }

        if let cgData = coingeckoData,
           let root = try? JSONSerialization.jsonObject(with: cgData) as? [String: Any],
           let tickers = root["tickers"] as? [[String: Any]] {
            var weightByKey: [String: Double] = [:]
            for t in tickers {
                if (t["is_stale"] as? Bool) == true { continue }
                let market = t["market"] as? [String: Any]
                let rawId = (market?["identifier"] as? String) ?? ""
                let rawName = (market?["name"] as? String) ?? rawId
                let norm = normalizeVenue(identifier: rawId, name: rawName)
                if excludedVenues.contains(norm.id) { continue }
                let origBase = ((t["base"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if (norm.id == "gate" || norm.id == "coinex") && origBase.uppercased() == "PRL" { continue }
                let rawBase = cleanSymbol(t["base"] as? String)
                let rawTarget = cleanSymbol(t["target"] as? String)
                let baseIsPearl = rawBase.uppercased() == "PEARL" || rawBase.uppercased() == "PRL"
                let targetIsPearl = !baseIsPearl && (rawTarget.uppercased() == "PEARL" || rawTarget.uppercased() == "PRL")
                guard baseIsPearl || targetIsPearl else { continue }
                let base = (baseIsPearl && !norm.isPool && rawBase.uppercased() == "PRL") ? "PRL" : "PEARL"
                let quote = baseIsPearl ? rawTarget : rawBase
                guard !quote.isEmpty, quote.uppercased() != "PEARL", quote.uppercased() != "PRL" else { continue }
                let pair = "\(base)/\(quote)"
                let convLast = (t["converted_last"] as? [String: Any]).flatMap { dbl($0["usd"]) }
                let convVol = max(0, (t["converted_volume"] as? [String: Any]).flatMap { dbl($0["usd"]) } ?? 0)
                let inApp: String? = (norm.id == "safetrade" && pair == "PEARL/USDT") ? "safetrade"
                    : (norm.id == "gate" && pair == "PEARL/USDT") ? "gate" : nil
                let id = "\(norm.id):\(pair.lowercased())"
                let url = (t["trade_url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? norm.fallbackURL
                if let prev = byKey[id] {
                    let prevW = weightByKey[id] ?? 0
                    let nextPrice: Double? = {
                        guard let p = convLast, convVol > 0 else { return prev.priceUsd }
                        if let pp = prev.priceUsd, prevW > 0 { return (pp * prevW + p * convVol) / (prevW + convVol) }
                        return p
                    }()
                    if convLast != nil && convVol > 0 { weightByKey[id] = prevW + convVol }
                    byKey[id] = MarketVenue(
                        id: id,
                        venue: prev.venue,
                        pair: prev.pair,
                        kind: prev.kind,
                        chain: prev.chain,
                        priceUsd: nextPrice,
                        volumeUsd24h: prev.volumeUsd24h + convVol,
                        liquidityUsd: prev.liquidityUsd,
                        share: 0,
                        tradeUrl: (convVol > prev.volumeUsd24h ? url : nil) ?? prev.tradeUrl ?? url,
                        inAppExchange: prev.inAppExchange
                    )
                } else {
                    if convLast != nil && convVol > 0 { weightByKey[id] = convVol }
                    byKey[id] = MarketVenue(
                        id: id,
                        venue: norm.name,
                        pair: pair,
                        kind: norm.isPool ? "pool" : "cex",
                        chain: norm.chain,
                        priceUsd: convLast,
                        volumeUsd24h: convVol,
                        liquidityUsd: nil,
                        share: 0,
                        tradeUrl: url,
                        inAppExchange: inApp
                    )
                }
            }
        }

        if let gData = gateData,
           let arr = try? JSONSerialization.jsonObject(with: gData) as? [[String: Any]],
           let g = arr.first(where: { ($0["currency_pair"] as? String) == "PEARL_USDT" }) {
            let last = dbl(g["last"])
            let qVol = dbl(g["quote_volume"]) ?? 0
            let id = "gate:pearl/usdt"
            let prev = byKey[id]
            byKey[id] = MarketVenue(
                id: id,
                venue: "Gate",
                pair: "PEARL/USDT",
                kind: "cex",
                chain: nil,
                priceUsd: last ?? prev?.priceUsd,
                volumeUsd24h: qVol > 0 ? qVol : (prev?.volumeUsd24h ?? 0),
                liquidityUsd: nil,
                share: 0,
                tradeUrl: TradeExchange.gate.webTradeURL.absoluteString,
                inAppExchange: "gate"
            )
        }

        if let dData = dexScreenerData,
           let root = try? JSONSerialization.jsonObject(with: dData) as? [String: Any],
           let pairs = root["pairs"] as? [[String: Any]] {
            var groupedDex: [String: (venue: MarketVenue, weight: Double, topVol: Double)] = [:]
            for p in pairs {
                let baseTok = p["baseToken"] as? [String: Any]
                let quoteTok = p["quoteToken"] as? [String: Any]
                let bAddr = ((baseTok?["address"] as? String) ?? "").lowercased()
                let qAddr = ((quoteTok?["address"] as? String) ?? "").lowercased()
                let bSym = ((baseTok?["symbol"] as? String) ?? "").uppercased()
                let qSym = ((quoteTok?["symbol"] as? String) ?? "").uppercased()
                let baseIsPearl = bAddr == "prl.omft.near" || bSym == "PEARL" || bSym == "PRL"
                let quoteIsPearl = !baseIsPearl && (qAddr == "prl.omft.near" || qSym == "PEARL" || qSym == "PRL")
                guard baseIsPearl || quoteIsPearl else { continue }
                let counterTok = baseIsPearl ? quoteTok : baseTok
                let counterAddr = ((counterTok?["address"] as? String) ?? "").lowercased()
                let quote = knownContracts[counterAddr]
                    ?? {
                        let s = cleanSymbol(counterTok?["symbol"] as? String)
                        return s.isEmpty ? cleanSymbol(counterTok?["address"] as? String) : s
                    }()
                guard !quote.isEmpty, quote.uppercased() != "PEARL" else { continue }
                let dexId = ((p["dexId"] as? String) ?? "dex").lowercased()
                let norm = normalizeVenue(identifier: dexId, name: dexId.capitalized)
                let pair = "PEARL/\(quote)"
                let id = "\(norm.id):\(pair.lowercased())"
                let vol = max(0, (p["volume"] as? [String: Any]).flatMap { dbl($0["h24"]) } ?? 0)
                let liq = (p["liquidity"] as? [String: Any]).flatMap { dbl($0["usd"]) }
                if vol <= 0 && (liq ?? 0) < 500 { continue }
                let rawPrice = dbl(p["priceUsd"])
                let priceNative = dbl(p["priceNative"])
                let pearlPrice: Double? = baseIsPearl ? rawPrice
                    : ((rawPrice != nil && priceNative != nil && priceNative! > 0) ? rawPrice! / priceNative! : nil)
                let pUrl = (p["url"] as? String) ?? norm.fallbackURL
                if let cur = groupedDex[id] {
                    let nextPrice: Double? = {
                        guard let pp = pearlPrice, vol > 0 else { return cur.venue.priceUsd }
                        if let cp = cur.venue.priceUsd, cur.weight > 0 {
                            return (cp * cur.weight + pp * vol) / (cur.weight + vol)
                        }
                        return pp
                    }()
                    let nextLiq: Double? = (liq != nil || cur.venue.liquidityUsd != nil)
                        ? (cur.venue.liquidityUsd ?? 0) + (liq ?? 0) : nil
                    groupedDex[id] = (
                        venue: MarketVenue(
                            id: id,
                            venue: cur.venue.venue,
                            pair: pair,
                            kind: "pool",
                            chain: cur.venue.chain,
                            priceUsd: nextPrice,
                            volumeUsd24h: cur.venue.volumeUsd24h + vol,
                            liquidityUsd: nextLiq,
                            share: 0,
                            tradeUrl: (vol > cur.topVol ? pUrl : nil) ?? cur.venue.tradeUrl,
                            inAppExchange: nil
                        ),
                        weight: cur.weight + (pearlPrice != nil ? vol : 0),
                        topVol: max(cur.topVol, vol)
                    )
                } else {
                    groupedDex[id] = (
                        venue: MarketVenue(
                            id: id,
                            venue: norm.name,
                            pair: pair,
                            kind: "pool",
                            chain: (p["chainId"] as? String) ?? "near",
                            priceUsd: pearlPrice,
                            volumeUsd24h: vol,
                            liquidityUsd: liq,
                            share: 0,
                            tradeUrl: pUrl,
                            inAppExchange: nil
                        ),
                        weight: pearlPrice != nil ? vol : 0,
                        topVol: vol
                    )
                }
            }
            for (id, entry) in groupedDex {
                let prev = byKey[id]
                let v = entry.venue
                byKey[id] = MarketVenue(
                    id: id,
                    venue: v.venue,
                    pair: v.pair,
                    kind: "pool",
                    chain: v.chain ?? prev?.chain,
                    priceUsd: v.priceUsd ?? prev?.priceUsd,
                    volumeUsd24h: v.volumeUsd24h > 0 ? v.volumeUsd24h : (prev?.volumeUsd24h ?? 0),
                    liquidityUsd: v.liquidityUsd ?? prev?.liquidityUsd,
                    share: 0,
                    tradeUrl: v.tradeUrl ?? prev?.tradeUrl,
                    inAppExchange: nil
                )
            }
        }

        var items = Array(byKey.values).sorted {
            if $0.volumeUsd24h != $1.volumeUsd24h { return $0.volumeUsd24h > $1.volumeUsd24h }
            return ($0.liquidityUsd ?? 0) > ($1.liquidityUsd ?? 0)
        }
        let total = items.reduce(0) { $0 + $1.volumeUsd24h }
        let cexVol = items.filter { !$0.isPool }.reduce(0) { $0 + $1.volumeUsd24h }
        let poolVol = items.filter { $0.isPool }.reduce(0) { $0 + $1.volumeUsd24h }
        items = items.map { item in
            var copy = item
            copy.share = total > 0 ? item.volumeUsd24h / total : 0
            return copy
        }
        return MarketsSnapshot(
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            totalVolumeUsd24h: total,
            cexVolumeUsd24h: cexVol,
            poolVolumeUsd24h: poolVol,
            items: items
        )
    }
}

@MainActor
final class TradeMarketsStore: ObservableObject {
    static let shared = TradeMarketsStore()

    @Published private(set) var snapshot: MarketsSnapshot?
    @Published private(set) var loading = false
    private var fetchedAt: Date?

    func refreshIfStale(olderThan seconds: TimeInterval = 60) async {
        if let at = fetchedAt, Date().timeIntervalSince(at) < seconds, snapshot != nil { return }
        await refresh()
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let next = try await TradeMarketsClient.fetch()
            if !next.items.isEmpty {
                snapshot = next
                fetchedAt = Date()
            }
        } catch {
            // Keep existing snapshot on transient error.
        }
        #if DEBUG
        if SafeTradeStore.shotDemo, snapshot == nil {
            snapshot = Self.demoSnapshot
            fetchedAt = Date()
        }
        #endif
    }

    #if DEBUG
    static let demoSnapshot = MarketsSnapshot(
        updatedAt: nil,
        totalVolumeUsd24h: 9_680_000,
        cexVolumeUsd24h: 5_980_000,
        poolVolumeUsd24h: 3_700_000,
        items: [
            MarketVenue(id: "gate:pearl/usdt", venue: "Gate", pair: "PEARL/USDT", kind: "cex", chain: nil, priceUsd: 1.523, volumeUsd24h: 2_450_000, liquidityUsd: nil, share: 2_450_000 / 9_680_000, tradeUrl: "https://www.gate.com/trade/PEARL_USDT", inAppExchange: "gate"),
            MarketVenue(id: "near-intents:pearl/usdc", venue: "Near Intents", pair: "PEARL/USDC", kind: "pool", chain: "near", priceUsd: 1.521, volumeUsd24h: 2_600_000, liquidityUsd: nil, share: 2_600_000 / 9_680_000, tradeUrl: "https://app.near-intents.org/", inAppExchange: nil),
            MarketVenue(id: "coinbase:pearl/usd", venue: "Coinbase Exchange", pair: "PEARL/USD", kind: "cex", chain: nil, priceUsd: 1.524, volumeUsd24h: 1_850_000, liquidityUsd: nil, share: 1_850_000 / 9_680_000, tradeUrl: "https://www.coinbase.com/advanced-trade/spot/PEARL-USD", inAppExchange: nil),
            MarketVenue(id: "safetrade:pearl/usdt", venue: "SafeTrade", pair: "PEARL/USDT", kind: "cex", chain: nil, priceUsd: 1.520, volumeUsd24h: 1_120_000, liquidityUsd: nil, share: 1_120_000 / 9_680_000, tradeUrl: "https://safetrade.com/exchange/PEARL-USDT", inAppExchange: "safetrade"),
            MarketVenue(id: "rhea-finance:pearl/usdc", venue: "Rhea Finance", pair: "PEARL/USDC", kind: "pool", chain: "near", priceUsd: 1.521, volumeUsd24h: 1_100_000, liquidityUsd: 420_000, share: 1_100_000 / 9_680_000, tradeUrl: "https://app.rhea.finance/", inAppExchange: nil),
            MarketVenue(id: "kraken:pearl/usd", venue: "Kraken", pair: "PEARL/USD", kind: "cex", chain: nil, priceUsd: 1.522, volumeUsd24h: 560_000, liquidityUsd: nil, share: 560_000 / 9_680_000, tradeUrl: "https://pro.kraken.com/app/trade/PEARL-USD", inAppExchange: nil),
        ]
    )
    #endif
}

struct TradeVolumeShareSection: View {
    @ObservedObject var store: SafeTradeStore
    @ObservedObject private var markets = TradeMarketsStore.shared
    @Environment(\.openURL) private var openURL

    enum Filter: String, CaseIterable {
        case all, cex, pool
    }

    @State private var filter: Filter = .all
    @State private var expanded = false
    @State private var hoveredSliceID: String?

    private static let donutInnerRadius: CGFloat = 58
    private static let donutHoverInset: CGFloat = 5

    private static let venueColors: [String: Color] = [
        "Gate": Color(red: 0.14, green: 0.72, blue: 0.56),
        "SafeTrade": Color(red: 0.55, green: 0.38, blue: 0.95),
        "Near Intents": Color(red: 0.06, green: 0.75, blue: 0.82),
        "Coinbase Exchange": Color(red: 0.12, green: 0.38, blue: 0.92),
        "Rhea Finance": Color(red: 0.95, green: 0.56, blue: 0.18),
        "Kraken": Color(red: 0.44, green: 0.32, blue: 0.88),
        "CoinEx": Color(red: 0.18, green: 0.66, blue: 0.74),
    ]

    private func color(for venue: String, index: Int = 0) -> Color {
        if venue == Loc("其他") { return Color.gray.opacity(0.45) }
        if let c = Self.venueColors[venue] { return c }
        let fallbackPalette: [Color] = [.teal, .indigo, .orange, .pink, .cyan, .mint]
        return fallbackPalette[abs(venue.hashValue + index) % fallbackPalette.count]
    }

    private var filteredItems: [MarketVenue] {
        guard let snap = markets.snapshot else { return [] }
        switch filter {
        case .all: return snap.items
        case .cex: return snap.items.filter { !$0.isPool }
        case .pool: return snap.items.filter { $0.isPool }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.md) {
            HStack {
                Text(Loc("全网交易量")).font(.headline)
                Spacer()
                if markets.loading && markets.snapshot == nil {
                    ProgressView().controlSize(.small)
                } else if let snap = markets.snapshot, snap.poolVolumeUsd24h > 0, snap.totalVolumeUsd24h > 0 {
                    Text(Loc("DEX %.1f%%", snap.poolVolumeUsd24h / snap.totalVolumeUsd24h * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let snap = markets.snapshot, !snap.items.isEmpty {
                let slices = MarketVolumeSlice.build(from: snap.items, total: snap.totalVolumeUsd24h)
                if !slices.isEmpty {
                    donut(slices: slices, total: snap.totalVolumeUsd24h)
                }

                Picker(Loc("类型"), selection: $filter) {
                    Text(Loc("全部")).tag(Filter.all)
                    Text(verbatim: "CEX").tag(Filter.cex)
                    Text(verbatim: "DEX").tag(Filter.pool)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)

                let allRows = filteredItems
                let visibleRows = expanded ? allRows : Array(allRows.prefix(8))
                VStack(spacing: 0) {
                    ForEach(Array(visibleRows.enumerated()), id: \.element.id) { idx, item in
                        venueRow(item, dotColor: color(for: item.venue, index: idx))
                            .padding(.vertical, Pearl.Space.xs + 2)
                        if item.id != visibleRows.last?.id {
                            Divider()
                        }
                    }
                }

                if allRows.count > 8 {
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(expanded ? Loc("收起") : Loc("查看全部 (%d)", allRows.count))
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderless)
                    .tint(Pearl.accent)
                }
            } else if !markets.loading {
                HStack {
                    Text(Loc("暂无市场数据")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(Loc("重试")) { Task { await markets.refresh() } }
                        .buttonStyle(.borderless).font(.caption.weight(.semibold)).tint(Pearl.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard()
        .task { await markets.refreshIfStale() }
    }

    private func selectSlice(_ id: String?) {
        guard id != hoveredSliceID else { return }
        withAnimation(.snappy(duration: 0.16)) {
            hoveredSliceID = id
        }
    }

    @ViewBuilder private func donut(slices: [MarketVolumeSlice], total: Double) -> some View {
        let enumerated = Array(slices.enumerated())
        let active = hoveredSliceID.flatMap { id in enumerated.first { $0.element.id == id } }
        let hasActive = active != nil

        Chart(enumerated, id: \.element.id) { idx, s in
            let isHovered = active?.element.id == s.id
            SectorMark(
                angle: .value(Loc("成交量"), s.volumeUsd),
                innerRadius: .fixed(Self.donutInnerRadius),
                outerRadius: .inset(isHovered ? 0 : Self.donutHoverInset),
                angularInset: 1.5
            )
            .cornerRadius(3)
            .foregroundStyle(color(for: s.name, index: idx))
            .opacity(!hasActive || isHovered ? 1.0 : 0.45)
            .annotation(position: .overlay) {
                if s.share >= 0.08 {
                    Text(String(format: "%.0f%%", s.share * 100))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .opacity(!hasActive || isHovered ? 1.0 : 0.55)
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plotFrame = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
                #if os(macOS)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let loc):
                            selectSlice(MarketVolumeSlice.hitTest(at: loc, in: plotFrame, innerRadius: Self.donutInnerRadius, slices: slices)?.id)
                        case .ended:
                            selectSlice(nil)
                        }
                    }
                #else
                HoldToScrub { p in
                    selectSlice(p.flatMap {
                        MarketVolumeSlice.hitTest(at: $0, in: plotFrame, innerRadius: Self.donutInnerRadius, slices: slices)?.id
                    })
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let loc):
                        selectSlice(MarketVolumeSlice.hitTest(at: loc, in: plotFrame, innerRadius: Self.donutInnerRadius, slices: slices)?.id)
                    case .ended:
                        selectSlice(nil)
                    }
                }
                .onTapGesture { loc in
                    let hit = MarketVolumeSlice.hitTest(at: loc, in: plotFrame, innerRadius: Self.donutInnerRadius, slices: slices)?.id
                    selectSlice(hit == hoveredSliceID ? nil : hit)
                }
                #endif
            }
        }
        .frame(height: 196)
        .overlay {
            donutCenterLabel(active: active, total: total)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private func donutCenterLabel(
        active: (offset: Int, element: MarketVolumeSlice)?,
        total: Double
    ) -> some View {
        let maxTextWidth = Self.donutInnerRadius * 2 - 20
        if let active {
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(color(for: active.element.name, index: active.offset))
                        .frame(width: 6, height: 6)
                    Text(verbatim: active.element.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Text(verbatim: Self.compactUSD(active.element.volumeUsd))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(verbatim: String(format: "%.1f%%", active.element.share * 100))
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: maxTextWidth)
        } else {
            VStack(spacing: 2) {
                Text(Loc("24h 全网成交"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(Self.compactUSD(total))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: maxTextWidth)
        }
    }

    @ViewBuilder private func venueRow(_ item: MarketVenue, dotColor: Color) -> some View {
        let targetExchange = item.inAppExchange.flatMap(TradeExchange.init(rawValue:))
        let isCurrentExchange = targetExchange == store.exchange
        // Mac App Store builds (guideline 3.1.5(iii), AppFeatures.tradeAccount == false) must not
        // link out to external exchange trade pages; switching the read-only chart (targetExchange) stays active.
        let validURL: URL? = AppFeatures.tradeAccount
            ? item.tradeUrl.flatMap(URL.init(string:)).flatMap {
                ($0.scheme == "https" || $0.scheme == "http") ? $0 : nil
            }
            : nil
        let rowContent = HStack(spacing: Pearl.Space.sm) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: item.venue)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if item.isPool {
                        Text(verbatim: "DEX")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                    if isCurrentExchange {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Pearl.accent)
                    }
                }
                HStack(spacing: 6) {
                    Text(verbatim: item.pair)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let p = item.priceUsd, p > 0 {
                        Text(verbatim: Self.formatPrice(p))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if let tvl = item.liquidityUsd, tvl > 0 {
                        Text(verbatim: "TVL \(Self.compactUSD(tvl))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: Pearl.Space.xs)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: Self.compactUSD(item.volumeUsd24h))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)
                Text(verbatim: String(format: "%.1f%%", item.share * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if targetExchange != nil {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isCurrentExchange ? Pearl.accent : .secondary)
                    .frame(width: 14)
            } else if validURL != nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
            } else {
                Color.clear.frame(width: 14, height: 14)
            }
        }
        .contentShape(Rectangle())

        if targetExchange != nil || validURL != nil {
            Button {
                if let ex = targetExchange {
                    withAnimation(.snappy) { store.setExchange(ex) }
                } else if let url = validURL {
                    openURL(url)
                }
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
        } else {
            rowContent
        }
    }

    static func compactUSD(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "$0" }
        if value >= 1_000_000_000 { return String(format: "$%.2fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "$%.2fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "$%.1fK", value / 1_000) }
        return String(format: "$%.0f", value)
    }

    static func formatPrice(_ value: Double) -> String {
        if value >= 10 { return String(format: "$%.2f", value) }
        if value >= 0.1 { return String(format: "$%.4f", value) }
        return String(format: "$%.6f", value)
    }
}
