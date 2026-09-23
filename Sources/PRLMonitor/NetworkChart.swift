import SwiftUI
import Charts

// ============================================================
// 全网走势图（概览）：算力(绿色面积) + 难度(白色虚线·右轴) + 出块时间(蓝色小图)。
// 数据来自自家 Blockbook：在所选时间窗内均匀采样 ~64 个区块，每个区块自带
// difficulty 与时间戳。算力与出块时间都是从这些采样点**实测**出来的：
//   出块时间 = 采样点前后的时间差 ÷ 块数差
//   算力     = 难度 × 2^48 ÷ 出块时间
// ============================================================

/// One sampled block (height, timestamp, difficulty) from Blockbook.
struct ChainSample: Identifiable {
    let height: Int
    let time: Date
    let difficulty: Double
    var id: Int { height }
}

/// Fetches + caches sampled chain history. Shared singleton so switching
/// dashboard sections (which rebuilds the view) doesn't refetch 64 blocks.
@MainActor
final class ChainHistory: ObservableObject {
    static let shared = ChainHistory()

    enum Span: String, CaseIterable, Identifiable {
        case h24, d7, d30, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .h24: return "24h"
            case .d7:  return Loc("7天")
            case .d30: return Loc("30天")
            case .all: return Loc("全部")
            }
        }
        /// Window length; nil = since genesis.
        var seconds: Double? {
            switch self {
            case .h24: return 86_400
            case .d7:  return 7 * 86_400
            case .d30: return 30 * 86_400
            case .all: return nil
            }
        }
    }

    @Published var span: Span = .d7 {
        didSet { if span != oldValue { load() } }
    }
    @Published var samples: [ChainSample] = []
    @Published var loading = false

    private var cache: [Span: (at: Date, samples: [ChainSample])] = [:]
    private var inflight: Task<Void, Never>?
    private static let cacheTTL: TimeInterval = 600   // chain moves ~1 block / 4 min

    /// How many blocks the window is sampled at. Blockbook has no header-only endpoint and a
    /// Pearl block carries its full tx list — ~87 KB EACH — so every sample is a round trip AND
    /// a fat one: 64 samples meant 4.2 MB and, behind URLSession.shared's 4–6 connections per
    /// host, 15–24 s before the chart appeared. 28 points still draw a smooth 190 pt line, and
    /// the wider spacing actually STEADIES the measured series (each block-time estimate then
    /// rests on more blocks). With the private session below a cold chart lands in ~4 s.
    private static let sampleCount = 28

    /// Private session purely so these fetches aren't capped at the shared session's 4–6
    /// connections per host. Ephemeral: the responses are big and already cached in `cache`.
    nonisolated private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 12
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    func load(force: Bool = false) {
        if !force, let c = cache[span], Date().timeIntervalSince(c.at) < Self.cacheTTL {
            samples = c.samples
            return
        }
        inflight?.cancel()
        loading = true
        let span = self.span
        inflight = Task { [weak self] in
            guard let heights = await Self.plan(span: span), let self, !Task.isCancelled else {
                self?.loading = false
                return
            }
            // Publish as blocks land instead of after the whole window: the first line shows up
            // in about a second and thickens, rather than a spinner sitting there for seconds.
            var out: [ChainSample] = []
            await withTaskGroup(of: ChainSample?.self) { group in
                for h in heights { group.addTask { await Self.fetchBlock(h) } }
                for await s in group {
                    guard let s else { continue }
                    out.append(s)
                    // Every 4th, so SwiftUI isn't asked to rebuild the chart 28 times.
                    if out.count % 4 == 0, out.count >= 4, span == self.span, !Task.isCancelled {
                        self.samples = out.sorted { $0.height < $1.height }
                    }
                }
            }
            guard !Task.isCancelled, out.count >= 2 else {
                if span == self.span { self.loading = false }
                return
            }
            let done = out.sorted { $0.height < $1.height }
            self.cache[span] = (Date(), done)
            if span == self.span { self.samples = done; self.loading = false }
        }
    }

    /// Tip height from Blockbook status, then the heights to sample across the window. The window
    /// is sized by the chain's REAL recent block time (probed over the last ~1000 blocks, both
    /// ends fetched concurrently); the x-axis uses each block's actual timestamp, so the probe
    /// only sizes the window, never skews the chart.
    nonisolated private static func plan(span: Span) async -> [Int]? {
        guard let d = await httpGET("https://blockbook.pearlresearch.ai/api/v2/", timeout: 15),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let bb = o["blockbook"] as? [String: Any],
              let tip = bb["bestHeight"] as? Int, tip > 2 else { return nil }
        var estBlockSec = 235.0
        let probeFrom = max(1, tip - 1000)
        if span.seconds != nil, probeFrom < tip {
            async let a = fetchBlock(probeFrom)
            async let b = fetchBlock(tip)
            if let pa = await a, let pb = await b {
                let est = pb.time.timeIntervalSince(pa.time) / Double(tip - probeFrom)
                if est.isFinite, est > 0 { estBlockSec = min(max(est, 10), 3600) }
            }
        }
        let spanBlocks = span.seconds.map { max(30, Int($0 / estBlockSec)) } ?? (tip - 1)
        let from = max(1, tip - spanBlocks)
        let n = sampleCount
        return Array(Set((0 ..< n).map { from + Int(Double(tip - from) * Double($0) / Double(n - 1)) })).sorted()
    }

    // MARK: measured series (block time → hashrate)

    /// Seconds per block around each sample, from a ±k-sample neighbourhood rather than the one
    /// adjacent interval: block discovery is Poisson, and a single 24h interval spans only ~7
    /// blocks (σ/μ ≈ 38%), which would make both this line and the hashrate derived from it
    /// mostly noise. k grows until the neighbourhood covers ≥40 blocks (capped at ±5), so a 30d
    /// window — already ~845 blocks per step — is left alone.
    static func blockTimes(_ s: [ChainSample]) -> [Double] {
        guard s.count >= 2 else { return s.map { _ in 0 } }
        var k = 2
        while k < 5 {
            let mid = s.count / 2
            let lo = max(0, mid - k), hi = min(s.count - 1, mid + k)
            if s[hi].height - s[lo].height >= 40 { break }
            k += 1
        }
        return s.indices.map { i in
            let lo = max(0, i - k), hi = min(s.count - 1, i + k)
            let dh = Double(s[hi].height - s[lo].height)
            let dt = s[hi].time.timeIntervalSince(s[lo].time)
            return dh > 0 && dt > 0 ? dt / dh : 0
        }
    }

    /// Measured hashrate (H/s) at each sample.
    ///
    /// This used to be `难度 × diffConst`, one constant learned from the live snapshot — which
    /// quietly assumed the chain's block time never moves. It moves a lot: across one 30-day
    /// window it ran 144s…364s, so that line was just the difficulty curve rescaled. It
    /// understated mid-July by ~45% (29 vs the explorer's own 50 EH/s) and, worse, drew hashrate
    /// CLIMBING through the last day, when blocks had slowed to 364s and the network had in fact
    /// dropped to ~25 EH/s. Measuring it per sample reproduces the explorer's published series.
    static func hashrates(_ s: [ChainSample]) -> [Double] {
        let bt = blockTimes(s)
        return s.indices.map { bt[$0] > 0 ? s[$0].difficulty * prlWorkPerDifficulty / bt[$0] : 0 }
    }

    nonisolated private static func fetchBlock(_ h: Int) async -> ChainSample? {
        guard let url = URL(string: "https://blockbook.pearlresearch.ai/api/v2/block/\(h)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("prl-monitor/1.0", forHTTPHeaderField: "User-Agent")
        guard let (d, r) = try? await session.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let t = o["time"] as? Int,
              let diff = num(o["difficulty"]), diff > 0 else { return nil }
        return ChainSample(height: (o["height"] as? Int) ?? h,
                           time: Date(timeIntervalSince1970: TimeInterval(t)),
                           difficulty: diff)
    }
}

