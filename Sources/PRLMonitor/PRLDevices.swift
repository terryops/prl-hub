import SwiftUI

// MARK: - 我的设备
//
// Read first, edit on tap: a summary card (daily net profit up front), then one card of
// rows — a device per row with what it is and what it earns. Every control (chip, count,
// owned / rented, hours, rent, delete) lives in the device's own editor sheet, so the
// list isn't a wall of steppers and the page has a single red action, inside the editor.

struct DevicesSection: View {
    @ObservedObject var store: PRLStore
    @State private var askSync = false
    @State private var askNoWatch = false
    @State private var editing: DeviceEditTarget?

    var body: some View {
        let fl = store.fleet()
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                if store.devices.isEmpty {
                    emptyState
                } else {
                    summary(fl)
                    listHeader
                    deviceList(fl)
                }
                // Anchor the very bottom so adding a device can scroll to it.
                Color.clear.frame(height: 1).id("devices-bottom")
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
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
        .sheet(item: $editing) { target in
            DeviceEditor(store: store, id: target.id)
        }
        }
    }

    /// Sync asks first (askSync); with no pool watches it says where to add one (askNoWatch).
    private func requestSync() {
        if store.poolWatchCount > 0 { askSync = true } else { askNoWatch = true }
    }

    /// A new device goes straight into its editor: picking its card is the next step anyway.
    private func addDevice() {
        let dev = Device(name: Loc("新设备"), gpu: "RTX 5080", count: 1)
        store.devices.append(dev)
        editing = DeviceEditTarget(id: dev.id)
    }

    // MARK: Empty

    /// No devices yet: the two ways to get some. Before any pool watch exists, one line says
    /// where syncing gets its miners from.
    private var emptyState: some View {
        VStack(spacing: Pearl.Space.md) {
            Image(systemName: "cpu")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Pearl.accent)
                .padding(.bottom, Pearl.Space.xs)
                .accessibilityHidden(true)
            if store.poolWatchCount == 0 {
                Text(Loc("先在「我的监控」添加矿池，再一键同步矿机"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2).minimumScaleFactor(0.85)
            }
            Button(action: requestSync) {
                HStack(spacing: Pearl.Space.xs) {
                    if store.syncing { ProgressView().controlSize(.small) }
                    else { Image(systemName: "tray.and.arrow.down") }
                    Text(Loc("从矿池同步"))
                }
            }
            .buttonStyle(.pearl)
            .disabled(store.syncing)
            .help(Loc("从矿池同步：按 24h 算力把矿机同步成设备"))
            Button(action: addDevice) {
                Label(Loc("添加设备"), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
        .pearlCard(padding: Pearl.Space.lg, radius: Pearl.Radius.md)
    }

    // MARK: Summary

    /// The figure that matters first — what the fleet nets a day — then the rest in one row.
    private func summary(_ fl: Fleet) -> some View {
        let fx = store.cfg.fx
        return VStack(alignment: .leading, spacing: Pearl.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Loc("日净利")).font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(money(fl.netDay * fx, 1))
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(profitColor(fl.netDay))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(Loc("/天")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Divider()
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: Pearl.Space.md, alignment: .leading)],
                      alignment: .leading, spacing: Pearl.Space.sm) {
                stat(Loc("算力"), formatHashrate(fl.pearl * 1e12))
                stat(Loc("显卡"), Loc("%@ 张", "\(fl.cards)"))
                if fl.watts > 0 { stat(Loc("自有功耗"), f(fl.watts, 0) + " W") }
                if fl.rentDay > 0 { stat(Loc("日租金"), money(fl.rentDay * fx, 1)) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard(padding: Pearl.Space.lg, radius: Pearl.Radius.md)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: List

    /// How many, then the two ways to add more — sync (the usual one) and by hand.
    private var listHeader: some View {
        HStack(spacing: Pearl.Space.md) {
            Text(Loc("%@ 台", "\(store.devices.count)"))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: Pearl.Space.xs)
            Button(action: requestSync) {
                HStack(spacing: 4) {
                    if store.syncing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "tray.and.arrow.down") }
                    Text(Loc("从矿池同步"))
                }
            }
            .disabled(store.syncing)
            .help(Loc("从矿池同步：按 24h 算力把矿机同步成设备"))
            Button(action: addDevice) { Label(Loc("添加"), systemImage: "plus") }
                .accessibilityLabel(Loc("添加设备"))
        }
        .buttonStyle(.borderless)
        .font(.subheadline.weight(.medium))
        .tint(Pearl.accent)
        .lineLimit(1)
    }

    private func deviceList(_ fl: Fleet) -> some View {
        let effPU = store.effPerUnit(myHashPearl: fl.pearl)
        return VStack(spacing: 0) {
            ForEach(store.devices) { dev in
                if dev.id != store.devices.first?.id {
                    Divider().padding(.leading, Pearl.Space.md)
                }
                Button { editing = DeviceEditTarget(id: dev.id) } label: {
                    DeviceListRow(store: store, dev: dev, effPU: effPU)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button { editing = DeviceEditTarget(id: dev.id) } label: { Label(Loc("编辑"), systemImage: "pencil") }
                    Button(role: .destructive) { store.devices.removeAll { $0.id == dev.id } } label: {
                        Label(Loc("删除"), systemImage: "trash")
                    }
                }
            }
        }
        .pearlCard(padding: 0, radius: Pearl.Radius.md)
    }

    private func money(_ v: Double, _ digits: Int) -> String {
        (v < 0 ? "-" : "") + store.localSymbol + f(abs(v), digits)
    }
}

