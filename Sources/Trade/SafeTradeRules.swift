import Foundation

// Pure SafeTrade logic — no networking, no UI — so it can be unit-tested:
// why a signed request was refused, a market's order rules, order-book walks,
// and Cloudflare's trace output.

/// Why SafeTrade refused a signed request, read from its `authz.*` error keys.
/// Each has a different fix, so the UI must not lump them into one "key rejected".
enum SafeTradeAuthProblem: Equatable {
    /// The key has a Trusted IPs list and this network's public IP isn't on it
    /// (the user saw it as "authz not trusted ip").
    case untrustedIP
    /// Unknown / disabled key, or a signature made with the wrong secret.
    case badKey
    /// The nonce is outside the server's window — the device clock is off.
    case clock
    /// Cloudflare's HTML block page, not the API: the network / proxy exit is blocked.
    case firewall
    /// Some other refusal (e.g. the key lacks a permission); carries the raw keys.
    case other([String])

    init?(status: Int, body: String) {
        guard status == 401 || status == 403 else { return nil }
        let keys = SafeTradeError.errorKeys(body)
        guard !keys.isEmpty else {
            // The API always answers `{"errors":[…]}`; an HTML page is Cloudflare's WAF.
            if body.range(of: "<html", options: .caseInsensitive) != nil { self = .firewall } else { self = .other([]) }
            return
        }
        let tokens = keys.map(Self.tokens)
        if tokens.contains(where: { t in t.contains("ip") || t.contains { $0.contains("trusted") || Self.listTokens.contains($0) } }) {
            self = .untrustedIP
        } else if tokens.contains(where: { $0.contains("nonce") }) {
            self = .clock
        } else if tokens.contains(where: { t in t.contains { ["apikey", "key", "signature", "secret"].contains($0) } }) {
            self = .badKey
        } else {
            self = .other(keys)
        }
    }

    private static let listTokens: Set<String> = ["whitelist", "whitelisted", "allowlist", "allowlisted"]

    /// Is this one of the stale-nonce keys? (A request refused for its nonce never
    /// reached the handler, so re-signing it is safe even for a POST.)
    static func isNonceKey(_ key: String) -> Bool { tokens(key).contains("nonce") }

    /// "authz.not_trusted_ip" → ["authz", "not", "trusted", "ip"]. Matching whole
    /// tokens keeps "ip" from hitting inside words like "invalid_permission".
    static func tokens(_ key: String) -> [String] {
        key.lowercased().split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).map(String.init)
    }

    var message: String {
        switch self {
        case .untrustedIP:
            return Loc("SafeTrade 拒绝了当前网络：这个 API 密钥绑定了 Trusted IPs（IP 白名单），而你现在的 IP 不在名单里。")
        case .badKey:
            return Loc("SafeTrade 不认这个 API 密钥：Key 或 Secret 不对，或者密钥已停用。")
        case .clock:
            return Loc("签名已过期：本机时间和 SafeTrade 相差太多，请打开「自动设置时间」后重试。")
        case .firewall:
            return Loc("请求被 SafeTrade 的防火墙（Cloudflare）拦截，通常是当前网络或代理的出口被拦，换个网络再试。")
        case .other(let keys):
            return Loc("SafeTrade 拒绝了这个请求（%@）", keys.isEmpty ? "401/403" : keys.joined(separator: ", "))
        }
    }
}

/// A market's order rules (`GET /trade/public/markets/{id}`). Checked live for
/// prlusdt 2026-09-27: price 2 dp, amount 4 dp, min amount 2 PRL, price 0.01–100000.
struct SafeTradeMarketRules: Decodable, Equatable {
    var amountPrecision: Int
    var pricePrecision: Int
    var minAmount: Decimal
    var minPrice: Decimal
    var maxPrice: Decimal

    /// Used until the live rules load (and if they never do).
    static let prlusdt = SafeTradeMarketRules(amountPrecision: 4, pricePrecision: 2,
                                              minAmount: 2, minPrice: Decimal(string: "0.01")!, maxPrice: 100000)

    init(amountPrecision: Int, pricePrecision: Int, minAmount: Decimal, minPrice: Decimal, maxPrice: Decimal) {
        self.amountPrecision = amountPrecision
        self.pricePrecision = pricePrecision
        self.minAmount = minAmount
        self.minPrice = minPrice
        self.maxPrice = maxPrice
    }

    private enum CodingKeys: String, CodingKey {
        case amount_precision, price_precision, min_amount, min_price, max_price
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.prlusdt
        func dec(_ k: CodingKeys) -> Decimal? {
            (try? c.decodeIfPresent(STNumberText.self, forKey: k)).flatMap { Decimal(string: $0.text) }
        }
        amountPrecision = (try? c.decodeIfPresent(Int.self, forKey: .amount_precision)) ?? fallback.amountPrecision
        pricePrecision = (try? c.decodeIfPresent(Int.self, forKey: .price_precision)) ?? fallback.pricePrecision
        minAmount = dec(.min_amount) ?? fallback.minAmount
        minPrice = dec(.min_price) ?? fallback.minPrice
        maxPrice = dec(.max_price) ?? fallback.maxPrice
    }

    enum Problem: Equatable {
        case priceDecimals(Int)        // more decimals than the market takes (the limit)
        case amountDecimals(Int)
        case belowMinAmount(Decimal)
        case priceOutOfRange(Decimal, Decimal)

