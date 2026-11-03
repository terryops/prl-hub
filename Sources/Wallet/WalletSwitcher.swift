import SwiftUI

// MARK: - Toolbar switcher

/// The wallet page's toolbar menu: every wallet on this device (tap to open it), plus
/// entries to add another wallet or manage the list.
struct WalletSwitcherMenu: View {
    @ObservedObject var store: WalletStore
    @Binding var addingWallet: Bool
    @Binding var managingWallets: Bool
    @State private var switchError: String?

    var body: some View {
        Menu {
            Section(Loc("切换钱包")) {
                ForEach(store.wallets) { w in
                    Button { open(w) } label: {
                        if w.id == store.activeWalletID {
                            Label(w.name, systemImage: "checkmark")
                        } else {
                            Text(w.name)
                        }
                        if let a = w.addresses[store.network.rawValue] {
                            Text(w.isWatchOnly ? Loc("只读") + " · " + shortAddr(a) : shortAddr(a))
                        } else if w.isWatchOnly {
                            Text(Loc("只读"))
                        }
                    }
                }
            }
            Section {
                Button { addingWallet = true } label: {
                    Label(Loc("添加钱包"), systemImage: "plus")
                }
                Button { managingWallets = true } label: {
                    Label(Loc("管理钱包"), systemImage: "list.bullet")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: store.isWatchOnly ? "eye" : "wallet.pass")
                Text(store.walletName).lineLimit(1)
                #if os(iOS)
                // macOS toolbar menus draw their own disclosure chevron.
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                #endif
            }
            .font(.callout.weight(.semibold))
        }
        .accessibilityLabel(Loc("切换钱包"))
        .alert(Loc("无法切换钱包"), isPresented: Binding(
            get: { switchError != nil }, set: { if !$0 { switchError = nil } })) {
            Button(Loc("知道了"), role: .cancel) { switchError = nil }
        } message: {
            Text(switchError ?? "")
        }
    }

    private func open(_ w: WalletRecord) {
        guard !store.switchWallet(to: w.id) else { return }
        switchError = store.lastError ?? Loc("无法切换钱包")
        store.lastError = nil
    }
}

// MARK: - Add wallet

