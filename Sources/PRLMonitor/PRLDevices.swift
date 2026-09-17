import SwiftUI

// MARK: - 我的设备（自适应卡片，替换原版固定列宽表格）

struct DevicesSection: View {
    @ObservedObject var store: PRLStore
    @State private var askSync = false
    @State private var askNoWatch = false
    @State private var cardHeight: CGFloat = 0
    var body: some View {
        let fl = store.fleet()
        let c = store.cfg
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                HStack(alignment: .center, spacing: Pearl.Space.sm) {
                    PearlSectionHeader(Loc("我的设备"), systemImage: "cpu", subtitle: Loc("%@ 台 · %@ 卡", "\(store.devices.count)", "\(fl.cards)"))
                    Spacer(minLength: Pearl.Space.xs)
                    // tray.and.arrow.down = "import", not the circular arrows that
                    // read as refresh. Tapping ASKS first (reuses the askSync alert)
                    // instead of silently rebuilding the synced devices.
                    Button {
                        if store.poolWatchCount > 0 { askSync = true } else { askNoWatch = true }
                    } label: {
                        if store.syncing { ProgressView().controlSize(.small) }
                        else { Image(systemName: "tray.and.arrow.down") }
                    }
                    .buttonStyle(.bordered).controlSize(.large).disabled(store.syncing)
                    .help(Loc("从矿池同步：按 24h 算力把矿机同步成设备")).accessibilityLabel(Loc("从矿池同步"))
                    Button {
                        store.devices.append(Device(name: Loc("新设备"), gpu: "RTX 5080", count: 1))
                    } label: { Image(systemName: "plus") }
                        .buttonStyle(.bordered).controlSize(.large)
                        .help(Loc("添加设备")).accessibilityLabel(Loc("添加设备"))
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Pearl.Space.xl) {
                        summ(Loc("设备"), Loc("%@ 台", "\(store.devices.count)"))
                        summ(Loc("显卡"), Loc("%@ 张 自%@/租%@", "\(fl.cards)", "\(fl.ownCards)", "\(fl.rentedCards)"))
                        summ(Loc("算力"), formatHashrate(fl.pearl * 1e12))
                        summ(Loc("日净利"), store.localSymbol + f(fl.netDay * c.fx, 1), fl.netDay > 0 ? .green : .red)
                        if fl.rentDay > 0 { summ(Loc("日租金"), store.localSymbol + f(fl.rentDay * c.fx, 1), .orange) }
                        summ(Loc("自有功耗"), f(fl.watts, 0) + " W")
                    }
                    .padding(.vertical, Pearl.Space.xs)
                }
                .pearlCard(padding: Pearl.Space.lg, radius: Pearl.Radius.md)

