import SwiftUI

/// Wallet tab entry point — a small state machine over WalletStore.phase.
struct WalletRootView: View {
    @EnvironmentObject var store: WalletStore

    var body: some View {
        NavigationStack {
            Group {
                switch store.phase {
                case .loading:
                    ProgressView(Loc("载入中…")).task { store.bootstrap() }
                case .noWallet:
                    WelcomeView(store: store)
                case .locked:
                    UnlockView(store: store)
                case .unlocked:
                    DashboardView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pearlScreenBackground()
            .animation(.snappy, value: store.phase)
        }
    }
}

// MARK: - Welcome (no wallet yet)

struct WelcomeView: View {
    @ObservedObject var store: WalletStore
    var body: some View {
        ScrollView {
            VStack(spacing: Pearl.Space.lg) {
                PearlHero(minHeight: 190) {
                    VStack(spacing: Pearl.Space.sm) {
                        PearlLogo(size: 72, showsWordmark: false)
                        Text(Loc("$Pearl Hub"))
                            .font(.largeTitle.bold())
                            .foregroundStyle(Pearl.onHero)
                    }
                }

                if !store.frameworkOK {
                    Label(Loc("未检测到 Go 钱包框架，暂时无法创建或恢复钱包"), systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Pearl.Space.sm)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: Pearl.Radius.xs))
                }

                VStack(spacing: Pearl.Space.sm) {
                    NavigationLink {
                        CreateWalletView(store: store)
                    } label: {
                        Label(Loc("创建新钱包"), systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.pearl)
                    .disabled(!store.frameworkOK)

                    NavigationLink {
                        ImportWalletView(store: store)
                    } label: {
                        Label(Loc("用助记词恢复钱包"), systemImage: "arrow.down.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(!store.frameworkOK)

                    WatchWalletOption { WatchWalletView(store: store) }
                        .padding(.top, Pearl.Space.xs)
                }
                .padding(.top, Pearl.Space.xs)

                // Clones of open-source wallets get re-signed with a stealer inside. Names no
                // other platform's store on purpose: guideline 2.3.10 rejects that.
                Text(Loc("开源可校验 · 请勿从第三方下载，只认官方应用商店或自行编译"))
                    .pearlExplanation(.footnote)
                    .multilineTextAlignment(.center)

                Spacer(minLength: Pearl.Space.lg)
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Loc("欢迎"))
    }
}

// MARK: - Unlock (wallet exists, locked)

struct UnlockView: View {
    @ObservedObject var store: WalletStore
    @State private var working = false
    var body: some View {
        VStack(spacing: Pearl.Space.lg) {
            Spacer()
            ZStack {
                GlowOrb(color: Pearl.indigo.opacity(0.22), diameter: 140)
                PearlIconBadge(systemImage: "lock.fill", size: 76)
            }
            VStack(spacing: Pearl.Space.xs) {
                Text(Loc("%@ 已锁定", store.walletName)).font(.title.bold())
                if let err = store.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            Button {
                working = true
                Task { await store.unlock(); working = false }
            } label: {
                Label(working ? Loc("解锁中…") : Loc("解锁"), systemImage: "lock.open")
            }
            .buttonStyle(.pearl).disabled(working)
            .frame(maxWidth: 320)
            .padding(.top, Pearl.Space.sm)
            // A seed that can't be read shouldn't strand the others: offer them here.
            if store.wallets.count > 1 {
                Menu {
                    ForEach(store.wallets.filter { $0.id != store.activeWalletID }) { w in
                        Button(w.name) { store.switchWallet(to: w.id) }
                    }
                } label: {
                    Label(Loc("切换钱包"), systemImage: "wallet.pass")
                }
                .fixedSize()
            }
            Spacer()
        }
        .padding(Pearl.Space.screen)
        .navigationTitle(Loc("解锁"))
    }
}
