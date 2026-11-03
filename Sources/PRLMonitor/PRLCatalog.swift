import SwiftUI

// MARK: - 显卡对比
//   regular (iPad / Mac): the table on the left, the selected card's detail beside it
//   compact (iPhone): the table; a tap drills into the detail
//
// The table is one card with its column titles written once (显卡 · 自有 · 租用, per day),
// a row per GPU — its name and specs, then the two daily figures in aligned columns.
// Only gains are coloured: a loss is the grey of a figure that doesn't pay, not a column
// of red. The detail is a plain form: what owning it nets, then what renting it nets.

struct CatalogSection: View {
    @ObservedObject var store: PRLStore
    @Environment(\.horizontalSizeClass) private var hsc
    @State private var pushed: String?      // compact: GPU name pushed onto the stack

    var body: some View {
        // Every figure here is derived from the live 币价/全网算力. Until the
        // first successful fetch (live mode), show a placeholder instead of
        // ranking cards by stale defaults.
        let ready = !store.live || store.liveReady
        Group {
            if !ready {
                PearlEmptyState(systemImage: "antenna.radiowaves.left.and.right",
                    title: Loc("等待联网行情…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if hsc == .compact {
                table(compact: true)
                    .navigationDestination(item: $pushed) { name in
                        GPUDetailView(store: store, name: name)
                    }
            } else {
                HStack(spacing: 0) {
                    table(compact: false)
                        .frame(minWidth: 360)
                    Divider()
                    GPUDetailView(store: store, name: store.selected)
                        .frame(width: 380)
                }
            }
        }
    }

    private func table(compact: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                // The menu's own wording ("按自有净利") says what it does.
                Picker(Loc("排序"), selection: $store.sortKey) {
                    ForEach(SortKey.allCases) { Text(Loc($0.rawValue)).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden()
                .fixedSize()

                VStack(spacing: 0) {
                    GPUTableHeader(rent: store.rentEnabled)
                    ForEach(store.calcs(), id: \.g.name) { k in
                        Divider().padding(.leading, Pearl.Space.md)
                        Button {
                            if compact { pushed = k.g.name } else { store.selected = k.g.name }
                        } label: {
                            GPURow(store: store, k: k,
                                   selected: !compact && store.selected == k.g.name,
                                   showChevron: compact)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .pearlCard(padding: 0, radius: Pearl.Radius.md)
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The figure columns' width, shared by the header and the rows so they line up.
private let gpuFigureWidth: CGFloat = 64

/// Column titles, once for the whole table.
private struct GPUTableHeader: View {
    let rent: Bool
    var body: some View {
        HStack(spacing: Pearl.Space.xs) {
            Text(Loc("显卡"))
            Spacer(minLength: Pearl.Space.xs)
            Text(Loc("自有") + Loc("/天")).frame(width: gpuFigureWidth, alignment: .trailing)
            if rent {
                Text(Loc("租用") + Loc("/天")).frame(width: gpuFigureWidth, alignment: .trailing)
            }
            // Room for the rows' chevron.
            Color.clear.frame(width: 8, height: 1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1).minimumScaleFactor(0.8)
        .padding(.horizontal, Pearl.Space.md)
        .padding(.vertical, Pearl.Space.xs + 2)
        .accessibilityHidden(true)
    }
}

/// A GPU in the table: name and specs, then what it nets a day owned (and rented).
struct GPURow: View {
    @ObservedObject var store: PRLStore
    let k: Calc
    let selected: Bool
    var showChevron: Bool = false

    var body: some View {
        let c = store.cfg
        let own = k.ownNet * c.fx
        let rent = store.rentNetUSD(k) * c.fx
        HStack(spacing: Pearl.Space.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(k.g.name).font(.body.weight(.semibold))
                    .lineLimit(1).minimumScaleFactor(0.85)
                Text(formatHashrate(k.g.pearl * 1e12) + " · " + f(k.g.watts, 0) + " W")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: Pearl.Space.xs)
            figure(own, weight: .semibold)
            if store.rentEnabled { figure(rent, weight: .regular) }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                .frame(width: 8)
                .opacity(showChevron ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Pearl.Space.md)
        .padding(.vertical, Pearl.Space.sm)
        .background(selected ? Pearl.accent.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(k.g.name)
        .accessibilityValue(spoken(own: own, rent: rent))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func spoken(own: Double, rent: Double) -> String {
        var parts = [Loc("自有净利") + " " + money(own)]
        if store.rentEnabled { parts.append(Loc("租净利") + " " + money(rent)) }
        return parts.joined(separator: ", ")
    }

    /// A daily figure: green when it pays, grey when it doesn't.
    private func figure(_ v: Double, weight: Font.Weight) -> some View {
        Text(money(v))
            .font(.callout.weight(weight)).monospacedDigit()
            .foregroundStyle(v > 0 ? AnyShapeStyle(Color.green) : AnyShapeStyle(.secondary))
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(width: gpuFigureWidth, alignment: .trailing)
    }

    private func money(_ v: Double) -> String {
        (v < 0 ? "-" : "") + store.localSymbol + f(abs(v), 1)
    }
}

// MARK: - Detail

struct GPUDetailView: View {
    @ObservedObject var store: PRLStore
    let name: String?
    @Environment(\.horizontalSizeClass) private var hsc

    var body: some View {
        Group {
            if let name, let g = gpu(name) {
                form(g)
            } else {
                PearlEmptyState(systemImage: "hand.point.left", title: Loc("← 选一张显卡"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if os(iOS)
        .navigationTitle(name ?? Loc("显卡"))
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func form(_ g: GPU) -> some View {
        let c = store.cfg
        let k = compute(g, c)
        return Form {
            Section {
                // Beside the table there is no navigation title to name the card.
                if hsc != .compact {
                    Text(g.name).font(.title2.bold())
                }
                LabeledContent(Loc("算力"), value: formatHashrate(g.pearl * 1e12))
                LabeledContent(Loc("功耗"), value: f(g.watts, 0) + " W")
                LabeledContent(Loc("价格"), value: "$" + f(g.price, 0))
            }
            .pearlListRowSurface()

            Section(Loc("自有")) {
                LabeledContent(Loc("自有净利")) {
                    Text(local(k.ownNet * c.fx, 1) + Loc("/天"))
                        .font(.headline).monospacedDigit().foregroundStyle(profitColor(k.ownNet))
                }
                row(Loc("日产"), f(k.dailyPRL, 2) + " PRL")
                row(Loc("毛收入"), local(k.grossRev * c.fx, 1) + Loc("/天"))
                row(Loc("扣抽水后"), local(k.netRev * c.fx, 1) + Loc("/天"))
                row(Loc("电费"), local(k.power * c.fx, 1) + Loc("/天"))
                LabeledContent {
                    Text(local(k.net30 * c.fx, 0)).monospacedDigit().foregroundStyle(profitColor(k.net30))
                } label: {
                    HStack(spacing: 4) {
                        Text(Loc("30天净"))
                        // The 30/90-day figures already decay with the monthly growth set in 参数.
                        if c.diffGrowthMonthly != 0 {
                            PearlInfoTip(Loc("难度月增 %@%% → 出币逐日衰减", f(c.diffGrowthMonthly, 0)),
                                         title: Loc("30天净"))
                        }
                    }
                }
                LabeledContent(Loc("90天净")) {
                    Text(local(k.net90 * c.fx, 0)).monospacedDigit().foregroundStyle(profitColor(k.net90))
                }
            }
            .pearlListRowSurface()

            rentSection(c, k)
                .pearlListRowSurface()
        }
        .formStyle(.grouped)
        .pearlListBackground()
    }

    /// Renting: the price it breaks even at, always; with 租用 on, this card's rent and
    /// what it leaves — and how far price or network hashrate can move before it doesn't.
    @ViewBuilder private func rentSection(_ c: Config, _ k: Calc) -> some View {
        let name = k.g.name
        let rentDay = store.rent(for: name)
        let r = rentDay / c.fx
        let extra = store.rentCoversPower ? 0 : k.power
        let cost = r + extra
        let net = k.netRev - cost
        let roi = cost > 0 ? net / cost * 100 : 0
        let bePrice = k.dailyPRL > 0 ? cost / (k.dailyPRL * (1 - c.poolFee)) : 0
        let beNet = cost > 0 ? c.nethashEH * (k.netRev / cost) : 0
        let beHr = store.beRentDayUSD(k) / 24
        Section {
            LabeledContent(Loc("盈亏平衡租金")) {
                Text(local(beHr * c.fx, 2) + Loc("/小时"))
                    .font(.headline).monospacedDigit().foregroundStyle(Pearl.accent)
            }
            if store.rentEnabled {
                Stepper(value: Binding(get: { store.rentHour(for: name) }, set: { store.setRentHour(name, $0) }),
                        in: 0...125, step: 0.5) {
                    LabeledContent(Loc("租金")) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(local(rentDay / 24, 2) + Loc("/小时")).monospacedDigit()
                            Text("≈ " + local(rentDay, 0) + Loc("/天"))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                Toggle(Loc("租金含电费"), isOn: $store.rentCoversPower)
                LabeledContent(Loc("租净利")) {
                    Text(local(net * c.fx, 1) + Loc("/天"))
                        .font(.headline).monospacedDigit().foregroundStyle(profitColor(net))
                }
                row(Loc("回报"), f(roi, 0) + "%")
                row(Loc("保本币价"), "$" + f(bePrice, 3))
                row(Loc("保本全网算力"), f(beNet, 1) + " EH/s")
            }
        } header: {
            HStack {
                Text(Loc("租用"))
                Spacer()
                if store.rentEnabled {
                    Text(net > 0 ? Loc("划算") : Loc("不划算"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(net > 0 ? Color.green : Color.secondary)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).monospacedDigit() }
    }

    private func local(_ v: Double, _ digits: Int) -> String {
        (v < 0 ? "-" : "") + store.localSymbol + f(abs(v), digits)
    }
}
