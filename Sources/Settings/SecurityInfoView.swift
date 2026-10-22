import SwiftUI

/// 设置 → 安全性说明: what the app sends and to whom, what is kept where, and what never
/// leaves the device. Keep in step with site/privacy.html, PrivacyInfo.xcprivacy and the
/// account wire format (AccountConfig.clean, WebSharedMerge.walletRows).
struct SecurityInfoView: View {
    var body: some View {
        SettingsPage(Loc("安全性说明")) {
            Section {
                PearlInfoRow(Loc("助记词和私钥只在你的设备上生成和保存，交易也在本机签名。我们拿不到你的私钥，无法动用或冻结你的资产。"),
                             title: Loc("自托管钱包"), systemImage: "lock.shield.fill")
            }
            .pearlListRowSurface()

            Section(Loc("我们拿不到的数据")) {
                PearlInfoRow(Loc("加密存于本机钥匙串，只属于这台设备：不同步到 iCloud，也不进备份。查看助记词和转账都要 Face ID / Touch ID 验证。"),
                             title: Loc("助记词与私钥"), systemImage: "key.fill")
                if AppFeatures.tradeEnabled {
                    PearlInfoRow(Loc("只存在你的钥匙串里（开着 iCloud 钥匙串时由 Apple 端到端加密同步）；交易请求由 App 签名后直接发往 safetrade.com。"),
                                 title: Loc("SafeTrade API 密钥"), systemImage: "key.horizontal.fill")
                }
                PearlInfoRow(Loc("App 直接向区块浏览器查询，不经过我们的服务器。"),
                             title: Loc("余额与交易记录"), systemImage: "list.bullet.rectangle")
                PearlInfoRow(Loc("内购全程由 Apple 处理，我们拿不到你的付款方式和 Apple 账号。"),
                             title: Loc("付款信息"), systemImage: "creditcard")
                PearlInfoRow(Loc("App 里没有广告、统计或崩溃收集 SDK，也不做跨应用追踪。"),
                             title: Loc("统计与追踪"), systemImage: "eye.slash")
            }
            .pearlListRowSurface()

            Section(Loc("发给我们服务器（pearlhub.net）的数据")) {
                PearlInfoRow(Loc("币价、矿池汇总和矿池费率。这些请求不带地址，也不带任何身份信息。"),
                             title: Loc("公开数据"), systemImage: "chart.line.uptrend.xyaxis")
                PearlInfoRow(Loc("开启后才发送：推送令牌、提醒条件、界面语言，以及推送时段和时区。删掉全部提醒、结束盯盘后，服务器上的这些数据随之删除。"),
                             title: Loc("价格提醒与锁屏盯盘"), systemImage: "bell.badge")
                PearlInfoRow(Loc("开启后才发送：矿池、收益地址（F2Pool 为只读页链接和账户名）、监控名称和提醒延迟。服务器会保存矿池最近报告的矿机名和在线状态，用来判断掉线；关掉提醒或删除监控后即从服务器移除。"),
                             title: Loc("掉线提醒"), systemImage: "wifi.exclamationmark")
                PearlInfoRow(Loc("购买后 Apple 会通知我们的服务器，服务器保存交易号、价格和国家或地区，用来处理退款。开启提醒或登录邮箱账号时，App 还会发送 Apple 签名的购买记录，用来确认高级版。"),
                             title: Loc("高级版购买记录"), systemImage: "sparkles")
                PearlInfoRow(Loc("登录后才有：服务器保存邮箱、设备名称和登录时间，并同步矿池监控、提醒、地址簿、每个钱包的名称和第一个收款地址、显卡与电费设置、语言和外观。同步数据加密存储，但不是端到端加密，服务器能读取。"),
                             title: Loc("邮箱账号"), systemImage: "person.crop.circle")
            }
            .pearlListRowSurface()

            Section(Loc("App 直接连接的第三方服务")) {
                PearlInfoRow(Loc("blockbook.pearlresearch.ai。查余额和记录时发送钱包的扩展公钥（xpub，可据此推出这个钱包的全部地址）；转账时广播本机签好的交易。"),
                             title: Loc("Pearl 区块浏览器"), systemImage: "cube")
                PearlInfoRow(Loc("添加矿池监控后，App 把收益地址（F2Pool 为只读页链接）发给对应矿池。"),
                             title: Loc("矿池公开接口"), systemImage: "server.rack")
                PearlInfoRow(Loc("SafeTrade、CoinGecko、WhatToMine、MiningPoolStats、open.er-api.com 等公开数据源，请求不带地址。"),
                             title: Loc("行情与汇率"), systemImage: "dollarsign.circle")
            }
            .pearlListRowSurface()

            Section(Loc("存在你设备上的数据")) {
                PearlInfoRow(Loc("钱包数据库、地址簿、设置和缓存都存在本机，钱包数据库不进备份；登录凭据存于本机钥匙串。"),
                             title: Loc("本机"), systemImage: "internaldrive")
                PearlInfoRow(Loc("矿池监控、提醒、地址簿、钱包名称、显卡与电费、语言和外观等设置，通过你自己的 iCloud 在你的设备间同步，我们无法访问。助记词从不同步。"),
                             title: Loc("iCloud 同步（高级版）"), systemImage: "icloud")
            }
            .pearlListRowSurface()

            Section(Loc("开源代码")) {
                PearlInfoRow(Loc("App 和网页版前端完全由下面的公开仓库编译发布，服务器后台的代码也已公开。任何人都可以审查代码、自己编译。"),
                             title: Loc("代码全部公开"), systemImage: "chevron.left.forwardslash.chevron.right")
                RepoLinkRow(title: Loc("App（iPhone / iPad / Mac）"), url: AppLinks.github)
                RepoLinkRow(title: Loc("网页版前端"), url: AppLinks.githubWeb)
                RepoLinkRow(title: Loc("服务器后台"), url: AppLinks.githubServer)
            }
            .pearlListRowSurface()
        }
        .accessibilityIdentifier("security-info")
    }
}

/// A repository with its address written out, so it can be read (and checked) without
/// opening it; tapping opens it, a long press copies it.
private struct RepoLinkRow: View {
    let title: String
    let url: URL

    private var address: String { (url.host ?? "") + url.path }

    var body: some View {
        Link(destination: url) {
            HStack(spacing: Pearl.Space.sm) {
                SettingsGlyph(systemImage: "arrow.up.right.square")
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(address)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(Pearl.accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
        .tint(.primary)
        .contextMenu {
            Button { copyToPasteboard(url.absoluteString) } label: {
                Label(Loc("复制"), systemImage: "doc.on.doc")
            }
        }
    }
}
