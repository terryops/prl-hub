import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 到账提醒 — 设置 → 通知设置. One address; a push when it is paid. The checking happens on the
/// server — see IncomeAlertStore.
struct IncomeAlertsView: View {
    @ObservedObject private var store = IncomeAlertStore.shared
    @ObservedObject private var push = PriceAlertStore.shared
    @ObservedObject private var pro = ProStore.shared
    @ObservedObject private var wallet = WalletStore.shared
    @State private var editing = false
    @State private var address = ""
    /// The addresses the user already has here, worked out when the page opens (and when the
    /// wallets change) rather than on every keystroke.
    @State private var known: [Known] = []

    var body: some View {
        ScrollView {
            VStack(spacing: Pearl.Space.lg) {
                if pro.isPro {
                    if push.authorization == .denied && push.pushHere && store.wire != nil {
                        NotificationsDeniedCard(message: Loc("通知权限已关闭，到账提醒无法送达"))
                    }
                    addressCard
                    #if os(macOS)
                    PushHereCard(store: push)
                    #endif
                    PushWindowCard(store: push)
                } else {
                    ProPaywallCard(pro: pro)
                }
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background { PearlBackground() }
        .navigationTitle(Loc("到账提醒"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .onAppear { known = Self.knownAddresses(wallets: wallet.wallets) }
        .onChange(of: wallet.wallets) { _, w in known = Self.knownAddresses(wallets: w) }
        .task {
            await push.refreshAuthorization()
            await push.pageOpened()
            await pro.loadProduct()
        }
    }

    private var howItWorks: String {
        var parts = [Loc("这个地址收到 PRL，1 个区块确认后就推送通知，不用打开 App。从这个地址转出的交易和找零不算。")]
        if push.window != nil {
            parts.append(Loc("推送时段之外到账的，到时段开始时再通知你。"))
        }
        parts.append(Loc("开启后服务器会保存这个地址，只用来查到账；不涉及助记词或私钥。"))
        return parts.joined(separator: "\n\n")
    }

    // MARK: card

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.md) {
            HStack(alignment: .center, spacing: Pearl.Space.sm) {
                HStack(spacing: 4) {
                    Text(Loc("收款地址")).font(.headline)
                    PearlInfoTip(howItWorks, title: Loc("到账提醒"))
                }
                Spacer(minLength: Pearl.Space.xs)
                AlertSyncStatus(store: push, active: store.wire != nil)
                if let s = store.setting, !editing {
                    Toggle(Loc("到账提醒"), isOn: Binding(get: { s.on }, set: { store.setOn($0) }))
                        .labelsHidden()
                        .accessibilityIdentifier("income-toggle")
                }
            }

            if let s = store.setting, !editing {
                current(s)
            } else {
                editor
            }
            AlertSyncFailure(store: push)
        }
        .pearlCard()
    }

    /// The address being watched (or switched off), and a way to choose another.
    private func current(_ s: IncomeAlertSetting) -> some View {
        HStack(spacing: Pearl.Space.sm) {
            PearlIconBadge(systemImage: "arrow.down.circle.fill", size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.label.isEmpty ? shortAddr(s.addr) : s.label)
                    .font(.body.weight(.semibold)).lineLimit(1)
                if !s.label.isEmpty {
                    Text(shortAddr(s.addr)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .opacity(s.on ? 1 : 0.5)
            Spacer(minLength: Pearl.Space.xs)
            Button(Loc("更换地址")) {
                address = s.addr
                editing = true
            }
            .font(.subheadline)
            .accessibilityIdentifier("income-change")
        }
    }

    private var normalized: String? { IncomeAlertStore.normalize(address) }

    /// Typing, pasting or picking an address.
    private var editor: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            HStack(spacing: Pearl.Space.sm) {
                TextField("\(WalletNetwork.mainnet.addressPrefix)…", text: $address, axis: .vertical)
                    .accessibilityLabel(Loc("收款地址"))
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder).font(.body.monospaced())
                    #if os(iOS)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    #endif
                    .accessibilityIdentifier("income-address")
                if !known.isEmpty {
                    Menu {
                        ForEach(known, id: \.addr) { k in
                            Button("\(k.name) · \(shortAddr(k.addr))") { address = k.addr }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(Loc("我的地址"))
                    .accessibilityIdentifier("income-pick")
                }
                Button(Loc("粘贴")) {
                    #if os(iOS)
                    if let s = UIPasteboard.general.string { address = s }
                    #else
                    if let s = NSPasteboard.general.string(forType: .string) { address = s }
                    #endif
                }
                .font(.caption)
            }
            if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && normalized == nil {
                Text(Loc("地址格式不正确（需为 %@ 开头的 Taproot 地址）", WalletNetwork.mainnet.addressPrefix))
                    .font(.caption).foregroundStyle(.red)
            }
            HStack(spacing: Pearl.Space.sm) {
                if editing {
                    Button(Loc("取消")) { editing = false }
                        .buttonStyle(.bordered)
                }
                Button {
                    guard let a = normalized else { return }
                    // The push leads with the name the address has here (a wallet's, a monitor's).
                    store.set(address: a, label: name(for: a))
                    editing = false
                } label: {
                    Label(Loc("开启到账提醒"), systemImage: "bell.badge")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.pearl)
                .disabled(normalized == nil)
                .accessibilityIdentifier("income-save")
            }
        }
    }

    // MARK: addresses the user already has here

    private struct Known { let name: String; let addr: String }

    /// The wallets' main addresses, then the monitors' payout addresses, each once.
    private static func knownAddresses(wallets: [WalletRecord]) -> [Known] {
        var seen = Set<String>(), out: [Known] = []
        for w in wallets {
            guard let a = w.addresses[WalletNetwork.mainnet.rawValue].flatMap(IncomeAlertStore.normalize), seen.insert(a).inserted else { continue }
            out.append(Known(name: w.name, addr: a))
        }
        for m in PoolStore.storedWatches() where m.pool.isAddressBased {
            guard let a = normalizeWatchAddress(m.pool, m.address), seen.insert(a).inserted else { continue }
            out.append(Known(name: m.displayName, addr: a))
        }
        return out
    }

    /// The name this address goes by here, for an address typed or pasted.
    private func name(for addr: String) -> String { known.first { $0.addr == addr }?.name ?? "" }
}
