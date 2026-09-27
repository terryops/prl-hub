import Foundation
import CryptoKit

// SafeTrade (safetrade.com) — OpenDAX **Finex** API v2. Official spec (Swagger 2.0):
// https://safetrade.com/api/v2/trade/public/swagger.json (rendered at safetrade.com/api).
// All verified live via URLSession 2026-06-04 (Cloudflare passes Apple's TLS
// fingerprint; curl is blocked). Public market data is split across namespaces:
//   auth    = X-Auth-Apikey / X-Auth-Nonce / X-Auth-Signature
//             signature = hex( HMAC_SHA256(secret, nonce + key) )
//   balances= GET /api/v2/trade/account/balances/spot   -> [{currency,balance,locked}]
//   orders  = GET/POST /api/v2/trade/market/orders       (POST Finex: market,side,amount,price,type)
//   ticker  = GET /api/v2/peatio/public/markets/{m}/tickers   (peatio ns!)
//   k-line  = GET /api/v2/trade/public/markets/{m}/k-line     (trade ns!) -> [[ts,o,h,l,c,v]]
//   depth   = GET /api/v2/trade/public/markets/{m}/depth      -> {asks:[[p,a]…], bids:[[p,a]…]}
// Ticker naming (checked live 2026-09-27 against depth): `buy` is the price you BUY
// at — the best ask — and `sell` the best bid. The reverse of the usual Peatio sense.

struct STBalance: Decodable, Identifiable, Equatable {
    let currency: String
    let balance: String
    let locked: String
    var id: String { currency }
    var balanceValue: Double { Double(balance) ?? 0 }
    var lockedValue: Double { Double(locked) ?? 0 }
}

struct STTicker: Decodable, Equatable {
    let last: String?
    let buy: String?
    let sell: String?
    let high: String?
    let low: String?
    let vol: String?
    let price_change_percent: String?
}
private struct STTickerEnvelope: Decodable { let ticker: STTicker }

/// Millisecond nonces, strictly increasing, on the SERVER's clock: SafeTrade refuses a
/// nonce outside its time window (`authz.nonce_expired`), so a phone whose clock is
/// off would fail every signed call. The offset is learned from response `Date` headers.
actor SafeTradeNonceGenerator {
    private var last = 0
    private var offsetMs = 0
    private let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    func next() -> String {
        let now = Int(Date().timeIntervalSince1970 * 1000) + offsetMs
        let nonce = max(now, last + 1)
        last = nonce
        return String(nonce)
    }

    func observe(serverDate header: String) {
        guard let server = httpDate.date(from: header) else { return }
        offsetMs = Self.offset(server: server, local: Date())
    }

    /// The header has whole-second resolution (the true time is on average half a
    /// second later), so only a clearly wrong device clock is corrected.
    nonisolated static func offset(server: Date, local: Date) -> Int {
        let skew = Int((server.timeIntervalSince(local) + 0.5) * 1000)
        return abs(skew) >= 2000 ? skew : 0
    }
}

/// An order timestamp, decoded leniently. The docs disagree on the wire format —
/// SafeTrade's wiki says ISO8601 strings, OpenDAX Finex shows unix seconds — so
/// accept either (plus milliseconds / numeric strings). Never throws: `orders()`
/// decodes with `try?`, so one odd timestamp must not blank the whole order list.
struct STTimestamp: Decodable, Equatable {
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
        (try? Date(s, strategy: .iso8601))
            ?? (try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}

struct STOrder: Decodable, Equatable {
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

/// One withdrawal network of a currency (`GET /trade/public/currencies/{id}`).
/// PRL has one (`pearl-tokens`); USDT has several chains (checked live 2026-09-23:
/// Arbitrum / BSC / Solana / Ethereum open, TRON / Base / Polygon … closed).
struct STCurrencyNetwork: Decodable, Identifiable {
    let blockchain_key: String
    let `protocol`: String?          // short ticker-style code, e.g. "BSC", "ARB"
    let protocol_name: String?
    let withdraw_enabled: Bool?
    let withdraw_fee: String?
    let withdraw_fee_ratio: String?
    let min_withdraw_amount: String?
    let status: String?
    let explorer_transaction: String?
    let system_options: SystemOptions?
    struct SystemOptions: Decodable { let address_validate_regexes: [String]? }

