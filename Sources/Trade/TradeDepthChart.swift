import SwiftUI
import Charts

// MARK: - 买卖深度图 (Pro)

/// The order-book depth card under the K-line. Pro draws the live book; everyone else
/// gets a dimmed illustrative shape with an unlock button — the paywall only ever opens
/// on that explicit tap (see UpsellPrompt for why nothing pops up on its own).
struct DepthSection: View {
    @ObservedObject var store: SafeTradeStore
    @ObservedObject private var pro = ProStore.shared
    @State private var showingPaywall = false

    private var curve: DepthCurve? { store.depth.flatMap(DepthCurve.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.md) {
            HStack(spacing: 6) {
                Text(Loc("买卖深度")).font(.subheadline.weight(.semibold))
                if !pro.isPro { PearlBadge(text: Loc("高级版"), systemImage: "sparkles") }
                Spacer(minLength: 0)
                if pro.isPro, store.depthStale {
                    Label(Loc("未能更新"), systemImage: "exclamationmark.arrow.circlepath")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            if pro.isPro { live } else { locked }
        }
        .pearlCard()
        // Poll the book only while the live chart is actually on screen.
        .onAppear { store.wantsDepthChart = pro.isPro }
        .onDisappear { store.wantsDepthChart = false }
        .onChange(of: pro.isPro) { _, isPro in store.wantsDepthChart = isPro }
        .sheet(isPresented: $showingPaywall) {
            ProUpsellSheet(headline: Loc("高级版功能：买卖深度图"), headlineIcon: "chart.bar.xaxis")
        }
    }

    // MARK: live (Pro)

    @ViewBuilder private var live: some View {
        if let curve {
            DepthSummary(curve: curve)
            DepthChart(curve: curve)
        } else {
            Text(store.depth == nil ? Loc("加载深度…") : Loc("暂无挂单"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: DepthChart.height, maxHeight: DepthChart.height)
        }
    }

    // MARK: locked (not Pro)

    /// An illustrative book — NOT market data — so the locked card shows what the
    /// feature looks like without giving it away.
    private static let sampleCurve: DepthCurve? = {
        func side(_ start: Double, _ step: Double, _ amounts: [Double]) -> [STBookLevel] {
            amounts.enumerated().map { STBookLevel(price: start + Double($0.offset) * step, amount: $0.element) }
        }
        return DepthCurve(STDepth(
            asks: side(1.01, 0.01, [9, 14, 6, 22, 11, 30, 8, 16, 41, 12, 19, 26, 9, 34, 15]),
            bids: side(0.99, -0.01, [12, 8, 25, 17, 33, 10, 21, 44, 14, 28, 9, 37, 18, 23, 30])))
    }()

    private var locked: some View {
        ZStack {
            Group {
                if let sample = Self.sampleCurve { DepthChart(curve: sample, interactive: false) }
            }
            .blur(radius: 3)
            .opacity(0.45)
            .accessibilityHidden(true)
            VStack(spacing: Pearl.Space.xs) {
                Image(systemName: "lock.fill").font(.title3).foregroundStyle(Pearl.accent)
                Text(Loc("买卖深度图是高级版功能"))
                    .font(.subheadline.weight(.semibold))
                Text(Loc("看清各价位的挂单量，以及买盘和卖盘谁更强"))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(Loc("解锁高级版")) { showingPaywall = true }
                    .buttonStyle(.pearl)
                    .fixedSize()
                    .padding(.top, Pearl.Space.xxs)
            }
            .padding(Pearl.Space.md)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Summary line

/// 买一 / 卖一 / 价差, and a bar weighing the bid side against the ask side of the
/// drawn window.
private struct DepthSummary: View {
    let curve: DepthCurve

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.xs) {
            HStack(spacing: Pearl.Space.md) {
                cell(Loc("买一"), curve.bestBid.map(price) ?? "—", .green)
                cell(Loc("卖一"), curve.bestAsk.map(price) ?? "—", .red)
                Spacer(minLength: 0)
                if let s = curve.spread, let pct = curve.spreadPercent {
                    cell(Loc("价差"), price(s) + String(format: " (%.2f%%)", pct), .secondary)
                }
            }
            if let share = curve.bidShare {
                VStack(spacing: 3) {
                    GeometryReader { g in
                        HStack(spacing: 2) {
                            Capsule().fill(Color.green.opacity(0.75))
                                .frame(width: max(2, (g.size.width - 2) * share))
                            Capsule().fill(Color.red.opacity(0.75))
                        }
                    }
                    .frame(height: 5)
                    HStack {
                        Text(Loc("买盘 %@", amount(curve.bidTotal))).foregroundStyle(.green)
                        Spacer()
                        Text(Loc("中间价 ±%@ 以内", String(format: "%.0f%%", (curve.hi / curve.mid - 1) * 100)))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(Loc("卖盘 %@", amount(curve.askTotal))).foregroundStyle(.red)
                    }
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.8)
                }
            }
        }
    }

    @ViewBuilder private func cell(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value).foregroundStyle(color).monospacedDigit()
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func price(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(2...4)).locale(LocBundleHolder.shared.locale))
    }

    private func amount(_ v: Double) -> String {
        v.formatted(.number.notation(.compactName).precision(.significantDigits(1...3))
            .locale(LocBundleHolder.shared.locale)) + " PRL"
    }
}

// MARK: - Chart

/// Cumulative depth: bids pile up leftwards from the best bid, asks rightwards from the
/// best ask, as stepped areas in the K-line's green / red. Press-and-hold (iPhone) or
/// hover (Mac) reads out a level: price, PRL through it, and what that PRL is worth.
struct DepthChart: View {
    let curve: DepthCurve
    var interactive = true
    static let height: CGFloat = 220

