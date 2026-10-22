import Foundation
import Testing
@testable import Pearl

struct WidgetMarketQuoteTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func workerDistinguishesNoChangeFromMissingHistory() throws {
        let quote = try #require(WidgetMarketQuote.worker([
            "usd": 0.52, "ts": now.timeIntervalSince1970,
            "change1h": NSNull(), "change24h": 0.0
        ]))
        #expect(quote.change1h == nil)
        #expect(quote.change24h == 0)
        #expect(quote.isFresh(asOf: now))
        #expect(!quote.isFresh(asOf: now + 300))
        #expect(!quote.isFresh(asOf: now - 61))
    }

    @Test func badPricesAndTimestampsCannotBecomeFreshQuotes() {
        for value: Any in [0.0, -1.0, Double.infinity, "NaN", true] {
            #expect(WidgetMarketQuote.worker(["usd": value, "ts": now.timeIntervalSince1970]) == nil)
        }
        #expect(WidgetMarketQuote.worker(["usd": 0.52]) == nil)
        #expect(WidgetMarketQuote.worker(["usd": 0.52, "ts": 0]) == nil)
        let quote = WidgetMarketQuote.worker(["usd": "0.52", "ts": now.timeIntervalSince1970,
                                             "change1h": "NaN", "change24h": Double.infinity])
        #expect(quote?.change1h == nil && quote?.change24h == nil)
    }

    @Test func safeTradeFallbackHasOnlyItsOwn24HourChange() throws {
        let quote = try #require(WidgetMarketQuote.safeTrade([
            "ticker": ["last": "0.5200", "price_change_percent": "-2.34%"]
        ], at: now))
        #expect(quote.usd == 0.52)
        #expect(quote.change1h == nil)
        #expect(quote.change24h == -2.34)
        #expect(WidgetMarketQuote.safeTrade(["last": "0.52"], at: now)?.change24h == nil)
    }

    @Test func slowFetchCannotOverwriteANewerAppPriceOrQuote() {
        var snap = WidgetSnapshot()
        snap.walletName = "My wallet"
        snap.balancePRL = 42
        snap.prlUsd = 0.60
        snap.prlUsdAt = now + 30
        let quote = WidgetMarketQuote(usd: 0.52, change1h: 1.2, change24h: -2.34, at: now)
        let applied = snap.applyMarketQuote(quote)
        #expect(applied)
        #expect(snap.prlUsd == 0.60 && snap.prlUsdAt == now + 30)
        #expect(snap.walletName == "My wallet" && snap.balancePRL == 42)
        let appliedOld = snap.applyMarketQuote(WidgetMarketQuote(usd: 0.45, change1h: nil, change24h: nil, at: now - 60))
        #expect(!appliedOld)
        #expect(snap.marketQuote == quote)
        // A newer fallback clears unavailable 1h history instead of mixing sources.
        let appliedNew = snap.applyMarketQuote(WidgetMarketQuote(usd: 0.61, change1h: nil, change24h: 3, at: now + 60))
        #expect(appliedNew)
        #expect(snap.marketQuote?.change1h == nil && snap.prlUsd == 0.61)
    }

    @Test func oldSnapshotsStillDecodeAndNewQuotesRoundTrip() throws {
        var snap = WidgetSnapshot()
        snap.balancePRL = 42
        let legacy = try JSONEncoder().encode(snap)
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: legacy).marketQuote == nil)
        snap.marketQuote = WidgetMarketQuote(usd: 0.52, change1h: 0, change24h: nil, at: now)
        let restored = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snap))
        #expect(restored.marketQuote == snap.marketQuote)
        #expect(restored.balancePRL == 42)
    }

    @Test func percentagesKeepTheirSignAndRespectTheLanguage() {
        let en = Locale(identifier: "en_US")
        #expect(WidgetPriceChange.text(2.34, locale: en) == "+2.34%")
        #expect(WidgetPriceChange.text(-2.34, locale: en) == "−2.34%")
        #expect(WidgetPriceChange.text(-0.001, locale: en) == "0.00%")
        #expect(WidgetPriceChange.text(nil, locale: en) == "—")
        #expect(WidgetPriceChange.text(.nan, locale: en) == "—")
        #expect(WidgetPriceChange.text(2.34, locale: Locale(identifier: "de_DE")) == "+2,34%")
        #expect(WidgetPriceChange.text(2.34, locale: en, decimals: 1) == "+2.3%")
        #expect(WidgetPriceChange.symbol(-2.34) == "arrow.down.right")
    }
}