    var id: String { blockchain_key }
    var name: String { protocol_name ?? blockchain_key }
    /// Compact label for tight spots: the full name unless it's long
    /// ("Binance Smart Chain" → "BSC").
    var shortName: String {
        if let full = protocol_name, full.count <= 12 { return full }
        return `protocol` ?? name
    }
    var canWithdraw: Bool { withdraw_enabled == true && (status ?? "active") == "active" }
    /// Same rule as the SafeTrade web client: max(fixed fee, amount × ratio).
    func fee(for amount: Decimal) -> Decimal {
        let fixed = Decimal(string: withdraw_fee ?? "") ?? 0
        let ratio = Decimal(string: withdraw_fee_ratio ?? "") ?? 0
        return ratio > 0 ? max(fixed, amount * ratio) : fixed
    }
    var minAmount: Decimal { Decimal(string: min_withdraw_amount ?? "") ?? 0 }
    func explorerURL(txid: String) -> URL? {
        explorer_transaction.flatMap { URL(string: $0.replacingOccurrences(of: "#{txid}", with: txid)) }
    }

    /// Address check for this chain: the exchange's own regexes when it publishes
    /// them (PRL does), else a checksum check by chain family (see ChainAddress).
    func isValidAddress(_ a: String) -> Bool {
        if let regexes = system_options?.address_validate_regexes, !regexes.isEmpty {
            return regexes.contains { a.range(of: $0, options: .regularExpression) != nil }
        }
        let key = blockchain_key.lowercased()
        if key.hasPrefix("tron") { return ChainAddress.isValidTron(a) }
        if key.hasPrefix("spl") || key.hasPrefix("sol") { return ChainAddress.isValidSolana(a) }
        // Ethereum and the EVM chains (BSC, Arbitrum, Base, Polygon, Avalanche, PulseChain…).
        return ChainAddress.isValidEVM(a)
    }
}
struct STCurrency: Decodable {
    let precision: Int?
    let networks: [STCurrencyNetwork]
}

/// A JSON value that may be a number or a numeric string, kept as its text.
/// SafeTrade's swagger types withdraw amounts as numbers, while balances and
/// orders come back as strings — accept both.
struct STNumberText: Decodable {
    let text: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { text = s }
        else { text = NSDecimalNumber(decimal: try c.decode(Decimal.self)).stringValue }
    }
}

/// A withdrawal as listed by `GET /trade/account/withdraws` (swagger:
/// account_entities.Withdraw). Every field optional — the list is decoded per-row
/// so one odd row can't blank the history.
struct STWithdraw: Decodable, Identifiable {
    let id: Int
    private let amount: STNumberText?
    private let fee: STNumberText?
    let rid: String?
    let address: String?
    let txid: String?
    let blockchain_txid: String?
    let state: String?
    let status: String?
    let blockchain_key: String?
    let created_at: STTimestamp?

    var amountText: String? { amount?.text }
    var feeText: String? { fee?.text }
    var destination: String? { rid ?? address }
    var chainTxid: String? { [blockchain_txid, txid].compactMap { $0 }.first { !$0.isEmpty } }
    var stateValue: String { (state ?? status ?? "").lowercased() }
}

/// An entry in the user's SafeTrade address book ("beneficiary"), managed on the
/// SafeTrade website. Withdrawing to one skips the e-mail code — the web client
/// sends `beneficiary_id` instead of address + chain and no email_code.
/// Swagger (account_entities.Beneficiary): id, address, label, description,
/// currency_id, blockchain_key, state. The web client's `name` / `currency` /
/// `data.address` variants are still read in case the live API differs.
struct STBeneficiary: Decodable, Identifiable {
    let id: Int
    let label: String?
    let name: String?
    let description: String?
    let currency_id: String?
    let currency: String?
    let blockchain_key: String?
    let state: String?
    private let address: String?
    private let data: Payload?
    private struct Payload: Decodable { let address: String? }

