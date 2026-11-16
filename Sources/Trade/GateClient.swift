import Foundation
import CryptoKit

// Gate (gate.com / api.gateio.ws) — REST API v4.
// Pair: PEARL_USDT (NEVER PRL_USDT, which is an unrelated token on Gate).
// Signing:
//   KEY: <apiKey>
//   Timestamp: <unix_seconds>
//   SIGN: hex( HMAC_SHA512(secret, "\(METHOD)\n\(path)\n\(query)\n\(sha512Hex(body))\n\(timestamp)") )

actor GateTimestampGenerator {
    private var offsetSeconds = 0
    private let clock: @Sendable () -> Date

    init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    private let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    func next() -> String {
        let now = Int(clock().timeIntervalSince1970.rounded(.down)) + offsetSeconds
        return String(now)
    }

    func observe(serverDate header: String) {
        guard let server = httpDate.date(from: header) else { return }
        offsetSeconds = Self.offset(server: server, local: clock())
    }

    nonisolated static func offset(server: Date, local: Date) -> Int {
        let skew = Int((server.timeIntervalSince(local) + 0.5).rounded(.down))
        return abs(skew) >= 2 ? skew : 0
    }
}

struct GateClient {
    static let pair = "PEARL_USDT"
    let root = "https://api.gateio.ws"
    private static let timestampGenerator = GateTimestampGenerator()

    enum Auth {
        case none
        case stored
        case explicit(key: String, secret: String)
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    // MARK: - Signing

