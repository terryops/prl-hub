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
                        PearlMascot(size: 88)
                        Text(Loc("$Pearl Hub"))
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        Text(Loc("自托管 · 私钥与签名留在本机（钥匙串 / 安全隔区）"))
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                    }
                }

                VStack(spacing: Pearl.Space.md) {
                    feature("lock.shield", Loc("安全存储"), Loc("助记词加密存于本机钥匙串，永不上传服务器"), Pearl.brand)
                    feature("arrow.left.arrow.right", Loc("便捷收发"), Loc("链上同步与广播交给远程节点"), Pearl.mint)
                    feature("chart.line.uptrend.xyaxis", Loc("行情与算力"), Loc("内置 PRL 挖矿监控"), Pearl.sunrise)
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
                }
                .padding(.top, Pearl.Space.xs)

                Spacer(minLength: Pearl.Space.lg)
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Loc("欢迎"))
    }

    @ViewBuilder private func feature(_ icon: String, _ title: String, _ sub: String, _ gradient: LinearGradient) -> some View {
        HStack(spacing: Pearl.Space.md) {
            PearlIconBadge(systemImage: icon, gradient: gradient, size: 44)
            VStack(alignment: .leading, spacing: Pearl.Space.xxs) {
                Text(title).font(.headline)
                Text(sub).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .pearlCard(padding: Pearl.Space.md)
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
                Text(Loc("点按解锁继续")).font(.callout).foregroundStyle(.secondary)
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
            Spacer()
        }
        .padding(Pearl.Space.screen)
        .navigationTitle(Loc("解锁"))
    }
}
