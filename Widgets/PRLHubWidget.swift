import WidgetKit
import SwiftUI

// MARK: - Pearl Hub combined widget
//
// One widget: wallet status on top (balance + fiat, plus recent transfers on the
// large size), then every pool watch's hashrate / online workers below. Reads the
// app's App Group snapshot and self-refreshes balance + price + AlphaPool hashrate
// on the system timeline so it stays current while the app is closed.

struct PearlWidget: Widget {
    let kind = "PRLHubWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PearlProvider()) { entry in
            PearlWidgetView(snap: entry.snap, age: entry.age, fresh: entry.fresh)
                .containerBackground(pearlGradient, for: .widget)
        }
        .configurationDisplayName("Pearl Hub")
        .description("钱包余额与挖矿监控")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PearlEntry: TimelineEntry {
    let date: Date
    let snap: WidgetSnapshot
    var age: String = ""        // precomputed minute-granularity freshness, e.g. "5 分钟前"
    var fresh: Bool = false     // refreshed within the last 5 minutes → stamp shows the fresh badge
}

/// Fresh-badge threshold: the shown minute count (same rounding as `freshnessAge`) is ≤ 5,
/// so "5 分钟前" is still bright and "6 分钟前" dims. Precomputed per timeline entry alongside
/// the label, so the dimming flips on the same minute boundary as the text.
func freshnessIsRecent(stamp: Date, asOf now: Date) -> Bool {
    guard stamp > .distantPast else { return false }
    return Int(now.timeIntervalSince(stamp) / 60) <= 5
}

/// Minute-granularity freshness label ("5 分钟前" / localized "现在"). Precomputed per
/// timeline entry so the widget's age advances by the MINUTE without a self-updating
/// `.relative` Text ticking every second. Empty when nothing has ever loaded.
func freshnessAge(stamp: Date, asOf now: Date, languageCode: String? = nil) -> String {
    guard stamp > .distantPast else { return "" }
    let fmt = RelativeDateTimeFormatter()
    // Follow the in-app language (published in the snapshot), not the device language,
    // so the stamp reads "5 min. ago" when the app is in English on a Chinese Mac.
    if let code = languageCode, !code.isEmpty { fmt.locale = Locale(identifier: code) }
    fmt.unitsStyle = .short
    fmt.dateTimeStyle = .named             // 0 min → localized "现在"
    let mins = max(0, Int(now.timeIntervalSince(stamp) / 60))
    return fmt.localizedString(from: DateComponents(minute: -mins))
}

struct PearlProvider: TimelineProvider {
    func placeholder(in context: Context) -> PearlEntry { PearlEntry(date: Date(), snap: .demo) }

