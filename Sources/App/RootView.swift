import SwiftUI
import Combine

/// Root navigation shell — a 5-tab TabView (bottom bar on iPhone, top on Mac).
/// Owns the single shared WalletStore and applies the app-wide appearance.
struct RootView: View {
    // Plain @State, NOT @SceneStorage: a cold launch must always open on 钱包,
    // never restore whatever tab the previous session ended on.
    //
    // DEBUG-only exception: a launch env var can pin the starting tab, so a screenshot /
    // verification run can land on a tab without driving the tab bar. Same shape as
    // PoolStore's SHOT_WATCH_ADDR seeding, and compiled out of release entirely.
    @State private var tab = RootView.initialTab

    private static var initialTab: Int {
        #if DEBUG
        if let t = ProcessInfo.processInfo.environment["SHOT_TAB"], let i = Int(t) { return i }
        #endif
        return 0
    }
    @AppStorage("ui.appearance") private var appearance = "system"   // system | light | dark
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var wallet = WalletStore.shared
    @StateObject private var contacts = ContactsStore()
    @StateObject private var loc = LocalizationManager.shared
    @StateObject private var currency = CurrencyManager.shared
    var body: some View {
        TabView(selection: $tab) {
            WalletRootView()
                .tabItem { Label(Loc("钱包"), systemImage: "bitcoinsign.circle") }
                .tag(0)

            // Trade tab gated off for the App Store build (guideline 3.1.5 crypto
            // exchange risk). Flip AppFeatures.tradeEnabled to restore it.
            if AppFeatures.tradeEnabled {
                TradeView()
                    .tabItem { Label(Loc("交易"), systemImage: "arrow.left.arrow.right.circle") }
                    .tag(1)
            }

            PRLMonitorView()
                .tabItem { Label(Loc("挖矿监控"), systemImage: "chart.line.uptrend.xyaxis") }
                .tag(2)

            PoolView()
                .tabItem { Label(Loc("我的监控"), systemImage: "square.stack.3d.up.fill") }
                .tag(3)

            SettingsView()
                .tabItem { Label(Loc("设置"), systemImage: "gearshape") }
                .tag(4)
        }
        .tint(Pearl.accent)                       // brand accent for all default-tinted controls
        // Widget deep links — a tap on the widget's price/balance/pool region opens
        // the app here with a pearlhub:// URL; jump to that destination's tab. The
        // 交易 tab only exists when trading is enabled, so a price (→交易) tap falls
        // back to 钱包 when it's gated off.
        .onOpenURL { url in
            guard let route = WidgetDeepLink(url: url) else { return }
            tab = (route == .trade && !AppFeatures.tradeEnabled) ? WidgetDeepLink.wallet.tab : route.tab
        }
        .background {                             // ambient pearl wash behind transparent scroll content
            PearlBackground()
        }
        .environmentObject(wallet)
        .environmentObject(contacts)
        .environmentObject(loc)
        .environmentObject(currency)
        // Re-resolve the chosen language for the whole tree, and rebuild it on
        // switch so every Loc(...) call site re-evaluates immediately.
        .environment(\.locale, loc.language.locale)
        .id(loc.language)
        .task {
            // One tick on the 评分提醒 counter per launch — the prompt itself is asked for
            // much later, from 我的监控, and only once the gates in ReviewPrompt allow it.
            ReviewPrompt.registerLaunch()
            // Lift any SafeTrade keys an older build left in plaintext
            // UserDefaults/iCloud-KVS into the (E2E-encrypted) iCloud Keychain,
            // then scrub the plaintext copies. No-ops once migrated.
            SafeTradeSecrets.migrateFromLegacyIfNeeded()
            // Pass the synced keys so locally-entered values are pushed up BEFORE the
            // initial pull — otherwise a stale cloud value/tombstone could clobber the
            // only current local copy on first launch (the protection was dead code).
            CloudSync.start(preferLocalKeys: CloudSync.syncedKeys)
            await currency.refreshIfStale()   // daily-cached USD rate table
        }
        // Re-pull from iCloud on every foreground so keys/config saved on another
        // device (e.g. SafeTrade API keys on the Mac) land here without a relaunch.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                CloudSync.refresh()
                PriceAlertStore.shared.foreground()
                Task { await currency.refreshIfStale() }
            }
        }
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
}

#Preview {
    RootView()
}