    var title: String { [label, name, description].compactMap { $0 }.first { !$0.isEmpty } ?? shortAddr(destination ?? "") }
    var currencyID: String? { (currency_id ?? currency)?.lowercased() }
    var destination: String? { (address ?? data?.address)?.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Pending entries still wait for the e-mail confirmation on the website.
    var isActive: Bool { (state ?? "active").lowercased() == "active" }
}

struct STCandle: Identifiable, Equatable {
    let time: Date
    let open, high, low, close, volume: Double
    var id: TimeInterval { time.timeIntervalSince1970 }
    var up: Bool { close >= open }
}

enum SafeTradeError: LocalizedError {
    case noCredentials, invalidURL, http(Int, String), decode(String), placedUnverified, withdrawUnverified
    var errorDescription: String? {
        switch self {
        case .withdrawUnverified: return Loc("提现请求可能已提交但未能确认结果，请先看下方提现记录，切勿重复提交。")
        case .noCredentials: return Loc("未配置 SafeTrade API 密钥")
        case .invalidURL: return Loc("SafeTrade 请求地址无效")
        case .http(let c, let m):
            if let auth = SafeTradeAuthProblem(status: c, body: m) { return auth.message }
            if let known = Self.errorKeys(m).lazy.compactMap(Self.message(forKey:)).first { return known }
            return "HTTP \(c): \(m.prefix(120))"
        case .decode(let m): return Loc("解析失败: %@", m)
        case .placedUnverified: return Loc("订单可能已提交但未能确认结果，请到下方订单列表核对，切勿重复下单。")
        }
    }

    /// Why a signed request was refused, when it was an auth refusal.
    var authProblem: SafeTradeAuthProblem? {
        if case .http(let c, let m) = self { return SafeTradeAuthProblem(status: c, body: m) }
        return nil
    }
}

extension SafeTradeError {
    /// `{"errors":["account.withdraw.invalid_otp_code"]}` → the error keys.
    static func errorKeys(_ body: String) -> [String] {
        guard let d = body.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        return (o["errors"] as? [String]) ?? []
    }

    /// Human copy for the exchange's error keys we expect around withdrawals
    /// (keys taken from SafeTrade's own web client) and orders; unknown keys fall
    /// through to the raw "HTTP code: body" text.
    static func message(forKey key: String) -> String? {
        if key.hasPrefix("market.") { return orderMessage(forKey: key) }
        switch key.replacingOccurrences(of: "account.beneficiary.", with: "account.withdraw.") {
        case "account.withdraw.missing_email_code": return Loc("请填写邮箱验证码")
        case "account.withdraw.missing_phone_code": return Loc("请填写短信验证码")
        case "account.withdraw.missing_otp_code": return Loc("请填写谷歌验证码（2FA）")
        case "account.withdraw.invalid_otp_code": return Loc("谷歌验证码（2FA）错误")
        case "account.withdraw.invalid_code": return Loc("验证码错误或已过期")
        case "account.withdraw.insufficient_balance": return Loc("SafeTrade 可用余额不足")
        case "account.withdraw.limit_exceeded": return Loc("超出今日提现额度")
        case "account.withdraw.withdraw_disabled": return Loc("SafeTrade 暂停了这条链的提现")
        case "account.withdraw.address_validation", "account.withdraw.missing_address", "account.withdraw.missing_rid":
            return Loc("收款地址无效")
        case "account.withdraw.blocked_address_send_back": return Loc("不能提现到 SafeTrade 自己的充值地址")
        case "account.withdraw.non_round_amount": return Loc("数量的小数位太多")
        default: return nil
        }
    }

