import SwiftUI
import Combine

/// SafeTrade top-up (充值) of PRL or USDT, by the routes SafeTrade's web client uses:
///   GET /trade/public/currencies/{id}                         → chains (deposit_enabled,
///       min_deposit_amount, min_confirmations, deposit_fee, explorer templates)
///   GET /trade/account/deposit_address/{id}?network={chain}   → {address ("addr?memo=…"),
///       network, currencies}; empty address = still being generated
///   GET /trade/account/deposits?currency={id}                 → recent deposits
/// The balances response already lists addresses SafeTrade has made before
/// (`deposit_addresses`), so those show without another request.
@MainActor
final class DepositStore: ObservableObject {
    let currency: String                     // "pearl" | "usdt"
    private let trade: SafeTradeStore
    /// The chains open for deposits.
    @Published var networks: [STCurrencyNetwork] = []
    /// The chosen chain. PRL has one and it is picked automatically; USDT has several
    /// and the user must pick — coins sent on another chain may be lost.
    @Published private(set) var networkKey: String?
    var network: STCurrencyNetwork? { networks.first { $0.blockchain_key == networkKey } }
    @Published private(set) var address: STDepositAddress?
    @Published private(set) var loadingInfo = false
    @Published private(set) var loadingAddress = false
    /// SafeTrade answered with an empty address: it's being generated.
    @Published private(set) var generating = false
    @Published private(set) var loadError: String?
    @Published private(set) var addressError: String?
    @Published private(set) var history: [STDeposit] = []
    /// The key was refused for this network's IP — see UntrustedIPCard.
    @Published private(set) var ipIssue: SafeTradeIPIssue?

    private let client = SafeTradeClient()
    private let gateClient = GateClient()
    var exchange: TradeExchange { trade.exchange }
    private var unit: String { currency.uppercased() }

    init(currency: String, trade: SafeTradeStore) {
        self.currency = currency
        self.trade = trade
    }

    func reloadForExchangeChange() async {
        networks = []
        networkKey = nil
        address = nil
        loadError = nil
        addressError = nil
        history = []
        ipIssue = nil
        await load()
    }

    func load() async {
        let ex = exchange
        loadingInfo = true
        async let info = ex == .gate ? gateClient.currency(currency) : client.currency(currency)
        async let recent: Void = loadHistory()
        do {
            let open = try await info.networks.filter { $0.canDeposit }
            guard exchange == ex else { return }
            networks = open
            loadError = open.isEmpty
                ? (ex == .gate ? Loc("Gate 暂时没有开放 %@ 的充值网络", unit) : Loc("SafeTrade 暂时没有开放 %@ 的充值网络", unit))
                : nil
            if let key = networkKey, !open.contains(where: { $0.blockchain_key == key }) { networkKey = nil }
            if networkKey == nil, open.count == 1 { networkKey = open[0].blockchain_key }
        } catch {
            guard exchange == ex else { return }
            loadError = ex == .gate
                ? Loc("读取 Gate 充值信息失败：%@", error.localizedDescription)
                : Loc("读取 SafeTrade 充值信息失败：%@", error.localizedDescription)
        }
        loadingInfo = false
        if networkKey != nil { await loadAddress() }
        await recent
    }

    func select(_ key: String) {
        guard key != networkKey else { return }
        networkKey = key
        address = nil
        addressError = nil
        Task { await loadAddress() }
    }