    static func sha512Hex(_ data: Data) -> String {
        SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func signature(method: String, path: String, query: String, body: Data,
                          timestamp: String, apiSecret: String) -> String {
        let payload = "\(method.uppercased())\n\(path)\n\(query)\n\(sha512Hex(body))\n\(timestamp)"
        let key = SymmetricKey(data: Data(apiSecret.utf8))
        let mac = HMAC<SHA512>.authenticationCode(for: Data(payload.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private func signedHeaders(method: String, path: String, query: String, body: Data,
                               apiKey: String, apiSecret: String) async -> [String: String] {
        let ts = await Self.timestampGenerator.next()
        let sign = Self.signature(method: method, path: path, query: query, body: body,
                                  timestamp: ts, apiSecret: apiSecret)
        return ["KEY": apiKey, "Timestamp": ts, "SIGN": sign]
    }

    // MARK: - Error classification

    static func errorPayload(_ body: String) -> (label: String?, message: String?) {
        guard let d = body.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (nil, nil) }
        let label = (o["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let msg = ((o["message"] as? String) ?? (o["detail"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label?.isEmpty == true ? nil : label, msg?.isEmpty == true ? nil : msg)
    }

    static func isExpiredTimestamp(body: String) -> Bool {
        guard let label = errorPayload(body).label?.uppercased() else { return false }
        return label == "REQUEST_EXPIRED" || label == "INVALID_TIMESTAMP"
    }

    static func isAddressNotWhitelisted(body: String) -> Bool {
        let (rawLabel, rawMsg) = errorPayload(body)
        let label = rawLabel?.uppercased() ?? ""
        let lowerMsg = (rawMsg ?? "").lowercased()
        if (label.contains("ADDRESS") && label.contains("WHITELIST")) || label == "NOT_IN_WHITELIST" {
            return true
        }
        return lowerMsg.contains("address") && lowerMsg.contains("whitelist") && !lowerMsg.contains("ip")
    }

    static func authProblem(status: Int, body: String) -> SafeTradeAuthProblem? {
        guard status == 401 || status == 403 else { return nil }
        if isAddressNotWhitelisted(body: body) { return nil }
        let (rawLabel, rawMsg) = errorPayload(body)
        let label = rawLabel?.uppercased() ?? ""
        let lowerMsg = (rawMsg ?? "").lowercased()
        if label.isEmpty, body.range(of: "<html", options: .caseInsensitive) != nil {
            return .firewall
        }
        if label == "INVALID_IP"
            || (lowerMsg.contains("ip") && (lowerMsg.contains("whitelist") || lowerMsg.contains("trusted") || lowerMsg.contains("not allowed") || lowerMsg.contains("forbidden"))) {
            return .untrustedIP
        }
        if label == "REQUEST_EXPIRED" || label == "INVALID_TIMESTAMP" {
            return .clock
        }
        if ["INVALID_KEY", "INVALID_SIGNATURE", "INVALID_CREDENTIALS", "KEY_EXPIRED"].contains(label) {
            return .badKey
        }
        if !label.isEmpty {
            return .other([label])
        }
        return .other([])
    }

    static func errorMessage(status: Int, body: String) -> String {
        if isAddressNotWhitelisted(body: body) {
            return Loc("收款地址不在 Gate 提币白名单中。请先到 Gate 网站将该地址加入白名单并完成验证。")
        }
        if let auth = authProblem(status: status, body: body) {
            switch auth {
            case .untrustedIP:
                return Loc("Gate 拒绝了当前网络：这个 API 密钥绑定了 IP 白名单，而你现在的 IP 不在名单里。")
            case .badKey:
                return Loc("Gate 不认这个 API 密钥：Key 或 Secret 不对，或者密钥已停用。")
            case .clock:
                return Loc("签名已过期：本机时间和 Gate 相差太多，请打开「自动设置时间」后重试。")
            case .firewall:
                return Loc("请求被 Gate 的防火墙拦截，通常是当前网络或代理的出口被拦，换个网络再试。")
            case .other(let keys):
                let detail = errorPayload(body).message ?? (keys.isEmpty ? "401/403" : keys.joined(separator: ", "))
                return Loc("Gate 拒绝了这个请求（%@）", detail)
            }
        }
        let (rawLabel, rawMsg) = errorPayload(body)
        let label = rawLabel?.uppercased() ?? ""
        switch label {
        case "BALANCE_NOT_ENOUGH", "INSUFFICIENT_BALANCE":
            return Loc("Gate 可用余额不足")
        case "AMOUNT_TOO_LITTLE":
            return Loc("数量低于交易所的最小下单量")
        case "AMOUNT_TOO_MUCH":
            return Loc("超出今日提现额度")
        case "INVALID_PRECISION":
            return Loc("数量的小数位太多")
        case "INVALID_CURRENCY", "WITHDRAWAL_DISABLED":
            return Loc("Gate 暂停了这条链的提现")
        case "INVALID_ADDRESS":
            return Loc("收款地址无效")
        case "IOC_NOT_FILLED":
            return Loc("盘口深度不够，市价单成交不了这么多，请减少数量或改用限价单")
        default:
            if let msg = rawMsg, !msg.isEmpty {
                return "Gate: \(msg)"
            }
            return "HTTP \(status): \(body.prefix(120))"
        }
    }

    // MARK: - Transport

    private func send(_ path: String, method: String = "GET",
                      query: [URLQueryItem] = [], json: [String: Any]? = nil,
                      auth: Auth = .none) async throws -> Data {
        let credentials: (key: String, secret: String)?
        switch auth {
        case .none:
            credentials = nil
        case .stored:
            guard AppFeatures.tradeAccount, let c = GateSecrets.credentials else {
                throw SafeTradeError.gateNoCredentials
            }
            credentials = c
        case .explicit(let key, let secret):
            guard AppFeatures.tradeAccount else { throw SafeTradeError.gateNoCredentials }
            credentials = (key, secret)
        }

        guard var comps = URLComponents(string: root + path) else { throw SafeTradeError.gateInvalidURL }
        if !query.isEmpty { comps.queryItems = query }
        let encodedQuery = comps.percentEncodedQuery ?? ""
        guard let url = comps.url else { throw SafeTradeError.gateInvalidURL }

        let bodyData: Data
        if let json {
            bodyData = try JSONSerialization.data(withJSONObject: json)
        } else {
            bodyData = Data()
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if json != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = bodyData
        }

        var resigned = false, redialed = false
        while true {
            if let credentials {
                let headers = await signedHeaders(method: method, path: path, query: encodedQuery,
                                                  body: bodyData, apiKey: credentials.key, apiSecret: credentials.secret)
                headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            }
            let reply: (Data, URLResponse)
            do {
                reply = try await Self.session.data(for: req)
            } catch let error where method == "GET" && !redialed && SafeTradeClient.isDroppedConnection(error) {
                redialed = true
                continue
            }
            let (data, resp) = reply
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if let date = http.value(forHTTPHeaderField: "Date") {
                await Self.timestampGenerator.observe(serverDate: date)
            }
            let code = http.statusCode
            if (200..<300).contains(code) { return data }
            let body = String(data: data, encoding: .utf8) ?? ""
            if credentials != nil, !resigned, Self.isExpiredTimestamp(body: body) {
                resigned = true
                continue
            }
            throw SafeTradeError.gateHTTP(code, Self.authProblem(status: code, body: body),
                                          Self.errorMessage(status: code, body: body))
        }
    }

    // MARK: - Public endpoints

    func publicIP() async throws -> String {
        for traceURL in ["https://www.gate.com/cdn-cgi/trace", "https://pearlhub.net/cdn-cgi/trace"] {
            guard let url = URL(string: traceURL) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            if let (data, resp) = try? await Self.session.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let ip = SafeTradeTrace.ip(in: String(data: data, encoding: .utf8) ?? "") {
                return ip
            }
        }
        return try await SafeTradeClient().publicIP()
    }

    private struct GateTickerRow: Decodable {
        let currency_pair: String?
        let last: String?
        let lowest_ask: String?
        let highest_bid: String?
        let change_percentage: String?
        let base_volume: String?
        let high_24h: String?
        let low_24h: String?
    }

    static func parseTicker(from data: Data) throws -> STTicker {
        let rows = try JSONDecoder().decode([GateTickerRow].self, from: data)
        guard let r = rows.first else { throw SafeTradeError.decode("empty gate ticker") }
        let formattedChange: String? = r.change_percentage.flatMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")
            guard let val = Double(trimmed) else { return nil }
            return String(format: "%+.2f%%", val)
        }
        return STTicker(last: r.last,
                        buy: r.lowest_ask,
                        sell: r.highest_bid,
                        high: r.high_24h,
                        low: r.low_24h,
                        vol: r.base_volume,
                        price_change_percent: formattedChange)
    }

    func ticker() async throws -> STTicker {
        let data = try await send("/api/v4/spot/tickers", query: [.init(name: "currency_pair", value: Self.pair)])
        do { return try Self.parseTicker(from: data) }
        catch { throw SafeTradeError.decode(error.localizedDescription) }
    }

    private struct GatePairInfo: Decodable {
        let amount_precision: Int?
        let precision: Int?
        let min_base_amount: STNumberText?
        let min_quote_amount: STNumberText?
        let fee: STNumberText?
        let up_rate: STNumberText?
        let down_rate: STNumberText?
    }

    static func parseMarketRules(from data: Data) throws -> SafeTradeMarketRules {
        let info = try JSONDecoder().decode(GatePairInfo.self, from: data)
        let fallback = SafeTradeMarketRules.gatePearlUsdt
        let pricePrecision = info.precision ?? fallback.pricePrecision
        let amountPrecision = info.amount_precision ?? fallback.amountPrecision
        let minAmount = info.min_base_amount.flatMap { Decimal(string: $0.text) } ?? fallback.minAmount
        let minQuote = info.min_quote_amount.flatMap { Decimal(string: $0.text) } ?? fallback.minQuote
        let feePct = info.fee.flatMap { Double($0.text) }
        let takerFee = feePct.map { $0 / 100.0 } ?? fallback.takerFee
        let upRate = info.up_rate.flatMap { Decimal(string: $0.text) }.flatMap { $0 > 0 ? $0 : nil } ?? fallback.upRate
        let downRate = info.down_rate.flatMap { Decimal(string: $0.text) }.flatMap { $0 > 0 ? $0 : nil } ?? fallback.downRate
        var minPrice = Decimal(1)
        for _ in 0..<max(0, pricePrecision) { minPrice /= 10 }
        return SafeTradeMarketRules(amountPrecision: amountPrecision,
                                    pricePrecision: pricePrecision,
                                    minAmount: minAmount,
                                    minPrice: minPrice,
                                    maxPrice: fallback.maxPrice,
                                    minQuote: minQuote,
                                    takerFee: takerFee,
                                    upRate: upRate,
                                    downRate: downRate)
    }

    func marketRules() async throws -> SafeTradeMarketRules {
        let data = try await send("/api/v4/spot/currency_pairs/\(Self.pair)")
        do { return try Self.parseMarketRules(from: data) }
        catch { throw SafeTradeError.decode(error.localizedDescription) }
    }

    func depth(limit: Int = 100) async throws -> STDepth {
        let data = try await send("/api/v4/spot/order_book",
                                  query: [.init(name: "currency_pair", value: Self.pair),
                                          .init(name: "limit", value: String(limit))])
        do { return try JSONDecoder().decode(STDepth.self, from: data) }
        catch { throw SafeTradeError.decode(error.localizedDescription) }
    }

    static func interval(for periodMinutes: Int) -> String {
        switch periodMinutes {
        case ..<5: return "1m"
        case ..<15: return "5m"
        case ..<30: return "15m"
        case ..<60: return "30m"
        case ..<240: return "1h"
        case ..<1440: return "4h"
        default: return "1d"
        }
    }

    /// Gate candlesticks format: `[ts_sec, quote_vol_usdt, close, high, low, open, base_vol_pearl, window_closed]`.
    static func parseCandles(from data: Data) -> [STCandle] {
        let rows = (try? JSONSerialization.jsonObject(with: data) as? [[Any]]) ?? []
        func dbl(_ v: Any) -> Double { (v as? NSNumber)?.doubleValue ?? Double("\(v)") ?? 0 }
        return rows.compactMap { r in
            guard r.count >= 7 else { return nil }
            let ts = dbl(r[0])
            guard ts > 0 else { return nil }
            return STCandle(time: Date(timeIntervalSince1970: ts),
                            open: dbl(r[5]),
                            high: dbl(r[3]),
                            low: dbl(r[4]),
                            close: dbl(r[2]),
                            volume: dbl(r[6]))
        }
    }

    func kline(period: Int, limit: Int = 120) async throws -> [STCandle] {
        let data = try await send("/api/v4/spot/candlesticks",
                                  query: [.init(name: "currency_pair", value: Self.pair),
                                          .init(name: "interval", value: Self.interval(for: period)),
                                          .init(name: "limit", value: String(min(max(limit, 1), 999)))])
        return Self.parseCandles(from: data)
    }

    // MARK: - Private Spot Account & Orders

    private struct GateSpotAccount: Decodable {
        let currency: String
        let available: STNumberText
        let locked: STNumberText
    }

    static func parseBalances(from data: Data) throws -> [STBalance] {
        let rows = try JSONDecoder().decode([GateSpotAccount].self, from: data)
        return rows.map {
            STBalance(currency: $0.currency.lowercased(), balance: $0.available.text, locked: $0.locked.text)
        }
    }

    func balances() async throws -> [STBalance] {
        let data = try await send("/api/v4/spot/accounts", auth: .stored)
        do { return try Self.parseBalances(from: data) }
        catch { throw SafeTradeError.decode(error.localizedDescription) }
    }

    func verifyCredentials(apiKey: String, apiSecret: String) async -> SafeTradeCredentialCheck {
        do {
            _ = try await send("/api/v4/spot/accounts", auth: .explicit(key: apiKey, secret: apiSecret))
            return .ok
        } catch SafeTradeError.gateHTTP(let code, let auth, let msg) {
            if let auth { return .rejected(auth) }
            return .serverError(code, msg)
        } catch {
            return .network(error.localizedDescription)
        }
    }

    private struct GateOrderRow: Decodable {
        let id: STLooseText?
        let currency_pair: String?
        let side: String?
        let type: String?
        let time_in_force: String?
        let price: STNumberText?
        let amount: STNumberText?
        let status: String?
        let finish_as: String?
        let filled_amount: STNumberText?
        let filled_total: STNumberText?
        let avg_deal_price: STNumberText?
        let create_time_ms: STTimestamp?
        let create_time: STTimestamp?
        let update_time_ms: STTimestamp?
        let update_time: STTimestamp?
    }

    static func syntheticIntID(_ raw: String) -> Int {
        if let exact = Int(raw) { return exact }
        let digest = SHA256.hash(data: Data(raw.utf8))
        var v: UInt64 = 0
        for b in digest.prefix(7) { v = (v << 8) | UInt64(b) }
        return Int(v & 0x7fff_ffff_ffff_ffff)
    }

    static func parseOrder(_ data: Data) throws -> (order: STOrder, filledAmount: Decimal, finishAs: String?) {
        let row = try JSONDecoder().decode(GateOrderRow.self, from: data)
        return mapOrder(row)
    }

    private static func mapOrder(_ r: GateOrderRow) -> (order: STOrder, filledAmount: Decimal, finishAs: String?) {
        let rawID = r.id?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let intID = rawID.flatMap { $0.isEmpty ? nil : syntheticIntID($0) }
        let tif = (r.time_in_force ?? "").lowercased()
        let rawType = (r.type ?? "limit").lowercased()
        let isIOCMarket = rawType == "limit" && tif == "ioc"
        let mappedType = isIOCMarket ? "market" : rawType
        let filled = r.filled_amount.flatMap { Decimal(string: $0.text) } ?? 0
        let filledTotal = r.filled_total.flatMap { Decimal(string: $0.text) } ?? 0

        let status = (r.status ?? "").lowercased()
        let state: String
        switch status {
        case "open":
            state = "wait"
        case "closed":
            state = "done"
        case "cancelled", "canceled":
            state = filled > 0 ? "done" : "cancel"
        default:
            state = status.isEmpty ? "wait" : status
        }

        let avgPrice: String? = {
            if let avg = r.avg_deal_price?.text, let v = Double(avg), v > 0 { return avg }
            if filled > 0, filledTotal > 0 {
                let d = NSDecimalNumber(decimal: filledTotal).doubleValue / NSDecimalNumber(decimal: filled).doubleValue
                return String(format: "%.4f", d)
            }
            return nil
        }()

        // Native Gate market buy orders store USDT cost in `amount` and PEARL filled in `filled_amount`.
        let originAmount: String? = {
            if rawType == "market", r.side?.lowercased() == "buy", filled > 0 {
                return r.filled_amount?.text
            }
            if isIOCMarket, state == "done", filled > 0 {
                return r.filled_amount?.text ?? r.amount?.text
            }
            return r.amount?.text
        }()

        let order = STOrder(
            id: intID,
            market: r.currency_pair ?? pair,
            side: r.side?.lowercased(),
            type: mappedType,
            price: mappedType == "market" ? nil : r.price?.text,
            state: state,
            origin_amount: originAmount,
            avg_price: avgPrice,
            created_at: r.create_time_ms ?? r.create_time,
            updated_at: r.update_time_ms ?? r.update_time,
            rawID: rawID
        )
        return (order, filled, r.finish_as?.lowercased())
    }

    func orders(status: String, limit: Int = 20) async throws -> [STOrder] {
        let data = try await send("/api/v4/spot/orders",
                                  query: [.init(name: "currency_pair", value: Self.pair),
                                          .init(name: "status", value: status),
                                          .init(name: "limit", value: String(limit))],
                                  auth: .stored)
        guard let rows = decodeRows(GateOrderRow.self, from: data) else {
            throw SafeTradeError.decode(String(String(data: data, encoding: .utf8)?.prefix(120) ?? ""))
        }
        return rows.map { Self.mapOrder($0).order }
    }

    /// Limit orders use GTC; market orders use Limit + IOC capped at `maxPrice` so `amount` is
    /// always denominated in PEARL (base) and the user's slippage ceiling/floor is enforced server-side.
    static func orderBody(side: String, amount: String, price: String?, maxPrice: String?, type: String) throws -> [String: String] {
        if type == "market" {
            guard let cap = maxPrice, !cap.isEmpty else {
                throw SafeTradeError.gateHTTP(400, nil, Loc("等待盘口数据后才能下市价单"))
            }
            return [
                "currency_pair": pair,
                "side": side,
                "type": "limit",
                "time_in_force": "ioc",
                "amount": amount,
                "price": cap,
            ]
        }
        return [
            "currency_pair": pair,
            "side": side,
            "type": "limit",
            "time_in_force": "gtc",
            "amount": amount,
            "price": price ?? "",
        ]
    }

    func placeOrder(side: String, amount: String, price: String?, maxPrice: String? = nil, type: String) async throws -> STOrder {
        let body = try Self.orderBody(side: side, amount: amount, price: price, maxPrice: maxPrice, type: type)
        let data: Data
        do {
            data = try await send("/api/v4/spot/orders", method: "POST", json: body, auth: .stored)
        } catch let e as URLError where SafeTradeClient.isAmbiguousPostFailure(e) {
            throw SafeTradeError.placedUnverified
        } catch SafeTradeError.gateHTTP(let code, _, _) where SafeTradeClient.isAmbiguousPostStatus(code) {
            throw SafeTradeError.placedUnverified
        }
        let parsed: (order: STOrder, filledAmount: Decimal, finishAs: String?)
        do { parsed = try Self.parseOrder(data) }
        catch { throw SafeTradeError.placedUnverified }

        if type == "market", parsed.order.state == "cancel", parsed.filledAmount <= 0 {
            throw SafeTradeError.gateHTTP(422, nil, Loc("盘口深度不够，市价单成交不了这么多，请减少数量或改用限价单"))
        }
        return parsed.order
    }

    func cancelOrder(_ order: STOrder) async throws {
        guard let key = order.cancelKey, !key.isEmpty else { return }
        _ = try await send("/api/v4/spot/orders/\(key)",
                           method: "DELETE",
                           query: [.init(name: "currency_pair", value: Self.pair)],
                           auth: .stored)
    }

    // MARK: - Wallet (Chains, Deposits, Withdrawals, Saved Addresses)

    private struct GateChainRow: Decodable {
        let chain: String
        let name_cn: String?
        let name_en: String?
        let is_disabled: Int?
        let is_deposit_disabled: Int?
        let is_withdraw_disabled: Int?
        let decimal: STLooseText?
        let is_tag: Int?
        let withdraw_amount_min: STNumberText?
    }

    private struct GateWithdrawStatusRow: Decodable {
        let currency: String?
        let withdraw_fix: STNumberText?
        let withdraw_percent: String?
        let withdraw_amount_mini: STNumberText?
        let withdraw_fix_on_chains: [String: STLooseText]?
        let withdraw_percent_on_chains: [String: STLooseText]?
    }

    private static func explorerTemplate(for chain: String) -> String? {
        switch chain.uppercased() {
        case "PEARL", "PRL": return "https://blockbook.pearlresearch.ai/tx/#{txid}"
        case "ETH": return "https://etherscan.io/tx/#{txid}"
        case "BSC": return "https://bscscan.com/tx/#{txid}"
        case "OPBNB": return "https://opbnbscan.com/tx/#{txid}"
        case "TRX": return "https://tronscan.org/#/transaction/#{txid}"
        case "SOL": return "https://solscan.io/tx/#{txid}"
        case "ARBEVM": return "https://arbiscan.io/tx/#{txid}"
        case "OPETH": return "https://optimistic.etherscan.io/tx/#{txid}"
        case "MATIC": return "https://polygonscan.com/tx/#{txid}"
        case "AVAX_C": return "https://snowtrace.io/tx/#{txid}"
        case "CELO": return "https://celoscan.io/tx/#{txid}"
        case "KAIA": return "https://kaiascan.io/tx/#{txid}"
        case "KAVAEVM": return "https://kavascan.com/tx/#{txid}"
        case "NEAR": return "https://nearblocks.io/txns/#{txid}"
        case "TON", "GRAM": return "https://tonviewer.com/transaction/#{txid}"
        default: return nil
        }
    }

    private static func parsePercentRatio(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "%", with: "")
        guard let d = Decimal(string: cleaned), d > 0 else { return "0" }
        return SafeTradeMarketRules.plain(d / 100)
    }

    private static func mergedMinWithdraw(chainMin: String?, coinMin: String?) -> String? {
        switch (chainMin, coinMin) {
        case let (a?, b?):
            if let da = Decimal(string: a), let db = Decimal(string: b) {
                return da >= db ? a : b
            }
            return a
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    static func parseCurrency(chainsData: Data, statusData: Data?, useChinese: Bool, currency: String) throws -> STCurrency {
        let ccy = currency.uppercased()
        let chains: [GateChainRow]
        do { chains = try JSONDecoder().decode([GateChainRow].self, from: chainsData) }
        catch { throw SafeTradeError.decode(error.localizedDescription) }

        let statusRow = statusData.flatMap { try? JSONDecoder().decode([GateWithdrawStatusRow].self, from: $0) }?.first
        var seenPrecision = 0

        let networks: [STCurrencyNetwork] = chains.map { ch in
            let active = (ch.is_disabled ?? 0) == 0
            let chainDec = ch.decimal.flatMap { Int($0.text) }.flatMap { $0 > 0 ? min(max($0, 2), 8) : nil }
            if active, let chainDec {
                seenPrecision = max(seenPrecision, chainDec)
            }
            let canDep = active && (ch.is_deposit_disabled ?? 0) == 0
            let canWdr = active && (ch.is_withdraw_disabled ?? 0) == 0
            let label = (useChinese ? ch.name_cn : ch.name_en).flatMap { $0.isEmpty ? nil : $0 }
                ?? ch.name_en ?? ch.chain
            let fix = statusRow?.withdraw_fix_on_chains?[ch.chain]?.text ?? statusRow?.withdraw_fix?.text
            let pctRaw = statusRow?.withdraw_percent_on_chains?[ch.chain]?.text ?? statusRow?.withdraw_percent
            let minWdr = mergedMinWithdraw(chainMin: ch.withdraw_amount_min?.text,
                                           coinMin: statusRow?.withdraw_amount_mini?.text)
            var opts: [String: STLooseText] = [:]
            if (ch.is_tag ?? 0) == 1 { opts["requires_memo"] = STLooseText("true") }
            if let chainDec { opts["precision"] = STLooseText(String(chainDec)) }
            return STCurrencyNetwork(
                blockchain_key: ch.chain,
                protocol: ch.chain,
                protocol_name: label,
                withdraw_enabled: canWdr,
                withdraw_fee: fix,
                withdraw_fee_ratio: Self.parsePercentRatio(pctRaw),
                min_withdraw_amount: minWdr,
                deposit_enabled: canDep,
                min_deposit_amount: nil,
                min_confirmations: nil,
                deposit_fee: "0",
                status: active ? "active" : "disabled",
                explorer_transaction: Self.explorerTemplate(for: ch.chain),
                system_options: nil,
                options: opts.isEmpty ? nil : opts
            )
        }
        let maxPrecision = seenPrecision > 0 ? seenPrecision : (ccy == "PEARL" ? 8 : 6)
        return STCurrency(precision: maxPrecision, networks: networks)
    }

    func currency(_ id: String) async throws -> STCurrency {
        let ccy = id.uppercased()
        async let chainsData = send("/api/v4/wallet/currency_chains", query: [.init(name: "currency", value: ccy)])
        async let statusData: Data? = GateSecrets.hasCredentials
            ? (try? await send("/api/v4/wallet/withdraw_status", query: [.init(name: "currency", value: ccy)], auth: .stored))
            : nil
        let cData = try await chainsData
        let sData = await statusData
        let useChinese = LocBundleHolder.shared.locale.identifier.lowercased().hasPrefix("zh")
        return try Self.parseCurrency(chainsData: cData, statusData: sData, useChinese: useChinese, currency: ccy)
    }

    private struct GateDepositAddrEnvelope: Decodable {
        let currency: String?
        let address: String?
        let multichain_addresses: [MultiChain]?
        struct MultiChain: Decodable {
            let chain: String?
            let address: String?
            let payment_id: String?
            let obtain_failed: Int?
        }
    }

    static func parseDepositAddress(from data: Data, currency: String, network: String) throws -> STDepositAddress {
        let env = try JSONDecoder().decode(GateDepositAddrEnvelope.self, from: data)
        if let multi = env.multichain_addresses, !multi.isEmpty {
            if let hit = multi.first(where: { ($0.chain ?? "").caseInsensitiveCompare(network) == .orderedSame }) {
                let rawAddr = (hit.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if (hit.obtain_failed ?? 0) != 0 || rawAddr.isEmpty || rawAddr.contains(where: \.isWhitespace) {
                    return STDepositAddress(address: nil, network: network, currencies: [currency], parent_address: nil)
                }
                let memo = (hit.payment_id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let packed = memo.isEmpty ? rawAddr : "\(rawAddr)?memo=\(memo)"
                return STDepositAddress(address: packed, network: network, currencies: [currency], parent_address: nil)
            }
            return STDepositAddress(address: nil, network: network, currencies: [currency], parent_address: nil)
        }
        let fallback = (env.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFallback = (fallback.isEmpty || fallback.contains(where: \.isWhitespace)) ? nil : fallback
        return STDepositAddress(address: cleanFallback, network: network, currencies: [currency], parent_address: nil)
    }

    func depositAddress(currency: String, network: String) async throws -> STDepositAddress {
        let data = try await send("/api/v4/wallet/deposit_address",
                                  query: [.init(name: "currency", value: currency.uppercased())],
                                  auth: .stored)
        do { return try Self.parseDepositAddress(from: data, currency: currency, network: network) }
        catch { throw SafeTradeError.decode(error.localizedDescription) }
    }

    private struct GateLedgerRow: Decodable {
        let id: STLooseText?
        let timestamp: STTimestamp?
        let currency: String?
        let address: String?
        let txid: String?
        let amount: STNumberText?
        let fee: STNumberText?
        let status: String?
        let chain: String?
    }

    private static func mapLedgerState(_ raw: String?) -> String {
        switch (raw ?? "").uppercased() {
        case "DONE": return "done"
        case "CANCEL", "CANCELED", "CANCELLED": return "cancelled"
        case "FAIL", "FAILED", "INVALID", "REJECT", "REJECTED": return "failed"
        default: return "processing"
        }
    }

    func deposits(currency: String, limit: Int = 10) async throws -> [STDeposit] {
        let data = try await send("/api/v4/wallet/deposits",
                                  query: [.init(name: "currency", value: currency.uppercased()),
                                          .init(name: "limit", value: String(limit))],
                                  auth: .stored)
        guard let rows = decodeRows(GateLedgerRow.self, from: data) else {
            throw SafeTradeError.decode(String(String(data: data, encoding: .utf8)?.prefix(120) ?? ""))
        }
        return rows.enumerated().map { idx, r in
            let rawID = r.id?.text ?? "\(idx)"
            return STDeposit(
                id: Self.syntheticIntID(rawID),
                currency: (r.currency ?? currency).lowercased(),
                blockchainKey: r.chain,
                amount: r.amount?.text,
                fee: r.fee?.text,
                txid: r.txid,
                address: r.address,
                state: Self.mapLedgerState(r.status),
                createdAt: r.timestamp?.date
            )
        }.sorted { ($0.created_at?.date ?? .distantPast) > ($1.created_at?.date ?? .distantPast) }
    }

    func withdraws(currency: String, limit: Int = 10) async throws -> [STWithdraw] {
        let data = try await send("/api/v4/wallet/withdrawals",
                                  query: [.init(name: "currency", value: currency.uppercased()),
                                          .init(name: "limit", value: String(limit))],
                                  auth: .stored)
        guard let rows = decodeRows(GateLedgerRow.self, from: data) else {
            throw SafeTradeError.decode(String(String(data: data, encoding: .utf8)?.prefix(120) ?? ""))
        }
        return rows.enumerated().map { idx, r in
            let rawID = r.id?.text ?? "\(idx)"
            return STWithdraw(
                id: Self.syntheticIntID(rawID),
                amount: r.amount?.text,
                fee: r.fee?.text,
                address: r.address,
                txid: r.txid,
                status: Self.mapLedgerState(r.status),
                blockchainKey: r.chain,
                createdAt: r.timestamp?.date
            )
        }.sorted { ($0.created_at?.date ?? .distantPast) > ($1.created_at?.date ?? .distantPast) }
    }

    private struct GateSavedAddressRow: Decodable {
        let currency: String?
        let chain: String?
        let address: String?
        let name: String?
        let tag: String?
        let verified: STLooseText?
    }

    /// Gate returns `"currency": "Universal address"` for universal whitelist entries;
    /// keeping `currency` nil lets `WithdrawStore` match them to any coin supporting `chain`.
    private static func normalizedSavedCurrency(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower.contains("universal") || lower.contains("通用") { return nil }
        return lower
    }

    static func parseSavedAddresses(from data: Data) throws -> [STBeneficiary] {
        guard let rows = try? JSONDecoder().decode([GateSavedAddressRow].self, from: data) else {
            // Fall back to row-by-row tolerant decoding in case one row has an unexpected shape.
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                throw SafeTradeError.decode(String(String(data: data, encoding: .utf8)?.prefix(120) ?? ""))
            }
            let dec = JSONDecoder()
            let validRows = arr.compactMap { elem -> GateSavedAddressRow? in
                guard JSONSerialization.isValidJSONObject(elem),
                      let d = try? JSONSerialization.data(withJSONObject: elem) else { return nil }
                return try? dec.decode(GateSavedAddressRow.self, from: d)
            }
            return mapSavedAddresses(validRows)
        }
        return mapSavedAddresses(rows)
    }

    private static func mapSavedAddresses(_ rows: [GateSavedAddressRow]) -> [STBeneficiary] {
        rows.enumerated().compactMap { idx, r in
            guard let addr = r.address?.trimmingCharacters(in: .whitespacesAndNewlines), !addr.isEmpty else {
                return nil
            }
            let key = "\(r.chain ?? "")|\(addr)|\(idx)"
            let verified = r.verified?.text == "1" || r.verified?.text.lowercased() == "true"
            let cleanMemo = r.tag?.trimmingCharacters(in: .whitespacesAndNewlines)
            return STBeneficiary(
                id: Self.syntheticIntID(key),
                name: r.name,
                currency: Self.normalizedSavedCurrency(r.currency),
                blockchainKey: r.chain,
                address: addr,
                active: verified,
                memo: (cleanMemo?.isEmpty == false) ? cleanMemo : nil
            )
        }
    }

    func beneficiaries(currency: String) async throws -> [STBeneficiary] {
        let data = try await send("/api/v4/wallet/saved_address",
                                  query: [.init(name: "currency", value: currency.uppercased())],
                                  auth: .stored)
        return try Self.parseSavedAddresses(from: data)
    }

    func createWithdraw(address: String, amount: Decimal, blockchainKey: String,
                        memo: String = "", currency: String) async throws {
        var body: [String: Any] = [
            "currency": currency.uppercased(),
            "address": address,
            "amount": SafeTradeMarketRules.plain(amount),
            "chain": blockchainKey,
        ]
        let trimmedMemo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMemo.isEmpty { body["memo"] = trimmedMemo }
        do {
            _ = try await send("/api/v4/withdrawals", method: "POST", json: body, auth: .stored)
        } catch let e as URLError where SafeTradeClient.isAmbiguousPostFailure(e) {
            throw SafeTradeError.withdrawUnverified
        } catch SafeTradeError.gateHTTP(let code, _, _) where SafeTradeClient.isAmbiguousPostStatus(code) {
            throw SafeTradeError.withdrawUnverified
        }
    }
}