    /// `market.order.*` / `market.account.*` keys. Matched on words rather than exact
    /// keys: the swagger lists none, and Peatio / Finex spell them differently.
    private static func orderMessage(forKey key: String) -> String? {
        let t = Set(SafeTradeAuthProblem.tokens(key))
        if t.contains("insufficient") && t.contains("balance") { return Loc("SafeTrade 可用余额不足") }
        if t.contains("liquidity") { return Loc("盘口深度不够，市价单成交不了这么多，请减少数量或改用限价单") }
        if t.contains("round") && t.contains("price") { return Loc("价格的小数位太多") }
        if t.contains("round") && (t.contains("amount") || t.contains("volume")) { return Loc("数量的小数位太多") }
        if (t.contains("amount") || t.contains("volume")) && (t.contains("min") || t.contains("less") || t.contains("small")) {
            return Loc("数量低于交易所的最小下单量")
        }
        if t.contains("price") && (t.contains("min") || t.contains("max") || t.contains("range") || t.contains("less") || t.contains("greater")) {
            return Loc("价格超出交易所允许的范围")
        }
        return nil
    }
}

/// Outcome of an API-key check, classified so the UI can tell the user *why* a
/// key didn't work — wrong key/secret vs. IP not whitelisted vs. network — rather
/// than silently saving a key that will never be able to trade.
enum SafeTradeCredentialCheck {
    case ok
    /// The exchange refused the credentials (401/403); `SafeTradeAuthProblem`
    /// tells a bad key from an IP that isn't whitelisted, a wrong clock, or a block.
    case rejected(SafeTradeAuthProblem)
    /// Reached the server but it returned some other non-2xx status.
    case serverError(Int, String)
    /// Never reached the server (offline, DNS, timeout, TLS) — the request failed
    /// before any HTTP status came back.
    case network(String)
}

enum SafeTradeMarket {
    /// The one market the app trades — the whole app is PRL-centric (price, alerts,
    /// balances), so the old free-form market setting is gone.
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

    /// How a request is signed: not at all (public data), with a stored key pair, or
    /// with explicit keys (checking what the user typed before it's saved).
    enum Auth {
        case none
        case stored(SafeTradeSecrets.Role)
        case explicit(key: String, secret: String)
    }

