#if os(iOS)
import SwiftUI
import WidgetKit

struct PearlQuoteMiningWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetBridge.quoteMiningKind, provider: QuoteMiningLockProvider()) { entry in
            QuoteMiningLockView(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("报价与矿池监控")
        .description("PRL 报价、总算力和在线矿机数")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct QuoteMiningLockProvider: TimelineProvider {
    func placeholder(in context: Context) -> LockEntry { LockEntry(date: Date(), snap: .demo) }

    func getSnapshot(in context: Context, completion: @escaping (LockEntry) -> Void) {
        completion(LockEntry(date: Date(), snap: context.isPreview ? .demo : WidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LockEntry>) -> Void) {
        nonisolated(unsafe) let completion = completion
        Task {
            let initial = WidgetStore.load()
            let poolsFresh = !WidgetBridge.isStale(initial.poolsAt, now: Date(), maxAge: WidgetBridge.freshFor)
            async let usdFetch = WidgetFetch.sharedPrlUsd(initial)
            async let poolFetch: [(Int, WidgetFetch.PoolLive?)] = poolsFresh ? [] : withTaskGroup(of: (Int, WidgetFetch.PoolLive?).self) { group in
                for (index, pool) in initial.pools.enumerated() {
                    group.addTask { (index, await WidgetFetch.poolLive(kind: pool.kind, address: pool.address)) }
                }
                var results: [(Int, WidgetFetch.PoolLive?)] = []
                for await result in group { results.append(result) }
                return results
            }
            let (usd, pools) = await (usdFetch, poolFetch)
            let now = Date()
            var snap = WidgetStore.load()
            var changed = snap.applyPoolRefresh(pools, from: initial, at: now)
            if let usd, usd.at > (snap.prlUsdAt ?? .distantPast) {
                snap.prlUsd = usd.usd
                snap.prlUsdAt = usd.at
                changed = true
            }
            if changed { WidgetStore.save(snap) }

            // Price and mining have independent clocks: one successful fetch
            // must not make the other source's old figures look current.
            var dates: Set<Date> = [now]
            for stamp in [snap.prlUsdAt, snap.poolsAt].compactMap({ $0 }) {
                let staleAt = stamp.addingTimeInterval(WidgetMarketQuote.staleAfter)
                if staleAt > now { dates.insert(staleAt) }
            }
            completion(Timeline(entries: dates.sorted().map { LockEntry(date: $0, snap: snap) },
                                policy: .after(now.addingTimeInterval(15 * 60))))
        }
    }
}

struct QuoteMiningLockView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LockEntry

    private var mining: WidgetMiningSummary { WidgetMiningSummary(entry.snap.pools) }
    private var price: String { priceLine(entry.snap) ?? "—" }
    private var locale: Locale { widgetLocale(entry.snap.languageCode) }
    private var priceStale: Bool { stale(entry.snap.prlUsdAt) }
    private var poolsStale: Bool { stale(entry.snap.poolsAt) }
    private func stale(_ stamp: Date?) -> Bool {
        stamp.map { entry.date.timeIntervalSince($0) >= WidgetMarketQuote.staleAfter } ?? true
    }
    private func loc(_ key: String) -> String { WLoc(key, entry.snap.languageCode) }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline: inline
            case .accessoryCircular: circular
            default: rectangular
            }
        }
        .environment(\.locale, locale)
        .widgetURL(WidgetDeepLink.pools.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var inline: some View {
        let detail = mining.monitorCount == 0 ? loc("添加矿池监控")
            : "\(mining.hashrateText) · \(mining.workersText)"
        return (Text(Image(entry.appearance.symbolName, label: Text(verbatim: "PRL")))
                + Text(verbatim: " \(price) · \(detail)"))
            .lineLimit(1).minimumScaleFactor(0.6)
            .opacity(priceStale || poolsStale ? 0.55 : 1)
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(entry.appearance.symbolName).font(.system(size: 10))
                Text(verbatim: price).font(.system(size: 16, weight: .bold, design: .rounded))
                    .opacity(priceStale ? 0.55 : 1)
                Text(verbatim: mining.hashrateText).font(.system(size: 9, weight: .semibold))
                    .opacity(poolsStale ? 0.55 : 1)
                if mining.monitorCount == 0 {
                    Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                } else {
                    Label(mining.workersText, systemImage: "desktopcomputer")
                        .font(.system(size: 9, weight: .medium))
                        .opacity(poolsStale ? 0.55 : 1)
                }
            }
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            .padding(.horizontal, 5)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(entry.appearance.symbolName).font(.system(size: 14))
                Text(verbatim: "PRL").font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 3)
                Text(verbatim: price).font(.system(size: 20, weight: .bold, design: .rounded))
            }
            .opacity(priceStale ? 0.55 : 1)
            if mining.monitorCount == 0 {
                Label(loc("添加矿池监控"), systemImage: "plus.circle")
                    .font(.system(size: 12, weight: .medium))
                Text(loc("我的监控")).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Label(mining.hashrateText, systemImage: "bolt.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .opacity(poolsStale ? 0.55 : 1)
                Label(mining.workersText, systemImage: "desktopcomputer")
                    .font(.system(size: 10, weight: .medium))
                    .opacity(poolsStale ? 0.55 : 1)
                HStack(spacing: 3) {
                    Text(monitorLabel)
                    Spacer(minLength: 2)
                    if let stamp = entry.snap.poolsAt {
                        if poolsStale { Image(systemName: "clock.arrow.circlepath") }
                        Text(stamp, style: .time)
                    }
                }
                .font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var monitorLabel: String {
        if mining.knownCount < mining.monitorCount {
            return String(format: loc("%d/%d 个监控有数据"), mining.knownCount, mining.monitorCount)
        }
        if mining.monitorCount == 1 { return entry.snap.pools.first?.label ?? loc("我的监控") }
        return String(format: loc("汇总 %d 个监控"), mining.monitorCount)
    }

    private var accessibilityText: String {
        var text = loc("报价与矿池监控") + ", " + loc("PRL 报价") + " " + price
        if mining.monitorCount == 0 {
            return text + ", " + loc("还没有监控。先到「我的监控」添加矿池和收款地址。")
        }
        text += ", " + loc("总算力") + " " + mining.hashrateText
        text += ", " + loc("在线") + " " + mining.workersText + ", " + monitorLabel
        if let stamp = entry.snap.poolsAt {
            text += ", " + String(format: loc("矿池更新于 %@"),
                                  stamp.formatted(.dateTime.year().month().day().hour().minute().locale(locale)))
        }
        return text
    }
}

#Preview(as: .accessoryCircular) { PearlQuoteMiningWidget() } timeline: { LockEntry(date: Date(), snap: .demo) }
#Preview(as: .accessoryRectangular) { PearlQuoteMiningWidget() } timeline: { LockEntry(date: Date(), snap: .demo) }
#Preview(as: .accessoryInline) { PearlQuoteMiningWidget() } timeline: { LockEntry(date: Date(), snap: .demo) }
#endif
