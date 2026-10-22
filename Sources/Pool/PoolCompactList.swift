import SwiftUI
import UniformTypeIdentifiers

// 我的监控 → 一览: the total hashrate in big type, then one short line per monitor (a
// phone) or one small tile per monitor (Mac, iPad) — for when the full cards
// (PoolView's WatchCard) take a screen each. Any line or tile opens that monitor's full
// card (WatchDetailView).

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
    /// Some rigs are down, but not all: the count is worth showing next to the dot.
    var partlyOffline: Bool { found && total > 0 && up < total }

    /// Green: every rig up. Orange: some down. Red: none up, or the lookup failed.
    /// A pool that lists no rigs is judged on its hashrate alone.
    var statusColor: Color {
        guard let d = data else { return .secondary }
        guard d.found else { return d.error != nil ? .red : .secondary }
        if total == 0 { return rate > 0 ? .green : .secondary }
        return up == total ? .green : up == 0 ? .red : .orange
    }

    var rateText: String { found && rate > 0 ? formatHashrate(rate) : "—" }

    /// The line under a tile's hashrate: rigs online, or why there is nothing to show.
    var detailText: String {
        guard let d = data else { return " " }
        if d.found { return total > 0 ? Loc("%@ 在线", "\(up)/\(total)") : (rate > 0 ? Loc("在线") : Loc("离线")) }
        return d.error ?? Loc("该地址未在 %@ 挖矿", watch.pool.label)
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
        VStack(alignment: .leading, spacing: Pearl.Space.md) {
            // With one monitor the total would only repeat its line.
            if monitors.count > 1 { total(monitors) }
            // Tiles where there is room for a few side by side (Mac, iPad); lines on a phone.
            ViewThatFits(in: .horizontal) {
                tiles(monitors, paused: paused)
                    .frame(minWidth: 600, idealWidth: 600, maxWidth: .infinity)
                lines(monitors, paused: paused)
            }
        }
    }

    // MARK: the total

    /// The fleet's hashrate in big type, then rigs online and what reached the payout
    /// addresses in the last 24h.
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

        var parts: [Text] = []
        if rigs > 0 {
            parts.append(Text(Loc("%@ 在线", "\(up)/\(rigs)")).foregroundStyle(up < rigs ? Color.orange : Color.secondary))
        }
        var note: String?
        if !addresses.isEmpty, !chainLoading, !received.isEmpty {
            let sum = received.reduce(0, +)
            var line = Loc("近 24h") + " +" + f(sum, abs(sum) < 0.01 ? 4 : 2) + " PRL"
            if let usd = store.prlUsd, sum > 0 { line += " ≈ " + currency.primaryString(sum * usd) }
            parts.append(Text(line))
            if !uncounted.isEmpty { note = Loc("不含 %@", uncounted.joined(separator: ", ")) }
        }
        let status = joined(parts)

        return VStack(alignment: .leading, spacing: 2) {
            Text(rate > 0 ? formatHashrate(rate) : "—")
                .font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            if !parts.isEmpty {
                // On one line where it fits; else the note drops to a line of its own
                // rather than the line breaking inside it.
                ViewThatFits(in: .horizontal) {
                    joined(parts + (note.map { [Text($0)] } ?? [])).lineLimit(1)
                    VStack(alignment: .leading, spacing: 1) {
                        status.fixedSize(horizontal: false, vertical: true)
                        if let note { Text(note) }
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "a · b · c"
    private func joined(_ parts: [Text]) -> Text {
        parts.enumerated().reduce(Text(verbatim: "")) { acc, item in
            item.offset == 0 ? item.element : acc + Text(verbatim: " · ") + item.element
        }
    }

    // MARK: a phone — one line per monitor

    private func lines(_ monitors: [CompactMonitor], paused: [PoolWatch]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(monitors.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Divider().padding(.leading, Self.lineInset) }
                Button { onOpen(m.watch) } label: { line(m) }
                    .buttonStyle(LineButtonStyle())
                    .modifier(MonitorActions(watch: m.watch, store: store, dragging: $dragging, onEdit: onEdit))
            }
            if !paused.isEmpty {
                if !monitors.isEmpty { Divider() }
                pausedFold(paused)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Pearl.Radius.md, style: .continuous))
        .pearlCard(padding: 0)
    }

    private static let lineInset: CGFloat = 14 + 28 + 12

    private func line(_ m: CompactMonitor) -> some View {
        HStack(spacing: 12) {
            PoolIcon(pool: m.watch.pool, size: 28)
            Text(m.watch.displayName).lineLimit(1)
            Spacer(minLength: 8)
            if m.loading {
                ProgressView().controlSize(.small)
            } else {
                // Down rigs are the one thing worth a second look: count them, in the dot's colour.
                if m.partlyOffline {
                    Text(verbatim: "\(m.up)/\(m.total)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(m.statusColor)
                }
                Text(m.rateText).font(.body.weight(.medium).monospacedDigit()).lineLimit(1)
                Circle().fill(m.statusColor).frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityValue(m.detailText)
    }

    // MARK: Mac / iPad — one tile per monitor

    private func tiles(_ monitors: [CompactMonitor], paused: [PoolWatch]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !monitors.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    ForEach(monitors) { m in
                        Button { onOpen(m.watch) } label: { tile(m) }
                            .buttonStyle(TileButtonStyle())
                            .modifier(MonitorActions(watch: m.watch, store: store, dragging: $dragging, onEdit: onEdit))
                    }
                }
            }
            if !paused.isEmpty {
                VStack(spacing: 0) { pausedFold(paused) }
                    .clipShape(RoundedRectangle(cornerRadius: Pearl.Radius.sm, style: .continuous))
                    .pearlCard(padding: 0, radius: Pearl.Radius.sm)
            }
        }
    }

    private func tile(_ m: CompactMonitor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PoolIcon(pool: m.watch.pool, size: 22)
                Text(m.watch.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Circle().fill(m.statusColor).frame(width: 8, height: 8)
            }
            Group {
                if m.loading { ProgressView().controlSize(.small) }
                else { Text(m.rateText).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit() }
            }
            .frame(height: 26, alignment: .leading)
            .lineLimit(1).minimumScaleFactor(0.6)
            Text(m.detailText)
                .font(.caption)
                .foregroundStyle(m.data?.error != nil ? Color.red : m.partlyOffline ? m.statusColor : Color.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard(padding: 14, radius: Pearl.Radius.sm)
        .accessibilityElement(children: .combine)
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
            .padding(.horizontal, 14).padding(.vertical, 12)
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
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .buttonStyle(LineButtonStyle())
                .modifier(MonitorActions(watch: w, store: store, dragging: $dragging, onEdit: onEdit))
            }
        }
    }
}

/// What a line or tile offers besides opening: the card's ⋯ actions on a long press /
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
            let shape = RoundedRectangle(cornerRadius: Pearl.Radius.sm, style: .continuous)
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
