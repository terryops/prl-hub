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
/// sees (from Cloudflare's trace, on the same session as the API calls) with a copy
/// button, and what to do — add it to the key's list, again after a network change.
/// The phone reaches SafeTrade over IPv4 or IPv6 as the network allows, so an IPv6
/// address there usually means the list only holds the IPv4 one.
struct UntrustedIPCard: View {
    let issue: SafeTradeIPIssue
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
                 ? Loc("这是 IPv6 地址：白名单里如果只有 IPv4，可能需要把这个 IPv6 地址也加进 Trusted IPs。")
                 : Loc("把上面这个 IP 加进这把密钥的 Trusted IPs 即可。"))
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text(Loc("同一个网络下，手机可能时而用 IPv4、时而用 IPv6 连接，IPv6 地址也会定期变化；换网络后 IP 也会变。开着代理或 VPN 时，这里显示的是代理的出口 IP。"))
                .font(.caption).foregroundStyle(.secondary)
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
