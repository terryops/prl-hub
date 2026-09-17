import Foundation

/// Compile-time feature switches.
///
/// `tradeEnabled` gates the in-app SafeTrade trading surface (the Trade tab +
/// the SafeTrade API-key section in Settings). It is **off by default**: an app
/// that facilitates crypto-exchange buying/selling triggers App Review guideline
/// 3.1.5(b) (must be the exchange itself, or licensed in each region), the single
/// biggest rejection risk — so every App Store build ships with trading compiled
/// out.
///
/// To build with trading IN, define the `TRADE_ENABLED` Swift compilation
/// condition. iOS TestFlight and App Store builds share one pipeline
/// (`deploy-testflight.sh`), so this is an explicit per-build choice rather than
/// a checked-in flag: run `TRADE_ENABLED=1 ./deploy-testflight.sh` for a
/// TestFlight test build, and the plain script for any build you'll submit to
/// App Store review. Read-only price/k-line data from SafeTrade's PUBLIC ticker
/// stays on regardless (it isn't a trading feature).
enum AppFeatures {
    #if TRADE_ENABLED
    static let tradeEnabled = true
    #else
    static let tradeEnabled = false
    #endif
}
