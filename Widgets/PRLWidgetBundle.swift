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

// MARK: - Localization

/// The widget's Loc(): the extension bundles the app's string tables (keyed by the
/// Simplified-Chinese source text, like the app), so look `key` up in the app's
/// resolved language from the snapshot → English → the key itself.
func WLoc(_ key: String, _ languageCode: String?) -> String {
    let miss = "\u{1}\u{0}miss"
    for bundle in WidgetStrings.bundles(languageCode) {
        let v = bundle.localizedString(forKey: key, value: miss, table: "Localizable")
        if v != miss { return v }
    }
    return key
}

/// Locale for dates and relative times: the app's language, else the device's first
/// preferred language — NOT Locale.current, which in an extension resolves to the
/// development region.
func widgetLocale(_ languageCode: String?) -> Locale {
    if let code = languageCode, !code.isEmpty { return Locale(identifier: code) }
    return Locale(identifier: Locale.preferredLanguages.first ?? "en")
}

private enum WidgetStrings {
    private static let lock = NSLock()
    // Guarded by `lock`.
    nonisolated(unsafe) private static var cache: [String: Bundle] = [:]

    static func bundles(_ languageCode: String?) -> [Bundle] {
        let code = languageCode ?? Bundle.main.preferredLocalizations.first ?? "en"
        return [bundle(code), code == "en" ? nil : bundle("en")].compactMap { $0 }
    }

    private static func bundle(_ code: String) -> Bundle? {
        lock.lock(); defer { lock.unlock() }
        if let b = cache[code] { return b }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) else { return nil }
        cache[code] = b
        return b
    }
}

// MARK: - Formatting

/// Formatters are built once, not per call: the widget formats every figure on
/// each of a timeline's 61 entries.
private enum WidgetFormatters {
    static let lock = NSLock()
    // Reconfigured per use, always under `lock`.
    static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()
    /// Fixed-point 8-decimal POSIX slice for balanceParts.
    static let slice8: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 8
        f.maximumFractionDigits = 8
        f.roundingMode = .down                 // truncate toward zero (balances ≥ 0)
        return f
    }()

    static func decimal(_ n: NSNumber, minFrac: Int, maxFrac: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        decimal.minimumFractionDigits = minFrac
        decimal.maximumFractionDigits = maxFrac
        return decimal.string(from: n)
    }

    static func slice(_ v: Double) -> String? {
        lock.lock(); defer { lock.unlock() }
        return slice8.string(from: NSNumber(value: v))
    }
}

func prlAmountString(_ v: Double, maxFrac: Int = 8) -> String {
    WidgetFormatters.decimal(NSNumber(value: v), minFrac: 0, maxFrac: maxFrac) ?? "0"
}

/// Split a PRL balance for display: a big grouped "1,234.56" head (integer + the
/// first 2 decimals, TRUNCATED not rounded so the tail stays exact) and the
/// remaining fraction digits (3rd–8th, trailing zeros trimmed). PRL has 8 decimals.
func balanceParts(_ v: Double) -> (head: String, tail: String) {
    let full = WidgetFormatters.slice(v) ?? "0.00000000"
    let comps = full.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let intRaw = comps.first ?? "0"
    let frac = comps.count > 1 ? comps[1] : "00000000"
    let head2 = String(frac.prefix(2))
    var tail = String(frac.dropFirst(2))
    while tail.hasSuffix("0") { tail.removeLast() }
    let intGrouped = WidgetFormatters.decimal(NSDecimalNumber(string: intRaw), minFrac: 0, maxFrac: 0) ?? intRaw
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
    symbol + (WidgetFormatters.decimal(NSNumber(value: v), minFrac: decimals, maxFrac: decimals) ?? "0")
}

/// "≈ $33.08 · ¥224.53" — total holdings value in USD plus the secondary currency
/// picked in the app (none → USD only); nil when no price is known yet.
func fiatLine(_ snap: WidgetSnapshot) -> String? {
    guard snap.prlUsd > 0 else { return nil }
    let usd = snap.balancePRL * snap.prlUsd
    var line = "≈ " + moneyString("$", usd)
    if let f = snap.fiat, f.rate > 0 { line += " · " + moneyString(f.symbol, usd * f.rate, decimals: f.decimals) }
    return line
}

/// Live unit price of one PRL in USD, e.g. "$0.52" — the market quote, distinct
/// from the holdings value above. USD only; nil until known.
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
        s.fiat = WidgetFiat(code: "CNY", symbol: "¥", decimals: 2, rate: 7.10)
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