    /// The deposit address on the chosen chain. SafeTrade & Gate generate it on first ask and
    /// answer with an empty address meanwhile, so ask again a few times.
    func loadAddress() async {
        guard let key = networkKey else { return }
        let ex = exchange
        addressError = nil
        #if DEBUG
        if SafeTradeStore.shotDemo { address = Self.demoAddress(network: key); return }
        #endif
        if ex == .safetrade,
           let known = trade.balance(currency)?.deposit_addresses
            .flatMap({ STDepositAddress.pick($0, currency: currency, network: key) }) {
            address = known
            return
        }
        loadingAddress = true
        defer { loadingAddress = false; generating = false }
        for attempt in 0..<6 {
            do {
                let a = try await (ex == .gate
                    ? gateClient.depositAddress(currency: currency, network: key)
                    : client.depositAddress(currency: currency, network: key))
                guard exchange == ex, networkKey == key else { return }          // switched chain/exchange meanwhile
                if a.isReady { address = a; ipIssue = nil; return }
                generating = true
            } catch {
                guard exchange == ex, networkKey == key else { return }
                await present(error)
                return
            }
            if attempt < 5 { try? await Task.sleep(for: .seconds(3)) }
            if Task.isCancelled || exchange != ex { return }
        }
        addressError = ex == .gate
            ? Loc("Gate 还在生成充值地址，请稍后下拉刷新。")
            : Loc("SafeTrade 还在生成充值地址，请稍后下拉刷新。")
    }

    /// Recent deposits — an optional extra: a failed read keeps what was shown.
    private func loadHistory() async {
        #if DEBUG
        if SafeTradeStore.shotDemo { history = Self.demoHistory(currency: currency); return }
        #endif
        let ex = exchange
        if let rows = try? await (ex == .gate ? gateClient.deposits(currency: currency) : client.deposits(currency: currency)),
           exchange == ex {
            history = rows
        }
    }

    private func present(_ error: Error) async {
        let ex = exchange
        if (error as? SafeTradeError)?.authProblem == .untrustedIP {
            addressError = nil
            ipIssue = SafeTradeIPIssue(ip: nil)
            if let ip = try? await (ex == .gate ? gateClient.publicIP() : client.publicIP()), exchange == ex {
                ipIssue = SafeTradeIPIssue(ip: ip)
            }
            return
        }
        if ex == .gate, case .other = (error as? SafeTradeError)?.authProblem {
            addressError = Loc("Gate 拒绝了读取充值地址的请求：请到 Gate「API 管理」为这把密钥开启「钱包 → 只读」权限。")
            return
        }
        addressError = error.localizedDescription
    }

    // MARK: demo (screenshots, DEBUG only)

    #if DEBUG
    private static func demoAddress(network key: String) -> STDepositAddress {
        let addr: String
        if key.hasPrefix("pearl") { addr = "prl1pq8x3v5kz2m7w9r4t6y0u3e5a8s2d4f6g8h0j2k4l6n8p0r2t4v6x8z0c3e5g" }
        else if key.hasPrefix("tron") { addr = "TQ7m2Vh4nX8pK3rZ5tW9yB6cD1fG3jL5nP" }
        else if key.hasPrefix("spl") || key.hasPrefix("sol") { addr = "7Yp3Kc2mZq9RwX4tV6nB8dF1hJ3kL5pS7uW9yA2cE4gH" }
        else { addr = "0x6b1f2c9d8e4a7f3b0c5d2e9a8b7c6d5e4f3a2b1c" }
        return STDepositAddress(address: addr, network: key, currencies: nil, parent_address: nil)
    }

    private static func demoHistory(currency: String) -> [STDeposit] {
        let now = Date().timeIntervalSince1970
        let chain = currency == SafeTradeMarket.base ? "pearl-tokens" : "bsc-tokens"
        let json = """
        [{"id":2,"currency":"\(currency)","blockchain_key":"\(chain)","amount":"120.5","fee":"0","credited":false,
          "txid":"9f2c4e6a8b0d1f3e5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f","state":"processing",
          "created_at":\(Int(now - 600))},
         {"id":1,"currency":"\(currency)","blockchain_key":"\(chain)","amount":"500","fee":"0","credited":true,
          "txid":"3a5c7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c","state":"accepted",
          "created_at":\(Int(now - 86_400 * 2))}]
        """
        return decodeRows(STDeposit.self, from: Data(json.utf8)) ?? []
    }
    #endif
}
