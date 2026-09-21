#if os(iOS)
import WidgetKit
import SwiftUI

// MARK: - Pearl Hub lock-screen widget (iOS only — accessory families don't exist on macOS)
//
// Today's date (month/day + weekday) and the live PRL price on the Lock Screen.
//   • accessoryRectangular — one line, styled like the system date: "9月19日周六 $1.11".
//   • accessoryInline      — price only ("$1.11"): the system already prefixes that slot
//                            with its own "19 周六", which a widget can't replace.
// Self-fetches just the price (nothing else is shown), falling back to the app's last
// snapshot price when the fetch fails. Read-only: never writes the shared snapshot back.

struct PearlLockWidget: Widget {
    let kind = "PRLHubLockWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LockProvider()) { entry in
            LockWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("PRL 币价")
        .description("日期、星期与 PRL 实时币价")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

struct LockEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
}

struct LockProvider: TimelineProvider {
    func placeholder(in context: Context) -> LockEntry { LockEntry(date: Date(), snap: .demo) }

    func getSnapshot(in context: Context, completion: @escaping (LockEntry) -> Void) {
        completion(LockEntry(date: Date(), snap: context.isPreview ? .demo : WidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LockEntry>) -> Void) {
        Task {
            let usd = await WidgetFetch.prlUsd()
            var snap = WidgetStore.load()
            if let usd { snap.prlUsd = usd }

            // One entry now, plus one at each of the next two midnights, so the date flips on
            // time even when the system defers the next reload (overnight, low budget). Price is
            // the only live figure, so ask for a reload every 15 min — WidgetKit clamps it to
            // the widget's budget anyway.
            let now = Date()
            let cal = Calendar.current
            var dates = [now]
            var day = cal.startOfDay(for: now)
            for _ in 0..<2 {
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                dates.append(next); day = next
            }
            completion(Timeline(entries: dates.map { LockEntry(date: $0, snap: snap) },
                                policy: .after(now.addingTimeInterval(15 * 60))))
        }
    }
}

// MARK: - Views

struct LockWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LockEntry

    /// Follow the in-app language like the home widget's freshness stamp does. With no
    /// override, use the device's first preferred language — NOT Locale.current, which in
    /// this unlocalized extension resolves to its development region (en).
    private var locale: Locale {
        if let code = entry.snap.languageCode, !code.isEmpty { return Locale(identifier: code) }
        return Locale(identifier: Locale.preferredLanguages.first ?? "en")
    }

    /// "9月19日周六" / "Sat, Sep 19". Chinese drops the space the locale format puts before
    /// the weekday, matching the system's own lock-screen date; other languages keep their
    /// locale-natural order and punctuation.
    private var dateLine: String {
        if locale.language.languageCode == .chinese {
            return entry.date.formatted(.dateTime.month(.abbreviated).day().locale(locale))
                + entry.date.formatted(.dateTime.weekday(.abbreviated).locale(locale))
        }
        return entry.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().locale(locale))
    }

    private var price: String { priceLine(entry.snap) ?? "—" }

    var body: some View {
        switch family {
        case .accessoryInline:
            Text(verbatim: price)
                .widgetURL(WidgetDeepLink.trade.url)
        default:
            Text(verbatim: "\(dateLine) \(price)")
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .widgetURL(WidgetDeepLink.trade.url)
        }
    }
}

#Preview(as: .accessoryRectangular) { PearlLockWidget() } timeline: { LockEntry(date: Date(), snap: .demo) }
#Preview(as: .accessoryInline) { PearlLockWidget() } timeline: { LockEntry(date: Date(), snap: .demo) }
#endif
