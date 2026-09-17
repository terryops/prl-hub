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
                            Text(shortAddr(a))
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
                Image(systemName: "wallet.pass")
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
                    VStack(spacing: Pearl.Space.sm) {
                        PearlIconBadge(systemImage: "wallet.pass", size: 56)
                        Text(Loc("每个钱包单独保存助记词，可随时在钱包页左上角切换。"))
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                            .tint(Pearl.indigo)
                        }
                        .contextMenu {
                            Button { startRename(w) } label: { Label(Loc("重命名"), systemImage: "pencil") }
                            Button(role: .destructive) { removing = w } label: { Label(Loc("删除"), systemImage: "trash") }
                        }
                }
            } footer: {
                Text(Loc("助记词只保存在本机钥匙串。删除钱包前，请确认已备份它的助记词。"))
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
            Text(Loc("助记词将从本机删除且无法恢复。请确认你已安全备份助记词，否则资产将永久丢失。"))
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
            PearlIconBadge(systemImage: "wallet.pass", size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(w.name).font(.body.weight(.semibold)).lineLimit(1)
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
