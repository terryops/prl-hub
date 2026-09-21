import SwiftUI
import Combine
import StoreKit

// ============================================================
// Pearl Hub Pro — one-time in-app purchase (StoreKit 2)
// ------------------------------------------------------------
// A single non-consumable (`com.prl.wizard.pro`, US$2.99) unlocks
// the premium features — today: server-monitored price alerts.
// App Store rules (3.1.1) require IAP for unlocking functionality;
// crypto donations can't gate anything.
//
// The bundle id is Universal Purchase, so one purchase covers
// iPhone, iPad and Mac. Entitlement = Transaction.currentEntitlements
// (verified by StoreKit), cached in UserDefaults only so the UI
// doesn't flash a paywall on launch before StoreKit answers.
// ============================================================

@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()
    static let productID = "com.prl.wizard.pro"

    @Published private(set) var isPro: Bool
    @Published private(set) var product: Product?
    @Published private(set) var busy = false
    @Published var message: String?

    private static let cacheKey = "pro.unlocked"
    private var updates: Task<Void, Never>?

    init() {
        isPro = UserDefaults.standard.bool(forKey: Self.cacheKey)
        #if DEBUG
        // Screenshot / UI-test seam, compiled out of release.
        if ProcessInfo.processInfo.environment["SHOT_PRO"] == "1" { isPro = true; return }
        #endif
        // Purchases made elsewhere (other device, Ask to Buy approval, refund).
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh(); await loadProduct() }
    }

    func loadProduct() async {
        guard product == nil else { return }
        product = try? await Product.products(for: [Self.productID]).first
    }

    /// Re-derive `isPro` from StoreKit's verified entitlements.
    func refresh() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil { owned = true }
        }
        set(owned)
    }

    func purchase() async {
        await loadProduct()
        guard let product else { message = Loc("暂时无法连接 App Store，请稍后再试"); return }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let t)):
                await t.finish()
                set(true)
            case .success(.unverified):
                message = Loc("购买未能通过验证，请稍后再试")
            case .pending:
                message = Loc("购买待确认（例如等待家长批准），完成后会自动解锁")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        busy = true
        defer { busy = false }
        try? await AppStore.sync()
        await refresh()
        message = isPro ? nil : Loc("没有找到可恢复的购买")
    }

    private func set(_ owned: Bool) {
        guard owned != isPro || UserDefaults.standard.object(forKey: Self.cacheKey) == nil else { return }
        isPro = owned
        UserDefaults.standard.set(owned, forKey: Self.cacheKey)
    }
}

// MARK: - Upsell (earned by usage, not by a visit count)

/// Shows the Pro upsell at most once, and only to someone actually using 交易 as a
/// price ticker: `threshold` *manual* refreshes (pull-to-refresh or the toolbar
/// button) inside a rolling `window`. Merely opening the tab no longer counts — the
/// old "2nd visit" rule fired the paywall at people who hadn't yet seen the prices
/// the alerts are about.
@MainActor
final class UpsellPrompt: ObservableObject {
    static let shared = UpsellPrompt()
    @Published var showing = false

    /// Price of the limit order that was just accepted; non-nil drives the "notify me
    /// when it fills" prompt in TradeView.
    @Published var orderPrompt: String?

    private static let threshold = 6
    private static let window: TimeInterval = 24 * 3600
    private static let stampsKey = "upsell.refreshStamps"
    private static let shownKey = "upsell.shown"
    private static let orderAskedKey = "upsell.orderAsked"

    /// Call ONLY from a user-initiated refresh. Automatic loads (tab appear, iCloud
    /// sync, polling) must not count, or this decays back into a timed popup.
    func tradeRefreshed() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.shownKey), !ProStore.shared.isPro else { return }
        let now = Date().timeIntervalSince1970
        var stamps = (d.array(forKey: Self.stampsKey) as? [Double] ?? []).filter { now - $0 < Self.window }
        stamps.append(now)
        // Keep the array bounded; only the most recent `threshold` stamps can matter.
        if stamps.count > Self.threshold { stamps.removeFirst(stamps.count - Self.threshold) }
        d.set(stamps, forKey: Self.stampsKey)
        guard stamps.count >= Self.threshold else { return }
        d.set(true, forKey: Self.shownKey)
        Task {
            // Let the refresh spinner finish before the sheet slides up.
            try? await Task.sleep(nanoseconds: 600_000_000)
            showing = true
        }
    }

    /// A limit order was accepted — the one moment where a price alert is obviously
    /// useful: the order fills about when PRL touches its price. Asked at most once,
    /// and declining ("暂不") is final, so nobody gets nagged after an order.
    func limitOrderPlaced(price: String) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: Self.orderAskedKey), !d.bool(forKey: Self.shownKey),
              !ProStore.shared.isPro, !price.isEmpty else { return }
        d.set(true, forKey: Self.orderAskedKey)
        Task {
            // Let the 下单成功 toast/refresh land first.
            try? await Task.sleep(nanoseconds: 800_000_000)
            orderPrompt = price
        }
    }

    /// "解锁高级版" on that prompt → the paywall (which then counts as shown).
    func openFromOrderPrompt() {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        orderPrompt = nil
        showing = true
    }
}
