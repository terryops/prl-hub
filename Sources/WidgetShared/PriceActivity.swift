#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

/// 锁屏盯盘 — a Live Activity showing the live PRL price on the Lock Screen and in
/// the Dynamic Island (Pro). Shared by the app (starts / updates it) and the widget
/// extension (draws it).
///
/// While the app runs it updates the activity itself from the app-wide price; while
/// it doesn't, the price-alert worker pushes updates to the activity's push token
/// (alerts/src/index.js, `live` table). The worker's JSON must match ContentState's
/// keys exactly: {"usd", "change1h", "change24h", "at"}.
struct PriceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// 1 PRL in USD.
        var usd: Double
        /// % change over the last hour / 24 hours (nil = unknown).
        var change1h: Double?
        var change24h: Double?
        /// Unix seconds of the price (plain number: ActivityKit decodes pushed
        /// JSON with default strategies, and a Date would expect 2001-based seconds).
        var at: Double
    }

    // Static copy, localized by the app when it starts the activity — the widget
    // extension bundles no strings of its own.
    var title: String
    var label1h: String
    var label24h: String

    /// Which presentation carries the price (chosen by the user; iOS always shows
    /// both a Lock Screen and a Dynamic Island presentation, so the other one is
    /// just kept minimal). Optional so a missing key decodes as `.full`.
    var style: Style?

    enum Style: String, Codable, CaseIterable, Identifiable {
        /// Lock Screen card + price in the Dynamic Island.
        case full
        /// Lock Screen card; the Dynamic Island shows only the pearl.
        case lock
        /// Price in the Dynamic Island; the Lock Screen shows a one-line strip.
        case island
        var id: String { rawValue }
    }
    var resolvedStyle: Style { style ?? .full }
}
#endif
