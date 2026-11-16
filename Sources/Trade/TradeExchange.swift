import Foundation

extension Notification.Name {
    static let tradeExchangeDidChange = Notification.Name("tradeExchangeDidChange")
}

/// Supported spot exchanges in the Trade tab.
enum TradeExchange: String, CaseIterable, Identifiable, Sendable {
    case safetrade
    case gate

    static let storageKey = "trade.exchange"

    static var saved: TradeExchange {
        if let raw = UserDefaults.standard.string(forKey: storageKey),
           let ex = TradeExchange(rawValue: raw) {
            return ex
        }
        if AppFeatures.tradeAccount && GateSecrets.hasCredentials && !SafeTradeSecrets.hasCredentials {
            return .gate
        }
        return .safetrade
    }

    static func save(_ ex: TradeExchange) {
        let prev = UserDefaults.standard.string(forKey: storageKey)
        UserDefaults.standard.set(ex.rawValue, forKey: storageKey)
        CloudSync.push(storageKey)
        if prev != ex.rawValue {
            NotificationCenter.default.post(name: .tradeExchangeDidChange, object: ex)
        }
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .safetrade: return "SafeTrade"
        case .gate: return "Gate"
        }
    }

    var marketID: String {
        switch self {
        case .safetrade: return SafeTradeMarket.defaultValue
        case .gate: return "PEARL_USDT"
        }
    }

    var defaultRules: SafeTradeMarketRules {
        switch self {
        case .safetrade: return .pearlusdt
        case .gate: return .gatePearlUsdt
        }
    }

    var webTradeURL: URL {
        switch self {
        case .safetrade: return URL(string: "https://safetrade.com/exchange/PEARL-USDT")!
        case .gate: return URL(string: "https://www.gate.com/trade/PEARL_USDT")!
        }
    }

    var apiManagementURL: URL {
        switch self {
        case .safetrade: return URL(string: "https://safetrade.com/my/api")!
        case .gate: return URL(string: "https://www.gate.com/myaccount/apikeys")!
        }
    }

    var hasCredentials: Bool {
        switch self {
        case .safetrade: return SafeTradeSecrets.hasCredentials
        case .gate: return GateSecrets.hasCredentials
        }
    }

    var apiKey: String {
        switch self {
        case .safetrade: return SafeTradeSecrets.apiKey
        case .gate: return GateSecrets.apiKey
        }
    }

    func invalidateCredentialCache() {
        switch self {
        case .safetrade: SafeTradeSecrets.invalidateCache()
        case .gate: GateSecrets.invalidateCache()
        }
    }
}