    func getSnapshot(in context: Context, completion: @escaping (PearlEntry) -> Void) {
        let snap = context.isPreview ? .demo : WidgetStore.load()
        let now = Date()
        completion(PearlEntry(date: now, snap: snap,
                              age: freshnessAge(stamp: snap.updatedAt, asOf: now, languageCode: snap.languageCode),
                              fresh: freshnessIsRecent(stamp: snap.updatedAt, asOf: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PearlEntry>) -> Void) {
        Task {
            var snap = WidgetStore.load()
            let network = snap.network
            let xpub = snap.xpub
            let poolsIn = snap.pools

            // Run every independent fetch CONCURRENTLY (mirrors PoolStore.refresh's
            // async-let pattern). Serially awaiting balance → price → fx → pools could
            // sum each request's timeout (~50s on a stalled network) and blow past
            // WidgetKit's timeline-generation budget; in parallel the wall time is just
            // the single slowest request. (balancePRL returns nil for a nil/empty xpub.)
            async let balF: Double? = WidgetFetch.balancePRL(xpub: xpub, network: network)
            async let usdF = WidgetFetch.sharedPrlUsd(snap)
            async let cnyF: Double? = WidgetFetch.usdCny()
            async let poolsF: [(Int, WidgetFetch.PoolLive?)] = withTaskGroup(of: (Int, WidgetFetch.PoolLive?).self) { group in
                for (i, p) in poolsIn.enumerated() {
                    group.addTask { (i, await WidgetFetch.poolLive(kind: p.kind, address: p.address)) }
                }
                var out: [(Int, WidgetFetch.PoolLive?)] = []
                for await r in group { out.append(r) }
                return out
            }
            let (bal, usd, cny, poolResults) = await (balF, usdF, cnyF, poolsF)

            // The fetches above can take many seconds, during which the app may have removed
            // or switched the wallet (clearWallet) or changed the pool watches. Merge into the
            // snapshot as it is NOW, and only onto the same wallet / pools the fetch was for —
            // writing back the copy read at the start would resurrect a removed wallet.
            snap = WidgetStore.load()

            // Track whether ANY self-fetch actually succeeded — the freshness timestamp
            // must only advance on success, otherwise a fully-offline refresh keeps the
            // stale balance/hashrate but stamps it "now", so it reads as just-refreshed.
            var didRefresh = false
            // Wallet: self-fetch covers only the external xpub balance; add back the
            // app-published stranded internal-chain change so the widget can't show LESS
            // than the app's authoritative total. (recentTx still comes from the app's
            // last write — direction/amount need the app's full chain logic.)
            if let bal, let xpub, snap.xpub == xpub, snap.network == network {
                snap.balancePRL = bal + snap.changePRL; didRefresh = true
            }
            if let usd { snap.prlUsd = usd.usd; snap.prlUsdAt = usd.at; didRefresh = true }
            if let cny { snap.usdCny = cny; didRefresh = true }

            let sameWatches = snap.pools.map { "\($0.kind)|\($0.address)" } == poolsIn.map { "\($0.kind)|\($0.address)" }
            if sameWatches {
                for (i, live) in poolResults {
                    guard let live, snap.pools.indices.contains(i) else { continue }
                    snap.pools[i].hashrate = live.hashrate
                    snap.pools[i].hashrateRaw = live.hashrateRaw
                    snap.pools[i].online = live.online
                    snap.pools[i].total = live.total
                    didRefresh = true
                }
            }
            if didRefresh { snap.updatedAt = Date() }
            WidgetStore.save(snap)

            // Freshness is the last SUCCESSFUL refresh (not the timeline build time), so the
            // shown age reflects how current the figures really are. When nothing was ever
            // loaded the stamp stays .distantPast → no age label and no fresh badge.
            //
            // Emit one entry per minute, each carrying a precomputed minute-granularity age
            // string, so the label advances "1 分钟前 → 2 分钟前 …" by the MINUTE. WidgetKit
            // swaps these on schedule WITHOUT spending a reload, so it's free; cover an hour
            // in case the system delays the next reload past the 30-min request.
            let stamp = snap.updatedAt
            let start = Date()
            var entries: [PearlEntry] = []
            for m in 0...60 {
                let at = start.addingTimeInterval(Double(m) * 60)
                entries.append(PearlEntry(date: at, snap: snap,
                                          age: freshnessAge(stamp: stamp, asOf: at, languageCode: snap.languageCode),
                                          fresh: freshnessIsRecent(stamp: stamp, asOf: at)))
            }
            completion(Timeline(entries: entries, policy: .after(start.addingTimeInterval(30 * 60))))
        }
    }
}

// MARK: - Views

struct PearlWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snap: WidgetSnapshot
    let age: String
    var fresh: Bool = false

    var body: some View {
        switch family {
        case .systemSmall: SmallCombined(snap: snap)
        case .systemLarge: LargeCombined(snap: snap, age: age, fresh: fresh)
        default:           MediumCombined(snap: snap, age: age, fresh: fresh)
        }
    }
}

// MARK: freshness stamp — shared by medium + large

/// Top-right "N 分钟前" stamp. Fresh (≤ 5 min) reads as a badge: a green check and
/// full-white semibold text on a faint capsule. Stale drops the icon and the capsule and
/// dims the text. The icon is the main tell — it survives the macOS desktop's vibrant
/// (desaturated) rendering, where colour and opacity differences flatten out.
private struct FreshnessStamp: View {
    let age: String
    let fresh: Bool
    let font: Font
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                if fresh {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.green)
                }
                Text(age)
                    .fontWeight(fresh ? .semibold : .regular)
                    .foregroundStyle(.white.opacity(fresh ? 1 : 0.45))
            }
            .font(font)
            // Same padding in both states so the text doesn't shift when the badge flips.
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(.white.opacity(fresh ? 0.2 : 0)))
        }
    }
}

// MARK: small — price hero on top, balance under, one-line mining summary

