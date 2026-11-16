import SwiftUI

/// 设置 → 交易: Gate API v4 key management.
struct GateSettingsSection: View {
    @State private var masked = Self.readMasked()
    @State private var apiKeyInput = ""
    @State private var apiSecretInput = ""
    @State private var verifying = false
    @State private var keyMsg: KeyMessage?
    @State private var showingGuide = false
    @FocusState private var focusedField: Field?
    private enum Field { case apiKey, apiSecret }

    private struct KeyMessage { let text: String; let warning: Bool; let id = UUID() }

    private static func readMasked() -> String? {
        GateSecrets.hasCredentials ? GateSecrets.maskedKey : nil
    }

    var body: some View {
        Section {
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
            Button { showingGuide = true } label: {
                Label(Loc("如何获取 API 密钥"), systemImage: "questionmark.circle")
            }
        } header: {
            HStack(spacing: 4) {
                Text(Loc("Gate API 密钥"))
                PearlInfoTip(Loc("API 密钥存于 iCloud 钥匙串（端到端加密，仅你可见），在各设备间同步；助记词不同步，仅存于本机钥匙串。"),
                             title: Loc("Gate API 密钥"))
            }
        }
        .sheet(isPresented: $showingGuide) { GateKeyGuide() }
        .onAppear { masked = Self.readMasked() }
        .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidUpdate)) { _ in
            GateSecrets.invalidateCache()
            masked = Self.readMasked()
        }
    }

    @ViewBuilder private var inputs: some View {
        SecureField("API Key", text: $apiKeyInput)
            .focused($focusedField, equals: .apiKey)
            #if os(iOS)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            #endif
            .accessibilityLabel("Gate API Key")
        SecureField("API Secret", text: $apiSecretInput)
            .focused($focusedField, equals: .apiSecret)
            #if os(iOS)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            #endif
            .accessibilityLabel("Gate API Secret")
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
        GateSecrets.clear()
        masked = Self.readMasked()
        flash(Loc("已清除"))
    }

    private func saveAndVerify(apiKey: String, apiSecret: String) async {
        verifying = true
        withAnimation { keyMsg = nil }
        let check = await GateClient().verifyCredentials(apiKey: apiKey, apiSecret: apiSecret)
        let saved = GateSecrets.save(apiKey: apiKey, apiSecret: apiSecret)
        apiKeyInput = ""
        apiSecretInput = ""
        masked = Self.readMasked()
        verifying = false
        guard saved else {
            flash(Loc("无法写入钥匙串（Keychain）"), warning: true)
            return
        }
        TradeExchange.save(.gate)
        switch check {
        case .ok:
            flash(Loc("已保存并通过验证（会经 iCloud 同步到其他设备）"))
        case .rejected(.untrustedIP):
            flash(Loc("已保存，但当前网络的 IP 不在这把密钥的白名单里。到交易页查看当前 IP（可能是 IPv6 地址），把它加进 Gate 白名单。"),
                  warning: true, sticky: true)
        case .rejected(.clock):
            flash(Loc("已保存，但验证未通过：本机时间和 Gate 相差太多，请打开「自动设置时间」。"), warning: true, sticky: true)
        case .rejected(.firewall):
            flash(Loc("已保存，但请求被 Gate 的防火墙拦截（网络或代理），换个网络后在交易页确认。"), warning: true, sticky: true)
        case .rejected:
            flash(Loc("已保存，但验证未通过：API Key/Secret 可能不正确，或未开启现货/只读权限。请在 Gate 后台核对密钥权限与 IP 白名单。"), warning: true, sticky: true)
        case .serverError(let code, _):
            flash(Loc("已保存，但交易所返回错误（HTTP %@）。请稍后在交易页重试。", String(code)), warning: true, sticky: true)
        case .network:
            flash(Loc("已保存，但暂时无法连接 Gate（网络问题）。请检查网络后在交易页确认。"), warning: true, sticky: true)
        }
    }

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
