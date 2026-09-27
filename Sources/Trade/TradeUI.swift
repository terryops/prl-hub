import SwiftUI

// Pieces shared by the Trade tab and the withdraw sheet.

extension View {
    /// Dim the screen under a centred "处理中…" card while `shown`.
    func processingOverlay(_ shown: Bool) -> some View {
        overlay {
            if shown {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView(Loc("处理中…")).controlSize(.large)
                        .pearlCard(padding: Pearl.Space.lg, radius: Pearl.Radius.sm, elevated: true)
                }
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: shown)
    }
}

/// A green success line and any red error lines, full width.
struct TradeStatusLines: View {
    let notice: String?
    let errors: [String?]

    var body: some View {
        if let notice {
            Label(notice, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach(Array(errors.compactMap { $0 }.enumerated()), id: \.offset) { _, e in
            Label(e, systemImage: "xmark.octagon").foregroundStyle(.red)
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Your IP isn't on this key's Trusted IPs": shows the address SafeTrade actually
/// sees (from Cloudflare's trace, so IPv6 / proxy exits show up as they are) with a
/// copy button, why it keeps changing, and the way out — a trading key without an IP
/// list, with the IP-bound key kept for withdrawals only.
struct UntrustedIPCard: View {
    let issue: SafeTradeIPIssue
    /// The refusal came from a withdrawal (the withdraw key), not from trading.
    var forWithdraw = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            Label(Loc("当前网络的 IP 不在密钥的白名单里"), systemImage: "network.badge.shield.half.filled")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text(Loc("这把 API 密钥设置了 Trusted IPs，SafeTrade 只接受名单里的 IP。SafeTrade 看到你现在的 IP 是："))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Pearl.Space.sm) {
                if let ip = issue.ip {
                    Text(verbatim: ip).font(.callout.monospaced()).textSelection(.enabled)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    Button(copied ? Loc("已复制") : Loc("复制")) {
                        copyToPasteboard(ip)
                        copied = true
                    }
                    .buttonStyle(.borderless).font(.caption.weight(.semibold)).tint(Pearl.accent)
                } else {
                    ProgressView().controlSize(.small)
                    Text(Loc("正在查询…")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(issue.isIPv6
                 ? Loc("这是 IPv6 地址：手机的 IPv6 地址会定期更换，同一个 Wi-Fi 下也会在 IPv4 和 IPv6 之间切换，所以白名单很难一直有效。")
                 : Loc("切换 Wi-Fi 和蜂窝网络、开关代理或 VPN 都会改变这个 IP。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(forWithdraw
                 ? Loc("提现用的密钥绑定了 Trusted IPs：把上面的 IP 加进这把密钥的白名单，或换到名单里的网络再提现。")
                 : Loc("建议在 SafeTrade 另建一把只开交易、不绑 IP 的密钥，填到「设置 → 交易」；开了提现、绑了 IP 的那把填到「提现专用密钥」，只在提现时使用。"))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
    }
}

/// A POST whose result is unknown: the submit button stays locked until the history
/// settles it. 重新核对 looks again; the override is for after checking on the website.
struct UnverifiedBanner: View {
    let text: String
    let checking: Bool
    let recheck: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            Label(text, systemImage: "questionmark.circle")
                .font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Pearl.Space.lg) {
                if checking {
                    ProgressView().controlSize(.small)
                    Text(Loc("正在核对…")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(Loc("重新核对"), action: recheck)
                        .buttonStyle(.borderless).font(.caption.weight(.semibold)).tint(Pearl.accent)
                    Button(Loc("我已在网站核对，解除锁定"), action: dismiss)
                        .buttonStyle(.borderless).font(.caption).tint(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
    }
}
