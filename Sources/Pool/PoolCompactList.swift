import SwiftUI
import UniformTypeIdentifiers

// 我的监控 → 一览: the total hashrate in big type, then one small tile per monitor — two
// across on a phone, more where there is room — for when the full cards (PoolView's
// WatchCard) take a screen each. A tile opens that monitor's full card (WatchDetailView).

/// 我的监控's two layouts. A per-device preference, so it is not synced.
enum MonitorLayout: String {
    case cards, compact
    static let key = "pool.layout"
}

/// The 卡片 / 一览 switch in 我的监控's header.
struct MonitorLayoutPicker: View {
    @Binding var layout: MonitorLayout

    var body: some View {
        Picker(Loc("显示方式"), selection: $layout) {
            Image(systemName: "rectangle.grid.1x2")
                .accessibilityLabel(Loc("卡片视图"))
                .tag(MonitorLayout.cards)
            Image(systemName: "list.bullet")
                .accessibilityLabel(Loc("一览视图"))
                .tag(MonitorLayout.compact)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(Loc("显示方式"))
    }
}

/// The toolbar's refresh button, on 我的监控 and on a monitor opened from 一览.
struct PoolRefreshButton: View {
    @ObservedObject var store: PoolStore

    var body: some View {
        Button { Task { await store.refresh(force: true) } } label: {
            // .small so the in-toolbar spinner stays icon-sized — a default
            // ProgressView fills the macOS toolbar button's glass background
            // and reads as a big white badge.
            if store.loading { ProgressView().controlSize(.small) }
            else { Image(systemName: "arrow.clockwise") }
        }
        .disabled(store.loading)
        .accessibilityLabel(Loc("刷新矿池数据"))
    }
}

// MARK: - what 一览 shows

/// One enabled monitor, reduced to what 一览 shows of it.
private struct CompactMonitor: Identifiable {
    let watch: PoolWatch
    let data: WatchData?
    /// Hashrate in the window the card would show for the shared 算力口径 choice.
    let rate: Double
    let up: Int
    let total: Int
    var id: UUID { watch.id }

    init(_ watch: PoolWatch, _ data: WatchData?, choice: SpeedWindow) {
        self.watch = watch
        self.data = data
        rate = data.map { $0.value(choice.nearest(in: $0.windows) ?? .day) } ?? 0
        let workers = data?.workers ?? []
        up = workers.filter(\.online).count
        total = workers.count
    }

    var loading: Bool { data == nil }
    var found: Bool { data?.found == true }
    /// How its pill is coloured. A pool that lists no rigs is judged on its hashrate alone.
    var tone: PillTone {
        guard let d = data else { return .idle }
        guard d.found else { return d.error != nil ? .down : .idle }
        if total == 0 { return rate > 0 ? .ok : .idle }
        return up == total ? .ok : up == 0 ? .down : .partial
    }

    var rateText: String { found && rate > 0 ? formatHashrate(rate) : "—" }

    /// What a tile's pill says: rigs online of rigs listed, else a word for the state.
    var badgeText: String {
        guard let d = data else { return "" }
        if d.found { return total > 0 ? "\(up)/\(total)" : (rate > 0 ? Loc("在线") : Loc("离线")) }
        return d.error != nil ? Loc("失败") : Loc("离线")
    }

    /// What a tile is read out as: rigs online, or why there is nothing to show.
    var detailText: String {
        guard let d = data else { return " " }
        if d.found { return total > 0 ? Loc("%@ 在线", "\(up)/\(total)") : (rate > 0 ? Loc("在线") : Loc("离线")) }
        return d.error ?? Loc("该地址未在 %@ 挖矿", watch.pool.label)
    }
}

/// A pill's colour. Quiet while all is well, so only trouble draws the eye; trouble in
/// the palette's own warm tones — the hard-hat gold, then rose — not the system's
/// green / orange / red, which the pearl palettes don't have.
enum PillTone {
    case ok, partial, down, idle

    /// The text, on a card.
    var ink: Color {
        switch self {
        case .ok, .idle: .secondary
        case .partial: Pearl.goldInk
        case .down: Pearl.roseInk
        }
    }

    var fill: Color {
        switch self {
        case .ok: Pearl.indigo.opacity(0.09)
        case .idle: Color.primary.opacity(0.06)
        case .partial: Pearl.gold.opacity(0.18)
        case .down: Pearl.rose.opacity(0.14)
        }
    }
}

// MARK: - the list

struct WatchCompactList: View {
    @ObservedObject var store: PoolStore
    @Binding var dragging: PoolWatch?
    let onOpen: (PoolWatch) -> Void
    let onEdit: (PoolWatch) -> Void
    @EnvironmentObject private var currency: CurrencyManager
    @AppStorage("pool.speedWindow") private var speedWindow: SpeedWindow = .live
    @State private var showPaused = false

