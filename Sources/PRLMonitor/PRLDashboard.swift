import SwiftUI
import Charts

// MARK: - 概览

struct DashboardSection: View {
    @ObservedObject var store: PRLStore
    @State private var trendMetric: MarketTrendCard.Metric? = nil   // nil = 趋势图收起；点卡片展开
    var body: some View {
        let c = store.cfg
        let fl = store.fleet()
        // Online data in yet? Manual mode shows its (intentional) values; live mode
        // stays blank until the first successful fetch — never a stale default.
        let ready = !store.live || store.liveReady
        ScrollView {
            VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                // 行情头部 + 刷新（单行紧凑：状态文字截断而非换行，避免在 iPhone 上撑高）
                marketHeader(c)

                StatGrid {
                    trendCard(.price) {
                        StatCard(title: Loc("PRL 币价"), value: ready ? "$" + f(c.price, 2) : "—",
                                 sub: store.live ? (ready ? Loc("SafeTrade 实时") : Loc("联网中…")) : Loc("手动"), color: .orange)
                    }
                    trendCard(.hashrate) {
                        StatCard(title: Loc("全网算力"), value: ready ? f(c.nethashEH, 2) + " EH/s" : "—",
                                 sub: !ready ? Loc("联网中…") : (c.hasDiffTrend ? Loc("近7天 %@ · 24h %@", pctSigned(c.diffChange(vs: c.diff7)), pctSigned(c.diffChange(vs: c.diff24))) : "Pearl matmul"),
                                 color: ready && c.hasDiffTrend && c.diffChange(vs: c.diff7) > 0 ? .orange : .primary)
                    }
                    trendCard(.perUnit) {
                        // Shown per P(=1000 TH)·day — same unit as the fleet total and the
                        // 实测每 P·天 row — so theory/measured are directly comparable. The model
                        // keeps perUnit per-TH (compute() uses g.pearl×perUnit), so ×1000 here only.
                        StatCard(title: Loc("单位日产"), value: ready ? f(c.perUnit * 1000, 2) : "—", sub: Loc("PRL/P·天"))
                    }
                    trendCard(.difficulty) {
                        StatCard(title: Loc("难度"), value: ready ? f(c.diffNow / 1e6, 2) + "M" : "—",
                                 sub: !ready ? Loc("联网中…") : Loc("挖矿难度"),
                                 color: ready && c.hasDiffTrend && c.diffChange(vs: c.diff7) > 0 ? .orange : .primary)
                    }
                }

                if let m = trendMetric {
                    MarketTrendCard(store: store, metric: Binding(get: { m }, set: { trendMetric = $0 }))
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // 全网走势：算力 + 难度 + 出块时间（Blockbook 区块采样）
                NetworkChartCard()

                Divider()
                PearlSectionHeader(Loc("每天的情况 · 我的全部设备"), systemImage: "rectangle.stack.fill",
                                   subtitle: Loc("%@ 台设备 · 共 %@ 张卡（自有 %@ · 租用 %@）· 总算力 %@", "\(store.devices.count)", "\(fl.cards)", "\(fl.ownCards)", "\(fl.rentedCards)", formatHashrate(fl.pearl * 1e12)))

                VStack(alignment: .leading, spacing: Pearl.Space.xs) {
                    Text(Loc("日净利 · 按设备估算（已扣电费）")).font(.headline).foregroundColor(.secondary)
                    if ready {
                        Text(store.localSymbol + " " + f(fl.netDay * c.fx, 1)).font(.system(.largeTitle, design: .rounded).weight(.heavy))
                            .foregroundColor(fl.netDay > 0 ? .green : .red).monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.5)
                        Text(store.sym(Loc("≈ $%@ / 天    ·    月 ≈ ¥%@", f(fl.netDay, 2), f(fl.netDay * c.fx * 30, 0))))
                            .font(.callout).foregroundColor(.secondary)
                    } else {
                        Text("—").font(.system(.largeTitle, design: .rounded).weight(.heavy)).foregroundColor(.secondary)
                        Text(Loc("等待联网行情…")).font(.callout).foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pearlAccentCard(gradient: fl.netDay > 0 ? Pearl.positive : Pearl.negative)

                // 按矿池实测到账（链上，以矿池为准）— 与上面的「设备估算」两个版本对照
                if ready && !store.actualIncome.isEmpty {
                    let inc24 = store.actualIncome.reduce(0.0) { $0 + $1.prl24h }
                    let inc7  = store.actualIncome.reduce(0.0) { $0 + $1.prl7d } / 7.0
                    let cost  = fl.powerDay + fl.rentDay   // 设备电费 + 租金 (USD/天)
                    VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                        Text(Loc("日净利 · 按矿池实测到账（链上）")).font(.headline).foregroundColor(.secondary)
                        HStack(spacing: Pearl.Space.sm) {
                            actualBox(Loc("近 24h"), inc24, c.price, cost, c.fx)
                            actualBox(Loc("近 7 天 · 日均"), inc7, c.price, cost, c.fx)
                        }
                        ForEach(store.actualIncome) { ai in
                            HStack(spacing: 6) {
                                Text(ai.pool).font(.caption).foregroundColor(.secondary)
                                Text(String(ai.addr.prefix(8)) + "…" + String(ai.addr.suffix(4)))
                                    .font(.caption2.monospaced()).foregroundColor(.secondary)
                                Spacer()
                                Text(Loc("24h %@ · 7天 %@ PRL", f(ai.prl24h, 1), f(ai.prl7d, 1)))
                                    .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                            }
                        }
                        // 实测每 P·天 = 链上日均到账 ÷ 你的总算力(P=1000T)，与理论「单位日产」对照看真实效率。
                        // 用近7日均(更稳)，缺则退回 24h。仅在已有设备算力时显示。
                        if fl.pearl > 0 {
                            let dailyInc = inc7 > 0 ? inc7 : inc24
                            let perP = dailyInc / fl.pearl * 1000   // fl.pearl 为 T(=Pearl)，×1000 → 每 P
                            let theoP = c.perUnit * 1000
                            HStack(spacing: 6) {
                                Image(systemName: "cube.fill").font(.caption).foregroundColor(Pearl.teal)
                                Text(Loc("实测每 P·天")).font(.caption).foregroundColor(.secondary)
                                Text(f(perP, 2) + " PRL").font(.caption.monospacedDigit().weight(.semibold))
                                Spacer(minLength: 4)
                                if theoP > 0 {
                                    Text(Loc("理论 %@ · 效率 %@%%", f(theoP, 2), f(perP / theoP * 100, 0)))
                                        .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                                }
                            }
                        }
                        Text(Loc("收入=链上实际到账（已自动扣除你各地址之间的互转，避免重复计入）；净利=到账×币价 − 你设备的电费/租金。"))
                            .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pearlCard()
                }

                StatGrid {
                    StatCard(title: Loc("日产 PRL"), value: ready ? f(fl.prlDay, 1) : "—", sub: Loc("枚/天"))
                    StatCard(title: Loc("日收入"), value: ready ? store.localSymbol + f(fl.revDay * c.fx, 1) : "—", sub: Loc("扣抽水·未扣电费"))
                    StatCard(title: fl.rentDay > 0 ? Loc("日电费(自付)") : Loc("日电费"), value: store.localSymbol + f(fl.powerDay * c.fx, 1), sub: "@$" + f(c.elec, 3) + "/kWh")
                    if fl.rentDay > 0 {
                        StatCard(title: Loc("日租金"), value: store.localSymbol + f(fl.rentDay * c.fx, 1), sub: Loc("%@ 张租用卡", "\(fl.rentedCards)"), color: .orange)
                        StatCard(title: Loc("自有卡"), value: Loc("%@ 张", "\(fl.ownCards)"), sub: store.sym(Loc("硬件 ¥%@", f(fl.cost * c.fx, 0))))
                        StatCard(title: Loc("租用卡"), value: Loc("%@ 张", "\(fl.rentedCards)"), sub: store.rentCoversPower ? Loc("租金含电") : Loc("电费自付"))
                    }
                }

                DiffProjection(store: store, fl: fl, ready: ready)
                PowerBar(store: store, watts: fl.watts)
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Wrap a StatCard so tapping it toggles the trend chart for that metric
    /// (tap again to collapse). Selected card gets an accent border.
    @ViewBuilder private func trendCard<C: View>(_ metric: MarketTrendCard.Metric,
                                                 @ViewBuilder _ card: () -> C) -> some View {
        Button {
            withAnimation(.snappy) { trendMetric = (trendMetric == metric ? nil : metric) }
        } label: {
            card().overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, lineWidth: trendMetric == metric ? 2 : 0)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func marketHeader(_ c: Config) -> some View {
        HStack(spacing: Pearl.Space.sm) {
            Text(Loc("行情")).font(.title3.bold()).fixedSize()        // never wrap / compress
            // 单一状态指示：圆点表示联网/手动，文字给简短结果（不再叠加「联网」字样与 ✅）。
            Circle().fill(store.live ? .green : .gray).frame(width: 7, height: 7)
            // 仅在非成功状态（加载中 / 手动 / 失败）下给一句简短文字；联网成功时只剩绿点。
            if !store.status.isEmpty {
                Text(store.status).font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if store.loading {
                ProgressView().controlSize(.small)
            } else {
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).controlSize(.small).fixedSize()
                    .accessibilityLabel(Loc("刷新"))
            }
            Toggle(Loc("自动"), isOn: Binding(get: { store.autoRefresh }, set: { store.setAuto($0) }))
                .toggleStyle(.switch).controlSize(.mini).font(.caption).fixedSize()
        }
    }

    @ViewBuilder private func actualBox(_ title: String, _ incPRL: Double, _ price: Double, _ costUSD: Double, _ fx: Double) -> some View {
        let rev = incPRL * price
        let net = rev - costUSD
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(store.localSymbol + f(net * fx, 1)).font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundColor(net > 0 ? .green : .red).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(store.sym(Loc("%@ PRL · 收入 ¥%@", f(incPRL, 1), f(rev * fx, 1)))).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DiffProjection: View {
    @ObservedObject var store: PRLStore
    let fl: Fleet
    var ready: Bool = true
    var body: some View {
        let c = store.cfg
        let p = project(netRev0: fl.revDay, power: fl.powerDay + fl.rentDay, monthlyPct: c.diffGrowthMonthly)
        let netPearl = c.nethashEH * 1e6
        let share = (netPearl + fl.pearl) > 0 ? fl.pearl / (netPearl + fl.pearl) : 0
        let dilution = netPearl > 0 ? netPearl / (netPearl + fl.pearl) : 1
        return VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            PearlSectionHeader(Loc("难度趋势预测"), systemImage: "chart.line.uptrend.xyaxis",
                               subtitle: c.diffGrowthMonthly == 0 ? Loc("难度恒定 · 线性外推")
                                                                  : Loc("难度月增 %@%% → 出币逐日衰减", f(c.diffGrowthMonthly,0)))
            StatGrid {
                StatCard(title: Loc("30 天净利"), value: ready ? store.localSymbol+f(p.net30*c.fx,0) : "—", sub: Loc("难度衰减后"), color: ready && p.net30 > 0 ? .green : (ready ? .red : .secondary))
                StatCard(title: Loc("90 天净利"), value: ready ? store.localSymbol+f(p.net90*c.fx,0) : "—", sub: Loc("难度衰减后"), color: ready && p.net90 > 0 ? .green : (ready ? .red : .secondary))
            }
            if ready && c.hasDiffTrend {
                let d7 = c.diffChange(vs: c.diff7), d3 = c.diffChange(vs: c.diff3), d24 = c.diffChange(vs: c.diff24)
                let trendHint = store.live ? Loc("月增长已按近7天趋势自动估算")
                                           : Loc("仅供参考，月增长可在【参数】手动设")
                Label(Loc("实时难度 %@M · 近7天 %@ · 近3天 %@ · 近24h %@　（%@）", f(c.diffNow/1e6,2), pctSigned(d7), pctSigned(d3), pctSigned(d24), trendHint),
                      systemImage: "chart.line.uptrend.xyaxis")
                    .font(.callout).foregroundColor(d7.isFinite && d7 > 0 ? .orange : .secondary)
            }
            if store.selfDilution {
                Label(Loc("已计入自身算力稀释：你占全网 %@%% · 单卡出币 ×%@", f(share*100,3), f(dilution,3)),
                      systemImage: "person.2.fill")
                    .font(.callout).foregroundColor(.secondary)
            }
        }
        .pearlCard()
    }
}

struct PowerBar: View {
    @ObservedObject var store: PRLStore
    let watts: Double
    var body: some View {
        let budget = max(store.powerBudgetW, 1)
        let util = watts / budget
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            HStack {
                PearlSectionHeader(Loc("机柜功耗"), systemImage: "bolt.fill",
                                   gradient: util > 1 ? Pearl.negative : Pearl.positive)
                Spacer()
                Text("\(f(watts,0)) W / \(f(budget,0)) W  (\(f(util*100,0))%)")
                    .font(.headline).monospacedDigit().foregroundColor(util > 1 ? .red : .primary)
            }
            ProgressView(value: min(util, 1))
                .tint(util > 1 ? .red : (util > 0.85 ? .orange : .green))
                .scaleEffect(x: 1, y: 2.2, anchor: .center)
                .padding(.vertical, 6)
            HStack {
                Text(Loc("机柜预算")).font(.callout).foregroundColor(.secondary)
                Spacer()
                Stepper(value: $store.powerBudgetW, in: 500...30000, step: 500) {
                    Text(f(store.powerBudgetW, 0) + " W").font(.callout.monospacedDigit())
                }.fixedSize()
            }
            if util > 1 {
                Label(Loc("超过机柜预算 %@W，需降功耗或减卡", f(watts-budget,0)), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundColor(.red)
            }
        }
        .pearlCard()
    }
}

// MARK: - 行情趋势图

/// One card under the 行情 stat row that charts the two headline metrics over time:
/// 币价 (real SafeTrade daily candles) and 全网算力 (derived from WhatToMine's
/// difficulty snapshots: now / 24h / 3d / 7d). Pick the metric with the segmented control.
struct MarketTrendCard: View {
    @ObservedObject var store: PRLStore
    @Binding var metric: Metric
    @State private var windowDays = 30

    enum Metric: String, CaseIterable, Identifiable {
        case price = "币价", hashrate = "全网算力", perUnit = "单位日产", difficulty = "难度"
        var id: String { rawValue }
    }
    private struct HRPoint: Identifiable { let id = UUID(); let x: Double; let label: String; let value: Double }

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            Picker(Loc("指标"), selection: $metric) {
                ForEach(Metric.allCases) { Text(Loc($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            switch metric {
            case .price:      priceTrend
            case .hashrate:   hashrateTrend
            case .perUnit:    perUnitTrend
            case .difficulty: difficultyTrend
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard()
    }

    // MARK: 币价走势（SafeTrade 日线）

    @ViewBuilder private var priceTrend: some View {
        let data = Array(store.priceHistory.suffix(windowDays))
        if data.count < 2 {
            placeholder(Loc("加载币价走势…"))
        } else {
            let firstP = data.first!.close, lastP = data.last!.close
            let up = lastP >= firstP
            let color = up ? Color.green : Color.red
            let lo = data.map(\.low).min() ?? lastP
            let hi = data.map(\.high).max() ?? lastP
            let pad = max((hi - lo) * 0.08, 0.0001)
            let pct = firstP > 0 ? (lastP / firstP - 1) * 100 : .nan

            Chart(data) { c in
                AreaMark(x: .value("日期", c.time), y: .value("价格", c.close))
                    .foregroundStyle(.linearGradient(colors: [color.opacity(0.28), color.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("日期", c.time), y: .value("价格", c.close))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            .frame(height: 180)
            // Clip to the plot frame: the area-fill gradient (monotone) overshoots
            // far below its frame and, with no clipping on the card, bled all the way
            // down into the next section. Containing it here stops the leak.
            .clipped()

            Picker(Loc("窗口"), selection: $windowDays) {
                Text(Loc("7天")).tag(7); Text(Loc("30天")).tag(30); Text(Loc("90天")).tag(90)
            }
            .pickerStyle(.segmented).labelsHidden()

            HStack(spacing: 10) {
                Text(Loc("%@天 %@", "\(windowDays)", pctSigned(pct, 1)))
                    .font(.callout.bold()).foregroundColor(up ? .green : .red)
                    .fixedSize(horizontal: true, vertical: false)
                Text(Loc("最高 $%@ · 最低 $%@", f(hi, 4), f(lo, 4)))
                    .font(.caption).foregroundColor(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: 全网算力 / 单位日产走势（难度快照推导）

    @ViewBuilder private var hashrateTrend: some View {
        let c = store.cfg
        diffTrend(points: diffPoints(c, base: c.nethashEH, inverse: false),
                  color: .orange, digits: 2, unit: "EH/s",
                  empty: store.liveReady ? Loc("暂无算力趋势数据") : Loc("联网后显示算力趋势"))
    }

    @ViewBuilder private var perUnitTrend: some View {
        let c = store.cfg
        // 单位日产 ∝ 1/难度：难度上升它下降，故用 inverse 推导历史点。
        // 与上方卡片同口径：每 P(=1000 TH)·天，故 base ×1000（各历史点按比例同步缩放）。
        diffTrend(points: diffPoints(c, base: c.perUnit * 1000, inverse: true),
                  color: .blue, digits: 2, unit: Loc("PRL/P·天"),
                  empty: store.liveReady ? Loc("暂无出币趋势数据") : Loc("联网后显示出币趋势"))
    }

    @ViewBuilder private var difficultyTrend: some View {
        let c = store.cfg
        // base = diffNow/1e6 → val(diffₓ) = diffₓ/1e6，即各快照难度本身（单位 M）。
        diffTrend(points: diffPoints(c, base: c.diffNow / 1e6, inverse: false),
                  color: .purple, digits: 2, unit: Loc("难度 (M)"),
                  empty: store.liveReady ? Loc("暂无难度趋势数据") : Loc("联网后显示难度趋势"))
    }

    /// Shared 4-point line chart for the difficulty-derived metrics (算力 / 单位日产).
    @ViewBuilder private func diffTrend(points pts: [HRPoint], color: Color, digits: Int,
                                        unit: String, empty: String) -> some View {
        if pts.count < 2 {
            placeholder(empty)
        } else {
            let vals = pts.map(\.value)
            let lo = vals.min() ?? 0, hi = vals.max() ?? 1
            let pad = max((hi - lo) * 0.25, hi * 0.04)
            let first = pts.first!.value, last = pts.last!.value
            let pct = first > 0 ? (last / first - 1) * 100 : .nan
            Chart(pts) { p in
                LineMark(x: .value("时间", p.x), y: .value("数值", p.value))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                PointMark(x: .value("时间", p.x), y: .value("数值", p.value))
                    .foregroundStyle(color).symbolSize(60)
                    .annotation(position: .top, spacing: 2) {
                        Text(f(p.value, digits)).font(.caption2.monospacedDigit()).foregroundColor(.secondary)
                    }
            }
            .chartYScale(domain: (lo - pad)...(hi + pad))
            // Axis labels hang right of their tick, so the last one ("现在", up to
            // "Sekarang") needs its own width of room past x = 0 or it gets clipped.
            .chartXScale(domain: -7.4...0,
                         range: .plotDimension(endPadding: captionWidth(pts.last!.label) + 2))
            .chartXAxis {
                AxisMarks(values: pts.map(\.x)) { value in
                    if let x = value.as(Double.self), let p = pts.first(where: { $0.x == x }) {
                        AxisValueLabel { Text(p.label).font(.caption2) }
                    }
                    AxisGridLine()
                }
            }
            .chartYAxis(.hidden)
            .frame(height: 180)
            .clipped()

            Text(Loc("%@ · %@→现在 %@", unit, pts.first!.label, pctSigned(pct, 1)))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    /// 4-point trend derived from difficulty snapshots (现在 / 24h / 3天 / 7天).
    /// 算力 ∝ 难度、单位日产 ∝ 1/难度，所以历史点 = 现值 × (diffₓ/diffNow)（inverse 时取倒数）；
    /// "现在" 点恰好等于上方卡片的数值。x = 天偏移（过去 → 0）。
    private func diffPoints(_ c: Config, base: Double, inverse: Bool) -> [HRPoint] {
        guard c.hasDiffTrend, c.diffNow > 0, base > 0 else { return [] }
        func val(_ diff: Double) -> Double? {
            guard diff > 0 else { return nil }
            return inverse ? base * c.diffNow / diff : base * diff / c.diffNow
        }
        var pts: [HRPoint] = []
        if let v = val(c.diff7)  { pts.append(.init(x: -7, label: Loc("7天前"), value: v)) }
        if let v = val(c.diff3)  { pts.append(.init(x: -3, label: Loc("3天前"), value: v)) }
        if let v = val(c.diff24) { pts.append(.init(x: -1, label: Loc("24h"), value: v)) }
        pts.append(.init(x: 0, label: Loc("现在"), value: base))
        return pts
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(.secondary)
            .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 180)
    }

    /// Rendered width of `s` in the caption2 font the axis labels use.
    private func captionWidth(_ s: String) -> CGFloat {
        #if os(iOS)
        let font = UIFont.preferredFont(forTextStyle: .caption2)
        #else
        let font = NSFont.preferredFont(forTextStyle: .caption2)
        #endif
        return ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }
}
