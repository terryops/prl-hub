import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 到账提醒, as the second card of 价格和到账提醒. One address; a push when it is paid. The
/// checking happens on the server — see IncomeAlertStore.
///
/// The address is picked, not typed: it starts as the open wallet's own, the menu lists the
/// other wallets and the monitors' payout addresses, and 其他地址… takes any other. Before the
/// alert was ever set the card ends in 开启到账提醒; after that the switch in its header
/// turns it off and on, and picking another address moves it there (on or off as it was).
struct IncomeAlertCard: View {
    @ObservedObject private var store = IncomeAlertStore.shared
    @ObservedObject private var wallet = WalletStore.shared
    /// For 推送时段, which the ⓘ mentions.
    @ObservedObject private var push = PriceAlertStore.shared
    /// The monitors as saved (the 矿池 tab owns its PoolStore): watched so a monitor added or
    /// removed while this page is open shows up in the menu.
    @AppStorage(PoolStore.watchesKey) private var storedWatches: Data?
    /// The addresses the user already has here, worked out when the card appears and when
    /// the wallets or monitors change.
    @State private var known: [Known] = []
    /// Picked before the alert was ever switched on (nil: the open wallet's own address).
    @State private var choice: String?
    @State private var typing = false

    /// The address the card shows: the one watched, else the one picked, else this wallet's.
    private var selected: String? { store.setting?.addr ?? choice ?? ownAddress }

    private var ownAddress: String? {
        let open = wallet.wallets.first { $0.id == wallet.activeWalletID }
        return (open?.addresses[WalletNetwork.mainnet.rawValue] ?? open?.watchAddress).flatMap(IncomeAlertStore.normalize)
            ?? known.first?.addr
    }

