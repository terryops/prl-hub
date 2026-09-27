import SwiftUI

/// 设置 → 交易（SafeTrade）: the API key.
///
/// Its own view so its state (typed keys, status line) re-renders only this section,
/// and the Keychain status is read into `masked` on appear / save / clear / sync —
/// never in `body`.
struct SafeTradeSettingsSection: View {
    @State private var masked = Self.readMasked()   // masked key, nil when not set
    @State private var apiKeyInput = ""
    @State private var apiSecretInput = ""
    @State private var verifying = false            // a save+verify request is in flight
    @State private var keyMsg: KeyMessage?
    @FocusState private var focusedField: Field?
    private enum Field { case apiKey, apiSecret }

    /// A transient status line under the fields ("已保存" / why the check failed).
    private struct KeyMessage { let text: String; let warning: Bool; let id = UUID() }

    private static func readMasked() -> String? {
        SafeTradeSecrets.hasCredentials ? SafeTradeSecrets.maskedKey : nil
    }

    var body: some View {
        Section(Loc("交易（SafeTrade）")) {
            LabeledContent(Loc("交易所"), value: "safetrade.com")
            // Two mutually-exclusive modes: once keys are saved, show only their masked
            // status + 清除密钥; clearing flips back to the input fields.
            if let masked {
                LabeledContent(Loc("当前 Key"), value: masked)
                LabeledContent(Loc("当前 Secret"), value: Loc("已设置 ✓"))
                Button(Loc("清除密钥"), role: .destructive) { clear() }
            } else {
                inputs
            }
            if let m = keyMsg {
                Label(m.text, systemImage: m.warning ? "exclamationmark.triangle" : "checkmark.seal")
                    .font(.footnote).foregroundStyle(m.warning ? .orange : .green)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(m.text)
            }
            Label(Loc("API 密钥存于 iCloud 钥匙串（端到端加密，仅你可见），在各设备间同步；助记词不同步，仅存于本机钥匙串。"), systemImage: "key.icloud")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { masked = Self.readMasked() }
        // Re-read when iCloud pulls settings in (keys themselves sync via the iCloud
        // Keychain, so also drop the memoized reads).
        .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidUpdate)) { _ in
            SafeTradeSecrets.invalidateCache()
            masked = Self.readMasked()
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

    @ViewBuilder private var inputs: some View {
        SecureField("API Key", text: $apiKeyInput)
            .focused($focusedField, equals: .apiKey)
            #if os(iOS)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            #endif
            .accessibilityLabel("SafeTrade API Key")
        SecureField("API Secret", text: $apiSecretInput)
            .focused($focusedField, equals: .apiSecret)
            #if os(iOS)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            #endif
            .accessibilityLabel("SafeTrade API Secret")
        Button {
            let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = apiSecretInput.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await saveAndVerify(apiKey: key, apiSecret: secret) }
        } label: {
            HStack {
                Text(verifying ? Loc("验证中…") : Loc("保存密钥"))
                if verifying { Spacer(); ProgressView() }
            }
        }
        .disabled(apiKeyInput.isEmpty || apiSecretInput.isEmpty || verifying)
    }

    private func clear() {
        SafeTradeSecrets.clear()
        masked = Self.readMasked()
        flash(Loc("已清除"))
    }

    /// Save the entered keys, then immediately verify them against SafeTrade so we
    /// can tell the user *why* if a signed request fails — wrong key/secret, IP not
    /// whitelisted, wrong clock, or a network problem — instead of silently storing a
    /// key that won't work. We still save on a failed check (the keys may be correct
    /// but the IP simply isn't whitelisted yet, which the user fixes exchange-side),
    /// and surface a warning rather than a hard failure.
    private func saveAndVerify(apiKey: String, apiSecret: String) async {
        verifying = true
        withAnimation { keyMsg = nil }
        // Check what the user typed *before* committing it (signs with these keys).
        let check = await SafeTradeClient().verifyCredentials(apiKey: apiKey, apiSecret: apiSecret)
        // Stored in the iCloud Keychain — syncs to your other devices end-to-end
        // encrypted, so no manual (plaintext) KVS push.
        let saved = SafeTradeSecrets.save(apiKey: apiKey, apiSecret: apiSecret)
        apiKeyInput = ""
        apiSecretInput = ""
        masked = Self.readMasked()
        verifying = false
        guard saved else {
            flash(Loc("无法写入钥匙串（Keychain）"), warning: true)
            return
        }
        switch check {
        case .ok:
            flash(Loc("已保存并通过验证（会经 iCloud 同步到其他设备）"))
        case .rejected(.untrustedIP):
            flash(Loc("已保存，但当前网络的 IP 不在这把密钥的 Trusted IPs 里。到交易页查看 SafeTrade 看到的 IPv4 地址，把它加进白名单。"),
                  warning: true, sticky: true)
        case .rejected(.clock):
            flash(Loc("已保存，但验证未通过：本机时间和 SafeTrade 相差太多，请打开「自动设置时间」。"), warning: true, sticky: true)
        case .rejected(.firewall):
            flash(Loc("已保存，但请求被 SafeTrade 的防火墙拦截（网络或代理），换个网络后在交易页确认。"), warning: true, sticky: true)
        case .rejected:
            flash(Loc("已保存，但验证未通过：API Key/Secret 可能不正确，或当前 IP 未加入白名单。请在 SafeTrade 后台核对密钥，并为此网络的 IP 开通访问权限。"), warning: true, sticky: true)
        case .serverError(let code, _):
            flash(Loc("已保存，但交易所返回错误（HTTP %@）。请稍后在交易页重试。", String(code)), warning: true, sticky: true)
        case .network:
            flash(Loc("已保存，但暂时无法连接 SafeTrade（网络问题）。请检查网络后在交易页确认。"), warning: true, sticky: true)
        }
    }

    /// Show a transient status line under the fields. Warnings are orange and linger
    /// longer (they're actionable); successes auto-dismiss quickly.
    private func flash(_ text: String, warning: Bool = false, sticky: Bool = false) {
        let m = KeyMessage(text: text, warning: warning)
        withAnimation { keyMsg = m }
        let seconds = sticky ? 10 : 3
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if keyMsg?.id == m.id { withAnimation { keyMsg = nil } }
        }
    }
}