    @State private var selected: Selection?
    @Environment(\.colorScheme) private var scheme

    private struct Selection: Equatable {
        let side: DepthCurve.Side
        let point: DepthPoint
    }

    private struct Plotted: Identifiable {
        let price: Double
        let cumulative: Double
        var id: Double { price }
    }

    /// Ascending price for plotting. Bids start at the window's left edge with the whole
    /// in-window total; `.stepStart` then holds each level's total from the level to its
    /// left up to its own price, dropping to the next level's total just past it.
    private var bidSeries: [Plotted] {
        guard let far = curve.bids.last else { return [] }
        return [Plotted(price: curve.lo, cumulative: far.cumulative)]
            + curve.bids.reversed().map { Plotted(price: $0.price, cumulative: $0.cumulative) }
    }

    /// Asks from the best ask out to the right edge; `.stepEnd` holds each level's
    /// total until the next level's price.
    private var askSeries: [Plotted] {
        guard let far = curve.asks.last else { return [] }
        return curve.asks.map { Plotted(price: $0.price, cumulative: $0.cumulative) }
            + [Plotted(price: curve.hi, cumulative: far.cumulative)]
    }

    /// Price labels with enough decimals that the ~4 ticks never print the same text.
    private var priceDigits: Int {
        let step = max(curve.hi - curve.lo, 0.0001) / 4
        return min(6, max(2, Int(ceil(-log10(step)))))
    }

