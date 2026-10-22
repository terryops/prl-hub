import SwiftUI

/// All second-level settings use the same form and navigation treatment.
struct SettingsPage<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .pearlListBackground()
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
    }
}

struct WalletSecuritySettingsView: View {
    var body: some View {
        SettingsPage(Loc("钱包与安全")) {
            WalletSettingsSection()
            Section(Loc("安全")) {
                PearlInfoRow(Loc("助记词加密存于钥匙串；查看助记词与转账需 Face ID / Touch ID 验证。"), systemImage: "key.fill")
            }
            .pearlListRowSurface()
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage("ui.appearance") private var appearance = "system"
    @AppStorage("ui.lockPortrait") private var lockPortrait = true

    var body: some View {
        SettingsPage(Loc("主题与配色")) {
            Section(Loc("外观")) {
                Picker(Loc("主题"), selection: $appearance) {
                    Text(Loc("跟随系统")).tag("system")
                    Text(Loc("浅色")).tag("light")
                    Text(Loc("深色")).tag("dark")
                }
                AppPalettePicker()
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .phone {
                    Toggle(Loc("锁定竖屏"), isOn: $lockPortrait)
                }
                #endif
            }
            .pearlListRowSurface()
        }
        .onChange(of: appearance) { _, _ in CloudSync.push("ui.appearance") }
        #if os(iOS)
        .onChange(of: lockPortrait) { _, _ in OrientationLock.apply() }
        #endif
    }
}

struct AppIconSettingsView: View {
    var body: some View {
        SettingsPage(Loc("应用图标")) {
            Section {
                AppIconPicker()
            }
            .pearlListRowSurface()
        }
    }
}

struct LanguageSettingsView: View {
    @EnvironmentObject private var loc: LocalizationManager

    var body: some View {
        SettingsPage(Loc("界面语言")) {
            Section(Loc("语言")) {
                Picker(Loc("界面语言"), selection: Binding(
                    get: { loc.language },
                    set: { loc.setLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
            }
            .pearlListRowSurface()
        }
    }
}

struct CurrencySettingsView: View {
    @EnvironmentObject private var currency: CurrencyManager

    var body: some View {
        SettingsPage(Loc("货币")) {
            Section(Loc("货币")) {
                LabeledContent(Loc("主货币"), value: "USD · " + Loc("美元"))
                Picker(Loc("副货币"), selection: Binding(
                    get: { currency.secondaryPref },
                    set: { currency.setSecondaryPref($0) })) {
                    Text(Loc("跟随语言")).tag(Fiat.auto)
                    Text(Loc("不显示")).tag(Fiat.none)
                    ForEach(Fiat.secondaries) { c in
                        Text("\(c.localizedName) · \(c.code)").tag(c.code)
                    }
                }
                if currency.secondaryPref == Fiat.auto, let s = currency.secondary {
                    LabeledContent(Loc("当前副货币"), value: "\(s.localizedName) · \(s.code)")
                }
                if let line = currency.rateLine() {
                    LabeledContent(Loc("当前汇率"), value: line)
                }
                if let at = currency.lastUpdated {
                    LabeledContent(Loc("汇率更新于"),
                                   value: at.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened)
                                                        .locale(LocBundleHolder.shared.locale)))
                }
                Button(Loc("立即刷新汇率")) { Task { await currency.refresh() } }
                PearlInfoRow(Loc("汇率以美元为基准，每天自动更新一次；离线时使用最近一次缓存。"),
                             systemImage: "clock.arrow.circlepath")
            }
            .pearlListRowSurface()
        }
    }
}

struct NetworkSettingsView: View {
    var body: some View {
        SettingsPage(Loc("Pearl 网络")) {
            NetworkSettingsSection()
        }
    }
}

struct TradeSettingsView: View {
    var body: some View {
        SettingsPage(Loc("交易（SafeTrade）")) {
            SafeTradeSettingsSection()
                .pearlListRowSurface()
        }
    }
}

struct AboutSettingsView: View {
    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    var body: some View {
        SettingsPage(Loc("关于")) {
            Section(Loc("关于")) {
                LabeledContent(Loc("应用"), value: "Pearl Hub")
                LabeledContent(Loc("版本"), value: appVersion)
                // Opens the App Store review sheet directly. The in-app prompt (see
                // ReviewPrompt) is rate-limited by the system and may show nothing at
                // all, so an explicit "I want to rate this" needs a path that always works.
                if let url = ReviewPrompt.writeReviewURL {
                    Link(destination: url) {
                        Label(Loc("为 Pearl Hub 评分"), systemImage: "star.fill")
                    }
                }
                LabeledContent(Loc("开发者"), value: "Cyber Corner")
                Link(destination: AppLinks.telegram) {
                    Label(Loc("加入 Telegram 频道 @prl_hub，获取更新公告与帮助"), systemImage: "paperplane.fill")
                }
                Link(destination: AppLinks.github) {
                    Label(Loc("GitHub 开源代码"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                NavigationLink {
                    LicensesView()
                } label: { Label(Loc("开源许可"), systemImage: "doc.text") }
            }
            .pearlListRowSurface()
        }
    }
}

/// 设置 → 钱包 (only while unlocked) plus the remove-wallet confirmation.
private struct WalletSettingsSection: View {
    @EnvironmentObject private var wallet: WalletStore
    @State private var confirmingReset = false
    @State private var resetError: String?

    var body: some View {
        if wallet.phase == .unlocked {
            Section(Loc("钱包")) {
                NavigationLink {
                    ManageWalletsView(store: wallet)
                } label: {
                    LabeledContent {
                        Text("\(wallet.wallets.count)")
                    } label: {
                        Label(Loc("管理钱包"), systemImage: "wallet.pass")
                    }
                }
                NavigationLink {
                    ContactsView()
                } label: { Label(Loc("地址簿"), systemImage: "person.crop.circle") }
                NavigationLink {
                    RevealSeedView(store: wallet)
                } label: { Label(Loc("查看助记词"), systemImage: "key.horizontal") }
                NavigationLink {
                    RecoverChangeView(store: wallet)
                } label: { Label(Loc("找回搁浅的找零"), systemImage: "arrow.uturn.down.circle") }
                Button { wallet.lock() } label: {
                    Label(Loc("锁定钱包"), systemImage: "lock").foregroundStyle(.primary)
                }
                Button(role: .destructive) { confirmingReset = true } label: {
                    Label(Loc("移除钱包（需助记词恢复）"), systemImage: "trash")
                }
            }
            .pearlListRowSurface()
            // .alert (not .confirmationDialog) — centered on every platform; a
            // confirmationDialog mis-anchors as a popover over the nav bar on iPad/Mac.
            .alert(Loc("确定要移除钱包「%@」吗？", wallet.walletName), isPresented: $confirmingReset) {
                Button(Loc("移除钱包"), role: .destructive) {
                    let ok = withAnimation { wallet.reset() }
                    if !ok { resetError = wallet.lastError ?? Loc("移除失败"); wallet.lastError = nil }
                }
                Button(Loc("取消"), role: .cancel) {}
            } message: {
                Text(Loc("助记词将从本机删除且无法恢复。请确认你已安全备份助记词，否则资产将永久丢失。"))
            }
            .alert(Loc("移除失败"), isPresented: Binding(
                get: { resetError != nil }, set: { if !$0 { resetError = nil } })) {
                Button(Loc("知道了"), role: .cancel) { resetError = nil }
            } message: {
                Text(resetError ?? "")
            }
        }
    }
}

/// 设置 → 网络.
private struct NetworkSettingsSection: View {
    @EnvironmentObject private var wallet: WalletStore

    var body: some View {
        Section(Loc("网络")) {
            Picker(Loc("Pearl 网络"), selection: Binding(
                get: { wallet.network },
                set: { wallet.changeNetwork($0) })) {
                ForEach(WalletNetwork.allCases) { Text($0.label).tag($0) }
            }
            // The indexers this build actually uses, in order.
            LabeledContent(Loc("索引服务"), value: BlockbookClient(network: wallet.network).allBases
                .map { URL(string: $0)?.host ?? $0 }.joined(separator: " · "))
        }
        .pearlListRowSurface()
    }
}

