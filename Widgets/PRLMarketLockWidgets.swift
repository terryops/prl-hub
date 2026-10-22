#if os(iOS)
import SwiftUI
import WidgetKit

struct PearlQuoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBridge.quoteKind, provider: MarketLockProvider()) { entry in
            MarketLockView(entry: entry, metric: .quote)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("PRL 报价")
        .description("报价与 1 小时、24 小时涨跌幅")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct PearlChange1hWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBridge.change1hKind, provider: MarketLockProvider()) { entry in
            MarketLockView(entry: entry, metric: .hour)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("PRL 1 小时涨跌幅")
        .description("过去 1 小时的 PRL 涨跌幅")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct PearlChange24hWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBridge.change24hKind, provider: MarketLockProvider()) { entry in
            MarketLockView(entry: entry, metric: .day)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("PRL 24 小时涨跌幅")
        .description("过去 24 小时的 PRL 涨跌幅")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct MarketLockProvider: TimelineProvider {
    func placeholder(in context: Context) -> LockEntry { LockEntry(date: Date(), snap: .demo) }

    func getSnapshot(in context: Context, completion: @escaping (LockEntry) -> Void) {
        completion(LockEntry(date: Date(), snap: context.isPreview ? .demo : WidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LockEntry>) -> Void) {
        nonisolated(unsafe) let completion = completion
        Task {
            let quote = await WidgetFetch.sharedMarketQuote(WidgetStore.load())
            var snap = WidgetStore.load()
            if let quote, snap.applyMarketQuote(quote) { WidgetStore.save(snap) }
            let now = Date()
            var dates = [now]
            // Fade an old quote on time even if WidgetKit defers the next fetch.
            if let at = snap.marketQuote?.at ?? snap.prlUsdAt {
                let staleAt = at.addingTimeInterval(WidgetMarketQuote.staleAfter)
                if staleAt > now { dates.append(staleAt) }
            }
            completion(Timeline(entries: dates.map { LockEntry(date: $0, snap: snap) },
                                policy: .after(now.addingTimeInterval(15 * 60))))
        }
    }
}

enum LockMarketMetric {
    case quote, hour, day

    var period: String { self == .hour ? "1h" : "24h" }
    var labelKey: String { self == .hour ? "1 小时" : "24 小时" }

    func change(in snap: WidgetSnapshot) -> Double? {
        self == .hour ? snap.marketQuote?.change1h : snap.marketQuote?.change24h
    }
}

/// Accessory widgets inherit the Lock Screen tint. Signed numbers and arrows
/// convey direction without depending on red / green colours.
struct MarketLockView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LockEntry
    let metric: LockMarketMetric

    private var locale: Locale { widgetLocale(entry.snap.languageCode) }
    private var price: String { priceLine(entry.snap) ?? "—" }
    private var stamp: Date? { entry.snap.marketQuote?.at ?? entry.snap.prlUsdAt }
    private var stale: Bool { stamp.map { entry.date.timeIntervalSince($0) >= WidgetMarketQuote.staleAfter } ?? true }
    private var change: Double? { metric.change(in: entry.snap) }
    private func percent(_ value: Double?, decimals: Int = 2) -> String {
        WidgetPriceChange.text(value, locale: locale, decimals: decimals)
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline: inline
            case .accessoryCircular: circular
            default: rectangular
            }
        }
        .environment(\.locale, locale)
        .opacity(stale ? 0.55 : 1)
        .widgetURL(WidgetDeepLink.trade.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var inline: some View {
        let label = metric == .quote
            ? " \(price) · 24h \(percent(change))"
            : " PRL \(metric.period) \(percent(change))"
        let icon = metric == .quote
            ? Image(entry.appearance.symbolName, label: Text(verbatim: "PRL"))
            : Image(systemName: WidgetPriceChange.symbol(change))
        return (Text(icon) + Text(verbatim: label))
            .lineLimit(1).minimumScaleFactor(0.6)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                if metric == .quote {
                    Image(entry.appearance.symbolName).font(.system(size: 12))
                    Text(verbatim: price).font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(verbatim: "PRL · USD").font(.system(size: 8, weight: .medium))
                } else {
                    Text(verbatim: "PRL · \(metric.period)").font(.system(size: 9, weight: .semibold))
                    Image(systemName: WidgetPriceChange.symbol(change)).font(.system(size: 11, weight: .bold))
                    Text(verbatim: percent(change, decimals: 1))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
            }
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            .padding(.horizontal, 4)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(entry.appearance.symbolName)
                Text(verbatim: metric == .quote ? "PRL · USD" : "PRL · \(metric.period)")
                Spacer(minLength: 2)
                if let stamp {
                    if stale { Image(systemName: "clock.arrow.circlepath") }
                    Text(stamp, style: .time).monospacedDigit()
                }
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            if metric == .quote {
                Text(verbatim: price).font(.system(size: 23, weight: .bold, design: .rounded))
                    .monospacedDigit()
                HStack(spacing: 10) {
                    changeLabel(.hour)
                    changeLabel(.day)
                }
                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
            } else {
                Label {
                    Text(verbatim: percent(change)).monospacedDigit()
                } icon: {
                    Image(systemName: WidgetPriceChange.symbol(change))
                        .font(.system(size: 15, weight: .bold))
                }
                .font(.system(size: 23, weight: .bold, design: .rounded))
                Text(verbatim: price).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func changeLabel(_ metric: LockMarketMetric) -> some View {
        Text(verbatim: "\(metric.period) \(percent(metric.change(in: entry.snap)))")
    }

    private var accessibilityText: String {
        let code = entry.snap.languageCode
        var text = WLoc("PRL 报价", code) + " " + price
        let metrics: [LockMarketMetric] = metric == .quote ? [.hour, .day] : [metric]
        for metric in metrics {
            text += ", " + WLoc(metric.labelKey, code) + " " + percent(metric.change(in: entry.snap))
        }
        if let stamp {
            text += ", " + String(format: WLoc("报价更新于 %@", code),
                                  stamp.formatted(.dateTime.year().month().day().hour().minute().locale(locale)))
        }
        return text
    }
}

#Preview(as: .accessoryCircular) { PearlQuoteWidget() } timeline: { LockEntry(date: Date(), snap: .demo) }
#Preview(as: .accessoryRectangular) { PearlQuoteWidget() } timeline: { LockEntry(date: Date(), snap: .demo) }
#Preview(as: .accessoryInline) { PearlQuoteWidget() } timeline: { LockEntry(date: Date(), snap: .demo) }
#Preview(as: .accessoryCircular) { PearlChange1hWidget() } timeline: { LockEntry(date: Date(), snap: .demo) }
#Preview(as: .accessoryRectangular) { PearlChange24hWidget() } timeline: { LockEntry(date: Date(), snap: .demo) }
#Preview(as: .accessoryInline) { PearlChange24hWidget() } timeline: { LockEntry(date: Date(), snap: .demo) }
#endif