    var body: some View {
        Chart {
            ForEach(bidSeries) { p in
                AreaMark(x: .value("价格", p.price), y: .value("累计", p.cumulative),
                         series: .value("盘", "bid"), stacking: .unstacked)
                    .interpolationMethod(.stepStart)
                    .foregroundStyle(fill(.green))
                LineMark(x: .value("价格", p.price), y: .value("累计", p.cumulative),
                         series: .value("盘", "bidLine"))
                    .interpolationMethod(.stepStart)
                    .foregroundStyle(Color.green)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(askSeries) { p in
                AreaMark(x: .value("价格", p.price), y: .value("累计", p.cumulative),
                         series: .value("盘", "ask"), stacking: .unstacked)
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(fill(.red))
                LineMark(x: .value("价格", p.price), y: .value("累计", p.cumulative),
                         series: .value("盘", "askLine"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(Color.red)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            // Mid price.
            RuleMark(x: .value("中间价", curve.mid))
                .foregroundStyle(Color.gray.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if let sel = selected {
                let color = sel.side == .bid ? Color.green : Color.red
                RuleMark(x: .value("价格", sel.point.price))
                    .foregroundStyle(Color.gray.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    // Kept inside the chart's own frame: above it sits the summary line.
                    .annotation(position: .top, alignment: .center,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        tooltip(sel)
                    }
                PointMark(x: .value("价格", sel.point.price), y: .value("累计", sel.point.cumulative))
                    .symbolSize(45).foregroundStyle(color)
            }
        }
        .chartXScale(domain: curve.lo...curve.hi)
        .chartYScale(domain: 0...max(curve.maxCumulative * 1.1, 1))
        // Same quiet axes as the K-line: explicit, untinted labels; faint guides only.
        // Price labels are centred ON their value (`.aligned`): the default hangs them to
        // the right of it, which read as the mid line sitting at the wrong price.
        .chartXAxis {
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { v in
                AxisTick(length: 3).foregroundStyle(Color.gray.opacity(0.5))
                AxisValueLabel {
                    if let x = v.as(Double.self) {
                        Text(x, format: .number.precision(.fractionLength(priceDigits)))
                            .font(.caption2).foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let y = v.as(Double.self) {
                        // Concrete gray: see CandleChart — .secondary vanishes against the grid.
                        Text(y, format: .number.notation(.compactName).precision(.significantDigits(1...3)))
                            .font(.caption2).foregroundStyle(Color.gray)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            if interactive {
                GeometryReader { geo in
                    #if os(macOS)
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc): select(level(at: loc, proxy, geo))
                            case .ended: select(nil)
                            }
                        }
                    #else
                    HoldToScrub { p in select(p.flatMap { level(at: $0, proxy, geo) }) }
                    #endif
                }
            }
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Loc("买卖深度"))
        .accessibilityValue(Loc("买盘 %@", "\(Int(curve.bidTotal)) PRL") + ", " + Loc("卖盘 %@", "\(Int(curve.askTotal)) PRL"))
    }

    private func fill(_ c: Color) -> LinearGradient {
        LinearGradient(colors: [c.opacity(0.32), c.opacity(0.06)], startPoint: .top, endPoint: .bottom)
    }

    /// Only touch `selected` when the level under the cursor changes.
    private func select(_ s: Selection?) {
        if s != selected { selected = s }
    }

    private func level(at loc: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) -> Selection? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = loc.x - geo[plot].origin.x
        guard x >= 0, x <= geo[plot].width, let price: Double = proxy.value(atX: x),
              let hit = curve.level(near: price) else { return nil }
        return Selection(side: hit.side, point: hit.point)
    }

    @ViewBuilder private func tooltip(_ s: Selection) -> some View {
        let color = s.side == .bid ? Color.green : Color.red
        VStack(alignment: .leading, spacing: 5) {
            Text(s.side == .bid ? Loc("买盘") : Loc("卖盘"))
                .font(.caption.weight(.semibold)).foregroundStyle(color)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                row(Loc("价格"), num(s.point.price, digits: 2...6) + " USDT")
                row(Loc("累计数量"), num(s.point.cumulative, digits: 0...2) + " PRL")
                row(Loc("累计金额"), num(s.point.cumulativeValue, digits: 0...2) + " USDT")
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        // Opaque, scheme-matched surface — same reasoning as the K-line tooltip.
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(scheme == .dark ? Color(white: 0.16) : .white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .fixedSize()
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.primary)
        }
    }

    private func num(_ v: Double, digits: ClosedRange<Int>) -> String {
        v.formatted(.number.precision(.fractionLength(digits)).locale(LocBundleHolder.shared.locale))
    }
}