                let effPU = store.effPerUnit(myHashPearl: fl.pearl)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Pearl.Space.lg)], spacing: Pearl.Space.lg) {
                    ForEach($store.devices) { $dev in
                        DeviceRow(store: store, dev: $dev, effPU: effPU, minBodyHeight: cardHeight)
                    }
                }
                .onPreferenceChange(DeviceCardHeightKey.self) { cardHeight = $0 }

                HStack(alignment: .top, spacing: Pearl.Space.sm) {
                    PearlIconBadge(systemImage: "info.circle", gradient: Pearl.brand, size: 30)
                    Text(store.sym(Loc("提示：自动保存。每台可选『自有』(付电费+计硬件成本) 或『租用』(按 ¥/小时 付租，全包价不另计电费/功率)。『可用h』= 每天实际挖矿小时，按比例缩放出币/电费/租金。租金单价可在此逐台调，默认值在【显卡对比】选中卡后设。")))
                        .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .pearlCard(padding: Pearl.Space.lg, radius: Pearl.Radius.md)

                // Anchor the very bottom so adding a device can scroll to it.
                Color.clear.frame(height: 1).id("devices-bottom")
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // When a device is added, jump to the bottom so the new row is visible.
        .onChange(of: store.devices.count) { old, new in
            guard new > old else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(60))
                withAnimation(.snappy) { proxy.scrollTo("devices-bottom", anchor: .bottom) }
            }
        }
        // First time in 我的设备 this launch, with pool watches set up but nothing
        // synced yet → directly ask whether to pull the miners in as devices.
        .onAppear {
            if !store.didOfferSync, store.poolWatchCount > 0, !store.hasSyncedDevices {
                store.didOfferSync = true
                askSync = true
            }
        }
        .alert(Loc("同步矿池矿机为设备？"), isPresented: $askSync) {
            Button(Loc("一键同步")) { store.syncFromPools() }
            Button(Loc("暂不"), role: .cancel) {}
        } message: {
            Text(Loc("检测到 %@ 个矿池监控，可按 24h 算力一键把矿机同步成设备。", "\(store.poolWatchCount)"))
        }
        // Sync tapped with no pool watches set up — point at the add-watch flow.
        .alert(Loc("还没有可同步的矿池监控"), isPresented: $askNoWatch) {
            Button(Loc("知道了"), role: .cancel) {}
        } message: {
            Text(Loc("先到「我的监控」添加你的矿池和挖矿地址；再回到「我的设备」点『从矿池同步』，即可一键把矿机同步成设备。"))
        }
        }
    }

    @ViewBuilder func summ(_ k: String, _ v: String, _ color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: Pearl.Space.xxs) {
            Text(k).font(.subheadline).foregroundColor(.secondary)
            Text(v).font(.title3.bold()).foregroundColor(color).monospacedDigit().fixedSize()
        }
    }
}

