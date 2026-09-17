import Foundation

/// Deep-link routes shared by the widget (which builds the tap URLs) and the app
/// (which parses them in `onOpenURL`). Keeping both sides on this one enum means the
/// URL the widget embeds and the tab the app opens can't drift apart.
///
/// A widget tap opens the owning app with one of these URLs WITHOUT needing a
/// registered `CFBundleURLTypes` scheme — WidgetKit routes a widget's URL straight
/// to the app that owns the extension. So there's nothing to declare in project.yml.
enum WidgetDeepLink: String {
    case wallet   // 钱包    — balance / recent transfers
    case trade    // 交易    — the PRL/USD price drives this; SafeTrade surface
    case pools    // 我的监控 — pool watches / hashrate

    static let scheme = "pearlhub"

    /// The URL to embed in the widget for this destination, e.g. `pearlhub://wallet`.
    var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

    /// Tab index in RootView's TabView this destination opens.
    /// (0 钱包 · 1 交易 · 2 挖矿监控 · 3 我的监控 · 4 设置 — see RootView.)
    /// Note: the 交易 tab only exists when trading is enabled — the app falls back
    /// to 钱包 for a `.trade` link otherwise (see RootView.onOpenURL).
    var tab: Int {
        switch self {
        case .wallet: return 0
        case .trade:  return 1
        case .pools:  return 3
        }
    }

    /// Parse an incoming widget URL back to a route (nil if it isn't one of ours).
    /// The route key lives in the host (`pearlhub://wallet`), with a path fallback
    /// in case a platform normalizes it to `pearlhub:/wallet`.
    init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        let key = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let route = WidgetDeepLink(rawValue: key) else { return nil }
        self = route
    }
}
