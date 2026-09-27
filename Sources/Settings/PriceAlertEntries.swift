import SwiftUI

// MARK: - 交易 tab promo

/// One-line status for the price-alert entries: a pitch before Pro, else how many
/// alerts are live.
@MainActor
func priceAlertSubtitle(_ store: PriceAlertStore, isPro: Bool) -> String {
    let on = store.rules.filter(\.enabled).count
    if !isPro { return Loc("涨破、跌破或急涨急跌时推送通知") }
    return on > 0 ? Loc("%d 条提醒生效中", on) : Loc("添加到价或涨跌幅提醒")
}

/// Card under the Trade chart that advertises / opens 价格提醒.
struct PriceAlertPromoCard: View {
    @ObservedObject private var store = PriceAlertStore.shared
    @ObservedObject private var pro = ProStore.shared

    private var subtitle: String { priceAlertSubtitle(store, isPro: pro.isPro) }

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
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
/// card, for the wallet screen, where a card would compete with the balance.
struct PriceAlertInlineLink: View {
    @ObservedObject private var store = PriceAlertStore.shared
    @ObservedObject private var pro = ProStore.shared

    private var subtitle: String { priceAlertSubtitle(store, isPro: pro.isPro) }

    var body: some View {
        NavigationLink {
            PriceAlertsView()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bell.badge").foregroundStyle(Pearl.accent)
                Text(Loc("价格提醒")).foregroundStyle(Pearl.accent)
                Text(verbatim: "·").foregroundStyle(.tertiary)
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}
