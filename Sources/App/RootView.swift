import SwiftUI
import Combine

/// Root navigation shell — a 5-tab TabView (bottom bar on iPhone, top on Mac).
/// Owns the single shared WalletStore and applies the app-wide appearance.
struct RootView: View {
    // Recover the active identity before any store reads or seeds preferences.
    private let account = WebLinkStore.shared
    // Plain @State, NOT @SceneStorage: a cold launch must always open on 钱包,
    // never restore whatever tab the previous session ended on.
    //
    // DEBUG-only exception: a launch env var can pin the starting tab, so a screenshot /
    // verification run can land on a tab without driving the tab bar. Same shape as
    // PoolStore's SHOT_WATCH_ADDR seeding, and compiled out of release entirely.
    @State private var tab = RootView.initialTab
    @State private var widgetPaywall = false   // the locked widget was tapped

    private static var initialTab: Int {
        #if DEBUG
        if let t = ProcessInfo.processInfo.environment["SHOT_TAB"], let i = Int(t) { return i }
        #endif
        return 0
    }
    @AppStorage("ui.appearance") private var appearance = "system"   // system | light | dark
    // Watched so that a change of palette (设置 → 外观 → 配色) rebuilds the tree below.
    @AppStorage(AppPalette.key) private var paletteStored: String?
    @AppStorage(AppIconChoice.key) private var iconStored: String?
    private var palette: AppPalette { _ = paletteStored; return AppPalette.current }
    @Environment(\.scenePhase) private var scenePhase
    // Not observed here: RootView only injects it. Observing would re-evaluate the whole
    // TabView on every wallet publish; the screens that show wallet state observe it.
    private let wallet = WalletStore.shared
    @StateObject private var contacts = ContactsStore()
    @StateObject private var loc = LocalizationManager.shared
    @StateObject private var currency = CurrencyManager.shared
    var body: some View {
        TabView(selection: $tab) {
            WalletRootView()
                .tabItem {
                    Label(Loc("钱包"), image: "TabWallet")
                }
                .tag(0)

            // Trade tab gated off for the App Store build (guideline 3.1.5 crypto
            // exchange risk). Flip AppFeatures.tradeEnabled to restore it.
            if AppFeatures.tradeEnabled {
                TradeView()
                    .tabItem {
                        Label(Loc("交易"), image: "TabTrade")
                    }
                    .tag(1)
            }

            PRLMonitorView()
                .tabItem {
                    Label(Loc("挖矿监控"), image: "TabMining")
                }
                .tag(2)

            PoolView()
                .tabItem {
                    Label(Loc("我的监控"), image: "TabMonitor")
                }
                .tag(3)

            SettingsView()
                .tabItem {
                    Label(Loc("设置"), image: "TabSettings")
                }
                .tag(4)
        }
        .tint(Pearl.accent)                       // brand accent for all default-tinted controls
        .toggleStyle(PearlSwitchStyle())          // …but a switch that is on has a colour of its own
        // Widget deep links — a tap on the widget's price/balance/pool region opens
        // the app here with a pearlhub:// URL; jump to that destination's tab. The
        // 交易 tab only exists when trading is enabled, so a price (→交易) tap falls
        // back to 钱包 when it's gated off.
        .onOpenURL { url in
            guard let route = WidgetDeepLink(url: url) else { return }
            tab = (route == .trade && !AppFeatures.tradeEnabled) ? WidgetDeepLink.wallet.tab : route.tab
            // A tap on the locked widget is explicit interest: offer Pro right away.
            if route == .pro, !ProStore.shared.isPro { widgetPaywall = true }
        }
        .sheet(isPresented: $widgetPaywall) {
            ProUpsellSheet(headline: Loc("高级版功能：桌面小组件"), headlineIcon: "square.grid.2x2")
        }
        .background {                             // ambient pearl wash behind transparent scroll content
            PearlBackground()
        }
        .environmentObject(wallet)
        .environmentObject(contacts)
        .environmentObject(loc)
        .environmentObject(currency)
        // Re-resolve the chosen language for the whole tree, and rebuild it on
        // switch so every Loc(...) call site re-evaluates immediately. The same for the
        // palette: every Pearl colour is looked up as a view is built.
        .environment(\.locale, loc.language.locale)
        .id(TreeIdentity(language: loc.language, palette: palette))
        .task {
            // Ahead of the launch counter below, which it reads: an install that has
            // launched before keeps the icon it had (设置 → 外观 → 应用图标).
            AppIconChoice.adoptDefault()
            // Likewise: only an install that synced before queues its edits while sync is off.
            CloudSync.adoptDefault()
            publishWidgetAppearance()
            Task { await AppIconChoice.applyAtLaunch() }
            // One tick on the 评分提醒 counter per launch — the prompt itself is asked for
            // much later, from 我的监控, and only once the gates in ReviewPrompt allow it.
            ReviewPrompt.registerLaunch()
            // Lift any SafeTrade keys an older build left in plaintext
            // UserDefaults/iCloud-KVS into the (E2E-encrypted) iCloud Keychain,
            // then scrub the plaintext copies. No-ops once migrated.
            SafeTradeSecrets.migrateFromLegacyIfNeeded()
            // Seeds only keys the cloud has never seen, then pulls — a value another
            // device saved while this one was closed wins over the stale local copy.
            CloudSync.start()
            // Signed in on another device: follow it (sign in once, on every device).
            Task { await account.join(automatic: true) }
            await currency.refreshIfStale()   // daily-cached USD rate table
        }
        // Re-pull from iCloud on every foreground so keys/config saved on another
        // device (e.g. SafeTrade API keys on the Mac) land here without a relaunch.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                CloudSync.refresh()
                PriceAlertStore.shared.foreground()
                PriceLiveActivity.shared.foreground()
                WebLinkStore.shared.foreground()
                Task { await currency.refreshIfStale() }
            }
        }
        .onChange(of: paletteStored) { _, _ in publishWidgetAppearance() }
        .onChange(of: iconStored) { _, _ in publishWidgetAppearance() }
        .onChange(of: appearance) { _, _ in publishWidgetAppearance() }
        .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidUpdate)) { _ in
            contacts.reload()
            wallet.adoptSyncedMeta()   // wallet name / network synced from another device
            loc.reloadFromDefaults()   // language chosen on another device
            currency.reloadFromDefaults()
        }
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        // Cap Dynamic Type so a large "Larger Text" / Display-Zoom setting can't
        // blow the layout out of bounds on iPhone (content stays readable + fits).
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 600)
        #endif
    }

    private func publishWidgetAppearance() {
        if WidgetBridge.updateAppearance(palette: palette.rawValue,
                                         icon: AppIconChoice.current.rawValue, mode: appearance) {
            PriceLiveActivity.shared.refreshAppearance()
        }
    }
}

/// What the tree is rebuilt for.
private struct TreeIdentity: Hashable {
    var language: AppLanguage
    var palette: AppPalette
}

#Preview {
    RootView()
}
