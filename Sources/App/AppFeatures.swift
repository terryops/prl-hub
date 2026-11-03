import Foundation

/// Compile-time feature switches. The deploy scripts set them (tools/lib.sh
/// `trade_settings`); a plain Xcode run has neither.
///
/// `tradeEnabled` (`TRADE_ENABLED`) — the 交易 / 行情 tab: SafeTrade's PUBLIC
/// PEARL/USDT market (price, K-line, Pro depth chart).
///
/// `tradeAccount` — the user's own SafeTrade account inside that tab: API keys,
/// balances, orders, deposit and withdraw. Always on for iOS (with `TRADE_ENABLED`).
/// On macOS only with `TRADE_ACCOUNT` too: App Review rejected the Mac app under
/// guideline 3.1.5(iii) (2.1.7, 2026-10-29: SafeTrade has no exchange licences), so
/// Mac App Store builds leave it out and the tab is the public 行情 only.
/// deploy-mac.sh (local) turns it on; deploy-mac-appstore.sh refuses to.
enum AppFeatures {
    #if TRADE_ENABLED
    static let tradeEnabled = true
    #else
    static let tradeEnabled = false
    #endif

    #if TRADE_ENABLED && (os(iOS) || TRADE_ACCOUNT)
    static let tradeAccount = true
    #else
    static let tradeAccount = false
    #endif
}
