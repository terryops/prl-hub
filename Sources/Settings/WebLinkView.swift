import SwiftUI

/// Account login uses the shared website and PKCE; wallet unlock remains local.
struct WebLinkView: View {
    @ObservedObject private var link = WebLinkStore.shared
    @State private var confirmLogout = false

    var body: some View {
        SettingsPage(Loc("邮箱账号")) {
            if link.isLinked {
                identity
                syncing
                membership
                management
            } else {
                if let offer = link.offer { signedInElsewhere(offer) }
                Section { syncSummary }
                    .pearlListRowSurface()
                signIn
            }
        }
        .alert(Loc("退出登录？"), isPresented: $confirmLogout) {
            Button(Loc("退出登录"), role: .destructive) { Task { await link.logout() } }
            Button(Loc("取消"), role: .cancel) {}
        } message: { Text(Loc("停止此设备的账号同步和通知，恢复未登录时的本地配置。钱包和 App Store 购买会保留。")) }
    }

    // MARK: Signed out

    /// Another of the user's devices left a ticket in iCloud Keychain. A device that hasn't
    /// been signed out uses it by itself; this is for one that has, or was offline then.
    private func signedInElsewhere(_ offer: DeviceTicket) -> some View {
        Section {
            // Which account, and the one button; no code and nothing lost is in the ⓘ.
            HStack(spacing: Pearl.Space.sm) {
                SettingsGlyph(systemImage: "laptopcomputer.and.iphone")
                VStack(alignment: .leading, spacing: 2) {
                    Text(Loc("其他设备已登录")).font(.headline)
                    if let email = offer.email {
                        Text(verbatim: email).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: Pearl.Space.sm)
                PearlInfoTip(offer.email.map { Loc("%@ 已在你的其他设备上登录。这台设备可以直接登录，不用收验证码，现有配置会保留。", $0) }
                                ?? Loc("你的账号已在其他设备上登录。这台设备可以直接登录，不用收验证码，现有配置会保留。"),
                             title: Loc("其他设备已登录"))
            }
            Button(Loc("直接登录")) { Task { await link.join(automatic: false) } }
                .buttonStyle(.pearl)
                .frame(maxWidth: 420)
                .padding(.vertical, Pearl.Space.xxs)
                .accessibilityIdentifier("account-join")
        }
        .disabled(link.signingIn)
        .pearlListRowSurface()
    }

    private var signIn: some View {
        Section {
            // The usual way in is the one button; starting from the account's settings
            // alone is the alternative, so it is a quieter row beneath it. What each does to
            // this device's settings: the hint on the first, the ⓘ beside the second.
            Button(Loc("用邮箱登录")) { Task { await link.login(importLocal: true) } }
                .buttonStyle(.pearl)
                .frame(maxWidth: 420)
                .accessibilityHint(Loc("这台设备上现有的配置会保留，并加入你的账号。"))
                .padding(.vertical, Pearl.Space.xxs)
            HStack(spacing: 4) {
                Button { Task { await link.login(importLocal: false) } } label: {
                    Text(Loc("登录后只用账号里的配置")).font(.subheadline).foregroundStyle(Pearl.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Loc("这台设备现有的配置会先收起来，退出登录后恢复。"))
                PearlInfoTip(Loc("这台设备现有的配置会先收起来，退出登录后恢复。"),
                             title: Loc("登录后只用账号里的配置"))
                Spacer(minLength: 0)
            }
            if link.signingIn {
                HStack(spacing: Pearl.Space.xs) {
                    ProgressView().controlSize(.small)
                    Text(Loc("登录中")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if case .failed(let why) = link.state {
                HStack(alignment: .firstTextBaseline, spacing: Pearl.Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(why).fixedSize(horizontal: false, vertical: true)
                }
                .font(.footnote).foregroundStyle(.orange)
            }
        }
        .disabled(link.signingIn)
        .pearlListRowSurface()
    }

    // MARK: Signed in

    private var identity: some View {
        Section {
            HStack(spacing: Pearl.Space.sm) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 36)).foregroundStyle(Pearl.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: link.email ?? Loc("邮箱账号")).font(.headline)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    status
                }
            }
            .padding(.vertical, 2)
        }
        .pearlListRowSurface()
    }

    @ViewBuilder private var status: some View {
        if link.signingIn {
            caption(Loc("登录中"))
        } else {
            switch link.state {
            case .syncing: caption(Loc("同步中"))
            case .synced(let at): caption(Loc("已同步") + " · " + RelTime(at))
            case .failed(let why):
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(why).fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption).foregroundStyle(.orange)
            case .idle: caption(Loc("已连接"))
            }
        }
    }

