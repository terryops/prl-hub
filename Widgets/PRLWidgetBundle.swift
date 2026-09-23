import WidgetKit
import SwiftUI

// MARK: - Pearl Hub widget bundle (iOS)
//
// Two widgets the user adds separately:
//   • Pearl Hub  — home screen / desktop: balance + fiat, recent transfers, pool hashrate.
//   • PRL 币价   — iOS Lock Screen: today's date, weekday and the live PRL price.
// Plus the 锁屏盯盘 Live Activity (iOS, Pro), which the app starts on demand.
// Both read the app's App Group snapshot for inputs and self-refresh on the system
// timeline so they stay current while the app is closed.

@main
struct PearlWidgetBundle: WidgetBundle {
    var body: some Widget {
        PearlWidget()
        #if os(iOS)
        PearlLockWidget()
        PriceLiveActivity()
        #endif
    }
}

// MARK: - Brand (inlined; the extension links nothing from the app's UI graph)

extension Color {
    static let pearlSky    = Color(red: 0.34, green: 0.62, blue: 0.99)
    static let pearlIndigo = Color(red: 0.32, green: 0.48, blue: 0.95)
    static let pearlViolet = Color(red: 0.53, green: 0.46, blue: 0.95)
    static let pearlGold   = Color(red: 1.00, green: 0.78, blue: 0.28)
}

let pearlGradient = LinearGradient(
    colors: [.pearlSky, .pearlIndigo, .pearlViolet],
    startPoint: .topLeading, endPoint: .bottomTrailing)

// MARK: - Formatting

func prlAmountString(_ v: Double, maxFrac: Int = 8) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.usesGroupingSeparator = true
    f.minimumFractionDigits = 0
    f.maximumFractionDigits = maxFrac
    return f.string(from: NSNumber(value: v)) ?? "0"
}

/// Split a PRL balance for display: a big grouped "1,234.56" head (integer + the
/// first 2 decimals, TRUNCATED not rounded so the tail stays exact) and the
/// remaining fraction digits (3rd–8th, trailing zeros trimmed). PRL has 8 decimals.
func balanceParts(_ v: Double) -> (head: String, tail: String) {
    let posix = Locale(identifier: "en_US_POSIX")
    let slice = NumberFormatter()
    slice.locale = posix
    slice.numberStyle = .decimal
    slice.usesGroupingSeparator = false
    slice.minimumFractionDigits = 8
    slice.maximumFractionDigits = 8
    slice.roundingMode = .down                 // truncate toward zero (balances ≥ 0)
    let full = slice.string(from: NSNumber(value: v)) ?? "0.00000000"
    let comps = full.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let intRaw = comps.first ?? "0"
    let frac = comps.count > 1 ? comps[1] : "00000000"
    let head2 = String(frac.prefix(2))
    var tail = String(frac.dropFirst(2))
    while tail.hasSuffix("0") { tail.removeLast() }
    let grp = NumberFormatter()
    grp.numberStyle = .decimal
    grp.usesGroupingSeparator = true
    grp.maximumFractionDigits = 0
    let intGrouped = grp.string(from: NSDecimalNumber(string: intRaw)) ?? intRaw
    let dec = Locale.current.decimalSeparator ?? "."
    return (intGrouped + dec + head2, tail)
}

/// The balance as a Text: big `head` (integer + 2 dp) followed by the remaining
/// fraction digits in the smaller, dimmer `tail` font. "——" when no wallet yet.
func balanceText(_ snap: WidgetSnapshot, head: Font, tail: Font) -> Text {
    guard snap.hasWallet else { return Text(verbatim: "——").font(head) }
    let p = balanceParts(snap.balancePRL)
    return Text(p.head).font(head)
        + Text(p.tail).font(tail).foregroundStyle(.white.opacity(0.6))
}

func moneyString(_ symbol: String, _ v: Double, decimals: Int = 2) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.usesGroupingSeparator = true
    f.minimumFractionDigits = decimals
    f.maximumFractionDigits = decimals
    return symbol + (f.string(from: NSNumber(value: v)) ?? "0")
}

/// "≈ $33.08 · ¥224.53" — total holdings value; nil when no price is known yet.
func fiatLine(_ snap: WidgetSnapshot) -> String? {
    guard snap.prlUsd > 0 else { return nil }
    let usd = snap.balancePRL * snap.prlUsd
    var line = "≈ " + moneyString("$", usd)
    if snap.usdCny > 0 { line += " · " + moneyString("¥", usd * snap.usdCny) }
    return line
}

/// Live unit price of one PRL in USD, e.g. "$0.52" — the market quote, distinct
/// from the holdings value above. USD only (not converted to CNY); nil until known.
/// Fixed 2 decimals per user preference.
func priceLine(_ snap: WidgetSnapshot) -> String? {
    guard snap.prlUsd > 0 else { return nil }
    return moneyString("$", snap.prlUsd, decimals: 2)
}

/// Human-readable raw hashrate, e.g. "1.23 GH/s".
func formatHashrate(_ hps: Double) -> String {
    guard hps > 0 else { return "—" }
    let units = ["H/s", "KH/s", "MH/s", "GH/s", "TH/s", "PH/s", "EH/s"]
    var v = hps, i = 0
    while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
    return String(format: v >= 100 ? "%.0f %@" : "%.2f %@", v, units[i])
}

// MARK: - Sample data (widget gallery / placeholder)

extension WidgetSnapshot {
    static var demo: WidgetSnapshot {
        var s = WidgetSnapshot()
        s.walletName = "Bikgo Pearl"
        s.balancePRL = 63.61479714
        s.prlUsd = 0.52
        s.usdCny = 7.10
        s.hasWallet = true
        s.recentTx = [
            WidgetTx(received: true,  amount: 12.5,  time: Date().addingTimeInterval(-1800)),
            WidgetTx(received: false, amount: 3.218, time: Date().addingTimeInterval(-7200)),
            WidgetTx(received: true,  amount: 48.0,  time: Date().addingTimeInterval(-86400)),
        ]
        s.pools = [
            WidgetPool(label: "Rig A · AlphaPool", kind: "AlphaPool", address: "prl1demo",
                       hashrate: "1.23 GH/s", hashrateRaw: 1.23e9, online: 3, total: 4),
            WidgetPool(label: "Rig B · HeroMiners", kind: "HeroMiners", address: "prl1demo2",
                       hashrate: "642 MH/s", hashrateRaw: 6.42e8, online: 2, total: 2),
        ]
        s.updatedAt = Date()
        return s
    }
}