/// Sheet for adding one more wallet while another is open: create a new seed or
/// import an existing one. Closes itself once the new wallet is committed.
struct AddWalletView: View {
    @ObservedObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Pearl.Space.lg) {
                    PearlIconBadge(systemImage: "wallet.pass", size: 56)
                        .padding(.vertical, Pearl.Space.sm)

                    NavigationLink {
                        CreateWalletView(store: store) { dismiss() }
                    } label: {
                        Label(Loc("创建新钱包"), systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.pearl)
                    .disabled(!store.frameworkOK)

                    NavigationLink {
                        ImportWalletView(store: store) { dismiss() }
                    } label: {
                        Label(Loc("用助记词恢复钱包"), systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(!store.frameworkOK)

                    // Same as the web's wallet page: just an address, no seed. Needs no Go
                    // framework, so it stays available when the two above can't be used.
                    WatchWalletOption { WatchWalletView(store: store) { dismiss() } }
                }
                .padding(Pearl.Space.screen)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(Loc("添加钱包"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc("取消")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Manage wallets

/// Every wallet on this device: open, rename or remove one, or add another.
struct ManageWalletsView: View {
    @ObservedObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var renaming: WalletRecord?
    @State private var renameText = ""
    @State private var removing: WalletRecord?
    /// Title + message of a failed switch or removal.
    @State private var failure: (title: String, message: String)?

    var body: some View {
        List {
            Section {
                ForEach(store.wallets) { w in
                    Button {
                        if !store.switchWallet(to: w.id) {
                            failure = (Loc("无法切换钱包"), store.lastError ?? "")
                            store.lastError = nil
                        }
                    } label: { row(w) }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) { removing = w } label: {
                                Label(Loc("删除"), systemImage: "trash")
                            }
                            Button { startRename(w) } label: {
                                Label(Loc("重命名"), systemImage: "pencil")
                            }
                            .tint(Pearl.plate)
                        }
                        .contextMenu {
                            Button { startRename(w) } label: { Label(Loc("重命名"), systemImage: "pencil") }
                            Button(role: .destructive) { removing = w } label: { Label(Loc("删除"), systemImage: "trash") }
                        }
                }
            }
        }
        .pearlListBackground()
        .navigationTitle(Loc("管理钱包"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label(Loc("添加钱包"), systemImage: "plus") }
            }
        }
        .sheet(isPresented: $adding) { AddWalletView(store: store) }
        .alert(Loc("重命名钱包"), isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Pearl Wallet", text: $renameText)
            Button(Loc("保存")) {
                if let w = renaming { store.renameWallet(id: w.id, to: renameText) }
                renaming = nil
            }
            Button(Loc("取消"), role: .cancel) { renaming = nil }
        }
        // .alert (not .confirmationDialog): centered on every platform — see SettingsView.
        .alert(Loc("确定要移除钱包「%@」吗？", removing?.name ?? ""), isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(Loc("移除钱包"), role: .destructive) {
                if let w = removing {
                    let ok = withAnimation { store.removeWallet(id: w.id) }
                    if !ok {
                        failure = (Loc("移除失败"), store.lastError ?? "")
                        store.lastError = nil
                    }
                }
                removing = nil
            }
            Button(Loc("取消"), role: .cancel) { removing = nil }
        } message: {
            Text(removing?.isWatchOnly == true
                 ? Loc("只从本机删除这个地址，不影响链上资产，之后可以再添加。")
                 : Loc("助记词将从本机删除且无法恢复。请确认你已安全备份助记词，否则资产将永久丢失。"))
        }
        .alert(failure?.title ?? "", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button(Loc("知道了"), role: .cancel) { failure = nil }
        } message: {
            Text(failure?.message ?? "")
        }
        // Removing the last wallet swaps the wallet tab back to onboarding; don't leave
        // this pushed screen orphaned on top of it.
        .onChange(of: store.phase) { _, phase in
            if phase != .unlocked { dismiss() }
        }
    }

    private func row(_ w: WalletRecord) -> some View {
        HStack(spacing: Pearl.Space.sm) {
            PearlIconBadge(systemImage: w.isWatchOnly ? "eye" : "wallet.pass", size: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Pearl.Space.xs) {
                    Text(w.name).font(.body.weight(.semibold)).lineLimit(1)
                    if w.isWatchOnly { PearlBadge(text: Loc("只读"), tint: .secondary) }
                }
                if let a = w.addresses[store.network.rawValue] {
                    Text(shortAddr(a)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Pearl.Space.xs)
            if w.id == store.activeWalletID {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3).foregroundStyle(Pearl.accent)
                    .accessibilityLabel(Loc("当前钱包"))
            }
        }
        .contentShape(Rectangle())
    }

    private func startRename(_ w: WalletRecord) {
        renameText = w.name
        renaming = w
    }
}

// MARK: - Read-only wallet

/// The read-only choice on 添加钱包 and the welcome screen: a quiet link under the two
/// seed buttons, with what it is in the ⓘ beside it (kept outside the link so a tap on
/// the ⓘ doesn't also open the page).
struct WatchWalletOption<Destination: View>: View {
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        HStack(spacing: 4) {
            NavigationLink { destination() } label: {
                Label(Loc("添加只读钱包"), systemImage: "eye")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Pearl.accent)
            .accessibilityIdentifier("watch-wallet-option")
            PearlInfoTip(Loc("只填一个地址，就能查看它的余额和交易记录。不需要助记词，也不能转账。"),
                         title: Loc("只读钱包"))
        }
        .font(.callout.weight(.medium))
        .frame(maxWidth: .infinity)
    }
}

/// Add a read-only wallet: a name and the address to watch (on the current network). It then
/// works like any other wallet here — balance, history, 收款 — except that it can't send.
struct WatchWalletView: View {
    @ObservedObject var store: WalletStore
    /// Extra close step after a successful commit (the add-wallet sheet closes itself).
    var onCommitted: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var address = ""
    @State private var error: String?

    init(store: WalletStore, onCommitted: (() -> Void)? = nil) {
        self.store = store
        self.onCommitted = onCommitted
        _name = State(initialValue: store.suggestedWatchName())
    }

    private var addr: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var addressValid: Bool { PRLAddress.isValid(addr, network: store.network) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                VStack(alignment: .leading, spacing: Pearl.Space.md) {
                    PearlSectionHeader(Loc("钱包名称"), systemImage: "wallet.pass")
                    TextField(store.suggestedWatchName(), text: $name).textFieldStyle(.roundedBorder)
                }
                .pearlCard()

                VStack(alignment: .leading, spacing: Pearl.Space.md) {
                    HStack {
                        PearlSectionHeader(Loc("地址"), systemImage: "eye",
                                           info: Loc("只填一个地址，就能查看它的余额和交易记录。不需要助记词，也不能转账。"))
                        Spacer()
                        Button(Loc("粘贴")) {
                            #if os(iOS)
                            if let s = UIPasteboard.general.string { address = s }
                            #else
                            if let s = NSPasteboard.general.string(forType: .string) { address = s }
                            #endif
                        }.font(.caption)
                    }
                    TextField("\(store.network.addressPrefix)…", text: $address, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                        .onChange(of: address) { _, _ in error = nil }
                        .accessibilityIdentifier("watch-address")
                    if !addr.isEmpty && !addressValid {
                        Text(Loc("地址格式不正确（需为 %@ 开头的 Taproot 地址）", store.network.addressPrefix))
                            .font(.caption).foregroundStyle(.red)
                    }
                }
                .pearlCard()

                if let error {
                    Label(error, systemImage: "exclamationmark.octagon")
                        .font(.footnote).foregroundStyle(.red)
                }
                Button { commit() } label: {
                    Label(Loc("添加只读钱包"), systemImage: "eye")
                }
                .buttonStyle(.pearl)
                .disabled(!addressValid)
                .accessibilityIdentifier("watch-add")
            }
            .padding(Pearl.Space.screen).frame(maxWidth: 520).frame(maxWidth: .infinity)
        }
        .pearlScreenBackground()
        .navigationTitle(Loc("只读钱包"))
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    private func commit() {
        guard store.commitWatchWallet(name: name, address: addr) else {
            error = store.lastError ?? Loc("地址格式不正确（需为 %@ 开头的 Taproot 地址）", store.network.addressPrefix)
            store.lastError = nil
            return
        }
        // Phase may flip to .unlocked (from the welcome screen), swapping the NavigationStack
        // root: pop this pushed view too, or it stays orphaned on top of the new root.
        dismiss()
        onCommitted?()
    }
}