        var message: String {
            switch self {
            case .priceDecimals(let n): return Loc("价格最多 %d 位小数", n)
            case .amountDecimals(let n): return Loc("数量最多 %d 位小数", n)
            case .belowMinAmount(let m): return Loc("最少下单 %@ PRL", SafeTradeMarketRules.plain(m))
            case .priceOutOfRange(let lo, let hi):
                return Loc("价格需在 %@ – %@ USDT 之间", SafeTradeMarketRules.plain(lo), SafeTradeMarketRules.plain(hi))
            }
        }
    }

    /// The first rule the typed order breaks, or nil. Empty / unparseable fields are
    /// the form's own concern and pass here; `price` is nil for a market order.
    func problem(amountText: String, priceText: String?) -> Problem? {
        if let priceText, let p = PRLAmount.parse(priceText) {
            if Self.decimalPlaces(priceText) > pricePrecision { return .priceDecimals(pricePrecision) }
            if p > 0, p < minPrice || p > maxPrice { return .priceOutOfRange(minPrice, maxPrice) }
        }
        if let a = PRLAmount.parse(amountText), a > 0 {
            if Self.decimalPlaces(amountText) > amountPrecision { return .amountDecimals(amountPrecision) }
            if a < minAmount { return .belowMinAmount(minAmount) }
        }
        return nil
    }

    /// Significant decimals typed ("1.50" → 1: a trailing zero changes nothing).
    static func decimalPlaces(_ text: String) -> Int {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let dot = t.firstIndex(of: ".") else { return 0 }
        let frac = t[t.index(after: dot)...]
        return frac.count - frac.reversed().prefix(while: { $0 == "0" }).count
    }

    /// Round DOWN to `places` — MAX fills must never exceed what's held.
    static func floor(_ x: Double, places: Int) -> Double {
        let m = pow(10, Double(places))
        return (x * m).rounded(.down) / m
    }

    /// Plain decimal text for the API and for display (no grouping, "." separator).
    static func plain(_ d: Decimal) -> String { NSDecimalNumber(decimal: d).stringValue }
}

/// One side of the order book, best price first.
struct STBookLevel: Equatable {
    let price: Double
    let amount: Double
}

/// `GET /trade/public/markets/{id}/depth` — `{"asks": [["1.48","5591.07"], …], "bids": […]}`.
struct STDepth: Decodable, Equatable {
    let asks: [STBookLevel]
    let bids: [STBookLevel]

    init(asks: [STBookLevel], bids: [STBookLevel]) { self.asks = asks; self.bids = bids }

    private enum CodingKeys: String, CodingKey { case asks, bids }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func side(_ k: CodingKeys) -> [STBookLevel] {
            let rows = (try? c.decode([[STNumberText]].self, forKey: k)) ?? []
            return rows.compactMap { r in
                guard r.count >= 2, let p = Double(r[0].text), let a = Double(r[1].text), p > 0, a > 0 else { return nil }
                return STBookLevel(price: p, amount: a)
            }
        }
        asks = side(.asks).sorted { $0.price < $1.price }
        bids = side(.bids).sorted { $0.price > $1.price }
    }
}

enum SafeTradeBook {
    /// SafeTrade's default taker fee (0.1%, `GET /trade/public/trading_fees`, 2026-09-27).
    /// Charged on what an order RECEIVES, so a buy's USDT cost is not raised by it —
    /// it only feeds the MAX safety margin.
    static let takerFee = 0.001

    /// Average fill price for `amount` walking `levels` best-first; nil when the
    /// visible book can't fill it (or amount ≤ 0).
    static func averagePrice(for amount: Double, levels: [STBookLevel]) -> Double? {
        guard amount > 0 else { return nil }
        var left = amount, cost = 0.0
        for l in levels {
            let take = min(left, l.amount)
            cost += take * l.price
            left -= take
            if left <= 1e-12 { return cost / amount }
        }
        return nil
    }

    /// How much base a `quote` budget buys walking the asks, with a safety margin
    /// for the book moving a tick and the fee: each level is priced one `tick`
    /// higher and the budget is shaved by the taker fee.
    static func affordableAmount(quote: Double, asks: [STBookLevel], tick: Double) -> Double {
        var budget = quote * (1 - takerFee), got = 0.0
        for l in asks {
            let price = l.price + tick
            let levelCost = l.amount * price
            if budget >= levelCost {
                budget -= levelCost
                got += l.amount
            } else {
                got += budget / price
                return got
            }
        }
        return got
    }
}

/// Cloudflare's `/cdn-cgi/trace` answer: `key=value` lines, among them `ip=` — the
/// address SafeTrade's edge sees, i.e. what a Trusted IPs list has to contain.
enum SafeTradeTrace {
    static func ip(in body: String) -> String? {
        for line in body.split(whereSeparator: \.isNewline) where line.hasPrefix("ip=") {
            let ip = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return ip.isEmpty ? nil : ip
        }
        return nil
    }
}

/// Decode a JSON array row by row, dropping rows that don't fit — one odd row must
/// not blank a whole list. nil when the body isn't an array at all.
func decodeRows<T: Decodable>(_ type: T.Type, from data: Data) -> [T]? {
    guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
    return rows.compactMap { row in
        (try? JSONSerialization.data(withJSONObject: row)).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
