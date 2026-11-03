import SwiftUI

// MARK: - 交易 tab promo

/// Card under the Trade chart that opens 价格提醒: its name, the 高级版 badge before Pro,
/// and how many alerts are live once there are some — no pitch line.
struct PriceAlertPromoCard: View {
    @ObservedObject private var store = PriceAlertStore.shared
    @ObservedObject private var pro = ProStore.shared

    private var status: String? {
        let on = store.rules.filter(\.isOn).count
        return pro.isPro && on > 0 ? Loc("%d 条提醒生效中", on) : nil
    }

    var body: some View {
        NavigationLink {
            PriceAlertsView()
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

/// The same entry as PriceAlertPromoCard, as one quiet line of small text with no
/// card, for the wallet screen, where a card would compete with the balance. Like the
/// other lines there (桌面小组件, NOCK): icon + name + chevron, plus the live count.
struct PriceAlertInlineLink: View {
    @ObservedObject private var store = PriceAlertStore.shared
    @ObservedObject private var pro = ProStore.shared

    private var status: String? {
        let on = store.rules.filter(\.isOn).count
        return pro.isPro && on > 0 ? Loc("%d 条提醒生效中", on) : nil
    }

    var body: some View {
        NavigationLink {
            PriceAlertsView()
        } label: {
            WalletShortcutRow(systemImage: "bell.badge", title: Loc("价格提醒"), status: status)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
