import SwiftUI

// MARK: - 交易 tab promo

/// Card under the Trade chart that opens 价格和到账提醒 (named for the price side, which is
/// what this tab is about): the 高级版 badge before Pro, and how many price alerts are live
/// once there are some — no pitch line.
struct PriceAlertPromoCard: View {
    @ObservedObject private var store = PriceAlertStore.shared
    @ObservedObject private var pro = ProStore.shared

    private var status: String? {
        let on = store.rules.filter(\.isOn).count
        return pro.isPro && on > 0 ? Loc("%d 条提醒生效中", on) : nil
    }

    var body: some View {
        NavigationLink {
            AlertsView()
        } label: {
            HStack(spacing: Pearl.Space.md) {
                PearlIconBadge(systemImage: "bell.badge.fill", size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(Loc("价格提醒")).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if !pro.isPro { PearlBadge(text: Loc("高级版"), systemImage: "sparkles") }
                    }
                    if let status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pearlCard(padding: Pearl.Space.md)
    }
}

/// 价格和到账提醒 as one row of the wallet page's bottom card (no card of its own, which
/// would compete with the balance). Like the other rows there: icon + name + chevron, plus
/// how many alerts are live.
struct AlertsInlineLink: View {
    @ObservedObject private var store = PriceAlertStore.shared
    /// Watched for `incomeRegistered`, which reads it.
    @ObservedObject private var income = IncomeAlertStore.shared
    @ObservedObject private var pro = ProStore.shared

    /// 到账提醒 counts only once this device really sends it to the server (Pro proven, pushes
    /// on here) — an address the worker never got must not read as a live alert.
    private var status: String? {
        let on = store.rules.filter(\.isOn).count + (store.incomeRegistered ? 1 : 0)
        return pro.isPro && on > 0 ? Loc("%d 条提醒生效中", on) : nil
    }

    var body: some View {
        NavigationLink {
            AlertsView()
        } label: {
            WalletShortcutRow(systemImage: "bell.badge", title: Loc("价格和到账提醒"), status: status)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wallet-alerts")
    }
}