    private var syncing: some View {
        Section {
            HStack(spacing: Pearl.Space.xs) {
                Button { Task { await link.sync() } } label: {
                    action(Loc("立即同步"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(link.state == .syncing || link.accountPro != true)
                // Why the button is off: sync is a Pro feature.
                if link.accountPro != true { PearlBadge(text: Loc("高级版"), tint: Pearl.accent) }
                syncTip(proOnly: link.accountPro != true)
            }
        }
        .pearlListRowSurface()
    }

    private var membership: some View {
        Section {
            if let pro = link.accountPro {
                HStack(spacing: Pearl.Space.sm) {
                    SettingsGlyph(systemImage: "sparkles")
                    Text(Loc("账号高级版"))
                    Spacer(minLength: Pearl.Space.sm)
                    Text(pro ? Loc("已开通") : Loc("未开通")).foregroundStyle(.secondary)
                }
            }
            Button { Task { await link.login(importLocal: false) } } label: {
                action(Loc("重新验证并关联购买"), systemImage: "checkmark.seal")
            }
            .buttonStyle(.plain)
            .disabled(link.signingIn)
        } header: {
            HStack(spacing: 4) {
                Text(Loc("高级版"))
                PearlInfoTip(Loc("在其他设备或网页版登录同一邮箱，App Store 购买的高级版也能使用。"),
                             title: Loc("同一邮箱共享购买"))
            }
        }
        .pearlListRowSurface()
    }

    private var management: some View {
        Group {
            Section {
                website(Loc("管理账号与设备"), systemImage: "laptopcomputer.and.iphone", query: "manage")
                website(Loc("删除账号"), systemImage: "trash", query: "delete", tint: .red)
            }
            .pearlListRowSurface()
            Section {
                // Not red: a page carries one red row, and here it is deleting the account.
                Button { confirmLogout = true } label: {
                    action(Loc("退出登录"), systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.plain)
            }
            .pearlListRowSurface()
        }
    }

    /// Account management lives on the website; the arrow says the row leaves the app.
    private func website(_ title: String, systemImage: String, query: String,
                         tint: Color = Pearl.accent) -> some View {
        Link(destination: URL(string: "https://pearlhub.net/?account=\(query)&client=apple")!) {
            action(title, systemImage: systemImage, tint: tint, trailing: "arrow.up.right")
        }
        .buttonStyle(.plain)
    }

    // MARK: Shared rows

    /// Before signing in: what the account is for, and that it takes Pro.
    private var syncSummary: some View {
        HStack(spacing: Pearl.Space.sm) {
            SettingsGlyph(systemImage: "arrow.triangle.2.circlepath")
            Text(Loc("跨设备数据同步"))
            Spacer(minLength: Pearl.Space.sm)
            PearlBadge(text: Loc("高级版"), tint: Pearl.accent)
            syncTip(proOnly: true)
        }
    }

    /// What an account carries between devices, what never leaves this one, and — without
    /// Pro — that nothing syncs yet.
    private func syncTip(proOnly: Bool) -> some View {
        var text = Loc("同步矿机、挖矿配置、监控、公开地址、通讯录、提醒和偏好设置。")
            + "\n" + Loc("助记词、私钥和钱包密码不会上传。")
        // The 高级版 badge beside it says sync takes Pro; this says what that means meanwhile.
        if proOnly { text += "\n\n" + Loc("免费账号的数据仅保存在本机。") }
        return PearlInfoTip(text, title: Loc("跨设备数据同步"))
    }

    /// A row that does something: the glyph column of the settings list, then its title.
    private func action(_ title: String, systemImage: String, tint: Color = Pearl.accent,
                        trailing: String? = nil) -> some View {
        HStack(spacing: Pearl.Space.sm) {
            SettingsGlyph(systemImage: systemImage, tint: tint)
            Text(title).foregroundStyle(tint)
            Spacer(minLength: Pearl.Space.sm)
            if let trailing {
                Image(systemName: trailing).font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
