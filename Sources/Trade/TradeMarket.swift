import SwiftUI
import Charts
#if os(macOS)
import AppKit
#endif

// MARK: - Market price + candlestick K-line

extension SafeTradeStore {
    /// Change shown next to the price, following the chart's period picker: the
    /// rolling change over the last 5 min / 15 min / 1 h / 4 h (from 1-minute
    /// candles), and the exchange's own rolling 24h change for 1日.
    var periodChange: String? {
        if period == 1440 { return ticker?.price_change_percent }
        guard let now = ticker?.last.flatMap(Double.init) ?? minuteCandles.last?.close,
              let pct = rollingChange(minutes: period, price: now) else { return nil }
        return String(format: "%+.2f%%", pct)
    }
}

struct MarketSection: View {
    @ObservedObject var store: SafeTradeStore
    @ObservedObject private var live = PriceLiveActivity.shared
    @ObservedObject private var pro = ProStore.shared
    @Environment(\.colorScheme) private var scheme
    @State private var fullScreen = false

    var body: some View {
        let t = store.ticker
        let chg = store.periodChange
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
                            // One line: beside the longer labels of some languages
                            // ("Verkauf") the "%" used to drop to a line of its own.
                            Text(chg).font(.subheadline.weight(.semibold).monospacedDigit())
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .foregroundStyle(CandleChart.directionColor(up: !down, scheme: scheme))
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

            // Nearly the full card width: sharing the row with the 锁屏盯盘 button (both
            // fixed-size) made it wider than a phone and pushed the whole screen past its
            // margins. The full-screen button beside it is only an icon wide.
            HStack(spacing: Pearl.Space.xs) {
                CandlePeriodPicker(store: store)
                Button { CandleFullScreen.show($fullScreen, true) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).tint(Pearl.accent)
                .help(Loc("全屏")).accessibilityLabel(Loc("全屏"))
                .accessibilityIdentifier("candle-fullscreen")
            }

            if let e = live.error {
                Text(e).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            CandleChart(candles: store.candles)
        }
        .pearlCard()
        // macOS has no full-screen cover: a large sheet over the window instead.
        #if os(iOS)
        .fullScreenCover(isPresented: $fullScreen) { CandleFullScreen(store: store, isPresented: $fullScreen) }
        #else
        .sheet(isPresented: $fullScreen) { CandleFullScreen(store: store, isPresented: $fullScreen) }
        #endif
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

/// 5分 … 1日, for the card and the full-screen chart alike.
struct CandlePeriodPicker: View {
    @ObservedObject var store: SafeTradeStore

    var body: some View {
        Picker(Loc("周期"), selection: Binding(get: { store.period }, set: { store.setPeriod($0) })) {
            Text(Loc("5分")).tag(5); Text(Loc("15分")).tag(15); Text(Loc("1时")).tag(60); Text(Loc("4时")).tag(240); Text(Loc("1日")).tag(1440)
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
    }
}

/// The K-line and its volume with the whole screen to themselves (a large sheet on the
/// Mac): the price and the period picker above, the chart in all the room that's left.
/// A phone turns sideways for it, 锁定竖屏 or not (OrientationLock.chart). Zoom is the
/// card's (one stored count); panning starts again at the latest candle.
struct CandleFullScreen: View {
    @ObservedObject var store: SafeTradeStore
    @Binding var isPresented: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase

    /// Open or close it. A phone's cover doesn't slide: turning sideways (and back) is
    /// the transition. The Mac's sheet animates as usual.
    static func show(_ shown: Binding<Bool>, _ value: Bool) {
        #if os(iOS)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { shown.wrappedValue = value }
        #else
        shown.wrappedValue = value
        #endif
    }

    var body: some View {
        let chg = store.periodChange
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Pearl.Space.xs) {
                Text("PRL/USDT").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Text(store.ticker?.last ?? "—")
                    .font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())
                if let chg {
                    Text(chg).font(.subheadline.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .foregroundStyle(CandleChart.directionColor(up: !chg.hasPrefix("-"), scheme: scheme))
                }
                Spacer(minLength: Pearl.Space.xs)
                Button { Self.show($isPresented, false) } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.borderless).tint(Pearl.accent)
                .keyboardShortcut(.cancelAction)
                .help(Loc("关闭")).accessibilityLabel(Loc("关闭"))
                .accessibilityIdentifier("candle-fullscreen-close")
            }
            CandlePeriodPicker(store: store)
            GeometryReader { geo in
                CandleChart(candles: store.candles,
                            plotHeight: max(geo.size.height - CandleChart.chrome, 160))
            }
        }
        .padding(.horizontal, Pearl.Space.md)
        .padding(.vertical, Pearl.Space.sm)
        .pearlScreenBackground()
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 1000, minHeight: 520, idealHeight: 700)
        #else
        .onAppear { OrientationLock.chart(open: true) }
        .onDisappear { OrientationLock.chart(open: false) }
        // The cover takes the Trade tab off screen, and its 5 s poll with it: keep the
        // price moving here meanwhile (and retry candles that failed to load).
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await store.refreshTickerOnly()
            }
        }
        #endif
    }
}

