import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Mining monitor: per-miner watches you add (AlphaPool / Lucky Pool, by address),
/// plus pool-level overview + an efficiency comparison across all pools.
struct PoolView: View {
    @StateObject private var store = PoolStore()
    @EnvironmentObject private var wallet: WalletStore

    @State private var adding = false
    /// nil = the sheet is adding a new watch; non-nil = editing this watch in place.
    @State private var editingID: UUID?
    @State private var newPool: PoolKind = .alphaPool
    @State private var newAddr = ""
    @State private var newAlias = ""
    @State private var draggingWatch: PoolWatch?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                    HStack(spacing: Pearl.Space.sm) {
                        PearlSectionHeader(Loc("我的监控"), systemImage: "square.stack.3d.up.fill")
                        Button { editingID = nil; newAddr = ""; newAlias = ""; newPool = .alphaPool; adding = true } label: {
                            Label(Loc("添加"), systemImage: "plus")
                        }.font(.callout)
                    }

                    if store.watches.isEmpty {
                        VStack(spacing: Pearl.Space.sm) {
                            PearlEmptyState(systemImage: "square.stack.3d.up",
                                            title: Loc("添加挖矿监控"),
                                            message: Loc("点「添加」，选择矿池并填入你的 Pearl 收款地址。可添加多个地址 / 多个矿池。"))
                            // Says plainly what this screen is: a reader of pool APIs. The
                            // device does no mining of any kind (App Store 3.1.5(ii)).
                            Text(Loc("Pearl Hub 本身不挖矿，仅读取矿池公开数据。"))
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        // Cards: at most 2 per row, laid out by hand (an HStack per row)
                        // rather than LazyVGrid — a grid sizes each cell to its own
                        // content and never stretches a short cell up to the row height,
                        // so two cards with different miner counts couldn't bottom-align
                        // their 链上到账 footers. HStack(alignment:.top) proposes the
                        // row's tallest height to both cards, so each card
                        // (maxHeight:.infinity) fills it and pins its footer to the
                        // bottom. ViewThatFits picks the 2-up form (each card ≥440pt, so
                        // two need ≥902pt) and falls back to 1-up when too narrow (iPhone).
                        ViewThatFits(in: .horizontal) {
                            cardColumns(2)
                            cardColumns(1)
                        }
                    }

                }
                .animation(.snappy, value: store.watches)
                .animation(.snappy, value: store.loading)
                .padding(Pearl.Space.screen).frame(maxWidth: 1200).frame(maxWidth: .infinity)
            }
            // A drop anywhere in the scroll area — not just onto a card (that's the card's own
            // DropDelegate) — ends the drag and persists the order immediately. This is the
            // fast path only: PoolStore.moveWatch also debounce-commits, so an order still
            // survives a drag the system cancels without calling anyone back.
            .onDrop(of: [.text], isTargeted: nil) { _ in
                let reordered = draggingWatch != nil
                draggingWatch = nil
                if reordered { store.commitWatchOrder() }
                return reordered
            }
            .navigationTitle(Loc("我的监控"))
            .toolbar {
                Button { Task { await store.refresh() } } label: {
                    // .small so the in-toolbar spinner stays icon-sized — a default
                    // ProgressView fills the macOS toolbar button's glass background
                    // and reads as a big white badge.
                    if store.loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(store.loading)
                .accessibilityLabel(Loc("刷新矿池数据"))
            }
            // Auto-refresh while the tab is visible: load immediately, then every
            // 60s. SwiftUI cancels this .task when the view disappears, which both
            // ends the loop and cancels an in-flight fetch (fetchWatchData returns
            // nil on cancellation, so cards keep their last state).
            .task {
                while !Task.isCancelled {
                    await store.refresh()
                    try? await Task.sleep(for: .seconds(60))
                }
            }
            .refreshable { await store.refresh() }
            // The good moment for the 评分提醒: the user's own rigs just reported in, so the
            // app has visibly done its job. Every other gate (launches, days installed, once
            // per version) lives in ReviewPrompt.
            .reviewPrompt(whenSucceeded: store.watches.contains {
                store.watchData[$0.id]?.found == true
            })
            .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidUpdate)) { _ in
                store.reloadWatches()   // a watch was added/removed on another device
            }
            .sheet(isPresented: $adding) { watchSheet }
        }
    }

    /// Lay the monitor cards out in `cols` equal-width columns. Each row is a
    /// CardRow that equalizes its own cards' heights so their 链上到账 footers line
    /// up — row-scoped, so a lone trailing card isn't stretched to match other rows.
    @ViewBuilder private func cardColumns(_ cols: Int) -> some View {
        let rows = stride(from: 0, to: store.watches.count, by: cols).map {
            Array(store.watches[$0 ..< min($0 + cols, store.watches.count)])
        }
        VStack(spacing: Pearl.Space.lg) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                CardRow(watches: row, cols: cols, store: store, dragging: $draggingWatch, onEdit: beginEdit)
            }
        }
    }

    /// Open the sheet in edit mode, pre-filled with this watch's pool/address/alias.
    private func beginEdit(_ w: PoolWatch) {
        editingID = w.id
        newPool = w.pool
        newAddr = w.address
        newAlias = w.alias ?? ""
        adding = true
    }

    // MARK: add / edit sheet

    /// F2Pool is the one pool a user can't just paste an address into — the link has to be
    /// generated, and generated with the right coin + permissions, so the sheet walks them
    /// through it rather than leaving a dead end. Permission "收益数据（不含付款信息）" hides the
    /// payout table we sum for 累计已付, hence the caveat.
    @ViewBuilder
    private var readOnlyPageGuide: some View {
        Section(Loc("如何获取只读页链接")) {
            VStack(alignment: .leading, spacing: 8) {
                guideStep(1, Loc("登录 f2pool 网站，点右上角头像 →「账户设置」。"))
                guideStep(2, Loc("左侧选「只读页面」，点「生成」。"))
                guideStep(3, Loc("币种勾选 PRL；权限勾选「算力与矿机列表」和「收益数据（含付款信息）」。"))
                guideStep(4, Loc("生成后复制链接，粘贴到上面即可。"))
            }
            .padding(.vertical, 2)
            Text(Loc("权限若只给「不含付款信息」，其余都能看，但「累计已付」会显示 0。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(Loc("链接是只读的，不能动用资金，且可随时在 F2Pool 撤销。"))
                .font(.caption).foregroundStyle(.secondary)
            if let u = URL(string: "https://f2pool.zendesk.com/hc/en-us/articles/360058722231") {
                Link(Loc("查看 F2Pool 官方图文教程"), destination: u).font(.caption)
            }
        }
    }

    private func guideStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(.tint))
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var watchSheet: some View {
        NavigationStack {
            Form {
                Section(Loc("矿池")) {
                    // .menu rather than .segmented — with 4+ pools the long names
                    // overflow a segmented control on iPhone.
                    Picker(Loc("矿池"), selection: $newPool) {
                        ForEach(PoolKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Text(newPool.isAddressBased
                         ? (editingID == nil
                            ? Loc("选择矿池后，填入你的 Pearl 收款地址即可查询。")
                            : Loc("更换矿池后将按新矿池重新查询该地址的挖矿数据。"))
                         : Loc("F2Pool 不支持按地址查询，请粘贴账户的只读页链接。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(newPool.isAddressBased ? Loc("挖矿地址") : Loc("只读页链接")) {
                    // Explicit row label + prompt: in a macOS grouped Form the
                    // TextField TITLE renders as the leading label, so a
                    // placeholder-as-title reads as row content with no visible
                    // input — keep the two roles separate.
                    TextField(newPool.isAddressBased ? Loc("地址") : Loc("链接"), text: $newAddr,
                              prompt: Text(verbatim: newPool.isAddressBased
                                           ? "prl1…" : "https://www.f2pool.com/mining-user/…"))
                        .font(.body.monospaced())
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)   // visible box so the input is obvious
                        #endif
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                    // Say WHY 添加 is greyed out. A silently-disabled confirm button is a dead
                    // end: the user sees their link sitting in the field and nothing to press.
                    if !newAddr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       normalizeWatchAddress(newPool, newAddr) == nil {
                        Label(newPool.isAddressBased
                              ? Loc("地址格式不正确")
                              : Loc("没认出只读页链接，请粘贴 F2Pool 生成的完整链接。"),
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if newPool.isAddressBased, let w = wallet.address {
                        Button(Loc("用我的钱包地址")) { newAddr = w }.font(.caption)
                    }
                    Button(Loc("粘贴")) {
                        #if os(iOS)
                        if let s = UIPasteboard.general.string { newAddr = s }
                        #else
                        if let s = NSPasteboard.general.string(forType: .string) { newAddr = s }
                        #endif
                    }.font(.caption)
                }
                if !newPool.isAddressBased { readOnlyPageGuide }
                // Alias LAST and de-emphasized — it's the only optional field.
                // The prompt shows the current pool's name to make the fallback
                // obvious: leave it empty and the card is titled after the pool.
                Section(Loc("别名（可选）")) {
                    TextField(Loc("别名"), text: $newAlias, prompt: Text(newPool.label))
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        #if os(iOS)
                        .autocorrectionDisabled()
                        #endif
                    Text(Loc("不填则直接显示矿池名称。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(editingID == nil ? Loc("添加监控") : Loc("编辑监控"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Loc("取消")) { adding = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingID == nil ? Loc("添加") : Loc("保存")) {
                        if let id = editingID {
                            store.updateWatch(id, pool: newPool, address: newAddr, alias: newAlias)
                        } else {
                            store.addWatch(pool: newPool, address: newAddr, alias: newAlias)
                        }
                        adding = false
                    }
                    .disabled(normalizeWatchAddress(newPool, newAddr) == nil)
                }
            }
            .frame(minWidth: 360, minHeight: 280)
        }
    }

}

/// Tallest monitor-card body in a row, so the others can match it (equal-height
/// cards → their bottom-pinned 链上到账 footers line up). Reduces to the max.
private struct CardBodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One row of up to `cols` monitor cards, kept to a shared height so their
/// bottom-pinned 链上到账 footers line up. The height is measured from this row's
/// own cards (CardBodyHeightKey) — row-scoped, so a lone trailing card or a taller
/// neighbouring row never stretches it. A vertical ScrollView proposes unbounded
/// height, so HStack/grid never hand a short card a concrete height; the measured
/// `rowHeight` fed back as each card's minHeight is what actually equalizes them.
private struct CardRow: View {
    let watches: [PoolWatch]
    let cols: Int
    @ObservedObject var store: PoolStore
    @Binding var dragging: PoolWatch?
    let onEdit: (PoolWatch) -> Void
    @State private var rowHeight: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: Pearl.Space.lg) {
            ForEach(watches) { w in
                // ≥440pt per card only in 2-up, so ViewThatFits can reject it when
                // narrow; 0 (= no min) in 1-up so the card fits an iPhone's width.
                card(w).frame(minWidth: cols > 1 ? 440 : 0, maxWidth: .infinity)
            }
            // Hold a lone trailing card to one column's width, not the whole row.
            if watches.count < cols { Color.clear.frame(maxWidth: .infinity) }
        }
        .onPreferenceChange(CardBodyHeightKey.self) { rowHeight = $0 }
    }

    @ViewBuilder private func card(_ w: PoolWatch) -> some View {
        // Equal heights only matter for side-by-side cards, so only pin in 2-up.
        WatchCard(watch: w, data: store.watchData[w.id],
                  onchain24h: store.onchain24h[w.id], onchain7d: store.onchain7d[w.id],
                  onchainTotal: store.onchainTotal[w.id],
                  prlUsd: store.prlUsd, minBodyHeight: cols > 1 ? rowHeight : 0,
                  onEdit: { onEdit(w) },
                  onDelete: { store.removeWatch(w.id) },
                  onRename: { store.renameWatch(w.id, alias: $0) },
                  onSetEnabled: { store.setEnabled(w.id, $0) })
        // NO source-dimming here, deliberately. It used to render at 0.5 opacity while
        // `dragging` pointed at this card — but `dragging` is only ever cleared from a drop
        // callback, and the system fires none when it CANCELS a drag (released where nothing
        // accepts it, or over the window chrome), so the card stayed grey until relaunch.
        // The drag is already legible without it: the system carries a floating preview and
        // the cards reorder live under it (dropEntered), which is the better signal anyway.
        .onDrag {
            dragging = w
            return NSItemProvider(object: w.id.uuidString as NSString)
        }
        .onDrop(of: [.text],
                delegate: WatchDropDelegate(item: w, store: store, dragging: $dragging))
    }
}

// MARK: - drag-to-reorder

/// Live-reorders `store.watches` as a dragged card hovers over another card, then
/// persists the new order when the drop lands. Drives drag-to-reorder in “我的监控”.
private struct WatchDropDelegate: DropDelegate {
    let item: PoolWatch
    let store: PoolStore
    @Binding var dragging: PoolWatch?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != item.id,
              let from = store.watches.firstIndex(where: { $0.id == dragging.id }),
              let to = store.watches.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation(.snappy) {
            store.moveWatch(from: from, to: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        store.commitWatchOrder()
        return true
    }
}

// MARK: - per-watch card

/// "≈ $52.96 · ¥359" for a PRL amount — the secondary part follows the user's
/// chosen secondary currency (omitted when set to "none"). Returns nil if the
/// live PRL price isn't in yet (caller then shows nothing — never a default).
@MainActor
fileprivate func fiatLabel(_ prl: Double, prlUsd: Double?, currency: CurrencyManager) -> String? {
    guard let prlUsd, prl > 0 else { return nil }
    return "≈ " + currency.dual(prl * prlUsd)
}

private struct WatchCard: View {
    let watch: PoolWatch
    let data: WatchData?
    let onchain24h: Double?
    let onchain7d: Double?
    let onchainTotal: Double?
    let prlUsd: Double?
    /// The tallest card's body height in the row, so every card matches it and
    /// their bottom-pinned 链上到账 footers line up. 0 = size to own content.
    var minBodyHeight: CGFloat = 0
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    let onSetEnabled: (Bool) -> Void

    @EnvironmentObject private var currency: CurrencyManager
    @State private var renaming = false
    @State private var aliasDraft = ""
    /// Hide offline rigs in the miner list. One shared, persisted flag — toggling
    /// it on any card applies to all of them.
    @AppStorage("pool.minerOnlineOnly") private var onlineOnly = false
    /// 实时(瞬时) vs 每小时(1h) hashrate for the headline stat + per-miner rows.
    /// Shared & persisted across all cards, like `onlineOnly`.
    @AppStorage("pool.speedWindow") private var speedWindow: SpeedWindow = .live

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            HStack(spacing: Pearl.Space.sm) {
                PearlIconBadge(systemImage: "person.crop.circle")
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(watch.displayName).font(.headline)
                        if !watch.isEnabled {
                            Text(Loc("已暂停"))
                                .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }
                    // When aliased, keep the underlying pool visible as a hint.
                    if watch.hasAlias {
                        Text(watch.pool.label).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button { onSetEnabled(!watch.isEnabled) } label: {
                        watch.isEnabled
                            ? Label(Loc("暂停监控"), systemImage: "pause.circle")
                            : Label(Loc("恢复监控"), systemImage: "play.circle")
                    }
                    Button(action: onEdit) { Label(Loc("编辑监控"), systemImage: "square.and.pencil") }
                    Button { aliasDraft = watch.alias ?? ""; renaming = true } label: {
                        Label(Loc("改别名"), systemImage: "pencil")
                    }
                    Button(role: .destructive, action: onDelete) { Label(Loc("删除监控"), systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .accessibilityLabel(Loc("监控选项"))
            }
            Text(watch.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)

            if !watch.isEnabled {
                // Paused: no stats, and crucially NO spinner — `data` is nil for a paused watch
                // (the store drops it), and the loading branch below would spin forever.
                VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                    Label(Loc("已暂停，不再获取数据"), systemImage: "pause.circle")
                        .font(.callout).foregroundStyle(.secondary)
                    Button { onSetEnabled(true) } label: {
                        Label(Loc("恢复监控"), systemImage: "play.fill").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Pearl.Space.xs)
            } else if let d = data {
                if d.found {
                    let sel = window(d)
                    speedPicker(d)
                    StatGrid(minimum: 140) {
                        hashStatCard(d, sel, primary: true)
                        // The second slot is the fixed reference. Normally that's 24h — but if
                        // 24h IS what's selected, showing it twice is just a duplicate, so the
                        // pool's freshest window takes the slot instead.
                        if let other = secondary(d, selected: sel) {
                            hashStatCard(d, other, primary: false)
                        }
                        StatCard(title: d.pendingLabel, value: f(d.pending, 4), sub: "PRL", color: .green)
                        StatCard(title: Loc("累计已付"), value: f(d.paid, 4), sub: "PRL")
                    }
                    if !d.workers.isEmpty { workerGroup(d.workers, sel) }
                } else if let e = d.error {
                    Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                } else {
                    Label(Loc("该地址未在 %@ 挖矿", watch.pool.label), systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                // This pool's income, INCLUDING not-yet-paid (待支付). Pool-specific
                // by construction — on-chain can't isolate one pool when several
                // pay into the same address. Pinned to the card's bottom (flexible
                // frame, .bottom) so two cards sharing a grid row line their 链上到账
                // blocks up despite differing miner counts — cards stretch to equal
                // height via .maxHeight:.infinity below + the grid's .top cells.
                //
                // Address-keyed pools only: an F2Pool watch is keyed by a read-only page
                // link, which never reveals the payout address — so there is nothing to
                // look up on-chain, and rendering the block would strand it on the
                // "链上查询中…" placeholder forever.
                if watch.pool.isAddressBased, d.found || d.paid > 0 || d.pending > 0 {
                    VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                        Divider().padding(.vertical, 1)
                        VStack(alignment: .leading, spacing: Pearl.Space.xs) {
                            HStack(spacing: 6) {
                                Image(systemName: "link").font(.caption).foregroundStyle(.green)
                                Text(Loc("链上到账")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer()
                            }
                            onchainRow(Loc("近 24h"), onchain24h, big: true)
                            onchainRow(Loc("近 7 天"), onchain7d, big: false)
                            onchainRow(Loc("累计"), onchainTotal, big: false, plus: false)
                            perPRow(hr24hRaw: d.hr24hRaw)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Loc("链上近 24h 到账 %@ PRL", f(onchain24h ?? 0, 2))
                            + (onchain7d.map { Loc("，近 7 天 %@ PRL", f($0, 2)) } ?? "")
                            + (onchainTotal.map { Loc("，累计 %@ PRL", f($0, 2)) } ?? ""))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        // Match the row's tallest card (minBodyHeight, measured by the parent) so a
        // shorter card grows and its bottom-pinned 链上到账 block aligns across the
        // row. A vertical ScrollView proposes unbounded height, so HStack/grid never
        // hand a short card a concrete height — only this explicit minHeight does.
        // The background measures the natural/grown body height back up to the parent.
        .frame(maxWidth: .infinity, minHeight: minBodyHeight, alignment: .topLeading)
        .background(GeometryReader { g in
            Color.clear.preference(key: CardBodyHeightKey.self, value: g.size.height)
        })
        .pearlCard()
        .alert(Loc("改别名"), isPresented: $renaming) {
            TextField(Loc("别名"), text: $aliasDraft)
            Button(Loc("保存")) { onRename(aliasDraft) }
            Button(Loc("取消"), role: .cancel) {}
        } message: {
            Text(Loc("给「%@」起个好记的别名；留空恢复默认。", watch.pool.label))
        }
    }

    /// The window this card is actually showing: the shared choice when this pool publishes
    /// it, else the nearest one it does (a user parked on 实时 sees F2Pool's 15分, not its 24h).
    private func window(_ d: WatchData) -> SpeedWindow {
        speedWindow.nearest(in: d.windows) ?? .day
    }

    /// The fixed second stat: 24h, unless 24h is the one selected — then the freshest window.
    private func secondary(_ d: WatchData, selected: SpeedWindow) -> SpeedWindow? {
        selected == .day ? d.windows.first(where: { $0 != .day }) : (d.windows.contains(.day) ? .day : nil)
    }

    /// 算力口径 switch for the headline stat + per-rig rows. Only the windows THIS pool
    /// publishes appear — F2Pool has no instantaneous rate (its freshest is a 15-minute
    /// average) and no 1h series, so its card offers 15分/24h and never a dead 实时 tab.
    /// Hidden entirely when the pool publishes just one window (nothing to switch between).
    @ViewBuilder private func speedPicker(_ d: WatchData) -> some View {
        if d.windows.count > 1 {
            // Bound to the RESOLVED window, not the raw shared choice: the shared choice may be
            // one this pool doesn't publish (default 实时, on an F2Pool card), and a selection
            // that matches no tag leaves a segmented control with nothing highlighted. Writing
            // still goes through to the shared value, so switching on one card moves them all.
            let sel = Binding(get: { window(d) }, set: { speedWindow = $0 })
            Picker(Loc("算力口径"), selection: sel) {
                ForEach(d.windows, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }

    /// One 算力 stat card for a window. The value is Σ per-rig where the pool reports it per
    /// rig — a true total that moves on every refresh — else the account-level figure.
    @ViewBuilder private func hashStatCard(_ d: WatchData, _ w: SpeedWindow, primary: Bool) -> some View {
        let v = d.value(w)
        StatCard(title: Loc("%@ 算力", w.label), value: v > 0 ? formatHashrate(v) : "—",
                 sub: w.sub, color: primary ? .orange : .primary)
    }

    /// Grouped, gridded miner list (instead of a scattered flat list). Each row shows that
    /// rig's hashrate for the selected window — "—" when this pool publishes that window only
    /// for the account and not per rig (Pearl Fortune). Tapping the green "N 在线" chip
    /// toggles hiding offline rigs (shared across all cards, persisted).
    @ViewBuilder private func workerGroup(_ workers: [WatchWorker], _ sel: SpeedWindow) -> some View {
        let shown = onlineOnly ? workers.filter(\.online) : workers
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(Loc("矿机 %@ 台", "\(workers.count)"), systemImage: "cpu")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button { onlineOnly.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: onlineOnly
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                        Text(Loc("%@ 在线", "\(workers.filter(\.online).count)"))
                    }
                    .font(.caption2).foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help(Loc("只看在线矿机"))
                .accessibilityLabel(Loc("只看在线矿机"))
            }
            if shown.isEmpty {
                Text(Loc("没有在线矿机")).font(.caption2).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8) {
                    // Index-keyed: pools often report several workers with the SAME name
                    // (unnamed rigs all collapse to "—"), and WatchWorker.id == name, so a
                    // name-keyed ForEach hits duplicate IDs → SwiftUI crash on refresh.
                    ForEach(Array(shown.enumerated()), id: \.offset) { _, w in
                        HStack(spacing: 6) {
                            Circle().fill(w.online ? .green : .gray).frame(width: 7, height: 7)
                            Text(w.name).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            let raw = w.rate(sel)
                            Text(raw > 0 ? formatHashrate(raw) : "—")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 每 P·天: on-chain daily income normalised to this address's 24h hashrate
    /// (P = PH/s = H/s ÷ 1e15 = 1000 T — bigger, more readable than per-T). Lumpy
    /// payouts are smoothed by dividing the 7-day income by the number of days actually
    /// mined, estimated from the 24h share (d7/d24). A steadily-mining address gives
    /// d7/d24 ≈ 7 (→ the intended /7 smoothing); an address that resumed only a day or
    /// two ago gives ≈ 1, so it isn't under-reported up to ~7×. (Lifetime-vs-7day is the
    /// WRONG gate: old income from before the window says nothing about days mined this
    /// week.) Hidden when there's no hashrate or income yet.
    @ViewBuilder private func perPRow(hr24hRaw: Double) -> some View {
        let ph = hr24hRaw / 1e15
        let d24 = onchain24h ?? 0
        let d7 = onchain7d ?? 0
        let daily: Double = {
            guard d7 > 0 else { return d24 }                  // no 7-day data → use 24h
            let days = d24 > 0 ? min(7, max(1, d7 / d24)) : 7 // active days from 24h share; steady-state if no 24h payout
            return d7 / days
        }()
        if ph > 0 && daily > 0 {
            HStack(alignment: .firstTextBaseline, spacing: Pearl.Space.xs) {
                Text(Loc("每 P·天")).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(width: 62, alignment: .leading)
                Text(f(daily / ph, 2) + " PRL/P")
                    .font(.caption.monospacedDigit()).foregroundStyle(Pearl.teal)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: Pearl.Space.xs)
                Text(Loc("实测效率")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// One clean on-chain income row: fixed-width period label, the PRL amount
    /// (scaled to fit one line, never wrapped), then the fiat estimate trailing.
    @ViewBuilder private func onchainRow(_ label: String, _ prl: Double?, big: Bool, plus: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Pearl.Space.xs) {
            Text(label)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 62, alignment: .leading)
            if let prl {
                // Precision tracks magnitude, not the row's `big` flag, so equal-sized
                // amounts render at the SAME dp (no +23.3691 next to 23.37). 4 dp only
                // for sub-0.01 dust, where 2 dp would collapse to a useless 0.00.
                Text((plus ? "+" : "") + f(prl, abs(prl) < 0.01 ? 4 : 2) + " PRL")
                    .font((big ? Font.callout.bold() : Font.caption).monospacedDigit())
                    .foregroundStyle(big ? Color.green : .primary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: Pearl.Space.xs)
                if let fx = fiatLabel(prl, prlUsd: prlUsd, currency: currency) {
                    Text(fx.replacingOccurrences(of: "≈ ", with: ""))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            } else {
                Text(Loc("链上查询中…")).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}
