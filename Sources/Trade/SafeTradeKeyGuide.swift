import SwiftUI

/// SafeTrade API key setup guide — delegates to the unified `TradeKeyGuide` starting on SafeTrade.
struct SafeTradeKeyGuide: View {
    var onFillKeys: ((TradeExchange) -> Void)?
    var body: some View {
        TradeKeyGuide(initialExchange: .safetrade, onFillKeys: onFillKeys)
    }
}