#if os(iOS)
/// UIKit long-press → scrub for the K-line crosshair. A SwiftUI gesture on the chart
/// (a zero-distance drag, and even a LongPress→Drag sequence) swallowed every swipe that
/// began on the chart, so the page wouldn't scroll there. UILongPressGestureRecognizer
/// fails as soon as the finger moves before 0.2 s, handing the touch to the enclosing
/// scroll view; once it has begun, the drag moves only the crosshair. Shared with the
/// depth chart (TradeDepthChart).
struct HoldToScrub: UIViewRepresentable {
    var onChange: (CGPoint?) -> Void
    /// Two-finger pinch, for a chart that zooms (the K-line): the scale since the pinch
    /// began, then nil once the fingers lift. A pinch that has begun keeps the page still.
    var onPinch: ((CGFloat?) -> Void)? = nil
    /// One-finger sideways drag, for a chart that pans (the K-line): how far the finger
    /// has moved to the right since the drag began, then nil once it lifts. Only a drag
    /// that starts out more sideways than up-and-down is one; any other still scrolls
    /// the page.
    var onPan: ((CGFloat?) -> Void)? = nil

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .clear
        let g = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        g.minimumPressDuration = 0.2
        v.addGestureRecognizer(g)
        if onPinch != nil {
            v.addGestureRecognizer(UIPinchGestureRecognizer(target: context.coordinator,
                                                            action: #selector(Coordinator.pinch(_:))))
        }
        if onPan != nil {
            let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = context.coordinator
            v.addGestureRecognizer(pan)
        }
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onPinch = onPinch
        context.coordinator.onPan = onPan
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange, onPinch: onPinch, onPan: onPan) }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: (CGPoint?) -> Void
        var onPinch: ((CGFloat?) -> Void)?
        var onPan: ((CGFloat?) -> Void)?
        init(onChange: @escaping (CGPoint?) -> Void, onPinch: ((CGFloat?) -> Void)?, onPan: ((CGFloat?) -> Void)?) {
            self.onChange = onChange
            self.onPinch = onPinch
            self.onPan = onPan
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            switch g.state {
            case .began, .changed: onPan?(g.translation(in: g.view).x)
            default: onPan?(nil)
            }
        }

        /// The pan is ours only when it sets off sideways. Judged by how far the finger has
        /// come, not how fast: the velocity can still read zero at this point, which handed
        /// a sideways drag to the page (and nudged it up or down a few points).
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let pan = g as? UIPanGestureRecognizer else { return true }
            let moved = pan.translation(in: pan.view), v = pan.velocity(in: pan.view)
            return moved == .zero ? abs(v.x) > abs(v.y) : abs(moved.x) > abs(moved.y)
        }

        /// The page's own scrolling waits to hear which it is: without this the two
        /// recognizers race, and a sideways drag sometimes scrolled the page instead. A
        /// vertical swipe fails ours at once (above), so scrolling isn't held up.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            g is UIPanGestureRecognizer && other is UIPanGestureRecognizer && other.view is UIScrollView
        }

        @objc func handle(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began, .changed: onChange(g.location(in: g.view))
            default: onChange(nil)
            }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began, .changed: onPinch?(g.scale)
            default: onPinch?(nil)
            }
        }
    }
}
#endif

