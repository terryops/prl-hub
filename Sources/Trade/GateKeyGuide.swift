import SwiftUI

/// 如何获取 API 密钥: unified step-by-step guide for SafeTrade (`safetrade.com/my/api`)
/// and Gate (`gate.com/myaccount/apikeys`), with an exchange switcher at the top,
/// live public-IP lookup for the selected exchange, and an optional direct jump to
/// the key input form when opened from the Trade tab.
struct TradeKeyGuide: View {
    @Environment(\.dismiss) private var dismiss
    @State private var exchange: TradeExchange
    @State private var ip: String?
    @State private var ipFailed = false
    @State private var copied = false
    var onFillKeys: ((TradeExchange) -> Void)?

    init(initialExchange: TradeExchange = TradeExchange.saved, onFillKeys: ((TradeExchange) -> Void)? = nil) {
        _exchange = State(initialValue: initialExchange)
        self.onFillKeys = onFillKeys
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                    Picker(Loc("交易所"), selection: $exchange) {
                        ForEach(TradeExchange.allCases) { ex in
                            Text(verbatim: ex.displayName).tag(ex)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("key-guide-exchange-picker")

                    VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                        if exchange == .gate {
                            gateSteps
                        } else {
                            safeTradeSteps
                        }
                    }
                    .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)

                    security
                }
                .padding(Pearl.Space.screen)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(exchange == .gate ? Loc("获取 Gate API 密钥") : Loc("获取 API 密钥"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(Loc("完成")) { dismiss() } }
                    .noGlassBackground()
            }
            .onChange(of: exchange) { _, next in
                TradeExchange.save(next)
            }
            .task(id: exchange) {
                ip = nil
                copied = false
                await lookUpIP(for: exchange)
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 620)
        #endif
    }

    // MARK: - Gate steps

    @ViewBuilder private var gateSteps: some View {
        step(1, Loc("开启安全验证"),
             Loc("登录 gate.com 或 Gate App，确保账户已开启谷歌验证（2FA）和资金密码。"))
        step(2, Loc("创建 API v4 密钥"),
             Loc("网页端右上角头像进入「API 管理」（手机 App 在左上角头像 →「安全中心 / 更多 → API 管理」），点「创建 API Key」，在「账户类型」弹窗里选「交易账户」，备注随便填（如 Pearl Hub），API Key 类型选「API v4 Key」。"),
             info: Loc("「账户类型」弹窗有三种：选「交易账户」。不要选「模拟交易」（虚拟盘，无法读写实盘资产），也不要选「第三方应用」（仅限 Gate 预设的合作托管平台固定服务器 IP，Pearl Hub 由你的设备本机直连 Gate）。")) {
            Link(destination: TradeExchange.gate.apiManagementURL) {
                Label(Loc("打开 Gate API 页面"), systemImage: "safari")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(Pearl.accent)
        }
        step(3, Loc("勾选权限"),
             Loc("开启「现货 → 读写」（仅查余额可选「只读」）和「钱包 → 只读」（查充值地址、提币手续费与地址簿必需）；「提现 → 读写」按需开启，其余合约、杠杆等全部保持关闭。"),
             info: Loc("只开「现货 + 提现」而不勾「钱包 → 只读」会导致充值和提现页无法读取地址与手续费。开启 API 提币时，Gate 还要求目标收款地址已先在 Gate 后台加入提币白名单（或手动成功提过一次）。")) {
            EmptyView()
        }
        step(4, Loc("绑定 IP 白名单"),
             Loc("选「绑定 IP」并填入当前网络的公网 IP（多个 IP 用英文逗号隔开，最多 20 个）："),
             info: Loc("开启提现权限时 Gate 强制要求绑定 IP；不开提现也可暂不绑定（有效期 90 天）。手机网络可能在 IPv4 与 IPv6 之间切换，换网络后提示 IP 不在白名单时把新 IP 补进去即可。新建或修改白名单约 1–5 分钟生效。")) {
            ipRow
        }
        step(5, Loc("复制 Key 和 Secret"),
             Loc("提交并确认风险提示，输入资金密码和二次验证码后，立即复制显示的 API Key 和 Secret（Secret 只显示这一次）。"))
        step(6, Loc("填进 App"),
             Loc("回到「设置 → 交易」，在 Gate 区域粘贴 API Key 和 Secret 并保存，App 会马上验证权限与白名单状态。")) {
            fillButton
        }
    }

    // MARK: - SafeTrade steps

    @ViewBuilder private var safeTradeSteps: some View {
        step(1, Loc("开启谷歌验证"),
             Loc("登录 safetrade.com。创建 API 密钥需要谷歌验证（2FA），还没开的话先在账户安全设置里开启。"))
        step(2, Loc("打开 API Keys 页面"),
             Loc("在 SafeTrade 顶部菜单点「API」，或直接打开 safetrade.com/my/api，然后点「Create」。")) {
            Link(destination: TradeExchange.safetrade.apiManagementURL) {
                Label(Loc("打开 SafeTrade API 页面"), systemImage: "safari")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(Pearl.accent)
        }
        step(3, Loc("设置权限"),
             Loc("Label 随便填（例如 Pearl Hub）。Restrictions 里勾选 Enable Reading 和 Enable Trading；只有要在 App 里提现时才勾 Enable Withdraw。"))
        step(4, Loc("填写 Trusted IPs"),
             Loc("SafeTrade 只接受这里列出的 IP。填入 SafeTrade 现在看到的你的 IP："),
             info: Loc("多个 IP 用空格隔开，IPv4 和 IPv6 都可以，最多 20 个。手机可能时而用 IPv4、时而用 IPv6，换网络后 IP 也会变——以后交易页提示 IP 不在白名单时，把它显示的新 IP 补进来即可。")) {
            ipRow
        }
        step(5, Loc("保存 API Key 和 Secret"),
             Loc("输入谷歌验证码确认后，页面会显示 API Key 和 API Secret。Secret 只显示这一次，请立刻复制。"))
        step(6, Loc("填进 App"),
             Loc("回到「设置 → 交易」，粘贴 API Key 和 API Secret 并保存，App 会马上验证能否使用。")) {
            fillButton
        }
    }

    @ViewBuilder private var fillButton: some View {
        if let onFillKeys {
            Button {
                onFillKeys(exchange)
            } label: {
                Label(Loc("填写 API 密钥"), systemImage: "key.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Pearl.plate)
            .padding(.top, Pearl.Space.xxs)
        }
    }

    // MARK: - Shared pieces

    @ViewBuilder private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        step(n, title, text) { EmptyView() }
    }

    private func step<Extra: View>(_ n: Int, _ title: String, _ text: String, info: String? = nil,
                                   @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: Pearl.Space.sm) {
            Text(verbatim: "\(n)")
                .font(.caption.weight(.bold)).foregroundStyle(Pearl.onAccent)
                .frame(width: 22, height: 22)
                .background(Pearl.brand, in: Circle())
            VStack(alignment: .leading, spacing: Pearl.Space.xs) {
                HStack(spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    if let info { PearlInfoTip(info, title: title) }
                }
                Text(text).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                extra()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

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
                Button(Loc("重试")) { Task { await lookUpIP(for: exchange) } }
                    .buttonStyle(.borderless).font(.caption.weight(.semibold)).tint(Pearl.accent)
            } else {
                ProgressView().controlSize(.small)
                Text(Loc("正在查询…")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Pearl.Space.sm)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Pearl.Radius.xs, style: .continuous))
    }

    private var security: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            HStack(spacing: 4) {
                Label(Loc("安全说明"), systemImage: "lock.shield")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.green)
                PearlInfoTip(keyHandling, title: Loc("安全说明"))
            }
            Text(Loc("建议只开需要的权限，并绑定 IP。不要把 API Key 或 Secret 告诉任何人，包括自称客服的人。"))
                .pearlExplanation()
            Link(destination: AppLinks.github) {
                Label(Loc("查看源代码"), systemImage: "arrow.up.right.square")
                    .font(.caption.weight(.semibold))
            }
            .tint(Pearl.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
    }

    private var keyHandling: String {
        [Loc("API Key 和 Secret 只存在你的钥匙串里（iCloud 钥匙串，端到端加密），不会上传到我们的服务器。"),
         exchange == .gate
            ? Loc("App 直接连接 api.gateio.ws，中间不经过我们或任何第三方。Secret 只在你的设备上用来给请求签名，本身从不发送出去。")
            : Loc("App 直接连接 safetrade.com，中间不经过我们或任何第三方。Secret 只在你的设备上用来给请求签名，本身从不发送出去。"),
         Loc("每次提现前都要通过设备验证（Face ID、Touch ID 或密码）。"),
         Loc("Pearl Hub 的源代码公开在 GitHub，任何人都可以检查。")]
            .joined(separator: "\n\n")
    }

    private func lookUpIP(for target: TradeExchange) async {
        ipFailed = false
        do {
            let resolved = target == .gate ? try await GateClient().publicIP() : try await SafeTradeClient().publicIP()
            if exchange == target { ip = resolved }
        } catch {
            if exchange == target, ip == nil { ipFailed = true }
        }
    }
}

struct GateKeyGuide: View {
    var onFillKeys: ((TradeExchange) -> Void)?
    var body: some View {
        TradeKeyGuide(initialExchange: .gate, onFillKeys: onFillKeys)
    }
}
