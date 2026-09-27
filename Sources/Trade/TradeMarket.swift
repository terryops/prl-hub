import SwiftUI
import Charts

// MARK: - Market price + candlestick K-line

struct MarketSection: View {
    @ObservedObject var store: SafeTradeStore
    @ObservedObject private var live = PriceLiveActivity.shared
    @ObservedObject private var pro = ProStore.shared

    /// Change shown next to the price, following the chart's period picker: the
    /// rolling change over the last 5 min / 15 min / 1 h / 4 h (from 1-minute
    /// candles), and the exchange's own rolling 24h change for 1日.
    private var periodChange: String? {
        if store.period == 1440 { return store.ticker?.price_change_percent }
        guard let now = store.ticker?.last.flatMap(Double.init) ?? store.minuteCandles.last?.close,
              let pct = store.rollingChange(minutes: store.period, price: now) else { return nil }
        return String(format: "%+.2f%%", pct)
    }

    var body: some View {
        let t = store.ticker
        let chg = periodChange
        let down = (chg ?? "").hasPrefix("-")
        VStack(alignment: .leading, spacing: Pearl.Space.md) {
            HStack {
                Text("PRL/USDT").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if PriceLiveActivity.supported { liveButton }
            }
            .padding(.bottom, -Pearl.Space.sm)
            HStack(alignment: .top, spacing: Pearl.Space.md) {
                VStack(alignment: .leading, spacing: Pearl.Space.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Pearl.Space.xs) {
                        Text(t?.last ?? "—")
                            .font(.system(.title, design: .rounded).weight(.bold)).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.5)
                            .contentTransition(.numericText())
                        // 24h change in the same green/red the candles use — a third
                        // colour pair (teal/rose) next to the chart just looked wrong.
                        if let chg {
                            Text(chg).font(.subheadline.weight(.semibold).monospacedDigit())
                                .foregroundStyle(down ? Color.red : Color.green)
                                .contentTransition(.numericText())
                                .animation(.snappy, value: chg)
                        }
                    }
                }
                Spacer(minLength: Pearl.Space.sm)
                // 2×2 label/value grid instead of two run-on caption lines. SafeTrade's
                // `buy` is the price you buy at (best ask), `sell` the one you sell at.
                Grid(alignment: .trailing, horizontalSpacing: Pearl.Space.sm, verticalSpacing: 3) {
                    GridRow { tickerCell(Loc("高"), t?.high); tickerCell(Loc("买"), t?.buy) }
                    GridRow { tickerCell(Loc("低"), t?.low);  tickerCell(Loc("卖"), t?.sell) }
                }
                .fixedSize()
            }

            // Full card width on its own row: sharing the row with the 锁屏盯盘 button
            // (both fixed-size) made it wider than a phone and pushed the whole
            // screen past its margins.
            Picker(Loc("周期"), selection: Binding(get: { store.period }, set: { store.setPeriod($0) })) {
                Text(Loc("5分")).tag(5); Text(Loc("15分")).tag(15); Text(Loc("1时")).tag(60); Text(Loc("4时")).tag(240); Text(Loc("1日")).tag(1440)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.small)

            if let e = live.error {
                Text(e).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CandleChart(candles: store.candles)
        }
        .pearlCard()
    }

    /// 锁屏盯盘 toggle (Pro). Without Pro it opens the upgrade sheet instead.
    private var liveButton: some View {
        Button {
            guard pro.isPro else { UpsellPrompt.shared.showing = true; return }
            Task { if live.running { await live.stop() } else { await live.start() } }
        } label: {
            HStack(spacing: 4) {
                if live.running {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text(Loc("盯盘中"))
                } else {
                    Image(systemName: "lock.iphone")
                    Text(Loc("锁屏盯盘"))
                }
            }
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.borderless)
        .tint(live.running ? .green : Pearl.accent)
        .fixedSize()
    }

    @ViewBuilder private func tickerCell(_ label: String, _ value: String?) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.tertiary)
            Text(value ?? "—").foregroundStyle(.secondary).monospacedDigit()
        }
        .font(.caption)
        .gridColumnAlignment(.trailing)
    }
}

#if os(iOS)
/// UIKit long-press → scrub for the K-line crosshair. A SwiftUI gesture on the chart
/// (a zero-distance drag, and even a LongPress→Drag sequence) swallowed every swipe that
/// began on the chart, so the page wouldn't scroll there. UILongPressGestureRecognizer
/// fails as soon as the finger moves before 0.2 s, handing the touch to the enclosing
/// scroll view; once it has begun, the drag moves only the crosshair.
private struct HoldToScrub: UIViewRepresentable {
    var onChange: (CGPoint?) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let g = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        g.minimumPressDuration = 0.2
        v.addGestureRecognizer(g)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.onChange = onChange }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    @MainActor final class Coordinator: NSObject {
        var onChange: (CGPoint?) -> Void
        init(onChange: @escaping (CGPoint?) -> Void) { self.onChange = onChange }

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began, .changed: onChange(g.location(in: g.view))
            default: onChange(nil)
            }
        }
    }
}
#endif

struct CandleChart: View {
    let candles: [STCandle]
    @State private var selected: STCandle?
    @Environment(\.colorScheme) private var scheme

    /// Minutes between candles, read from the data itself so the axis always matches what
    /// is drawn (the period picker can change a beat before the new candles arrive).
    private var candleMinutes: Double {
        guard candles.count >= 2 else { return 1440 }
        return abs(candles[1].time.timeIntervalSince(candles[0].time)) / 60
    }