#if os(macOS)
/// Mouse-wheel zoom for the K-line. SwiftUI has no scroll-wheel gesture and the wheel
/// belongs to the page's scroll view, so a local event monitor picks out the turns made
/// with the pointer over this view and keeps them from scrolling the page. Only a real
/// wheel counts: a trackpad's two-finger scroll (and a Magic Mouse's) comes with exact
/// pixel deltas and still scrolls the page — a trackpad zooms by pinching.
struct WheelZoom: NSViewRepresentable {
    /// The lines one turn moved: positive rolling away from you.
    var onTurn: (Double) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = Anchor()
        context.coordinator.attach(to: v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onTurn = onTurn
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTurn: onTurn) }

    /// Only marks where the chart is: clicks, hovering and pinches go to the chart itself.
    private final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor final class Coordinator {
        var onTurn: (Double) -> Void
        private weak var view: NSView?
        private var monitor: Any?
        init(onTurn: @escaping (Double) -> Void) { self.onTurn = onTurn }

        func attach(to view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let wheel = !event.hasPreciseScrollingDeltas && event.phase.isEmpty && event.momentumPhase.isEmpty
                let lines = Double(event.scrollingDeltaY), at = event.locationInWindow, window = event.windowNumber
                guard wheel, lines != 0 else { return event }
                let taken = MainActor.assumeIsolated { self?.take(lines, at: at, window: window) ?? false }
                return taken ? nil : event
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when the pointer was over the chart — the part of it on screen, not what
        /// has scrolled away under the title bar — and the turn has been used. The bounds
        /// are checked themselves: views no longer clip, so `visibleRect` alone reaches
        /// past them, across the whole window.
        private func take(_ lines: Double, at point: NSPoint, window number: Int) -> Bool {
            guard let view, let window = view.window, window.windowNumber == number,
                  !view.isHiddenOrHasHiddenAncestor, window.contentLayoutRect.contains(point),
                  view.bounds.intersection(view.visibleRect).contains(view.convert(point, from: nil))
            else { return false }
            onTurn(lines)
            return true
        }
    }
}
#endif

/// Where the volume bars sit in the K-line's own plot: a band under the price range,
/// measured in price units. One chart then draws both, so the bars line up with their
/// candles and share the crosshair — two stacked charts only align while their y-axis
/// labels happen to be equally wide.
struct CandleVolumeBand: Equatable {
    /// The band's share of the plot height, and the tallest bar's share of the band
    /// (the rest is the row the band's caption sits in).
    static let share = 0.2, barShare = 0.72

    /// Bottom of the plot — where every bar starts.
    let floor: Double
    /// Top of the band — the bottom of the price range.
    let ceiling: Double
    let maxVolume: Double

    init(priceLow: Double, priceHigh: Double, maxVolume: Double) {
        ceiling = priceLow
        floor = priceLow - (priceHigh - priceLow) * Self.share / (1 - Self.share)
        self.maxVolume = max(maxVolume, 0)
    }

    /// y of the top of a bar for `volume`.
    func top(_ volume: Double) -> Double {
        guard maxVolume > 0 else { return floor }
        return floor + (ceiling - floor) * Self.barShare * min(max(volume, 0) / maxVolume, 1)
    }
}

struct CandleChart: View {
    let candles: [STCandle]
    /// Fixed so the chart doesn't stretch to fill the column; the loading placeholder
    /// takes the same height, so the card doesn't jump when the candles land. The
    /// full-screen chart passes the room it has.
    var plotHeight: CGFloat = 320
    /// What the chart adds above the plot: the zoom buttons' row on the Mac.
    #if os(macOS)
    static let chrome: CGFloat = 30
    #else
    static let chrome: CGFloat = 0
    #endif
    private var height: CGFloat { plotHeight + Self.chrome }
    /// How many of the latest candles are drawn. Pinching the chart changes it (on the Mac
    /// a mouse wheel does too, and there is a pair of buttons); it used to be a 30 / 60 / 120 picker.
    @AppStorage("safetrade.candleCount") private var visibleCount = 60
    /// The count a pinch started from; nil between pinches.
    @State private var pinchStart: Int?
    /// Candles hidden past the right edge: 0 ends the chart at the latest one, and dragging
    /// the chart to the right brings older ones in. Not kept between visits.
    @State private var hidden = 0
    /// `hidden` when a drag started; nil between drags.
    @State private var panStart: Int?
    @State private var selected: STCandle?
    @Environment(\.colorScheme) private var scheme

