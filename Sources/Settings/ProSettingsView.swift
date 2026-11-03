import SwiftUI

/// Membership has its own destination for both prospective and active members.
struct ProSettingsView: View {
    @ObservedObject private var pro = ProStore.shared
    @ObservedObject private var web = WebLinkStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: Pearl.Space.lg) {
                if pro.isPro {
                    activeMembership
                } else {
                    ProPaywallCard(pro: pro)
                }
                syncDetails
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background { PearlBackground() }
        .navigationTitle(Loc("Pro 会员"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await pro.loadProduct() }
    }

    private var activeMembership: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.lg) {
            HStack(spacing: Pearl.Space.sm) {
                PearlIconBadge(systemImage: "sparkles", size: 44)
                Text(Loc("Pearl Hub 高级版")).font(.headline)
                Spacer(minLength: 0)
                PearlBadge(text: Loc("已开通"), tint: Pearl.accent)
            }
            ProFeatureList()
            Button(Loc("恢复购买")) { Task { await pro.restore() } }
                .disabled(pro.busy)
            if let message = pro.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pearlAccentCard()
    }

    /// Sync is signed in through the email account: its title, what it carries in the ⓘ,
    /// and the way to the account.
    private var syncDetails: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.md) {
            HStack(spacing: 4) {
                Label(Loc("跨设备数据同步"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                PearlInfoTip(Loc("用邮箱登录，同步矿机、挖矿配置、监控、公开地址、通讯录、提醒和偏好设置。助记词、私钥和钱包密码不会上传。")
                             + "\n\n" + Loc("在其他设备或网页版登录同一邮箱，App Store 购买的高级版也能使用。"),
                             title: Loc("跨设备数据同步"))
            }
            NavigationLink {
                WebLinkView()
            } label: {
                HStack {
                    Label(Loc("邮箱账号"), systemImage: "person.crop.circle")
                    Spacer(minLength: Pearl.Space.sm)
                    if web.isLinked { Text(Loc("已连接")) }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
            }
            .accessibilityIdentifier("pro-sync-account")
        }
        .pearlCard()
    }
}