/// Tallest device-card height across the grid, so the others stretch to match
/// (equal-height cards → their 日净利 footers line up). Reduces to the max.
private struct DeviceCardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct DeviceRow: View {
    @ObservedObject var store: PRLStore
    @Binding var dev: Device
    var effPU: Double
    /// Tallest card height in the grid (measured by the parent); 0 = size to own content.
    var minBodyHeight: CGFloat = 0
    @State private var editingName = false
    @FocusState private var nameFocused: Bool
    var body: some View {
        let e = store.deviceEcon(dev, perUnit: effPU)
        let net = e.net * Double(dev.count) * store.cfg.fx
        let watts = store.devWatts(dev) * Double(dev.count)
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            HStack(spacing: Pearl.Space.sm) {
                if editingName {
                    TextField(Loc("名称"), text: $dev.name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { editingName = false }
                    #if os(iOS)
                        .autocorrectionDisabled()
                    #endif
                    Button { editingName = false; nameFocused = false } label: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderless).foregroundColor(.green)
                    .help(Loc("完成")).accessibilityLabel(Loc("完成修改名称"))
                } else {
                    // 已存设备：名字以 label 显示，点击（铅笔）才变成文本框可改。
                    Button {
                        editingName = true
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(50))
                            nameFocused = true
                        }
                    } label: {
                        HStack(spacing: Pearl.Space.xxs) {
                            Text(dev.name).font(.headline).foregroundColor(.primary)
                            Image(systemName: "pencil").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(Loc("点击修改名称")).accessibilityLabel(Loc("修改名称"))
                    Spacer(minLength: Pearl.Space.xs)
                }
                if dev.rented {
                    PearlBadge(text: Loc("租用"), systemImage: "key.fill", tint: .orange)
                }
                Button(role: .destructive) {
                    store.devices.removeAll { $0.id == dev.id }
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            if dev.synced {
                HStack {
                    Image(systemName: "link").foregroundColor(.green)
                    Text(Loc("24h ") + formatHashrate((dev.customPearl ?? 0) * 1e12))
                        .font(.callout.monospacedDigit())
                    Spacer()
                    Picker(Loc("芯片"), selection: $dev.gpu) {
                        Text(Loc("未设")).tag("")
                        ForEach(GPUS) { Text($0.name).tag($0.name) }
                    }.pickerStyle(.menu).labelsHidden()
                }
                if let g = gpu(dev.gpu) {
                    Text(Loc("≈ %@× %@（矿池实测算力 ÷ 该芯片算力，用于估租金/成本）", f(store.devCards(dev), 2), g.name))
                        .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(Loc("未设芯片 → 电费按能效估算，租金 / 硬件成本无法计算"))
                        .font(.caption2).foregroundColor(.orange)
                }
            } else {
                HStack {
                    Picker(Loc("显卡"), selection: $dev.gpu) { ForEach(GPUS) { Text($0.name).tag($0.name) } }
                        .pickerStyle(.menu).labelsHidden()
                    Spacer()
                    Stepper(value: $dev.count, in: 1...256) { Text(Loc("× %@", "\(dev.count)")).font(.body.monospacedDigit()) }
                        .fixedSize()
                }
            }
            HStack(spacing: Pearl.Space.sm) {
                Picker(Loc("类型"), selection: $dev.rented) { Text(Loc("自有")).tag(false); Text(Loc("租用")).tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 150)
                Spacer()
                Stepper(value: $dev.hoursPerDay, in: 0...24, step: 1) { Text(f(dev.hoursPerDay, 0) + "h").font(.body.monospacedDigit()) }
                    .fixedSize()
            }
            if dev.rented {
                HStack(spacing: Pearl.Space.xs) {
                    Text(Loc("租金")).font(.callout).foregroundColor(.secondary)
                    if dev.rentDaily != nil {
                        Button { dev.rentDaily = nil } label: { Text(Loc("用默认")).font(.caption2) }
                            .buttonStyle(.borderless)
                    }
                    Spacer(minLength: Pearl.Space.xs)
                    // 手动录入按小时租金（可直接键入数字，或用步进器微调）；内部仍存日租
                    // （=时×24），收益按「可用h」缩放。橙色 = 已手动覆盖默认值。
                    let hourlyBinding = Binding(get: { (dev.rentDaily ?? store.devRent(dev)) / 24 },
                                                set: { dev.rentDaily = max(0, $0) * 24 })
                    Text(store.localSymbol).font(.body.monospacedDigit()).foregroundColor(.secondary)
                    TextField("0", value: hourlyBinding,
                              format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .foregroundColor(dev.rentDaily != nil ? .orange : .primary)
                        .frame(width: 58)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .accessibilityLabel(Loc("租金") + " " + store.localSymbol + Loc("/小时"))
                    Text(Loc("/小时")).font(.callout).foregroundColor(.secondary)
                    Stepper(value: hourlyBinding, in: 0...100000, step: 0.5) { EmptyView() }
                        .labelsHidden().fixedSize()
                }
            }
            Spacer(minLength: 0)   // pin 日净利 to the card bottom so equal-height
                                   // cards line their footers up across a row
            Divider()
            HStack {
                Text(store.sym(Loc("日净利 ¥")) + f(net, 1)).font(.body.monospacedDigit().bold())
                    .foregroundColor(net > 0 ? .green : .red)
                Spacer()
                // 租用云设备为全包价，不显示功率；自有设备才显示功耗。
                if !dev.rented {
                    Text(f(watts, 0) + " W").font(.body.monospacedDigit()).foregroundColor(.secondary)
                }
            }
        }
        // Equal-height cards: stretch to the grid's tallest (minBodyHeight) and
        // report our own natural/grown height back up via the preference.
        .frame(maxWidth: .infinity, minHeight: minBodyHeight, alignment: .topLeading)
        .background(GeometryReader { g in
            Color.clear.preference(key: DeviceCardHeightKey.self, value: g.size.height)
        })
        .modifier(DeviceRowSurface(rented: dev.rented))
    }
}

// 卡片表面：自有用标准玻璃卡；租用沿用橙色强调（玻璃卡 + 橙色描边/渐变）。
private struct DeviceRowSurface: ViewModifier {
    let rented: Bool
    func body(content: Content) -> some View {
        if rented {
            content
                .pearlAccentCard(padding: Pearl.Space.lg, radius: Pearl.Radius.md, gradient: Pearl.sunrise)
        } else {
            content
                .pearlCard(padding: Pearl.Space.lg, radius: Pearl.Radius.md)
        }
    }
}