/// Which device the editor sheet is open on.
private struct DeviceEditTarget: Identifiable { let id: UUID }

// MARK: - Row

/// One device in the list: name (and 租用), what it runs on, and its daily net.
private struct DeviceListRow: View {
    @ObservedObject var store: PRLStore
    let dev: Device
    let effPU: Double

    var body: some View {
        let net = store.deviceEcon(dev, perUnit: effPU).net * Double(dev.count) * store.cfg.fx
        HStack(spacing: Pearl.Space.sm) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(dev.name).font(.body.weight(.semibold)).lineLimit(1)
                    if dev.rented { PearlBadge(text: Loc("租用"), tint: .orange) }
                }
                detail
            }
            Spacer(minLength: Pearl.Space.sm)
            VStack(alignment: .trailing, spacing: 2) {
                Text((net < 0 ? "-" : "") + store.localSymbol + f(abs(net), 1))
                    .font(.body.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(profitColor(net))
                Text(Loc("/天")).font(.caption2).foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Pearl.Space.md)
        .padding(.vertical, Pearl.Space.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Synced rigs: their measured hashrate and the chip behind the cost figures (orange
    /// when none is set). Hand-added ones: card × count. Either way, hours if not all day.
    @ViewBuilder private var detail: some View {
        HStack(spacing: 4) {
            if dev.synced {
                Image(systemName: "link").foregroundStyle(.green).font(.caption2)
                Text(formatHashrate((dev.customPearl ?? 0) * 1e12))
                Text(verbatim: "·")
                if dev.gpu.isEmpty {
                    Text(Loc("未设芯片")).foregroundStyle(.orange)
                } else {
                    Text(dev.gpu)
                }
            } else {
                Text(dev.gpu)
                Text(Loc("× %@", "\(dev.count)"))
            }
            if dev.hoursPerDay < 24 {
                Text(verbatim: "· " + f(dev.hoursPerDay, 0) + "h")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
    }
}

// MARK: - Editor

/// Everything about one device, as a form: what it is, how it runs, what it nets — and
/// the only delete on the page.
private struct DeviceEditor: View {
    @ObservedObject var store: PRLStore
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    /// The device as last seen, so the sheet can still draw while it closes after a delete.
    @State private var last: Device?

    private var dev: Binding<Device> {
        Binding(
            get: { store.devices.first { $0.id == id } ?? last ?? Device(name: "", gpu: "", count: 1) },
            set: { nv in
                if let i = store.devices.firstIndex(where: { $0.id == id }) { store.devices[i] = nv }
            })
    }

    var body: some View {
        let d = dev.wrappedValue
        let effPU = store.effPerUnit(myHashPearl: store.fleet().pearl)
        let net = store.deviceEcon(d, perUnit: effPU).net * Double(d.count) * store.cfg.fx
        NavigationStack {
            Form {
                Section {
                    LabeledContent(Loc("名称")) {
                        TextField(Loc("名称"), text: dev.name)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .autocorrectionDisabled()
                            #endif
                    }
                }

                Section {
                    if d.synced {
                        LabeledContent(Loc("算力"), value: "24h " + formatHashrate((d.customPearl ?? 0) * 1e12))
                        // The ⓘ sits in the row's label, outside the menu picker it explains.
                        LabeledContent {
                            Picker(Loc("芯片"), selection: dev.gpu) {
                                Text(Loc("未设")).tag("")
                                ForEach(GPUS) { Text($0.name).tag($0.name) }
                            }
                            .labelsHidden()
                        } label: {
                            HStack(spacing: 4) {
                                Text(Loc("芯片"))
                                if let g = gpu(d.gpu) {
                                    PearlInfoTip(Loc("≈ %@× %@（矿池实测算力 ÷ 该芯片算力，用于估租金/成本）", f(store.devCards(d), 2), g.name),
                                                 title: Loc("芯片"))
                                } else {
                                    PearlInfoTip(Loc("未设芯片 → 电费按能效估算，租金 / 硬件成本无法计算"),
                                                 title: Loc("芯片"), tint: .orange)
                                }
                            }
                        }
                    } else {
                        Picker(Loc("显卡"), selection: dev.gpu) {
                            ForEach(GPUS) { Text($0.name).tag($0.name) }
                        }
                        Stepper(value: dev.count, in: 1...256) {
                            LabeledContent(Loc("数量"), value: "\(d.count)")
                        }
                    }
                }

                Section {
                    LabeledContent {
                        Picker(Loc("类型"), selection: dev.rented) {
                            Text(Loc("自有")).tag(false)
                            Text(Loc("租用")).tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 180)
                    } label: {
                        HStack(spacing: 4) {
                            Text(Loc("类型"))
                            PearlInfoTip(store.sym(Loc("提示：自动保存。每台可选『自有』(付电费+计硬件成本) 或『租用』(按 ¥/小时 付租，全包价不另计电费/功率)。『可用h』= 每天实际挖矿小时，按比例缩放出币/电费/租金。租金单价可在此逐台调，默认值在【显卡对比】选中卡后设。")),
                                         title: Loc("类型"))
                        }
                    }
                    Stepper(value: dev.hoursPerDay, in: 0...24, step: 1) {
                        LabeledContent(Loc("每天挖矿时长"), value: f(d.hoursPerDay, 0) + "h")
                    }
                    if d.rented { rentRow(d) }
                }

                Section {
                    LabeledContent(Loc("日净利")) {
                        Text((net < 0 ? "-" : "") + store.localSymbol + f(abs(net), 1))
                            .monospacedDigit().foregroundStyle(profitColor(net))
                    }
                    if !d.rented {
                        LabeledContent(Loc("自有功耗"),
                                       value: f(store.devWatts(d) * Double(d.count), 0) + " W")
                    }
                }

                Section {
                    Button(Loc("删除设备"), role: .destructive) { confirmingDelete = true }
                        .frame(maxWidth: .infinity)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(d.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Loc("完成")) { dismiss() }
                }
                .noGlassBackground()
            }
            .confirmationDialog(Loc("删除设备"), isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button(Loc("删除"), role: .destructive) {
                    last = d
                    store.devices.removeAll { $0.id == id }
                    dismiss()
                }
                Button(Loc("取消"), role: .cancel) {}
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
        .onAppear { last = store.devices.first { $0.id == id } }
    }

    /// Hourly rent, typed or stepped (stored as daily = hourly × 24; earnings scale with
    /// the hours above). Orange = overriding the chip's default; 用默认 puts it back.
    private func rentRow(_ d: Device) -> some View {
        let hourly = Binding(get: { store.devRent(dev.wrappedValue) / 24 },
                             set: { nv in
                                 var v = dev.wrappedValue
                                 v.rentDaily = max(0, nv) * 24; v.rentCurrency = nil; v.rentFX = nil
                                 dev.wrappedValue = v
                             })
        return HStack(spacing: Pearl.Space.xs) {
            Text(Loc("租金"))
            if d.rentDaily != nil {
                Button { dev.wrappedValue.rentDaily = nil } label: { Text(Loc("用默认")).font(.caption) }
                    .buttonStyle(.borderless)
            }
            Spacer(minLength: Pearl.Space.xs)
            Text(store.localSymbol).foregroundStyle(.secondary)
            TextField("0", value: hourly, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .foregroundStyle(d.rentDaily != nil ? .orange : .primary)
                .frame(width: 64)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
                .accessibilityLabel(Loc("租金") + " " + store.localSymbol + Loc("/小时"))
            Text(Loc("/小时")).foregroundStyle(.secondary)
            Stepper(value: hourly, in: 0...100000, step: 0.5) { EmptyView() }
                .labelsHidden().fixedSize()
        }
    }
}