private struct SmallCombined: View {
    let snap: WidgetSnapshot
    private var online: Int { snap.pools.reduce(0) { $0 + $1.online } }
    private var total: Int { snap.pools.reduce(0) { $0 + $1.total } }
    private var raw: Double { snap.pools.reduce(0) { $0 + $1.hashrateRaw } }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("PRL/USD").font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.6))
            PriceBig(snap: snap, size: 18)
            Spacer(minLength: 2)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                balanceText(snap, head: .system(.callout, design: .rounded).weight(.bold),
                            tail: .system(.caption2, design: .rounded).weight(.bold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                Text("PRL").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            }
            if let fiat = fiatLine(snap) {
                Text(fiat).font(.system(size: 9)).foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            Spacer(minLength: 2)
            if !snap.pools.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.fill").foregroundStyle(Color.pearlGold)
                    Text(formatHashrate(raw)).lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 2)
                    Image(systemName: "desktopcomputer")
                    Text("\(online)/\(total)").monospacedDigit()
                }
                .font(.caption2).foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        // Small widgets get ONE tap target only (Link is ignored here) — send the
        // whole tile to 钱包, since price/balance is the hero of this layout.
        .widgetURL(WidgetDeepLink.wallet.url)
    }
}

// MARK: medium — price | balance two-column header, then a split mining panel

private struct MediumCombined: View {
    let snap: WidgetSnapshot
    let age: String
    var fresh: Bool = false
    var body: some View {
        VStack(spacing: 0) {
            // Freshness stamp — top-right corner (minute-granularity "N 分钟前").
            if !age.isEmpty { FreshnessStamp(age: age, fresh: fresh, font: .system(size: 9)) }
            Spacer(minLength: 0)

            // Header: PRL price is the gold hero on the left; balance + fiat on the
            // right, split by a hairline. No wallet name — the price leads. Each half
            // taps to its own page: 价格 → 交易, 余额 → 钱包.
            HStack(spacing: 0) {
                Link(destination: WidgetDeepLink.trade.url) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PRL/USD").font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.6))
                    PriceBig(snap: snap, size: 22)
                    Text("USD").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                }

                Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 52)

                Link(destination: WidgetDeepLink.wallet.url) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snap.labelBalance).font(.caption2.weight(.medium)).foregroundStyle(.white.opacity(0.6))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        balanceText(snap, head: .system(.title3, design: .rounded).weight(.bold),
                                    tail: .system(.caption2, design: .rounded).weight(.bold))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                        Text("PRL").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    }
                    if let fiat = fiatLine(snap) {
                        Text(fiat).font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1).minimumScaleFactor(0.6)
                    } else {
                        Text(" ").font(.system(size: 10))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 14)
                }
            }
            .foregroundStyle(.white)

            Rectangle().fill(.white.opacity(0.10)).frame(height: 1).padding(.vertical, 11)

            // Lower panel taps to its own page: pool watches → 我的监控, transfers → 钱包.
            if snap.pools.isEmpty {
                Link(destination: WidgetDeepLink.wallet.url) { TxStrip(snap: snap) }
            } else {
                Link(destination: WidgetDeepLink.pools.url) { MiningPanel(pools: snap.pools) }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Fallback for the gaps between Link regions (divider, freshness stamp).
        .widgetURL(WidgetDeepLink.wallet.url)
    }
}

// MARK: large — price headline + balance, recent transfers, then up to 4 pool rows