    /// Our own ephemeral session. URLSession.shared wrote the signed account calls
    /// (balances, orders, withdrawals, address book) into the on-disk Cache.db — the
    /// request headers with the API key included. Nothing here may be cached. The
    /// first use also scrubs what older builds left in the shared cache.
    private static let session: URLSession = {
        purgeSharedCacheOnce()
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// One-time wipe of URLCache.shared (older builds' SafeTrade entries live there).
    /// Wiping everything is harmless — other features just re-fetch once — and,
    /// unlike per-URL removal, can't miss a query variant.
    private static func purgeSharedCacheOnce() {
        let flag = "safetrade.sharedCachePurged"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        URLCache.shared.removeAllCachedResponses()
        UserDefaults.standard.set(true, forKey: flag)
    }

    /// hex( HMAC_SHA256(secret, nonce + key) ).
    static func signature(nonce: String, apiKey: String, apiSecret: String) -> String {
        let key = SymmetricKey(data: Data(apiSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data((nonce + apiKey).utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func signedHeaders(apiKey: String, apiSecret: String) async -> [String: String] {
        let nonce = await Self.nonceGenerator.next()
        return ["X-Auth-Apikey": apiKey, "X-Auth-Nonce": nonce,
                "X-Auth-Signature": Self.signature(nonce: nonce, apiKey: apiKey, apiSecret: apiSecret)]
    }

    /// `path` is a full `/api/v2/...` path (namespaces differ per resource).
    private func send(_ path: String, method: String = "GET",
                      query: [URLQueryItem] = [], form: [String: String]? = nil, json: [String: Any]? = nil,
                      auth: Auth = .none) async throws -> Data {
        let credentials: (key: String, secret: String)?
        switch auth {
        case .none: credentials = nil
        case .stored(let role):
            guard let c = SafeTradeSecrets.credentials(for: role) else { throw SafeTradeError.noCredentials }
            credentials = c
        case .explicit(let key, let secret): credentials = (key, secret)
        }
        guard var comps = URLComponents(string: root + path) else { throw SafeTradeError.invalidURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw SafeTradeError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var body = URLComponents()
            body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
            req.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        }
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        for attempt in 0..<2 {
            if let credentials {
                let headers = await signedHeaders(apiKey: credentials.key, apiSecret: credentials.secret)
                headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            }
            let (data, resp) = try await Self.session.data(for: req)
            let http = resp as? HTTPURLResponse
            if let date = http?.value(forHTTPHeaderField: "Date") { await Self.nonceGenerator.observe(serverDate: date) }
            let code = http?.statusCode ?? 0
            if (200..<300).contains(code) { return data }
            let body = String(data: data, encoding: .utf8) ?? ""
            // A stale nonce is refused at the gateway before the request is acted on,
            // so one re-sign on the clock just learned from this reply is safe even
            // for a POST.
            if credentials != nil, attempt == 0,
               SafeTradeError.errorKeys(body).contains(where: SafeTradeAuthProblem.isNonceKey) { continue }
            throw SafeTradeError.http(code, body)
        }
        throw SafeTradeError.invalidURL   // unreachable: the loop returns or throws
    }

    func balances() async throws -> [STBalance] {
        let data = try await send("/api/v2/trade/account/balances/spot", auth: .stored(.trading))
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
            _ = try await send("/api/v2/trade/account/balances/spot", auth: .explicit(key: apiKey, secret: apiSecret))
            return .ok
        } catch SafeTradeError.http(let code, let body) {
            // 401/403 = auth refused (see SafeTradeAuthProblem for which kind);
            // anything else 2xx-failing is a server-side problem to retry later.
            if let problem = SafeTradeAuthProblem(status: code, body: body) { return .rejected(problem) }
            return .serverError(code, body)
        } catch {
            // URLSession failure — offline, DNS, timeout, TLS — never hit the server.
            return .network(error.localizedDescription)
        }
    }

    /// The public IP SafeTrade's edge sees for this device — what a Trusted IPs list
    /// must contain. Cloudflare answers `/cdn-cgi/trace` itself, so it works even
    /// while the API is refusing the key. Same session as the API calls, so it
    /// normally rides the same connection (same IPv4 / IPv6 address).
    func publicIP() async throws -> String {
        let data = try await send("/cdn-cgi/trace")
        guard let ip = SafeTradeTrace.ip(in: String(data: data, encoding: .utf8) ?? "") else {
            throw SafeTradeError.decode("cdn-cgi/trace")
        }
        return ip
    }

    func ticker(market: String) async throws -> STTicker {
        let market = SafeTradeMarket.normalized(market)
        let data = try await send("/api/v2/peatio/public/markets/\(market)/tickers")
        do { return try JSONDecoder().decode(STTickerEnvelope.self, from: data).ticker }
        catch { throw SafeTradeError.decode(error.localizedDescription) }
    }

    /// Order rules: precisions, minimum amount, price range.
    func marketRules(market: String) async throws -> SafeTradeMarketRules {
        let market = SafeTradeMarket.normalized(market)
        let data = try await send("/api/v2/trade/public/markets/\(market)")
        do { return try JSONDecoder().decode(SafeTradeMarketRules.self, from: data) }
        catch { throw SafeTradeError.decode(error.localizedDescription) }
    }

    /// Order book, best levels first — what a market order will actually fill at.
    func depth(market: String, limit: Int = 50) async throws -> STDepth {
        let market = SafeTradeMarket.normalized(market)
        let data = try await send("/api/v2/trade/public/markets/\(market)/depth",
                                  query: [.init(name: "limit", value: String(limit))])
        do { return try JSONDecoder().decode(STDepth.self, from: data) }
        catch { throw SafeTradeError.decode(error.localizedDescription) }
    }

    /// Newest first. `state: "wait"` lists every resting order (the plain list is
    /// capped, so older open orders would otherwise drop out of reach of 撤单).
    /// Rows are decoded one by one; a body that isn't a list at all throws, so a
    /// failed read is never mistaken for "no orders".
    func orders(market: String, state: String? = nil, limit: Int = 20) async throws -> [STOrder] {
        let market = SafeTradeMarket.normalized(market)
        var query: [URLQueryItem] = [.init(name: "market", value: market), .init(name: "limit", value: String(limit)),
                                     .init(name: "ordering", value: "desc")]
        if let state { query.append(.init(name: "state", value: state)) }
        let data = try await send("/api/v2/trade/market/orders", query: query, auth: .stored(.trading))
        guard let rows = decodeRows(STOrder.self, from: data) else {
            throw SafeTradeError.decode(String(String(data: data, encoding: .utf8)?.prefix(120) ?? ""))
        }
        return rows
    }

    /// Public currency info — networks with fee / minimum / whether withdrawals are open.
    func currency(_ id: String) async throws -> STCurrency {
        let data = try await send("/api/v2/trade/public/currencies/\(id)")
        do { return try JSONDecoder().decode(STCurrency.self, from: data) }
        catch { throw SafeTradeError.decode(error.localizedDescription) }
    }

    /// Newest first (explicit: the API's default order isn't documented, and the
    /// unverified-withdrawal check looks for the latest row). Reads sign with the
    /// trading key — it works from any network, unlike an IP-bound withdraw key.
    func withdraws(currency: String, limit: Int = 10) async throws -> [STWithdraw] {
        let data = try await send("/api/v2/trade/account/withdraws",
                                  query: [.init(name: "currency", value: currency),
                                          .init(name: "limit", value: String(limit)),
                                          .init(name: "ordering", value: "desc")],
                                  auth: .stored(.trading))
        guard let rows = decodeRows(STWithdraw.self, from: data) else {
            throw SafeTradeError.decode(String(String(data: data, encoding: .utf8)?.prefix(120) ?? ""))
        }
        return rows
    }

    /// The user's SafeTrade address book, all currencies.
    /// Accepts a bare array or a `{"data": [...]}` envelope; throws (with a peek at
    /// the body) when the response has rows we can't read, so the UI can say why
    /// the address book looks empty instead of silently showing nothing.
    func beneficiaries() async throws -> [STBeneficiary] {
        let data = try await send("/api/v2/trade/account/beneficiaries",
                                  query: [.init(name: "limit", value: "100")], auth: .stored(.trading))
        let json = try? JSONSerialization.jsonObject(with: data)
        guard let rows = (json as? [Any]) ?? ((json as? [String: Any])?["data"] as? [Any]) else {
            throw SafeTradeError.decode(String(String(data: data, encoding: .utf8)?.prefix(160) ?? ""))
        }
        let parsed = rows.compactMap { row in
            (try? JSONSerialization.data(withJSONObject: row))
                .flatMap { try? JSONDecoder().decode(STBeneficiary.self, from: $0) }
        }
        if parsed.isEmpty, let first = rows.first,
           let peek = (try? JSONSerialization.data(withJSONObject: first)).flatMap({ String(data: $0, encoding: .utf8) }) {
            throw SafeTradeError.decode(String(peek.prefix(160)))
        }
        return parsed
    }

    /// Ask SafeTrade to e-mail (or SMS) the one-time withdrawal code. Same body as
    /// the web client: the code is bound to this address + amount.
    func sendWithdrawCode(type: String, address: String, amount: Decimal,
                          blockchainKey: String, currency: String) async throws {
        _ = try await send("/api/v2/trade/account/withdraws/generate_code", method: "POST",
                           json: ["type": type, "address": address, "currency": currency,
                                  "amount": NSDecimalNumber(decimal: amount), "blockchain_key": blockchainKey],
                           auth: .stored(.withdraw))
    }

    /// Create an on-chain withdrawal (`POST /trade/account/withdraws`, the body the
    /// SafeTrade web client sends). Empty codes are left out: which ones the
    /// exchange demands depends on the account (e-mail always, 2FA / SMS if enabled).
    /// With `beneficiaryID` the destination is a SafeTrade address-book entry and
    /// replaces address + chain; the web client then asks for no e-mail code.
    /// Signs with the withdraw-only key when one is set.
    func createWithdraw(address: String, amount: Decimal, blockchainKey: String, beneficiaryID: Int?,
                        emailCode: String, otpCode: String, phoneCode: String,
                        currency: String) async throws {
        // Per SafeTrade's swagger (account.CreateWithdrawParams): blockchain_key is
        // always required; address and email_code only without beneficiary_id.
        var body: [String: Any] = ["currency": currency, "amount": NSDecimalNumber(decimal: amount),
                                   "blockchain_key": blockchainKey]
        if let beneficiaryID {
            body["beneficiary_id"] = beneficiaryID
        } else {
            body["address"] = address
        }
        if !emailCode.isEmpty { body["email_code"] = emailCode }
        if !otpCode.isEmpty { body["otp_code"] = otpCode }
        if !phoneCode.isEmpty { body["phone_code"] = phoneCode }
        do {
            _ = try await send("/api/v2/trade/account/withdraws", method: "POST", json: body, auth: .stored(.withdraw))
        } catch let e as URLError where Self.isAmbiguousPostFailure(e) {
            throw SafeTradeError.withdrawUnverified   // may have gone through — never invite a blind retry
        } catch SafeTradeError.http(let code, _) where Self.isAmbiguousPostStatus(code) {
            throw SafeTradeError.withdrawUnverified
        }
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
                                          .init(name: "limit", value: String(limit))])
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
            data = try await send("/api/v2/trade/market/orders", method: "POST", form: form, auth: .stored(.trading))
        } catch let e as URLError where Self.isAmbiguousPostFailure(e) {
            // The POST body may have reached the exchange and BOOKED the order before
            // the response was lost (timeout / connection dropped / TLS mid-flight).
            // Reporting a hard failure here would invite a duplicate re-tap, so signal
            // "placed but unverified" and let the store reconcile against the order list.
            // Pre-send failures (offline/DNS/can't-connect) are NOT reclassified — they
            // never reached the server, so they stay a clean, safe-to-retry failure.
            throw SafeTradeError.placedUnverified
        } catch SafeTradeError.http(let code, _) where Self.isAmbiguousPostStatus(code) {
            throw SafeTradeError.placedUnverified   // a 5xx can come back after the engine booked it
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
    /// `.badServerResponse` is NOT in the safe list: it means a reply came back
    /// malformed — i.e. the request was sent (the local proxy has mangled replies before).
    static func isAmbiguousPostFailure(_ e: URLError) -> Bool {
        switch e.code {
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .badURL, .unsupportedURL:
            return false   // never reached the exchange → re-tap can't double-book
        default:
            return true    // timed out / connection lost / TLS after send / bad reply → may be booked
        }
    }

    /// A non-2xx reply to an order / withdrawal POST that doesn't prove it was refused:
    /// a 5xx (Cloudflare's 502 / 504 included) can arrive after the engine acted on it.
    /// 4xx are the exchange's own refusals and stay clean failures.
    static func isAmbiguousPostStatus(_ code: Int) -> Bool { code == 0 || code >= 500 }

    /// Cancel a single resting order by id (`POST /trade/market/orders/{id}/cancel`,
    /// the only cancel route in the swagger). A 2xx means the cancel was ACCEPTED;
    /// the order flips to `cancel` once the engine removes it, which the caller
    /// reconciles by re-fetching the list.
    func cancelOrder(id: Int) async throws {
        _ = try await send("/api/v2/trade/market/orders/\(id)/cancel", method: "POST", auth: .stored(.trading))
    }
}
