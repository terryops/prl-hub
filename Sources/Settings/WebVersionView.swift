import SwiftUI

/// Pearl Hub in a browser (pearlhub.net): monitors, market, pools and the income calculator,
/// for a computer without the app. Only what it shows is described here — nothing about
/// buying there (App Store 3.1.1).
enum WebVersion {
    static let url = URL(string: "https://pearlhub.net/")!
    /// 我的监控's card pointing at it was opened or closed.
    static let hintDismissedKey = "pool.webHintDismissed"
}

/// 设置 → 网页版, and the sheet behind 我的监控's card: the address to type on a computer,
/// with copy / share (AirDrop to a Mac) / open.
struct WebVersionView: View {
    @ObservedObject private var link = WebLinkStore.shared
    @State private var copied = false

    var body: some View {
        SettingsPage(Loc("网页版")) {
            Section {
                PearlInfoRow(Loc("在任何电脑的浏览器里看矿机监控、行情、矿池对比和收益计算，不用安装。"),
                             title: Loc("电脑上也能看"), systemImage: "desktopcomputer")
                // Only an account that syncs (Pro) finds its monitors there already.
                if link.isLinked, link.accountPro == true, let email = link.email {
                    PearlInfoRow(Loc("用 %@ 登录网页版，账号里的监控和提醒会自动同步过去。", email),
                                 title: Loc("用同一邮箱登录"), systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .pearlListRowSurface()
            Section {
                HStack(spacing: Pearl.Space.sm) {
                    Text(verbatim: "pearlhub.net")
                        .font(.title3.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    Spacer(minLength: Pearl.Space.sm)
                    Button(copied ? Loc("已复制") : Loc("复制")) {
                        copyToPasteboard(WebVersion.url.absoluteString)
                        copied = true
                    }
                    .buttonStyle(.borderless).font(.callout.weight(.semibold)).tint(Pearl.accent)
                }
                .padding(.vertical, Pearl.Space.xxs)
                Link(destination: WebVersion.url) {
                    row(Loc("在浏览器打开"), systemImage: "safari", trailing: "arrow.up.right")
                }
                .buttonStyle(.plain)
                ShareLink(item: WebVersion.url) {
                    row(Loc("分享"), systemImage: "square.and.arrow.up", trailing: nil)
                }
                .buttonStyle(.plain)
            }
            .pearlListRowSurface()
        }
    }

    private func row(_ title: String, systemImage: String, trailing: String?) -> some View {
        HStack(spacing: Pearl.Space.sm) {
            Label(title, systemImage: systemImage).foregroundStyle(Pearl.accent)
            Spacer(minLength: 0)
            if let trailing {
                Image(systemName: trailing).font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The card at the top of 我的监控 that says the web version exists. Shown on iPhone / iPad
/// (a Mac is the computer already), never beside the 掉线提醒 card; opening it or closing it
/// retires it — 设置 → 网页版 stays.
struct WebVersionHintCard: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Pearl.Space.sm) {
            Button(action: onOpen) {
                HStack(spacing: Pearl.Space.md) {
                    PearlIconBadge(systemImage: "desktopcomputer", size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Loc("电脑上也能看")).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Text(Loc("打开 pearlhub.net，监控、币价和提醒都在。"))
                            .pearlExplanation()
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("web-hint")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Loc("关闭"))
        }
        .pearlCard(padding: Pearl.Space.md)
    }
}