    var body: some View {
        let monitors = store.watches.filter(\.isEnabled).map {
            CompactMonitor($0, store.watchData[$0.id], choice: speedWindow)
        }
        let paused = store.watches.filter { !$0.isEnabled }
        VStack(alignment: .leading, spacing: 12) {
            // With one monitor the total would only repeat its tile.
            if monitors.count > 1 { total(monitors) }
            tiles(monitors, paused: paused)
        }
    }

    // MARK: the total

    /// The fleet's hashrate in big type, with rigs online in a pill beside its label and
    /// what reached the payout addresses in the last 24h under it.
    private func total(_ monitors: [CompactMonitor]) -> some View {
        let reporting = monitors.filter(\.found)
        let rate = reporting.reduce(0) { $0 + $1.rate }
        let up = reporting.reduce(0) { $0 + $1.up }
        let rigs = reporting.reduce(0) { $0 + $1.total }
        // One figure per payout address: two monitors on one address share its income.
        let addresses = Set(monitors.map(\.watch).compactMap(store.chainAddress))
        let received = addresses.compactMap { store.onchain[$0]?.h24 }
        let chainLoading = addresses.contains { store.onchain[$0]?.h24 == nil && store.onchain[$0]?.failed != true }
        // An F2Pool monitor is a read-only page link with no payout address in it, so its
        // income can't be in the figure: say so, or it reads as the whole account's.
        let uncounted = Array(Set(monitors.map(\.watch).filter { !$0.pool.isAddressBased }.map(\.pool.label))).sorted()

        var income: String?
        var note: String?
        if !addresses.isEmpty, !chainLoading, !received.isEmpty {
            let sum = received.reduce(0, +)
            var line = Loc("近 24h") + " +" + f(sum, abs(sum) < 0.01 ? 4 : 2) + " PRL"
            if let usd = store.prlUsd, sum > 0 { line += " ≈ " + currency.primaryString(sum * usd) }
            income = line
            if !uncounted.isEmpty { note = Loc("不含 %@", uncounted.joined(separator: ", ")) }
        }

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text(Loc("总算力")).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if rigs > 0 {
                    RigsBadge(text: Loc("%@ 在线", "\(up)/\(rigs)"),
                              tone: up == rigs ? .ok : up == 0 ? .down : .partial)
                }
            }
            heroRate(rate)
                .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            if let income {
                // On one line where it fits; else the note drops to a line of its own
                // rather than the line breaking inside it.
                ViewThatFits(in: .horizontal) {
                    Text(note.map { income + " · " + $0 } ?? income).lineLimit(1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(income).fixedSize(horizontal: false, vertical: true)
                        if let note { Text(note) }
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard(padding: 18)
        .accessibilityElement(children: .combine)
    }

    /// "2.53 PH/s" with the unit a step quieter than the figure.
    private func heroRate(_ rate: Double) -> Text {
        guard rate > 0 else { return Text(verbatim: "—") }
        let s = formatHashrate(rate)
        guard let space = s.lastIndex(of: " ") else { return Text(verbatim: s) }
        return Text(verbatim: String(s[..<space]))
            + Text(verbatim: String(s[space...]))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
    }

    /// The paused fold's padding.
    private static let padH: CGFloat = 18
    private static let padV: CGFloat = 16
    private static let lineInset: CGFloat = padH + 28 + 12

    // MARK: the tiles

    /// Two across on a phone; as many as fit on an iPad or a Mac.
    private func tiles(_ monitors: [CompactMonitor], paused: [PoolWatch]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !monitors.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(monitors) { m in
                        Button { onOpen(m.watch) } label: { tile(m) }
                            .buttonStyle(TileButtonStyle())
                            .modifier(MonitorActions(watch: m.watch, store: store, dragging: $dragging, onEdit: onEdit))
                    }
                }
            }
            if !paused.isEmpty {
                VStack(spacing: 0) { pausedFold(paused) }
                    .clipShape(RoundedRectangle(cornerRadius: Pearl.Radius.md, style: .continuous))
                    .pearlCard(padding: 0)
            }
        }
    }