    /// The closest zoom: fewer candles than this are just wide blocks.
    static let minVisible = 20

    private var shownCount: Int { Self.zoomedCount(from: visibleCount, scale: 1, loaded: candles.count) }
    private var shownHidden: Int { Self.pannedOffset(from: hidden, by: 0, plotWidth: 1, shown: shownCount, loaded: candles.count) }
    private var displayedCandles: [STCandle] {
        Array(candles[Self.window(loaded: candles.count, shown: shownCount, hidden: shownHidden)])
    }

    /// The candles on screen: `shown` of them, ending `hidden` short of the latest.
    nonisolated static func window(loaded: Int, shown: Int, hidden: Int) -> Range<Int> {
        let end = min(max(loaded - max(hidden, 0), 0), loaded)
        return max(end - max(shown, 0), 0)..<end
    }

    /// `start` candles hidden, after the chart has been dragged `translation` points to the
    /// right (a candle's width at a time): the chart follows the finger, so older candles
    /// come in from the left — as far back as is loaded, and forward to the latest again.
    nonisolated static func pannedOffset(from start: Int, by translation: Double, plotWidth: Double, shown: Int, loaded: Int) -> Int {
        let most = max(loaded - shown, 0)
        guard translation.isFinite, plotWidth > 0, shown > 0 else { return min(max(start, 0), most) }
        let moved = (translation / (plotWidth / Double(shown))).rounded()
        return min(max(start + Int(max(min(moved, 1e6), -1e6)), 0), most)
    }

    /// A drag in progress (`translation` to the right since it began), or its end (nil).
    private func pan(_ translation: Double?, plotWidth: Double) {
        guard let translation else { panStart = nil; return }
        let start = panStart ?? shownHidden
        if panStart == nil { panStart = start; select(nil) }
        let next = Self.pannedOffset(from: start, by: translation, plotWidth: plotWidth, shown: shownCount, loaded: candles.count)
        if next != hidden { hidden = next }
    }

    /// `count` candles seen `scale` times larger: spreading two fingers (scale > 1) leaves
    /// fewer, wider candles; pinching brings in more, up to every one that is loaded.
    nonisolated static func zoomedCount(from count: Int, scale: Double, loaded: Int) -> Int {
        let most = max(loaded, minVisible)
        guard scale.isFinite, scale > 0 else { return min(max(count, minVisible), most) }
        return min(max(Int((Double(count) / scale).rounded()), minVisible), most)
    }

    /// A pinch in progress (`scale` since it began), or its end (nil).
    private func pinch(_ scale: Double?) {
        guard let scale else { pinchStart = nil; return }
        let start = pinchStart ?? shownCount
        if pinchStart == nil { pinchStart = start }
        zoom(to: Self.zoomedCount(from: start, scale: scale, loaded: candles.count))
    }

    private func zoom(to count: Int) {
        if count != visibleCount { visibleCount = count }
    }

    /// One turn of a mouse wheel as a pinch's scale: 15% a notch, rolling away from you
    /// to zoom in. A slow notch can arrive as a fraction of a line and a fast spin as
    /// many at once, so any turn is at least one notch and at most three.
    nonisolated static func wheelScale(lines: Double) -> Double {
        guard lines.isFinite, lines != 0 else { return 1 }
        let notches = min(max(abs(lines).rounded(.up), 1), 3)
        return pow(1.15, lines > 0 ? notches : -notches)
    }

