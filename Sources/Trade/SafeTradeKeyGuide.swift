import SwiftUI

/// 如何获取 API 密钥: creating a SafeTrade API key for the app, step by step, plus what
/// the app does (and doesn't do) with it.
///
/// Labels follow safetrade.com's own "API Keys" page (safetrade.com/my/api, "Create API
/// Key" dialog: Label · Restrictions: Enable Reading / Trading / Withdraw · Trusted IPs,
/// IPv4 or IPv6, space-separated, at most 20 · Google Authentication code), so the steps
/// read the same as the screen the user has open. The IP SafeTrade sees for this device
/// is looked up live, ready to paste into Trusted IPs.
struct SafeTradeKeyGuide: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ip: String?
    @State private var ipFailed = false
    @State private var copied = false

    private static let apiPage = URL(string: "https://safetrade.com/my/api")!

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                    Text(Loc("在 SafeTrade 网站创建一把 API 密钥，填进 App 后就能在这里看余额、下单和提现。全程约 2 分钟。"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                        step(1, Loc("开启谷歌验证"),
                             Loc("登录 safetrade.com。创建 API 密钥需要谷歌验证（2FA），还没开的话先在账户安全设置里开启。"))
                        step(2, Loc("打开 API Keys 页面"),
                             Loc("在 SafeTrade 顶部菜单点「API」，或直接打开 safetrade.com/my/api，然后点「Create」。")) {
                            Link(destination: Self.apiPage) {
                                Label(Loc("打开 SafeTrade API 页面"), systemImage: "safari")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .tint(Pearl.accent)
                        }
                        step(3, Loc("设置权限"),
                             Loc("Label 随便填（例如 Pearl Hub）。Restrictions 里勾选 Enable Reading 和 Enable Trading；只有要在 App 里提现时才勾 Enable Withdraw。"))
                        step(4, Loc("填写 Trusted IPs"),
                             Loc("SafeTrade 只接受这里列出的 IP。填入 SafeTrade 现在看到的你的 IP：")) {
                            ipRow
                            Text(Loc("多个 IP 用空格隔开，IPv4 和 IPv6 都可以，最多 20 个。手机可能时而用 IPv4、时而用 IPv6，换网络后 IP 也会变——以后交易页提示 IP 不在白名单时，把它显示的新 IP 补进来即可。"))
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        step(5, Loc("保存 API Key 和 Secret"),
                             Loc("输入谷歌验证码确认后，页面会显示 API Key 和 API Secret。Secret 只显示这一次，请立刻复制。"))
                        step(6, Loc("填进 App"),
                             Loc("回到「设置 → 交易（SafeTrade）」，粘贴 API Key 和 API Secret 并保存，App 会马上验证能否使用。"))
                    }
                    .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
                    security
                }
                .padding(Pearl.Space.screen)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(Loc("获取 API 密钥"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(Loc("完成")) { dismiss() } }
                    .noGlassBackground()
            }
            .task { await lookUpIP() }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 600)
        #endif
    }

    // MARK: pieces

    @ViewBuilder private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        step(n, title, text) { EmptyView() }
    }

    private func step<Extra: View>(_ n: Int, _ title: String, _ text: String,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: Pearl.Space.sm) {
            Text(verbatim: "\(n)")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Pearl.brand, in: Circle())
            VStack(alignment: .leading, spacing: Pearl.Space.xs) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                extra()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The address to whitelist, as SafeTrade sees it right now (no key needed).
    @ViewBuilder private var ipRow: some View {
        HStack(spacing: Pearl.Space.sm) {
            if let ip {
                Text(verbatim: ip).font(.callout.monospaced()).textSelection(.enabled)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 0)
                Button(copied ? Loc("已复制") : Loc("复制")) {
                    copyToPasteboard(ip)
                    copied = true
                }
                .buttonStyle(.borderless).font(.caption.weight(.semibold)).tint(Pearl.accent)
            } else if ipFailed {
                Text(Loc("暂时查不到当前 IP，请稍后再试。")).font(.caption).foregroundStyle(.orange)
                Spacer(minLength: 0)
                Button(Loc("重试")) { Task { await lookUpIP() } }
                    .buttonStyle(.borderless).font(.caption.weight(.semibold)).tint(Pearl.accent)
            } else {
                ProgressView().controlSize(.small)
                Text(Loc("正在查询…")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Pearl.Space.sm)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Pearl.Radius.xs, style: .continuous))
    }

    /// What happens to the key — every line here is how the code actually behaves:
    /// Keychain-only storage, signing on the device, requests to safetrade.com only
    /// (the price-alert server never sees a key), Face ID before a withdrawal, and the
    /// source on GitHub.
    private var security: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            Label(Loc("安全说明"), systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
            bullet("key.icloud", Loc("API Key 和 Secret 只存在你的钥匙串里（iCloud 钥匙串，端到端加密），不会上传到我们的服务器。"))
            bullet("arrow.left.arrow.right", Loc("App 直接连接 safetrade.com，中间不经过我们或任何第三方。Secret 只在你的设备上用来给请求签名，本身从不发送出去。"))
            bullet("faceid", Loc("每次提现前都要通过设备验证（Face ID、Touch ID 或密码）。"))
            bullet("chevron.left.forwardslash.chevron.right", Loc("Pearl Hub 的源代码公开在 GitHub，任何人都可以检查。"))
            Link(destination: AppLinks.github) {
                Label(Loc("查看源代码"), systemImage: "arrow.up.right.square")
                    .font(.caption.weight(.semibold))
            }
            .tint(Pearl.accent)
            .padding(.leading, 28)
            Text(Loc("建议只开需要的权限，并绑定 IP。不要把 API Key 或 Secret 告诉任何人，包括自称客服的人。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Pearl.Space.xs) {
            Image(systemName: icon).font(.caption).foregroundStyle(.green)
                .frame(width: 20)
            Text(text).font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func lookUpIP() async {
        ipFailed = false
        do { ip = try await SafeTradeClient().publicIP() }
        catch { if ip == nil { ipFailed = true } }
    }
}
