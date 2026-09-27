import SwiftUI

/// 设置 → 交易（SafeTrade）: the trading key and the optional withdraw-only key.
///
/// Its own view so its state (typed keys, status lines) re-renders only this section,
/// and the Keychain status is read into `status` on appear / save / clear / sync —
/// never in `body`.
struct SafeTradeSettingsSection: View {
    @State private var status = KeyStatus.read()
    @State private var tradingInput = KeyInput()
    @State private var withdrawInput = KeyInput()
    @State private var verifying: SafeTradeSecrets.Role?      // a save+verify request is in flight
    @State private var keyMsg: KeyMessage?
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case key(SafeTradeSecrets.Role), secret(SafeTradeSecrets.Role) }

    private struct KeyInput { var key = ""; var secret = "" }
    /// A transient status line under one key's fields ("已保存" / why the check failed).
    private struct KeyMessage { let role: SafeTradeSecrets.Role; let text: String; let warning: Bool; let id = UUID() }

    /// What's stored, read once per change rather than on every render.
    private struct KeyStatus {
        var trading: String?      // masked key, nil when not set
        var withdraw: String?

        static func read() -> KeyStatus {
            KeyStatus(trading: SafeTradeSecrets.hasCredentials ? SafeTradeSecrets.maskedKey : nil,
                      withdraw: SafeTradeSecrets.hasWithdrawCredentials ? SafeTradeSecrets.maskedWithdrawKey : nil)
        }
    }

    var body: some View {
        Section(Loc("交易（SafeTrade）")) {
            LabeledContent(Loc("交易所"), value: "safetrade.com")
            // Two mutually-exclusive modes per key: once saved, show only its masked
            // status + 清除; clearing flips back to the input fields.
            if let masked = status.trading {
                LabeledContent(Loc("当前 Key"), value: masked)
                LabeledContent(Loc("当前 Secret"), value: Loc("已设置 ✓"))
                Button(Loc("清除密钥"), role: .destructive) { clear(.trading) }
            } else {
                inputs(for: .trading, $tradingInput)
            }
            message(for: .trading)
            Label(Loc("API 密钥存于 iCloud 钥匙串（端到端加密，仅你可见），在各设备间同步；助记词不同步，仅存于本机钥匙串。"), systemImage: "key.icloud")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Section {
            if let masked = status.withdraw {
                LabeledContent(Loc("当前 Key"), value: masked)
                Button(Loc("清除提现密钥"), role: .destructive) { clear(.withdraw) }
            } else {
                inputs(for: .withdraw, $withdrawInput)
            }
            message(for: .withdraw)
        } header: {
            Text(Loc("提现专用密钥（可选）"))
        } footer: {
            Text(Loc("开了 Enable Withdraw 的密钥必须绑定 Trusted IPs，之后它的所有请求都只认名单里的 IP，手机一换网络交易页就会报错。把这把密钥单独填在这里：交易只用上面那把（不开提现、不绑 IP），这把只在提现时使用。"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { status = .read() }
        // Re-read when iCloud pulls settings in (keys themselves sync via the iCloud
        // Keychain, so also drop the memoized reads).
        .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidUpdate)) { _ in
            SafeTradeSecrets.invalidateCache()
            status = .read()
        }
        #if os(iOS)
        .toolbar {
            // 文本/密钥输入键盘上方的「完成」按钮，点一下即可收起键盘。
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(Loc("完成")) { focusedField = nil }.fontWeight(.semibold)
            }
        }
        #endif
    }

    @ViewBuilder private func inputs(for role: SafeTradeSecrets.Role, _ input: Binding<KeyInput>) -> some View {
        SecureField("API Key", text: input.key)
            .focused($focusedField, equals: .key(role))
            #if os(iOS)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            #endif
            .accessibilityLabel(role == .trading ? "SafeTrade API Key" : "SafeTrade withdraw API Key")
        SecureField("API Secret", text: input.secret)
            .focused($focusedField, equals: .secret(role))
            #if os(iOS)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            #endif
            .accessibilityLabel(role == .trading ? "SafeTrade API Secret" : "SafeTrade withdraw API Secret")
        Button {
            let key = input.wrappedValue.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = input.wrappedValue.secret.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await saveAndVerify(role, apiKey: key, apiSecret: secret) }
        } label: {
            HStack {
                Text(verifying == role ? Loc("验证中…") : (role == .trading ? Loc("保存密钥") : Loc("保存提现密钥")))
                if verifying == role { Spacer(); ProgressView() }
            }
        }
        .disabled(input.wrappedValue.key.isEmpty || input.wrappedValue.secret.isEmpty || verifying != nil)
    }

    @ViewBuilder private func message(for role: SafeTradeSecrets.Role) -> some View {
        if let m = keyMsg, m.role == role {
            Label(m.text, systemImage: m.warning ? "exclamationmark.triangle" : "checkmark.seal")
                .font(.footnote).foregroundStyle(m.warning ? .orange : .green)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(m.text)
        }
    }

    private func clear(_ role: SafeTradeSecrets.Role) {
        SafeTradeSecrets.clear(role: role)
        status = .read()
        flash(role, Loc("已清除"))
    }

    /// Save the entered keys, then immediately verify them against SafeTrade so we
    /// can tell the user *why* if a signed request fails — wrong key/secret, IP not
    /// whitelisted, wrong clock, or a network problem — instead of silently storing a
    /// key that won't work. We still save on a failed check (the keys may be correct
    /// but the IP simply isn't whitelisted yet, which the user fixes exchange-side),
    /// and surface a warning rather than a hard failure.
    private func saveAndVerify(_ role: SafeTradeSecrets.Role, apiKey: String, apiSecret: String) async {
        verifying = role
        withAnimation { keyMsg = nil }
        // Check what the user typed *before* committing it (signs with these keys).
        let check = await SafeTradeClient().verifyCredentials(apiKey: apiKey, apiSecret: apiSecret)
        // Stored in the iCloud Keychain — syncs to your other devices end-to-end
        // encrypted, so no manual (plaintext) KVS push.
        let saved = SafeTradeSecrets.save(apiKey: apiKey, apiSecret: apiSecret, role: role)
        if role == .trading { tradingInput = KeyInput() } else { withdrawInput = KeyInput() }
        status = .read()
        verifying = nil
        guard saved else {
            flash(role, Loc("无法写入钥匙串（Keychain）"), warning: true)
            return
        }
        switch check {
        case .ok:
            flash(role, Loc("已保存并通过验证（会经 iCloud 同步到其他设备）"))
        case .rejected(.untrustedIP):
            flash(role, role == .trading
                  ? Loc("已保存，但当前网络的 IP 不在这把密钥的 Trusted IPs 里。交易密钥建议不绑 IP，否则换网络就会被拒。")
                  : Loc("已保存。当前网络的 IP 不在这把密钥的 Trusted IPs 里，只有在名单里的网络才能提现。"),
                  warning: true, sticky: true)
        case .rejected(.clock):
            flash(role, Loc("已保存，但验证未通过：本机时间和 SafeTrade 相差太多，请打开「自动设置时间」。"), warning: true, sticky: true)
        case .rejected(.firewall):
            flash(role, Loc("已保存，但请求被 SafeTrade 的防火墙拦截（网络或代理），换个网络后在交易页确认。"), warning: true, sticky: true)
        case .rejected:
            flash(role, Loc("已保存，但验证未通过：API Key/Secret 可能不正确，或当前 IP 未加入白名单。请在 SafeTrade 后台核对密钥，并为此网络的 IP 开通访问权限。"), warning: true, sticky: true)
        case .serverError(let code, _):
            flash(role, Loc("已保存，但交易所返回错误（HTTP %@）。请稍后在交易页重试。", String(code)), warning: true, sticky: true)
        case .network:
            flash(role, Loc("已保存，但暂时无法连接 SafeTrade（网络问题）。请检查网络后在交易页确认。"), warning: true, sticky: true)
        }
    }

    /// Show a transient status line under the key's fields. Warnings are orange and
    /// linger longer (they're actionable); successes auto-dismiss quickly.
    private func flash(_ role: SafeTradeSecrets.Role, _ text: String, warning: Bool = false, sticky: Bool = false) {
        let m = KeyMessage(role: role, text: text, warning: warning)
        withAnimation { keyMsg = m }
        let seconds = sticky ? 10 : 3
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if keyMsg?.id == m.id { withAnimation { keyMsg = nil } }
        }
    }
}
