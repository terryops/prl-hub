import SwiftUI

// MARK: - 锁屏盯盘

/// Settings → 通知 → 锁屏盯盘: the on/off + style card, or the Pro offer.
struct LiveActivitySettingsView: View {
    @ObservedObject private var pro = ProStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: Pearl.Space.lg) {
                if pro.isPro { LiveActivityCard() } else { ProPaywallCard(pro: pro) }
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Loc("锁屏盯盘"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// On/off for the Lock Screen / Dynamic Island live price (Pro, iPhone only).
struct LiveActivityCard: View {
    @ObservedObject private var live = PriceLiveActivity.shared
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            HStack(spacing: Pearl.Space.md) {
                PearlIconBadge(systemImage: "lock.iphone", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Loc("锁屏盯盘")).font(.headline)
                    Text(Loc("锁屏和灵动岛实时显示 PRL 价格，约每分钟更新，最长 8 小时。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(get: { live.running }, set: { on in
                        busy = true
                        Task { if on { await live.start() } else { await live.stop() }; busy = false }
                    }))
                    .labelsHidden()
                }
            }
            // 显示样式: iOS always shows the activity both on the Lock Screen and in the
            // Dynamic Island — the choice is which of the two carries the price.
            VStack(spacing: 0) {
                styleRow("full", Loc("完整"), Loc("锁屏大卡片 + 灵动岛显示价格"))
                Divider().padding(.leading, 30)
                styleRow("lock", Loc("锁屏为主"), Loc("锁屏大卡片；灵动岛只显示小珍珠"))
                Divider().padding(.leading, 30)
                styleRow("island", Loc("灵动岛为主"), Loc("灵动岛显示价格；锁屏只占一行"))
            }
            .padding(.top, Pearl.Space.xs)
            if let e = live.error {
                Text(e).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pearlCard(padding: Pearl.Space.md)
    }

    private func styleRow(_ raw: String, _ title: String, _ detail: String) -> some View {
        Button { live.styleRaw = raw } label: {
            HStack(alignment: .firstTextBaseline, spacing: Pearl.Space.sm) {
                Image(systemName: live.styleRaw == raw ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(live.styleRaw == raw ? Pearl.accent : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(live.styleRaw == raw ? .isSelected : [])
    }
}