private struct LargeCombined: View {
    let snap: WidgetSnapshot
    let age: String
    var fresh: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Freshness stamp — top-right corner (minute-granularity "N 分钟前").
            if !age.isEmpty { FreshnessStamp(age: age, fresh: fresh, font: .caption2) }
            // Price is the headline (left, gold); balance + fiat sit to the right.
            // No wallet name. Each side taps to its own page: 价格 → 交易, 余额 → 钱包.
            HStack(alignment: .top) {
                Link(destination: WidgetDeepLink.trade.url) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PRL/USD").font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.6))
                    PriceBig(snap: snap, size: 24)
                }
                }
                Spacer(minLength: 8)
                Link(destination: WidgetDeepLink.wallet.url) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(snap.labelBalance).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.6))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        balanceText(snap, head: .system(.title2, design: .rounded).weight(.bold),
                                    tail: .system(.caption, design: .rounded).weight(.bold))
                            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                        Text("PRL").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    }
                    if let fiat = fiatLine(snap) {
                        Text(fiat).font(.caption2).foregroundStyle(.white.opacity(0.8))
                    }
                }
                }
            }
            .foregroundStyle(.white)
            // Recent transfers — tap to 钱包.
            if !snap.recentTx.isEmpty {
                Link(destination: WidgetDeepLink.wallet.url) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snap.labelRecentTx).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    ForEach(Array(snap.recentTx.prefix(2).enumerated()), id: \.offset) { _, tx in
                        TxRow(tx: tx).font(.caption)
                    }
                }
                }
            }
            Rectangle().fill(.white.opacity(0.16)).frame(height: 1)
            // Mining — the pool rows tap to 我的监控.
            if snap.pools.isEmpty {
                Text(" ").font(.caption)
            } else {
                Link(destination: WidgetDeepLink.pools.url) {
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(snap.pools.prefix(4).enumerated()), id: \.offset) { _, p in
                        PoolRow(pool: p, compact: false)
                    }
                    if snap.pools.count > 4 {
                        Text("+\(snap.pools.count - 4)").font(.caption2).foregroundStyle(.white.opacity(0.6))
                    }
                }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Fallback for the gaps between Link regions (divider, freshness stamp).
        .widgetURL(WidgetDeepLink.wallet.url)
    }
}

// MARK: - Shared pieces

/// 币价 — the live PRL unit price as the widget's GOLD hero figure (the star of
/// this design). Adaptive precision (priceLine) so a sub-dollar coin never collapses
/// to "$0.00"; shows "—" until a price is known.
private struct PriceBig: View {
    let snap: WidgetSnapshot
    var size: CGFloat
    var body: some View {
        Text(priceLine(snap) ?? "—")
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .foregroundStyle(priceLine(snap) == nil ? Color.pearlGold.opacity(0.5) : Color.pearlGold)
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
    }
}

/// Mining (medium) — one rounded panel with each pool as an equal column split by a
/// hairline: bigger and tidier than loose rows. Shows up to 2 pools.
private struct MiningPanel: View {
    let pools: [WidgetPool]
    private var shown: [WidgetPool] { Array(pools.prefix(2)) }
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { idx, p in
                HStack(spacing: 6) {
                    Circle().fill(p.online > 0 ? Color.green : Color.white.opacity(0.4)).frame(width: 7, height: 7)
                    Image(systemName: "bolt.fill").font(.system(size: 11)).foregroundStyle(Color.pearlGold)
                    Text(p.hashrate).font(.system(size: 13, weight: .bold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.55)
                    Spacer(minLength: 3)
                    Text("\(p.online)/\(p.total)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                if idx == 0 && shown.count > 1 {
                    Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 22)
                }
            }
        }
        .foregroundStyle(.white)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One pool row: status dot · label · hashrate · online/total — matches the design.
private struct PoolRow: View {
    let pool: WidgetPool
    let compact: Bool
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(pool.online > 0 ? Color.green : Color.white.opacity(0.4)).frame(width: 7, height: 7)
            Text(pool.label)
                .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                .lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").foregroundStyle(Color.pearlGold).font(.caption2)
                Text(pool.hashrate)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            }
            HStack(spacing: 3) {
                Image(systemName: "desktopcomputer").font(.caption2)
                Text("\(pool.online)/\(pool.total)")
                    .font(compact ? .caption : .subheadline).monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
    }
}

/// When there are no pools, the medium widget fills the lower area with the most
/// recent transfers instead.
private struct TxStrip: View {
    let snap: WidgetSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(snap.labelRecentTx).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            if snap.recentTx.isEmpty {
                Text(snap.labelNoTx).font(.caption2).foregroundStyle(.white.opacity(0.6))
            } else {
                ForEach(Array(snap.recentTx.prefix(2).enumerated()), id: \.offset) { _, tx in
                    TxRow(tx: tx).font(.caption2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TxRow: View {
    let tx: WidgetTx
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: tx.received ? "arrow.down" : "arrow.up")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tx.received ? .green : .orange)
            Text((tx.received ? "+" : "-") + prlAmountString(tx.amount, maxFrac: 4))
                .foregroundStyle(.white).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 2)
            Text(tx.time, style: .relative).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
        }
    }
}

#Preview(as: .systemMedium) { PearlWidget() } timeline: { PearlEntry(date: Date(), snap: .demo) }