    /// The pool's icon and the rigs-online pill on top; the name, then the hashrate in
    /// bold, below.
    private func tile(_ m: CompactMonitor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                PoolIcon(pool: m.watch.pool, size: 26)
                Spacer(minLength: 0)
                // Rigs online: quiet when all are up, gold when some are down, rose when none are.
                if !m.loading { RigsBadge(text: m.badgeText, tone: m.tone) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(m.watch.displayName).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Group {
                    if m.loading { ProgressView().controlSize(.small) }
                    else {
                        Text(m.rateText).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit()
                            .foregroundStyle(m.found ? Color.primary : Color.secondary)
                    }
                }
                .frame(height: 26, alignment: .leading)
                .lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard(padding: 16)
        .accessibilityElement(children: .combine)
        .accessibilityValue(m.detailText)
    }

    // MARK: paused monitors

    /// Paused monitors, folded into one line: nothing is fetched for them, so they only
    /// take room. Opened, each is a line that leads to its card (to resume it).
    @ViewBuilder private func pausedFold(_ paused: [PoolWatch]) -> some View {
        Button { withAnimation(.snappy) { showPaused.toggle() } } label: {
            HStack {
                Text(Loc("已暂停") + " · \(paused.count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: showPaused ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Self.padH).padding(.vertical, Self.padV - 2)
        }
        .buttonStyle(LineButtonStyle())
        if showPaused {
            ForEach(paused) { w in
                Divider().padding(.leading, Self.lineInset)
                Button { onOpen(w) } label: {
                    HStack(spacing: 12) {
                        PoolIcon(pool: w.pool, size: 28).opacity(0.45)
                        Text(w.displayName).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, Self.padH).padding(.vertical, Self.padV - 4)
                }
                .buttonStyle(LineButtonStyle())
                .modifier(MonitorActions(watch: w, store: store, dragging: $dragging, onEdit: onEdit))
            }
        }
    }
}

/// Rigs online as a tinted pill, coloured by its `PillTone`. Caption-sized on the total
/// card as on the tiles: a larger face swells the pill past the label beside it.
private struct RigsBadge: View {
    let text: String
    let tone: PillTone

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .frame(minWidth: 44)
            .foregroundStyle(tone.ink)
            .background(tone.fill, in: Capsule())
            .fixedSize()
    }
}

/// What a tile or a paused line offers besides opening: the card's ⋯ actions on a long press /
/// right click, and the same drag-to-reorder as the cards, so an order set in either
/// layout holds in both.
private struct MonitorActions: ViewModifier {
    let watch: PoolWatch
    let store: PoolStore
    @Binding var dragging: PoolWatch?
    let onEdit: (PoolWatch) -> Void

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { store.setEnabled(watch.id, !watch.isEnabled) } label: {
                    watch.isEnabled
                        ? Label(Loc("暂停监控"), systemImage: "pause.circle")
                        : Label(Loc("恢复监控"), systemImage: "play.circle")
                }
                Button { onEdit(watch) } label: { Label(Loc("编辑监控"), systemImage: "square.and.pencil") }
                Button(role: .destructive) { store.removeWatch(watch.id) } label: {
                    Label(Loc("删除监控"), systemImage: "trash")
                }
            }
            .onDrag {
                dragging = watch
                return NSItemProvider(object: watch.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: WatchDropDelegate(item: watch, store: store, dragging: $dragging))
    }
}

/// A line's pressed (and, on a Mac, hovered) state, since a plain button shows neither.
private struct LineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Highlight(pressed: configuration.isPressed) { configuration.label }
    }

    private struct Highlight<Content: View>: View {
        let pressed: Bool
        @ViewBuilder let label: Content
        @State private var hovering = false

        var body: some View {
            label
                .contentShape(Rectangle())
                .background(Color.primary.opacity(pressed ? 0.08 : hovering ? 0.04 : 0))
                .onHover { hovering = $0 }
        }
    }
}

/// The same for a tile: a tint laid over the card, inside its corners.
private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Highlight(pressed: configuration.isPressed) { configuration.label }
    }

    private struct Highlight<Content: View>: View {
        let pressed: Bool
        @ViewBuilder let label: Content
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Pearl.Radius.md, style: .continuous)
            label
                .contentShape(shape)
                .overlay(shape.fill(Color.primary.opacity(pressed ? 0.07 : hovering ? 0.035 : 0)).allowsHitTesting(false))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - one monitor, opened from 一览

/// The monitor's full card on a page of its own. It reads the store live, so it keeps
/// refreshing with the list behind it.
struct WatchDetailView: View {
    @ObservedObject var store: PoolStore
    let id: UUID
    let onEdit: (PoolWatch) -> Void
    let onDelete: (PoolWatch) -> Void
    @ObservedObject private var alerts = OfflineAlertStore.shared

    var body: some View {
        let watch = store.watches.first { $0.id == id }
        ScrollView {
            if let w = watch {
                let addr = store.chainAddress(for: w)
                WatchCard(watch: w, data: store.watchData[w.id],
                          onchain: addr.flatMap { store.onchain[$0] },
                          addressHr24hRaw: addr.map { store.addressHashrate24h($0) } ?? 0,
                          prlUsd: store.prlUsd,
                          alertMinutes: alerts.threshold(for: w.id),
                          alertAgain: alerts.reminder(for: w.id),
                          onEdit: { onEdit(w) },
                          onDelete: { onDelete(w) },
                          onRename: { store.renameWatch(w.id, alias: $0) },
                          onSetEnabled: { store.setEnabled(w.id, $0) })
                    .padding(Pearl.Space.screen)
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
            }
        }
        .pearlScreenBackground()
        .navigationTitle(watch?.displayName ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { PoolRefreshButton(store: store) }
        .refreshable { await store.refresh(force: true) }
    }
}