// MARK: - 概览卡片

/// Every series here is measured from the sampled blocks themselves, so the card needs no
/// store: it no longer borrows the live fetch's difficulty→hashrate constant.
struct NetworkChartCard: View {
    @ObservedObject private var chain = ChainHistory.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            header
            if chain.samples.count < 2 {
                if chain.loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    VStack(spacing: Pearl.Space.sm) {
                        Text(Loc("链上数据加载失败")).font(.caption).foregroundColor(.secondary)
                        Button(Loc("重试")) { chain.load(force: true) }
                            .font(.caption).buttonStyle(.bordered).controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, minHeight: 220)
                }
            } else {
                mainChart(chain.samples)
                blockTimeSection(chain.samples)
                footer(chain.samples)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard()
        .onAppear { chain.load() }
    }

    // MARK: header — legend + range picker

    // Legend and range picker each get their own row: on a phone they don't fit
    // side-by-side, and a fixed-size range picker would squeeze the legend labels
    // to zero width (the line swatches showed but the text vanished).
    private var header: some View {
        VStack(spacing: Pearl.Space.sm) {
            HStack(spacing: Pearl.Space.md) {
                legendItem(.green, dashed: false, Loc("全网算力"))
                legendItem(.primary, dashed: true, Loc("难度"))
                legendItem(.blue, dashed: false, Loc("出块时间"))
                if chain.loading && chain.samples.count >= 2 {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
            }
            Picker(Loc("窗口"), selection: $chain.span) {
                ForEach(ChainHistory.Span.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }

    private func legendItem(_ color: Color, dashed: Bool, _ label: String) -> some View {
        HStack(spacing: 4) {
            LegendLine(dashed: dashed).stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
                .frame(width: 16, height: 2)
            Text(label).font(.caption2).foregroundColor(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private struct LegendLine: Shape {
        let dashed: Bool
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.width, y: rect.midY))
            return p
        }
    }

    // MARK: main chart — hashrate area + difficulty dashed (dual axis)

    @ViewBuilder private func mainChart(_ samples: [ChainSample]) -> some View {
        // Area series: 算力 (EH/s)，每个采样点由该处的难度与实测出块时间算出。
        let vals = ChainHistory.hashrates(samples).map { $0 / 1e18 }
        let yMax = max((vals.max() ?? 1) * 1.08, 1e-12)
        // Difficulty (dashed) normalized into the same plot: lo→0, hi→yMax,
        // with right-side labels mapping plot height back to difficulty.
        let dLo = samples.map(\.difficulty).min() ?? 0
        let dHi = max(samples.map(\.difficulty).max() ?? 1, dLo + 1e-9)
        let dNorm: (Double) -> Double = { ($0 - dLo) / (dHi - dLo) * yMax }

        Chart {
            ForEach(Array(zip(samples, vals)), id: \.0.id) { s, v in
                // yStart pinned to 0 (not the domain floor) so the negative bottom
                // headroom below stays empty — the green never spills past the 0 line.
                AreaMark(x: .value("时间", s.time), yStart: .value("基线", 0), yEnd: .value("算力", v))
                    .foregroundStyle(.linearGradient(colors: [Color.green.opacity(0.30), Color.green.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", s.time), y: .value("算力", v), series: .value("series", "hash"))
                    .foregroundStyle(.green).lineStyle(StrokeStyle(lineWidth: 1.8))
            }
            ForEach(samples) { s in
                LineMark(x: .value("时间", s.time), y: .value("难度", dNorm(s.difficulty)),
                         series: .value("series", "diff"))
                    // Color.primary, NOT .primary: the hierarchical style doesn't
                    // resolve inside Chart marks and falls back to the palette blue.
                    .foregroundStyle(Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
            }
        }
        // 6% headroom above the top gridline AND below the 0 gridline so neither
        // edge label (top at yMax, "0 H/s" at the bottom) is halved by .clipped() —
        // each label centers on its gridline and would otherwise lose its outer half.
        .chartYScale(domain: -yMax * 0.06 ... yMax * 1.06)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, yMax / 2, yMax]) { v in
                AxisGridLine()
                AxisValueLabel {
                    if let y = v.as(Double.self) {
                        Text(formatHashrate(y * 1e18))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            AxisMarks(position: .trailing, values: [0, yMax / 2, yMax]) { v in
                AxisValueLabel {
                    if let y = v.as(Double.self) {
                        Text(f((dLo + y / yMax * (dHi - dLo)) / 1e6, 2) + "M")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .frame(height: 190)
        .clipped()
    }

    // MARK: block-time mini chart

    private struct BTPoint: Identifiable { let id: Int; let t: Date; let secs: Double }

    @ViewBuilder private func blockTimeSection(_ samples: [ChainSample]) -> some View {
        // The SAME series the hashrate line is derived from — plotting a raw per-interval
        // block time here while the green line used a smoothed one would put the two charts
        // visibly at odds about the same fact (blocks slow ⇄ hashrate falls).
        let secs = ChainHistory.blockTimes(samples)
        let pts: [BTPoint] = samples.indices.compactMap { i in
            secs[i] > 0 ? BTPoint(id: samples[i].height, t: samples[i].time, secs: secs[i]) : nil
        }
        if pts.count >= 2 {
            let first = samples.first!, last = samples.last!
            let avg = last.time.timeIntervalSince(first.time) / Double(max(last.height - first.height, 1))
            HStack {
                Text(Loc("出块时间")).font(.caption).foregroundColor(.secondary)
                Spacer()
                Text(Self.fmtDur(avg)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            Chart(pts) { p in
                AreaMark(x: .value("时间", p.t), y: .value("出块", p.secs))
                    .foregroundStyle(.linearGradient(colors: [Color.blue.opacity(0.30), Color.blue.opacity(0.03)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("时间", p.t), y: .value("出块", p.secs))
                    .foregroundStyle(.blue).lineStyle(StrokeStyle(lineWidth: 1.4))
            }
            .chartYScale(domain: 0 ... max((pts.map(\.secs).max() ?? 1) * 1.25, 1))
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 52)
            .clipped()
        }
    }

    @ViewBuilder private func footer(_ samples: [ChainSample]) -> some View {
        HStack {
            Text("Block " + Self.grouped(samples.first!.height))
            Spacer()
            Text("Block " + Self.grouped(samples.last!.height))
        }
        .font(.caption2.monospacedDigit()).foregroundColor(.secondary)
    }

    private static let groupedFormatter: NumberFormatter = {
        let nf = NumberFormatter(); nf.numberStyle = .decimal; return nf
    }()
    private static func grouped(_ n: Int) -> String {
        groupedFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static func fmtDur(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "—" }
        let m = Int(s) / 60, sec = Int(s) % 60
        return m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
    }
}
