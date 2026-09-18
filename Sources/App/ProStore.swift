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

// MARK: - One-time upsell

/// Shows the Pro upsell once, the 2nd time the user opens the 交易 tab — never to Pro
/// users. Counted on tab switches (RootView), so pushing into 价格提醒 and back
/// doesn't count as another visit.
@MainActor
final class UpsellPrompt: ObservableObject {
    static let shared = UpsellPrompt()
    @Published var showing = false

    private static let opensKey = "upsell.tradeOpens"
    private static let shownKey = "upsell.shown"

    func tradeOpened() {
        let d = UserDefaults.standard
        let n = d.integer(forKey: Self.opensKey) + 1
        d.set(n, forKey: Self.opensKey)
        guard n >= 2, !d.bool(forKey: Self.shownKey), !ProStore.shared.isPro else { return }
        d.set(true, forKey: Self.shownKey)
        Task {
            // Let the tab settle before the sheet slides up.
            try? await Task.sleep(nanoseconds: 600_000_000)
            showing = true
        }
    }
}
