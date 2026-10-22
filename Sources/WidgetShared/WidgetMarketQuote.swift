import Foundation
import CoreFoundation

/// A price and its rolling changes from the same source and observation. Kept
/// separately from the app's spot price, which can refresh more often on Trade.
struct WidgetMarketQuote: Codable, Equatable, Sendable {
    static let staleAfter: TimeInterval = 15 * 60
    var usd: Double
    var change1h: Double?
    var change24h: Double?
    var at: Date

    func isFresh(asOf now: Date = Date(), maxAge: TimeInterval = 300) -> Bool {
        let age = now.timeIntervalSince(at)
        return usd.isFinite && usd > 0 && at.timeIntervalSince1970 > 0
            && age >= -60 && age < maxAge
    }

    static func worker(_ object: [String: Any]) -> Self? {
        guard let usd = number(object["usd"]), usd > 0,
              let ts = number(object["ts"]), ts > 0 else { return nil }
        return Self(usd: usd, change1h: number(object["change1h"]),
                    change24h: number(object["change24h"]), at: Date(timeIntervalSince1970: ts))
    }

    /// SafeTrade has a rolling 24h change but no 1h figure. Missing changes stay
    /// unknown; never carry the previous source's changes into this quote.
    static func safeTrade(_ object: [String: Any], at: Date = Date()) -> Self? {
        let ticker = (object["ticker"] as? [String: Any]) ?? object
        guard let usd = number(ticker["last"]), usd > 0 else { return nil }
        let change: Any? = (ticker["price_change_percent"] as? String)
            .map { $0.replacingOccurrences(of: "%", with: "") } ?? ticker["price_change_percent"]
        return Self(usd: usd, change1h: nil,
                    change24h: number(change), at: at)
    }

    private static func number(_ value: Any?) -> Double? {
        let number: Double?
        if let string = value as? String { number = Double(string) }
        else if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { number = value.doubleValue }
        else { number = nil }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }
}

enum WidgetPriceChange {
    static func text(_ value: Double?, locale: Locale, decimals: Int = 2) -> String {
        guard let value, value.isFinite else { return "—" }
        // Round before choosing the sign so a tiny decline reads 0.00%, not -0.00%.
        let scale = pow(10.0, Double(decimals))
        let rounded = (value * scale).rounded() / scale
        let magnitude = abs(rounded).formatted(.number.locale(locale)
            .precision(.fractionLength(decimals)))
        return (rounded > 0 ? "+" : rounded < 0 ? "−" : "") + magnitude + "%"
    }

    static func symbol(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "minus" }
        return value > 0 ? "arrow.up.right" : value < 0 ? "arrow.down.right" : "minus"
    }
}

extension WidgetSnapshot {
    /// Merge after a fetch completes, preserving newer app quotes and wallet data.
    @discardableResult
    mutating func applyMarketQuote(_ quote: WidgetMarketQuote) -> Bool {
        guard quote.usd.isFinite, quote.usd > 0,
              quote.at.timeIntervalSince1970 > 0,
              quote.at >= (marketQuote?.at ?? .distantPast), quote != marketQuote else { return false }
        marketQuote = quote
        if quote.at >= (prlUsdAt ?? .distantPast) {
            prlUsd = quote.usd
            prlUsdAt = quote.at
        }
        return true
    }
}
