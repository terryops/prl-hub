import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Paywall

/// Pearl Hub Pro — a one-time US$2.99 in-app purchase that unlocks price alerts.
struct ProPaywallCard: View {
    @ObservedObject var pro: ProStore

    var body: some View {
        VStack(spacing: Pearl.Space.lg) {
            VStack(spacing: Pearl.Space.xs) {
                PearlIconBadge(systemImage: "sparkles", size: 52)
                Text(Loc("Pearl Hub 高级版")).font(.title3.weight(.bold))
                Text(Loc("价格一到，第一时间通知你"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                feature("scope", Loc("到价提醒：涨破或跌破你设定的价格"))
                feature("waveform.path.ecg", Loc("涨跌幅提醒：5 分钟、1 小时或 24 小时"))
                feature("bell.badge", Loc("没打开 App 也能收到通知"))
                if PriceLiveActivity.supported {
                    feature("lock.iphone", Loc("锁屏盯盘：锁屏和灵动岛实时显示价格"))
                }
                feature("laptopcomputer.and.iphone", Loc("一次购买，iPhone、iPad 和 Mac 通用"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: Pearl.Space.sm) {
                Button {
                    Task { await pro.purchase() }
                } label: {
                    HStack(spacing: Pearl.Space.xs) {
                        if pro.busy { ProgressView().controlSize(.small).tint(.white) }
                        Text(pro.product.map { Loc("以 %@ 解锁", $0.displayPrice) } ?? Loc("解锁高级版"))
                    }
                }
                .buttonStyle(.pearl)
                .disabled(pro.busy)

                HStack(spacing: 6) {
                    Button(Loc("恢复购买")) { Task { await pro.restore() } }
                        .disabled(pro.busy)
                    Text("·").foregroundStyle(.tertiary)
                    Text(Loc("一次性购买，不是订阅。")).foregroundStyle(.secondary)
                }
                .font(.footnote)

                if let msg = pro.message {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .pearlAccentCard()
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Pearl.Space.sm) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Pearl.accent)
                .frame(width: 24)          // one column for every icon, whatever its glyph width
            Text(text).font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - One-time upsell sheet

/// The paywall as a sheet — shown once, after repeated manual refreshes on 交易
/// (UpsellPrompt).
/// Closes itself when the purchase goes through; TradeView then opens 价格提醒.
struct ProUpsellSheet: View {
    @ObservedObject private var pro = ProStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 620   // measured; the sheet hugs its content

    var body: some View {
        ScrollView {
            VStack(spacing: Pearl.Space.md) {
                PearlBadge(text: Loc("新功能：价格提醒"), systemImage: "bell.badge")
                ProPaywallCard(pro: pro)
                Button(Loc("暂不")) { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { contentHeight = g.size.height }
                    .onChange(of: g.size.height) { _, h in contentHeight = h }
            })
        }
        .background { PearlBackground() }
        .task { await pro.loadProduct() }
        .onChange(of: pro.isPro) { _, unlocked in if unlocked { dismiss() } }
        #if os(iOS)
        .presentationDetents([.height(contentHeight + Pearl.Space.lg)])
        .presentationDragIndicator(.visible)
        // Opaque: a partial-height sheet otherwise gets the system's see-through glass.
        .presentationBackground {
            ZStack { Color(uiColor: .systemBackground); PearlBackground() }
        }
        #else
        .frame(width: 460, height: 660)
        #endif
    }
}