    private var howItWorks: String {
        var parts = [Loc("这个地址收到 PRL，1 个区块确认后就推送通知，不用打开 App。从这个地址转出的交易和找零不算。")]
        if push.window != nil {
            parts.append(Loc("推送时段之外到账的，到时段开始时再通知你。"))
        }
        parts.append(Loc("开启后服务器会保存这个地址，只用来查到账；不涉及助记词或私钥。"))
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.md) {
            AlertCardHeader(systemImage: "arrow.down.circle.fill", title: Loc("到账提醒"),
                            subtitle: Loc("收到 PRL 就推送通知"), info: howItWorks) {
                if let s = store.setting {
                    Toggle(Loc("到账提醒"), isOn: Binding(get: { s.on }, set: { store.setOn($0) }))
                        .labelsHidden()
                        .accessibilityIdentifier("income-toggle")
                }
            }

            addressPicker

            if store.setting == nil {
                Button {
                    guard let a = selected else { typing = true; return }
                    // The push leads with the name the address has here (a wallet's, a monitor's).
                    store.set(address: a, label: name(for: a))
                } label: {
                    Label(Loc("开启到账提醒"), systemImage: "bell.badge")
                }
                .buttonStyle(.pearl)
                .accessibilityIdentifier("income-save")
            }
        }
        .pearlCard()
        .onAppear { known = Self.knownAddresses(wallets: wallet.wallets) }
        .onChange(of: wallet.wallets) { _, w in known = Self.knownAddresses(wallets: w) }
        .onChange(of: storedWatches) { _, _ in known = Self.knownAddresses(wallets: wallet.wallets) }
        .sheet(isPresented: $typing) {
            IncomeAddressSheet(initial: selected.flatMap { a in known.contains { $0.addr == a } ? nil : a } ?? "") { pick($0) }
        }
        .animation(.snappy, value: store.setting)
    }

    // MARK: the address

    @ViewBuilder private var addressPicker: some View {
        if known.isEmpty {
            // Nothing to choose from: straight to typing one.
            Button { typing = true } label: { addressRow }
                .buttonStyle(.plain)
                .accessibilityIdentifier("income-pick")
        } else {
            Menu {
                let wallets = known.filter { $0.kind == .wallet }
                let monitors = known.filter { $0.kind == .monitor }
                if !wallets.isEmpty {
                    Section(Loc("我的钱包")) { ForEach(wallets) { option($0) } }
                }
                if !monitors.isEmpty {
                    Section(Loc("我的监控")) { ForEach(monitors) { option($0) } }
                }
                Section {
                    Button { typing = true } label: { Label(Loc("其他地址…"), systemImage: "keyboard") }
                }
            } label: {
                addressRow
            }
            .menuIndicator(.hidden)
            #if os(macOS)
            .menuStyle(.button)
            #endif
            .buttonStyle(.plain)
            .accessibilityIdentifier("income-pick")
        }
    }

    private func option(_ k: Known) -> some View {
        Button { pick(k.addr) } label: {
            if k.addr == selected {
                Label(k.name, systemImage: "checkmark")
            } else {
                Text(k.name)
            }
            Text(shortAddr(k.addr))
        }
    }

    /// The address as a field that opens the choices: whose it is, then the address itself.
    private var addressRow: some View {
        let addr = selected
        let name = addr.map(name(for:)) ?? ""
        return HStack(spacing: Pearl.Space.sm) {
            Image(systemName: icon(for: addr))
                .font(.body.weight(.medium))
                .foregroundStyle(Pearl.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let addr {
                    Text(name.isEmpty ? shortAddr(addr) : name)
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                    if !name.isEmpty {
                        Text(shortAddr(addr)).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                } else {
                    Text(Loc("收款地址")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Pearl.Space.xs)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Pearl.Space.md)
        .padding(.vertical, Pearl.Space.sm)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Pearl.Radius.sm, style: .continuous))
        .contentShape(Rectangle())
        .opacity(store.setting?.on == false ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Loc("收款地址"))
        .accessibilityValue(addr.map { name.isEmpty ? $0 : name + ", " + shortAddr($0) } ?? "")
    }

    /// Before the alert exists a pick only changes what 开启 will watch; after, it moves the
    /// alert there, still on or off as it was (an alert switched off is not sent anywhere).
    private func pick(_ addr: String) {
        if let s = store.setting {
            guard addr != s.addr else { return }
            store.set(address: addr, label: name(for: addr), on: s.on)
        } else {
            choice = addr
        }
    }

    // MARK: addresses the user already has here

    struct Known: Identifiable {
        enum Kind { case wallet, monitor }
        let name: String
        let addr: String
        let kind: Kind
        var id: String { addr }
    }

    private func icon(for addr: String?) -> String {
        switch known.first(where: { $0.addr == addr })?.kind {
        case .wallet: return "wallet.pass"
        case .monitor: return "server.rack"
        case nil: return "arrow.down.circle"
        }
    }

    /// The wallets' main addresses, then the monitors' payout addresses, each once.
    private static func knownAddresses(wallets: [WalletRecord]) -> [Known] {
        var seen = Set<String>(), out: [Known] = []
        for w in wallets {
            // A read-only wallet is its one watched address.
            guard let a = (w.addresses[WalletNetwork.mainnet.rawValue] ?? w.watchAddress).flatMap(IncomeAlertStore.normalize),
                  seen.insert(a).inserted else { continue }
            out.append(Known(name: w.name, addr: a, kind: .wallet))
        }
        for m in PoolStore.storedWatches() where m.pool.isAddressBased {
            guard let a = normalizeWatchAddress(m.pool, m.address), seen.insert(a).inserted else { continue }
            out.append(Known(name: m.displayName, addr: a, kind: .monitor))
        }
        return out
    }

    /// The name this address goes by here (the one saved with the alert, for an address that
    /// is no longer one of these).
    private func name(for addr: String) -> String {
        known.first { $0.addr == addr }?.name ?? (store.setting?.addr == addr ? store.setting?.label ?? "" : "")
    }
}

/// 其他地址…: type or paste any mainnet PRL address.
private struct IncomeAddressSheet: View {
    let initial: String
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var normalized: String? { IncomeAlertStore.normalize(text) }
    private var invalid: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && normalized == nil }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                HStack(alignment: .center, spacing: Pearl.Space.sm) {
                    TextField("\(WalletNetwork.mainnet.addressPrefix)…", text: $text, axis: .vertical)
                        .accessibilityLabel(Loc("收款地址"))
                        .lineLimit(1...4)
                        .font(.body.monospaced())
                        .focused($focused)
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                        .textFieldStyle(.plain)
                        .submitLabel(.done)
                        .onSubmit(done)
                        .accessibilityIdentifier("income-address")
                    Button(action: paste) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.body.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(Loc("粘贴"))
                }
                .padding(Pearl.Space.md)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: Pearl.Radius.sm, style: .continuous))

                if invalid {
                    Text(Loc("地址格式不正确（需为 %@ 开头的 Taproot 地址）", WalletNetwork.mainnet.addressPrefix))
                        .font(.caption).foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .padding(Pearl.Space.screen)
            .background { PearlBackground() }
            .navigationTitle(Loc("收款地址"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Loc("完成"), action: done).disabled(normalized == nil)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #else
        .frame(minWidth: 440, minHeight: 220)
        #endif
        .onAppear { text = initial; focused = true }
    }

    private func done() {
        guard let a = normalized else { return }
        onDone(a)
        dismiss()
    }

    private func paste() {
        #if os(iOS)
        if let s = UIPasteboard.general.string { text = s }
        #else
        if let s = NSPasteboard.general.string(forType: .string) { text = s }
        #endif
    }
}
