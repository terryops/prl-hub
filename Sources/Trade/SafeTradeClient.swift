import Foundation
import CryptoKit

// SafeTrade (safetrade.com) — OpenDAX **Finex** API v2.
// All verified live via URLSession 2026-06-04 (Cloudflare passes Apple's TLS
// fingerprint; curl is blocked). Public market data is split across namespaces:
//   auth    = X-Auth-Apikey / X-Auth-Nonce / X-Auth-Signature
//             signature = hex( HMAC_SHA256(secret, nonce + key) )
//   balances= GET /api/v2/trade/account/balances/spot   -> [{currency,balance,locked}]
//   orders  = GET/POST /api/v2/trade/market/orders       (POST Finex: market,side,amount,price,type)
//   ticker  = GET /api/v2/peatio/public/markets/{m}/tickers   (peatio ns!)
//   k-line  = GET /api/v2/trade/public/markets/{m}/k-line     (trade ns!) -> [[ts,o,h,l,c,v]]

struct STBalance: Decodable, Identifiable {
    let currency: String
    let balance: String
    let locked: String
    var id: String { currency }
    var balanceValue: Double { Double(balance) ?? 0 }
    var lockedValue: Double { Double(locked) ?? 0 }
}

struct STTicker: Decodable {
    let last: String?
    let buy: String?
    let sell: String?
    let high: String?
    let low: String?
    let vol: String?
    let price_change_percent: String?
}
private struct STTickerEnvelope: Decodable { let ticker: STTicker }

private actor SafeTradeNonceGenerator {
    private var last = 0

    func next() -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let nonce = max(now, last + 1)
        last = nonce
        return String(nonce)
    }
}

/// An order timestamp, decoded leniently. The docs disagree on the wire format —
/// SafeTrade's wiki says ISO8601 strings, OpenDAX Finex shows unix seconds — so
/// accept either (plus milliseconds / numeric strings). Never throws: `orders()`
/// decodes with `try?`, so one odd timestamp must not blank the whole order list.
struct STTimestamp: Decodable {
    let date: Date?

    init(_ date: Date?) { self.date = date }

    init(from decoder: Decoder) throws {
        let c = try? decoder.singleValueContainer()
        if let n = try? c?.decode(Double.self) {
            date = Self.epoch(n)
        } else if let s = try? c?.decode(String.self) {
            date = Double(s).flatMap(Self.epoch) ?? Self.iso8601(s)
        } else {
            date = nil
        }
    }

    /// Unix seconds, or milliseconds when the value is too large to be seconds.
    private static func epoch(_ n: Double) -> Date? {
        guard n.isFinite, n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
    }

    private static func iso8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions.insert(.withFractionalSeconds)
        return f.date(from: s)
    }
}

struct STOrder: Decodable {
    let id: Int?
    let market: String?
    let side: String?
    let type: String?
    let price: String?
    let state: String?
    let origin_amount: String?
    // A market order has no `price` (it fills at whatever the book offers); the
    // exchange reports the *realized* average fill price here instead (verified
    // live: a market order returns `price: null, avg_price: "0.55"`), so we can
    // show the real executed price rather than a "市价" placeholder.
    let avg_price: String?
    let created_at: STTimestamp?
    let updated_at: STTimestamp?

    /// When the order was placed — falls back to its last update if the create
    /// time is missing or unparseable; nil means the row simply shows no date.
    var placedAt: Date? { created_at?.date ?? updated_at?.date }

    /// Open orders still resting on the book — these are the only ones the
    /// exchange will accept a cancel for. `done`/`cancel`/`reject` are terminal.
    var isOpen: Bool {
        switch state?.lowercased() {
        case "wait", "pending": return true
        default: return false
        }
    }

    /// The actual price to SHOW for this order. Limit orders carry their set
    /// `price`; market orders have `price == nil` and fill at an average, so fall
    /// back to the realized `avg_price`. Returns nil only when the order is
    /// genuinely unpriced (a market order still matching / unfilled, no avg yet) —
    /// the caller shows a neutral "—" rather than the literal "市价".
    var displayPrice: String? {
        for candidate in [price, avg_price] {
            if let s = candidate, let v = Double(s), v > 0 { return s }
        }
        return nil
    }
}

struct STCandle: Identifiable {
    let time: Date
    let open, high, low, close, volume: Double
    var id: TimeInterval { time.timeIntervalSince1970 }
    var up: Bool { close >= open }
}

enum SafeTradeError: LocalizedError {
    case noCredentials, invalidURL, http(Int, String), decode(String), placedUnverified
    var errorDescription: String? {
        switch self {
        case .noCredentials: return Loc("未配置 SafeTrade API 密钥")
        case .invalidURL: return Loc("SafeTrade 请求地址无效")
        case .http(let c, let m): return "HTTP \(c): \(m.prefix(120))"
        case .decode(let m): return Loc("解析失败: %@", m)
        case .placedUnverified: return Loc("订单可能已提交但未能确认结果，请到下方订单列表核对，切勿重复下单。")
        }
    }
}