    #if os(macOS)
    private func wheel(_ lines: Double) {
        zoom(to: Self.zoomedCount(from: shownCount, scale: Self.wheelScale(lines: lines), loaded: candles.count))
    }
    #endif

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
        case ..<120: return dailyTicks ? .dateTime.month(.defaultDigits).day() : .dateTime.hour().minute()
        default:     return .dateTime.month(.abbreviated).day()
        }
    }

    /// Hourly candles get a fixed midnight tick per day. The automatic ticks landed on
    /// midnight anyway, and "9/14, 12 AM" ×5 overflowed an iPhone-width axis and overlapped.
    /// Zoomed in to under a day and a half there may be no midnight to mark at all, so
    /// that close the axis shows times instead.
    private var dailyTicks: Bool {
        guard (30..<120).contains(candleMinutes),
              let first = displayedCandles.first, let last = displayedCandles.last else { return false }
        return last.time.timeIntervalSince(first.time) >= 36 * 3600
    }

    /// Enough decimals that neighbouring price ticks (~¼ of the visible range apart) never
    /// print the same label — a sub-dollar coin can move less than a cent in a window.
    private func priceFractionDigits(lo: Double, hi: Double) -> Int {
        let step = max(hi - lo, 0.0001) / 4
        return min(6, max(2, Int(ceil(-log10(step)))))
    }

    /// Both bodies and volume use the same 70% time slot. A fixed body width
    /// overlaps neighbouring candles on a phone and loses the gaps between them.
    private var barHalfWidth: TimeInterval {
        let gaps = zip(candles.dropFirst(), candles)
            .map { $0.time.timeIntervalSince($1.time) }.filter { $0 > 0 }
        return (gaps.min() ?? 86400) * 0.35
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(macOS)
            HStack { Spacer(); zoomButtons }
                .frame(height: 22)
            #endif
            plot.overlay(alignment: .topLeading) { countHandle }
        }
        .frame(height: height)
        .onChange(of: visibleCount) { _, _ in select(nil) }
        .onChange(of: candles) { _, _ in select(nil) }
        // Another period is another series: start again from its latest candle.
        .onChange(of: candleMinutes) { _, _ in hidden = 0 }
    }

    /// VoiceOver can't pinch: an unseen caption over the plot reads the count and adjusts it.
    /// The visible "K 线" title was redundant under the period picker.
    private var countHandle: some View {
        Text(Loc("K 线")).font(.caption).foregroundStyle(.clear)
            .allowsHitTesting(false)
            .accessibilityValue(shownCount.formatted())
            .accessibilityAdjustableAction { step(out: $0 == .increment) }
            .accessibilityIdentifier("candle-count")
    }

    /// One step of the buttons / VoiceOver: half as many candles again, or a third fewer.
    private func step(out: Bool) {
        zoom(to: Self.zoomedCount(from: shownCount, scale: out ? 1 / 1.5 : 1.5, loaded: candles.count))
    }

    #if os(macOS)
    private var zoomButtons: some View {
        HStack(spacing: 6) {
            Button { step(out: true) } label: { Image(systemName: "minus.magnifyingglass") }
                .help(Loc("缩小")).accessibilityLabel(Loc("缩小"))
                .disabled(shownCount >= max(candles.count, Self.minVisible))
            Button { step(out: false) } label: { Image(systemName: "plus.magnifyingglass") }
                .help(Loc("放大")).accessibilityLabel(Loc("放大"))
                .disabled(shownCount <= Self.minVisible)
        }
        .buttonStyle(.borderless).foregroundStyle(axisColor)
    }
    #endif

    @ViewBuilder private var plot: some View {
        if candles.isEmpty {
            Text(Loc("加载 K 线…")).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: plotHeight, maxHeight: plotHeight)
        } else {
            let lo = displayedCandles.map(\.low).min() ?? 0
            let hi = displayedCandles.map(\.high).max() ?? 1
            let pad = max((hi - lo) * 0.08, 0.0001)
            let priceDigits = priceFractionDigits(lo: lo, hi: hi)
            let band = CandleVolumeBand(priceLow: lo - pad, priceHigh: hi + pad,
                                        maxVolume: displayedCandles.map(\.volume).max() ?? 0)
            let halfBar = barHalfWidth
            // Keep flat and very small bodies readable, including an entirely flat
            // series. The old doji padding became zero when high == low.
            let minimumBody = (hi + pad - band.floor) / (plotHeight - 24) * 1.5
            Chart {
                ForEach(displayedCandles) { c in
                    let color = Self.directionColor(up: c.up, scheme: scheme)
                    let middle = (c.open + c.close) / 2
                    let bodyHeight = max(abs(c.close - c.open), minimumBody)
                    RectangleMark(xStart: .value("时间", c.time.addingTimeInterval(-halfBar)),
                                  xEnd: .value("时间", c.time.addingTimeInterval(halfBar)),
                                  yStart: .value("量", band.floor), yEnd: .value("量", band.top(c.volume)))
                        .foregroundStyle(color.opacity(0.65))
                    RuleMark(x: .value("时间", c.time),
                             yStart: .value("低", c.low), yEnd: .value("高", c.high))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    RectangleMark(xStart: .value("时间", c.time.addingTimeInterval(-halfBar)),
                                  xEnd: .value("时间", c.time.addingTimeInterval(halfBar)),
                                  yStart: .value("开", middle - bodyHeight / 2),
                                  yEnd: .value("收", middle + bodyHeight / 2))
                        .foregroundStyle(color)
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
                        .symbolSize(35).foregroundStyle(Self.directionColor(up: sel.up, scheme: scheme))
                }
            }
            .chartYScale(domain: band.floor...(hi + pad))
            // Quiet axes: faint horizontal guides only, no vertical dashed lattice.
            // Labels are built explicitly so they can't inherit the app tint (a bare
            // AxisValueLabel picked up the accent blue on the date axis).
            .chartXAxis {
                if dailyTicks {
                    AxisMarks(values: .stride(by: .day)) { v in
                        AxisValueLabel {
                            if let d = v.as(Date.self) {
                                Text(d, format: timeAxisFormat)
                                    .font(.caption2.monospacedDigit()).foregroundStyle(axisColor)
                            }
                        }
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 4)) { v in
                        AxisValueLabel {
                            if let d = v.as(Date.self) {
                                Text(d, format: timeAxisFormat)
                                    .font(.caption2.monospacedDigit()).foregroundStyle(axisColor)
                            }
                        }
                    }
                }
            }
            .chartYAxis {
                // Price ticks only: the automatic ones that land in the volume band (whose
                // y is a price that means nothing there) are left out.
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 7)) { v in
                    if let y = v.as(Double.self), y >= band.ceiling {
                        AxisGridLine().foregroundStyle(Color.primary.opacity(scheme == .dark ? 0.14 : 0.1))
                        AxisValueLabel {
                            // Explicit text colour stays readable independently of the grid style.
                            Text(y, format: .number.precision(.fractionLength(priceDigits)))
                                .font(.caption2.monospacedDigit()).foregroundStyle(axisColor)
                        }
                    }
                }
                // The band's one label: the volume of its tallest bar, level with that bar's top.
                if band.maxVolume > 0 {
                    AxisMarks(position: .trailing, values: [band.top(band.maxVolume)]) { _ in
                        AxisValueLabel {
                            Text(Self.compactVolume(band.maxVolume)).font(.caption2.monospacedDigit()).foregroundStyle(axisColor)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    // The band's caption, in the row the bars leave free above them. It
                    // follows the crosshair, and shows the latest candle otherwise.
                    if let plot = proxy.plotFrame, let y = proxy.position(forY: band.ceiling),
                       let c = selected ?? displayedCandles.last {
                        volumeCaption(c)
                            .offset(x: geo[plot].minX, y: geo[plot].minY + y)
                            .allowsHitTesting(false)
                    }
                    #if os(macOS)
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        // A mouse wheel turned over the chart zooms it. See WheelZoom.
                        .background(WheelZoom { wheel($0) })
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc): select(candle(at: loc, proxy, geo))
                            case .ended: select(nil)
                            }
                        }
                        // Trackpad pinch.
                        .gesture(MagnifyGesture()
                            .onChanged { pinch($0.magnification) }
                            .onEnded { _ in pinch(nil) })
                        // Click and drag sideways to pan.
                        .simultaneousGesture(DragGesture(minimumDistance: 4)
                            .onChanged { pan($0.translation.width, plotWidth: plotWidth(proxy, geo)) }
                            .onEnded { _ in pan(nil, plotWidth: 0) })
                    #else
                    // Press-and-hold (0.2 s) arms the crosshair, then drag to scrub; a plain
                    // up-or-down swipe that starts on the chart scrolls the page, a sideways
                    // one pans the candles; two fingers pinch to zoom. See HoldToScrub.
                    HoldToScrub(onChange: { p in select(p.flatMap { candle(at: $0, proxy, geo) }) },
                                onPinch: { pinch($0.map(Double.init)) },
                                onPan: { pan($0.map(Double.init), plotWidth: plotWidth(proxy, geo)) })
                    #endif
                }
            }
            .frame(height: plotHeight)
            .accessibilityIdentifier("candle-chart")
        }
    }

    private var axisColor: Color { Color(white: scheme == .dark ? 0.7 : 0.38) }

    /// Bodies, wicks and price readouts. System green is too pale on a white chart and a
    /// deep forest green / crimson read as dull, so daylight gets a clear emerald and a
    /// bright red, with lighter equivalents at night.
    static func directionColor(up: Bool, scheme: ColorScheme) -> Color {
        if scheme == .dark {
            return up ? Color(red: 0.15, green: 0.87, blue: 0.59)   // #26DE96
                      : Color(red: 1.00, green: 0.33, blue: 0.41)   // #FF5469
        }
        return up ? Color(red: 0.06, green: 0.71, blue: 0.46)       // #0FB575
                  : Color(red: 0.95, green: 0.24, blue: 0.33)       // #F23D54
    }

    private func volumeCaption(_ c: STCandle) -> some View {
        HStack(spacing: 4) {
            Text(Loc("成交量")).foregroundStyle(axisColor)
            Text(Self.compactVolume(c.volume) + " PRL").foregroundStyle(axisColor).monospacedDigit()
        }
        .font(.caption2)
        .lineLimit(1)
    }

    /// Only touch `selected` when the candle under the cursor actually changes, so a drag
    /// doesn't re-render all 120 candles on every point it moves.
    private func select(_ c: STCandle?) {
        if c?.id != selected?.id { selected = c }
    }

    private func plotWidth(_ proxy: ChartProxy, _ geo: GeometryProxy) -> Double {
        Double(proxy.plotFrame.map { geo[$0].width } ?? geo.size.width)
    }

    /// Nearest candle to the cursor's x-position.
    private func candle(at loc: CGPoint, _ proxy: ChartProxy, _ geo: GeometryProxy) -> STCandle? {
        guard let plot = proxy.plotFrame else { return nil }
        let x = loc.x - geo[plot].origin.x
        guard x >= 0, x <= geo[plot].width, let date: Date = proxy.value(atX: x) else { return nil }
        return displayedCandles.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }

    @ViewBuilder private func tooltip(_ c: STCandle) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Text(_:format:) follows the app's language (environment locale), not the system's.
            Text(c.time, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                .font(.caption.weight(.semibold)).foregroundStyle(.primary)
            // 对齐成 2×2 网格，标签弱化、数值加粗，避免挤在一起看不清。
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    // Own keys: the bare "开"/"收" keys are the On-toggle and Receive
                    // strings elsewhere ("On" / "Receive" in English).
                    ohlc(Loc("开盘价"), pf(c.open), .primary)
                    ohlc(Loc("高"), pf(c.high), Self.directionColor(up: true, scheme: scheme))
                }
                GridRow {
                    ohlc(Loc("低"), pf(c.low), Self.directionColor(up: false, scheme: scheme))
                    ohlc(Loc("收盘价"), pf(c.close), Self.directionColor(up: c.up, scheme: scheme))
                }
                GridRow {
                    ohlc(Loc("成交量"), vf(c.volume) + " PRL", .primary).gridCellColumns(2)
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

    private func pf(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(2...6)).locale(LocBundleHolder.shared.locale))
    }

    /// A candle's volume in full (the k-line counts it in PRL, the base currency);
    /// decimals only while the number is small enough for them to matter.
    private func vf(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...(v < 100 ? 2 : 0))).locale(LocBundleHolder.shared.locale))
    }

    /// Compact volume ("45.7K", "3.56万") to three significant digits. Where the language
    /// has no unit for the magnitude — Chinese has none for thousands — that precision
    /// rounds whole digits away (4,567 came out as "4570", which reads as exact), so
    /// those keep every integer digit.
    nonisolated static func compactVolume(_ v: Double, locale: Locale = LocBundleHolder.shared.locale) -> String {
        let compact = FloatingPointFormatStyle<Double>.number.notation(.compactName).locale(locale)
        let whole = v.formatted(compact.precision(.fractionLength(0)))
        return whole.filter { ("0"..."9").contains($0) }.count > 3
            ? whole : v.formatted(compact.precision(.significantDigits(1...3)))
    }
}
