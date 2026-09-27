import SwiftUI

// MARK: - Formatting

enum PriceAlertFormat {
    /// "$0.88", "$0.90", "$12.35" — always 2 decimals, like the wallet's price chip;
    /// mirrors the worker's fmtUSD so the list and the notification agree.
    static func usd(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }

    /// Round to the 2 decimals the alert inputs allow.
    static func cents(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    static func pct(_ v: Double) -> String {
        String(format: "%g%%", v)
    }

    static func title(_ r: PriceAlertRule) -> String {
        switch r.kind {
        case .above: return Loc("涨到 %@", usd(r.value))
        case .below: return Loc("跌到 %@", usd(r.value))
        case .move:  return Loc("涨跌超过 %@", pct(r.value))
        }
    }

    static func subtitle(_ r: PriceAlertRule) -> String {
        let what: String
        switch r.kind {
        case .above, .below: what = Loc("到价提醒")
        case .move:
            switch r.window {
            case 300:  what = Loc("5 分钟内")
            case 3600: what = Loc("1 小时内")
            default:   what = Loc("24 小时内")
            }
        }
        guard let t = r.lastFired else { return what }
        return what + " · " + Loc("上次提醒：%@", RelTime(t))
    }

    static func icon(_ r: PriceAlertRule) -> String {
        switch r.kind {
        case .above: return "arrow.up.right"
        case .below: return "arrow.down.right"
        case .move:  return "waveform.path.ecg"
        }
    }

    static func gradient(_ r: PriceAlertRule) -> LinearGradient {
        switch r.kind {
        case .above: return Pearl.positive
        case .below: return Pearl.negative
        case .move:  return Pearl.brand
        }
    }
}