/// Outcome of an API-key check, classified so the UI can tell the user *why* a
/// key didn't work — wrong key/secret vs. IP not whitelisted vs. network — rather
/// than silently saving a key that will never be able to trade.
enum SafeTradeCredentialCheck {
    case ok
    /// The exchange rejected the credentials (401/403). Can't distinguish a bad
    /// key/secret from an IP that isn't whitelisted — both surface here.
    case rejected(Int, String)
    /// Reached the server but it returned some other non-2xx status.
    case serverError(Int, String)
    /// Never reached the server (offline, DNS, timeout, TLS) — the request failed
    /// before any HTTP status came back.
    case network(String)
}

enum SafeTradeMarket {
    static let defaultValue = "prlusdt"
    private static let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")

    static func cleaned(_ raw: String?) -> String {
        (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isValid(_ market: String) -> Bool {
        let s = cleaned(market)
        guard (3...32).contains(s.count) else { return false }
        return s.unicodeScalars.allSatisfy { allowedScalars.contains($0) }
    }

    static func normalized(_ raw: String?) -> String {
        let s = cleaned(raw)
        return isValid(s) ? s : defaultValue
    }
}

struct SafeTradeClient {
    let root = "https://safetrade.com"
    private static let nonceGenerator = SafeTradeNonceGenerator()

    /// Signs with the *passed-in* key/secret (defaulting to the stored ones) so a
    /// pre-save check can validate exactly what the user just typed.
    private func signedHeaders(apiKey: String = SafeTradeSecrets.apiKey,
                               apiSecret: String = SafeTradeSecrets.apiSecret) async -> [String: String] {
        let nonce = await Self.nonceGenerator.next()
        let key = SymmetricKey(data: Data(apiSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data((nonce + apiKey).utf8), using: key)
        let sig = mac.map { String(format: "%02x", $0) }.joined()
        return ["X-Auth-Apikey": apiKey, "X-Auth-Nonce": nonce, "X-Auth-Signature": sig]
    }

    /// `path` is a full `/api/v2/...` path (namespaces differ per resource).
    /// `credentials`, when supplied, signs the request with those explicit keys
    /// instead of the stored ones (used to verify keys before they're saved).
    private func send(_ path: String, method: String = "GET",
                      query: [URLQueryItem] = [], form: [String: String]? = nil,
                      authed: Bool, credentials: (key: String, secret: String)? = nil) async throws -> Data {
        if authed && credentials == nil && !SafeTradeSecrets.hasCredentials { throw SafeTradeError.noCredentials }
        guard var comps = URLComponents(string: root + path) else { throw SafeTradeError.invalidURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw SafeTradeError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if authed {
            let headers = await signedHeaders(apiKey: credentials?.key ?? SafeTradeSecrets.apiKey,
                                              apiSecret: credentials?.secret ?? SafeTradeSecrets.apiSecret)
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        }
        if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            req.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw SafeTradeError.http(code, String(data: data, encoding: .utf8) ?? "") }
        return data
    }

    func balances() async throws -> [STBalance] {
        let data = try await send("/api/v2/trade/account/balances/spot", authed: true)
        do { return try JSONDecoder().decode([STBalance].self, from: data) }
        catch { throw SafeTradeError.decode(error.localizedDescription) }
    }

    /// Make a lightweight authenticated request (balances) to confirm the given
    /// key/secret actually work, so saving an API key can surface *why* if they
    /// don't. Signs with the passed-in credentials so it validates what the user
    /// typed before it's committed to the Keychain. Never throws — every outcome
    /// is folded into a classified result for the caller to message.
    func verifyCredentials(apiKey: String, apiSecret: String) async -> SafeTradeCredentialCheck {
        do {
            _ = try await send("/api/v2/trade/account/balances/spot",
                               authed: true, credentials: (apiKey, apiSecret))
            return .ok
        } catch SafeTradeError.http(let code, let body) {
            // 401/403 = auth rejected (bad key/secret or IP not whitelisted);
            // anything else 2xx-failing is a server-side problem to retry later.
            return (code == 401 || code == 403) ? .rejected(code, body) : .serverError(code, body)
        } catch SafeTradeError.noCredentials {
            return .rejected(0, "")
        } catch {
            // URLSession failure — offline, DNS, timeout, TLS — never hit the server.
            return .network(error.localizedDescription)
        }
    }

    func ticker(market: String) async throws -> STTicker {
        let market = SafeTradeMarket.normalized(market)
        let data = try await send("/api/v2/peatio/public/markets/\(market)/tickers", authed: false)
        do { return try JSONDecoder().decode(STTickerEnvelope.self, from: data).ticker }
        catch { throw SafeTradeError.decode(error.localizedDescription) }
    }

    func orders(market: String, limit: Int = 20) async throws -> [STOrder] {
        let market = SafeTradeMarket.normalized(market)
        let data = try await send("/api/v2/trade/market/orders",
                                  query: [.init(name: "market", value: market), .init(name: "limit", value: String(limit))],
                                  authed: true)
        return (try? JSONDecoder().decode([STOrder].self, from: data)) ?? []
    }

    /// K-line OHLCV. `period` in minutes (15, 60, 240, 1440…). Rows: [ts, o, h, l, c, v].
    /// Without a time range the API returns the OLDEST candles, so we request the
    /// most recent `limit` window explicitly (time_from … now).
    func kline(market: String, period: Int, limit: Int = 120) async throws -> [STCandle] {
        let market = SafeTradeMarket.normalized(market)
        let to = Int(Date().timeIntervalSince1970)
        let from = to - period * 60 * limit
        let data = try await send("/api/v2/trade/public/markets/\(market)/k-line",
                                  query: [.init(name: "period", value: String(period)),
                                          .init(name: "time_from", value: String(from)),
                                          .init(name: "time_to", value: String(to)),
                                          .init(name: "limit", value: String(limit))],
                                  authed: false)
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [[Any]]) ?? []
        func dbl(_ v: Any) -> Double { (v as? NSNumber)?.doubleValue ?? Double("\(v)") ?? 0 }
        return rows.compactMap { r in
            guard r.count >= 6 else { return nil }
            return STCandle(time: Date(timeIntervalSince1970: dbl(r[0])),
                            open: dbl(r[1]), high: dbl(r[2]), low: dbl(r[3]), close: dbl(r[4]), volume: dbl(r[5]))
        }
    }

    func placeOrder(market: String, side: String, amount: String,
                    price: String?, type: String) async throws -> STOrder {
        let market = SafeTradeMarket.normalized(market)
        var form = ["market": market, "side": side, "amount": amount, "type": type]
        if type == "limit", let price { form["price"] = price }
        let data: Data
        do {
            data = try await send("/api/v2/trade/market/orders", method: "POST", form: form, authed: true)
        } catch let e as URLError where Self.isAmbiguousPostFailure(e) {
            // The POST body may have reached the exchange and BOOKED the order before
            // the response was lost (timeout / connection dropped / TLS mid-flight).
            // Reporting a hard failure here would invite a duplicate re-tap, so signal
            // "placed but unverified" and let the store reconcile against the order list.
            // Pre-send failures (offline/DNS/can't-connect) are NOT reclassified — they
            // never reached the server, so they stay a clean, safe-to-retry failure.
            throw SafeTradeError.placedUnverified
        }
        // send() already enforced a 2xx, so by the time we reach here the order has
        // been ACCEPTED server-side. A decode failure means we can't read the result
        // (body drift / interstitial) — signal "placed but unverified" so the UI
        // reconciles instead of reporting a hard failure that invites a duplicate.
        do { return try JSONDecoder().decode(STOrder.self, from: data) }
        catch { throw SafeTradeError.placedUnverified }
    }

    /// Was an order-POST transport failure ambiguous (the request may already be live
    /// on the exchange)? Failures that provably happened BEFORE the request left the
    /// device are safe to retry and stay hard failures; anything in-flight is ambiguous.
    private static func isAmbiguousPostFailure(_ e: URLError) -> Bool {
        switch e.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .badURL, .unsupportedURL, .badServerResponse:
            return false   // never reached the exchange → re-tap can't double-book
        default:
            return true    // timed out / connection lost / TLS after send → may be booked
        }
    }

    /// Cancel a single resting order by id. OpenDAX exposes TWO cancel routes
    /// depending on the matching engine: Peatio uses `/orders/{id}/cancel`, Finex
    /// uses `/orders/cancel/{id}`. SafeTrade's `trade` namespace answers the
    /// Peatio form (the Finex form 404s), so try that first and fall back to the
    /// Finex form only on a 404 — robust whichever the gateway exposes.
    /// A 2xx means the cancel was ACCEPTED; the order flips to `cancel` once the
    /// engine removes it, which the caller reconciles by re-fetching the list.
    func cancelOrder(id: Int) async throws {
        do {
            _ = try await send("/api/v2/trade/market/orders/\(id)/cancel", method: "POST", authed: true)
        } catch let e as SafeTradeError {
            guard case .http(404, _) = e else { throw e }
            _ = try await send("/api/v2/trade/market/orders/cancel/\(id)", method: "POST", authed: true)
        }
    }
}