    /// Time labels fine enough that the ~4 ticks differ: 5-min candles span ~10 h and
    /// 15-min ~30 h (times),
    /// hourly ~5 days (one tick per day, date only), 4-hour / daily candles weeks to months
    /// (dates).
    private var timeAxisFormat: Date.FormatStyle {
        switch candleMinutes {
        case ..<30:  return .dateTime.hour().minute()
        case ..<120: return .dateTime.month(.defaultDigits).day()
        default:     return .dateTime.month(.abbreviated).day()
        }
    }

    /// Hourly candles get a fixed midnight tick per day. The automatic ticks landed on
    /// midnight anyway, and "9/14, 12 AM" ×5 overflowed an iPhone-width axis and overlapped.
    private var dailyTicks: Bool { (30..<120).contains(candleMinutes) }

    /// Enough decimals that neighbouring price ticks (~¼ of the visible range apart) never
    /// print the same label — a sub-dollar coin can move less than a cent in a window.
    private func priceFractionDigits(lo: Double, hi: Double) -> Int {
        let step = max(hi - lo, 0.0001) / 4
        return min(6, max(2, Int(ceil(-log10(step)))))
    }

    var body: some View {
        if candles.isEmpty {
            Text(Loc("加载 K 线…")).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 260, maxHeight: 260)
        } else {
            let lo = candles.map(\.low).min() ?? 0
            let hi = candles.map(\.high).max() ?? 1
            let pad = max((hi - lo) * 0.08, 0.0001)
            let priceDigits = priceFractionDigits(lo: lo, hi: hi)
            Chart {
                ForEach(candles) { c in
                    RuleMark(x: .value("时间", c.time),
                             yStart: .value("低", c.low), yEnd: .value("高", c.high))
                        .foregroundStyle(c.up ? Color.green : Color.red)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    // A doji (open == close) still needs a visible body: pad it to a hairline.
                    RectangleMark(x: .value("时间", c.time),
                                  yStart: .value("开", c.open),
                                  yEnd: .value("收", c.close == c.open ? c.close + (hi - lo) * 0.002 : c.close),
                                  width: .fixed(4))
                        .foregroundStyle(c.up ? Color.green : Color.red)
                        .cornerRadius(1)
                }
                // Crosshair + OHLC tooltip following the cursor.
                if let sel = selected {
                    RuleMark(x: .value("时间", sel.time))
                        .foregroundStyle(Color.gray.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .center,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(sel)
                        }
                    PointMark(x: .value("时间", sel.time), y: .value("收", sel.close))
                        .symbolSize(45).foregroundStyle(sel.up ? Color.green : Color.red)
                }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            // Quiet axes: faint horizontal guides only, no vertical dashed lattice.
            // Labels are built explicitly so they can't inherit the app tint (a bare
            // AxisValueLabel picked up the accent blue on the date axis).
            .chartXAxis {
                if dailyTicks {
                    AxisMarks(values: .stride(by: .day)) { v in
                        AxisValueLabel {
                            if let d = v.as(Date.self) {
                                Text(d, format: timeAxisFormat)
                                    .font(.caption2).foregroundStyle(Color.secondary)
                            }
                        }
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 4)) { v in
                        AxisValueLabel {
                            if let d = v.as(Date.self) {
                                Text(d, format: timeAxisFormat)
                                    .font(.caption2).foregroundStyle(Color.secondary)
                            }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let y = v.as(Double.self) {
                            // Text(_:format:) formats with the app's locale from the environment.
                            // A concrete gray, not .secondary: inside these AxisMarks the hierarchical
                            // style resolves against the 6%-opacity grid line and the labels vanish.
                            Text(y, format: .number.precision(.fractionLength(priceDigits)))
                                .font(.caption2).foregroundStyle(Color.gray)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    #if os(macOS)
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc): select(candle(at: loc, proxy, geo))
                            case .ended: select(nil)
                            }
                        }
                    #else
                    // Press-and-hold (0.2 s) arms the crosshair, then drag to scrub; a plain
                    // swipe that starts on the chart scrolls the page. See HoldToScrub.
                    HoldToScrub { p in select(p.flatMap { candle(at: $0, proxy, geo) }) }
                    #endif
                }
            }
            .frame(height: 260)   // fixed so the chart doesn't stretch to fill the column
        }
    }

    /// Only touch `selected` when the candle under the cursor actually changes, so a drag
    /// doesn't re-render all 120 candles on every point it moves.
    private func select(_ c: STCandle?) {
        if c?.id != selected?.id { selected = c }
    }

    /// Nearest candle to the cursor's x-position.
    private func candle(at loc: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) -> STCandle? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = loc.x - geo[plot].origin.x
        guard x >= 0, x <= geo[plot].width, let date: Date = proxy.value(atX: x) else { return nil }
        return candles.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }

    @ViewBuilder private func tooltip(_ c: STCandle) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(c.time.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.weight(.semibold)).foregroundStyle(.primary)
            // 对齐成 2×2 网格，标签弱化、数值加粗，避免挤在一起看不清。
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    // Own keys: the bare "开"/"收" keys are the On-toggle and Receive
                    // strings elsewhere ("On" / "Receive" in English).
                    ohlc(Loc("开盘价"), pf(c.open), .primary)
                    ohlc(Loc("高"), pf(c.high), .green)
                }
                GridRow {
                    ohlc(Loc("低"), pf(c.low), .red)
                    ohlc(Loc("收盘价"), pf(c.close), c.up ? .green : .red)
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        // Opaque, scheme-matched surface so the tooltip always has strong contrast.
        // A translucent material let the (light) chart backdrop show through in 白天
        // mode and washed the OHLC labels out — use solid white in light / charcoal
        // in dark so .primary/.secondary text reads cleanly either way.
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(scheme == .dark ? Color(white: 0.16) : .white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .fixedSize()
    }

    @ViewBuilder private func ohlc(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(color)
        }
    }

    private func pf(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(2...6))) }
}
