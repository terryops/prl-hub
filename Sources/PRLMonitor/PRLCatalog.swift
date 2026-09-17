import SwiftUI

// MARK: - 显卡对比（自适应 master-detail，替换 macOS-only 的 HSplitView）
//   regular(iPad/Mac)：左列表 + 右详情并排
//   compact(iPhone)：列表，点选下钻到详情页

struct CatalogSection: View {
    @ObservedObject var store: PRLStore
    @Environment(\.horizontalSizeClass) private var hsc
    @State private var pushed: String?      // compact: GPU name pushed onto the stack

    var body: some View {
        // Every figure here is derived from the live 币价/全网算力. Until the
        // first successful fetch (live mode), show a placeholder instead of
        // ranking cards by stale defaults.
        let ready = !store.live || store.liveReady
        VStack(spacing: 0) {
            HStack {
                Text(Loc("排序")).font(.subheadline).foregroundColor(.secondary)
                Picker(Loc("排序"), selection: $store.sortKey) {
                    ForEach(SortKey.allCases) { Text(Loc($0.rawValue)).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden()
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 8)
            Divider()

            if !ready {
                PearlEmptyState(systemImage: "antenna.radiowaves.left.and.right",
                    title: Loc("等待联网行情…"),
                    message: Loc("拿到最新币价 / 全网算力后，再显示各显卡的收益对比"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hsc == .compact {
                List {
                    ForEach(store.calcs(), id: \.g.name) { k in
                        Button { pushed = k.g.name } label: {
                            GPURow(store: store, k: k, selected: false, showChevron: true)
                        }
                        .buttonStyle(.plain)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .pearlListBackground()
                .navigationDestination(item: $pushed) { name in
                    GPUDetailView(store: store, name: name)
                }
            } else {
                HStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: Pearl.Space.xs) {
                            ForEach(store.calcs(), id: \.g.name) { k in
                                GPURow(store: store, k: k, selected: store.selected == k.g.name)
                                    .contentShape(Rectangle())
                                    .onTapGesture { store.selected = k.g.name }
                            }
                        }
                        .padding(Pearl.Space.screen)
                    }
                    .frame(minWidth: 360)
                    Divider()
                    GPUDetailView(store: store, name: store.selected)
                        .frame(width: 360)
                }
            }
        }
    }
}

/// 列表行：自适应，紧凑屏只显示关键列。
struct GPURow: View {
    @ObservedObject var store: PRLStore
    let k: Calc
    let selected: Bool
    var showChevron: Bool = false
    var body: some View {
        let c = store.cfg
        let rentNet = store.rentNetUSD(k) * c.fx
        let positive = k.ownNet > 0
        HStack(spacing: Pearl.Space.sm) {
            PearlIconBadge(systemImage: "memorychip",
                gradient: selected ? Pearl.brandVivid : (positive ? Pearl.positive : Pearl.negative),
                size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(k.g.name).font(.body.bold())
            }
            Spacer(minLength: Pearl.Space.xs)
            VStack(alignment: .trailing, spacing: 2) {
                Text(store.sym(Loc("自有 ¥")) + f(k.ownNet * c.fx, 1)).font(.callout.monospacedDigit().bold())
                    .foregroundColor(positive ? .green : .red)
                if store.rentEnabled {
                    Text(store.sym(Loc("租净 ¥")) + f(rentNet, 1)).font(.caption.monospacedDigit())
                        .foregroundColor(rentNet > 0 ? .green : .red)
                } else {
                    Text(formatHashrate(k.g.pearl * 1e12) + " · " + f(k.dailyPRL, 1) + "/d").font(.caption.monospacedDigit()).foregroundColor(.secondary)
                }
            }
            // Chevron lives INSIDE the card (not as the List's detached accessory)
            // so the row reads as one cohesive tappable card.
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 2)
            }
        }
        .padding(.vertical, Pearl.Space.sm).padding(.horizontal, Pearl.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: Pearl.Radius.sm, style: .continuous)
                .fill(selected ? Pearl.accent.opacity(0.22)
                      : (positive ? Pearl.teal.opacity(0.10) : Pearl.rose.opacity(0.12)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Pearl.Radius.sm, style: .continuous)
                .strokeBorder(selected ? Pearl.accent.opacity(0.55)
                              : (positive ? Pearl.teal.opacity(0.30) : Pearl.rose.opacity(0.30)),
                              lineWidth: 1)
        )
    }
}

struct GPUDetailView: View {
    @ObservedObject var store: PRLStore
    let name: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                if let name, let g = gpu(name) {
                    let c = store.cfg; let k = compute(g, c)
                    HStack(spacing: Pearl.Space.sm) {
                        PearlIconBadge(systemImage: "memorychip", gradient: Pearl.brandVivid, size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name).font(.title.bold())
                        }
                    }
                    VStack(alignment: .leading, spacing: Pearl.Space.xs) {
                        info(Loc("算力"), formatHashrate(g.pearl * 1e12) + " · " + f(g.watts, 0) + "W · $" + f(g.price, 0))
                        info(Loc("日产"), f(k.dailyPRL, 2) + " PRL")
                        info(Loc("毛收入"), "$" + f(k.grossRev, 2) + Loc("/天"))
                        info(Loc("扣抽水"), store.localSymbol + f(k.netRev * c.fx, 1) + Loc("/天"))
                        info(Loc("电费"), store.localSymbol + f(k.power * c.fx, 1) + Loc("/天"))
                        info(Loc("自有净利"), store.localSymbol + f(k.ownNet * c.fx, 1) + Loc("/天"), k.ownNet > 0 ? .green : .red)
                        info(Loc("30天净"), store.localSymbol + f(k.net30 * c.fx, 0), k.net30 > 0 ? .green : .red)
                        info(Loc("90天净"), store.localSymbol + f(k.net90 * c.fx, 0), k.net90 > 0 ? .green : .red)
                        if c.diffGrowthMonthly != 0 {
                            Text(Loc("↑ 已按难度月增 %@%% 衰减；在【参数】可调", f(c.diffGrowthMonthly,0)))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .pearlCard()
                    let beDay = store.beRentDayUSD(k); let beHr = beDay / 24
                    VStack(alignment: .leading, spacing: Pearl.Space.xs) {
                        Text(store.rentCoversPower ? Loc("★ 盈亏平衡租金（含电）") : Loc("★ 盈亏平衡租金（不含电）")).font(.headline)
                        Text(store.localSymbol + f(beHr * c.fx, 2) + "/h · $" + f(beHr, 3) + "/h")
                            .font(.system(.title3, design: .rounded).weight(.bold)).foregroundColor(.teal)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        Text("= " + store.localSymbol + f(beDay * c.fx, 1) + Loc("/天 · $") + f(beDay, 2) + Loc("/天"))
                            .font(.callout).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pearlAccentCard(gradient: Pearl.mint)
                    if store.rentEnabled { rentBlock(c, k) }
                } else {
                    PearlEmptyState(systemImage: "hand.point.left",
                        title: Loc("← 选一张显卡"),
                        message: Loc("从左侧列表挑一张显卡，查看收益与盈亏平衡分析"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, Pearl.Space.xl)
                }
            }
            .padding(Pearl.Space.screen).frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        .navigationTitle(name ?? Loc("显卡"))
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder func info(_ k: String, _ v: String, _ color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.callout).foregroundColor(.secondary).frame(width: 76, alignment: .leading)
            Text(v).font(.callout).foregroundColor(color).monospacedDigit()
            Spacer()
        }
    }

    @ViewBuilder func rentBlock(_ c: Config, _ k: Calc) -> some View {
        let name = k.g.name
        let rentDay = store.rent(for: name)
        let r = rentDay / c.fx
        let extra = store.rentCoversPower ? 0 : k.power
        let cost = r + extra
        let net = k.netRev - cost
        let roi = cost > 0 ? net / cost * 100 : 0
        let bePrice = k.dailyPRL > 0 ? cost / (k.dailyPRL * (1 - c.poolFee)) : 0
        let beNet = cost > 0 ? c.nethashEH * (k.netRev / cost) : 0
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            HStack {
                Text(Loc("租用分析（本卡）")).font(.headline)
                Spacer()
                Text(net > 0 ? Loc("✅ 划算") : Loc("❌ 不划算")).font(.callout.bold())
                    .padding(.horizontal, Pearl.Space.sm).padding(.vertical, Pearl.Space.xxs)
                    .background(net > 0 ? Color.green.opacity(0.2) : Color.red.opacity(0.2), in: Capsule())
                    .foregroundColor(net > 0 ? .green : .red)
            }
            Stepper(value: Binding(get: { store.rentHour(for: name) }, set: { store.setRentHour(name, $0) }), in: 0...125, step: 0.5) {
                Text(store.sym(Loc("本卡租金 ¥")) + f(rentDay / 24, 2) + Loc("/小时")).font(.callout.monospacedDigit())
            }
            info(Loc("折合"), store.localSymbol + f(rentDay, 0) + Loc("/天 · $") + f(rentDay / c.fx, 2) + Loc("/天"))
            Toggle(Loc("租金含电费"), isOn: $store.rentCoversPower).font(.callout).toggleStyle(.switch)
            info(Loc("租净利"), store.localSymbol + f(net * c.fx, 1) + Loc("/天 · 回报 ") + f(roi, 0) + "%", net > 0 ? .green : .red)
            info(Loc("安全垫"), Loc("币价 $") + f(bePrice, 3) + Loc(" 归零"))
            info("", Loc("全网 ") + f(beNet, 1) + Loc(" EH/s 归零"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard()
    }
}
