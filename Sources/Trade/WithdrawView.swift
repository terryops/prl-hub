import SwiftUI
import Combine

struct WithdrawView: View {
    @ObservedObject var trade: SafeTradeStore
    @ObservedObject private var wallet = WalletStore.shared
    @ObservedObject private var book = WithdrawAddressBook.shared
    @EnvironmentObject private var contacts: ContactsStore
    @StateObject private var store: WithdrawStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var address = ""
    @State private var amount = ""
    @State private var emailCode = ""
    @State private var otpCode = ""
    @State private var phoneCode = ""
    @State private var confirming = false
    @State private var authenticating = false   // Face ID / passcode prompt up before submitting
    @State private var naming = false          // "保存为常用地址" name prompt
    @State private var presetName = ""
    @State private var managingPresets = false
    /// Chosen SafeTrade address-book entry; only counts while the form still shows
    /// its exact address + chain (see `beneficiary`).
    @State private var beneficiaryID: Int?
    @FocusState private var focused: Bool

    init(trade: SafeTradeStore, currency: String) {
        self.trade = trade
        _store = StateObject(wrappedValue: WithdrawStore(currency: currency, trade: trade))
    }

    private var isPRL: Bool { store.currency == "prl" }
    private var unit: String { store.currency.uppercased() }
    private var available: Decimal {
        Decimal(string: trade.balance(store.currency)?.balance ?? "") ?? 0
    }
    private var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var addressValid: Bool {
        if isPRL { return PRLAddress.isValid(trimmedAddress, network: .mainnet) }
        return store.network?.isValidAddress(trimmedAddress) ?? false
    }
    /// Typed amount, rejected if it has more decimals than the exchange accepts.
    private var amountValue: Decimal? {
        guard let v = PRLAmount.parse(amount) else { return nil }
        var x = v, r = Decimal()
        NSDecimalRound(&r, &x, store.precision, .plain)
        return r == v ? v : nil
    }
    private var fee: Decimal { store.network?.fee(for: amountValue ?? 0) ?? 0 }
    private var received: Decimal { max(0, (amountValue ?? 0) - fee) }

    /// Why the amount can't be sent yet (nil = fine or still empty).
    private var amountProblem: String? {
        guard let a = amountValue, !amount.isEmpty else { return amount.isEmpty ? nil : Loc("数量格式不对") }
        if let n = store.network, a < n.minAmount { return Loc("最少提现 %@ %@", fmt(n.minAmount), unit) }
        if a > available { return Loc("%@ 余额不足", unit) }
        if a <= fee { return Loc("数量需大于手续费") }
        return nil
    }
    private var codeReady: Bool { addressValid && amountProblem == nil && (amountValue ?? 0) > 0 }
    /// What sent codes are bound to (see WithdrawStore.codeContext).
    private var codeSignature: String { "\(trimmedAddress)|\(amount)|\(store.networkKey ?? "")" }
    /// The selected SafeTrade address-book entry, if the form still matches it.
    /// Editing the address or switching chain silently drops back to a plain
    /// address withdrawal (which then needs the e-mail code again).
    private var beneficiary: STBeneficiary? {
        store.beneficiaries.first {
            $0.id == beneficiaryID && $0.isActive && $0.destination == trimmedAddress
                && bookKey($0) == store.networkKey
        }
    }
    private var canSubmit: Bool {
        codeReady && store.network?.canWithdraw == true && (beneficiary != nil || emailCode.count == 6)
            && (otpCode.isEmpty || otpCode.count == 6)
            && (!store.needsPhoneCode || phoneCode.count == 6)
            && !store.submitting && !authenticating
            && store.unverified == nil && !store.verifying   // a previous one's outcome is still unknown
    }

    /// Mainnet receive address of every wallet on this device (index 0).
    private var myWallets: [(name: String, address: String)] {
        guard isPRL else { return [] }
        return wallet.wallets.compactMap { w in w.addresses[WalletNetwork.mainnet.rawValue].map { (w.name, $0) } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Pearl.Space.lg) {
                    formCard
                    codesCard
                    statusMessages
                    historyCard
                }
                .padding(Pearl.Space.screen)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(Loc("提现 %@", unit))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Loc("关闭")) { dismiss() } }
                    .noGlassBackground()
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(Loc("完成")) { focused = false }.fontWeight(.semibold)
                }
                #endif
            }
            .processingOverlay(store.submitting)
            .task {
                if isPRL, address.isEmpty, let a = activeWalletAddress { address = a }
                await store.load()
            }
            .refreshable { await store.load() }
            .onChange(of: store.networkKey) { old, new in
                // An address picked from a saved entry for the old chain doesn't belong
                // on the new one: clear it rather than let it ride along to another
                // network. (Kept if the same address is also saved for the new chain.)
                guard let old, old != new, savedFor(chain: old), !savedFor(chain: new) else { return }
                address = ""
                beneficiaryID = nil
            }
            .onChange(of: codeSignature) { _, now in
                guard let sentFor = store.codeContext, sentFor != now else { return }
                emailCode = ""; phoneCode = ""
                store.invalidateCodes()
            }
            .alert(isPRL ? Loc("加入通讯录") : Loc("保存为常用地址"), isPresented: $naming) {
                TextField(Loc("名称"), text: $presetName)
                Button(Loc("保存")) { savePreset() }
                Button(Loc("取消"), role: .cancel) {}
            } message: {
                Text(isPRL ? shortAddr(trimmedAddress)
                           : "\(store.network?.name ?? "") · \(shortAddr(trimmedAddress))")
            }
            .sheet(isPresented: $managingPresets) { PresetAddressesView(currency: store.currency, store: store) }
            .sheet(isPresented: $confirming) {
                WithdrawConfirmSheet(
                    amount: "\(fmt(amountValue ?? 0)) \(unit)",
                    fee: "\(fmt(fee)) \(unit)",
                    received: fmt(received), unit: unit,
                    network: store.network?.name,
                    address: trimmedAddress,
                    addressName: savedName,
                    onConfirm: submitConfirmed)
            }
        }
    }

    /// Runs after the user confirms in WithdrawConfirmSheet. Money leaves the account,
    /// so the device owner must authenticate first (Face ID / Touch ID / passcode) —
    /// the same gate as an on-chain send from the wallet.
    private func submitConfirmed() {
        let a = trimmedAddress, v = amountValue ?? 0
        let viaBook = beneficiary?.id
        authenticating = true
        Task {
            let ok = await wallet.authenticate(reason: Loc("验证身份以确认提现"))
            authenticating = false
            guard ok else {
                store.error = wallet.lastError ?? Loc("身份验证未通过，已取消提现")
                wallet.lastError = nil
                return
            }
            if await store.submit(address: a, amount: v, beneficiaryID: viaBook,
                                  emailCode: viaBook == nil ? emailCode : "",
                                  otpCode: otpCode, phoneCode: phoneCode) {
                amount = ""; emailCode = ""; otpCode = ""; phoneCode = ""
                await trade.refresh()
            }
        }
    }

    private var activeWalletAddress: String? {
        wallet.wallets.first { $0.id == wallet.activeWalletID }?.addresses[WalletNetwork.mainnet.rawValue]
    }

    // MARK: presets

    private var usdtPresets: [WithdrawAddress] { book.items(for: store.currency) }

    /// Label shown under a filled-in address that is already saved somewhere.
    private var savedName: String? {
        guard addressValid else { return nil }
        if let b = beneficiary { return Loc("SafeTrade 地址簿「%@」· 免邮箱验证码", b.title) }
        if isPRL {
            if let w = myWallets.first(where: { $0.address == trimmedAddress }) { return Loc("钱包「%@」", w.name) }
            return contacts.name(for: trimmedAddress).map { Loc("通讯录「%@」", $0) }
        }
        return usdtPresets.first { $0.address == trimmedAddress && $0.blockchainKey == store.networkKey }
            .map { Loc("常用地址「%@」", $0.name) }
    }

    /// Is the current address a saved entry (own preset or SafeTrade address book)
    /// for `chain`?
    private func savedFor(chain: String?) -> Bool {
        guard let chain, !trimmedAddress.isEmpty else { return false }
        return usdtPresets.contains { $0.address == trimmedAddress && $0.blockchainKey == chain }
            || store.beneficiaries.contains { $0.destination == trimmedAddress && bookKey($0) == chain }
    }

    private var canSavePreset: Bool { addressValid && savedName == nil && (isPRL || store.networkKey != nil) }

    private func savePreset() {
        if isPRL {
            contacts.add(name: presetName, address: trimmedAddress)
        } else if let key = store.networkKey {
            book.add(currency: store.currency, blockchainKey: key, address: trimmedAddress, name: presetName)
        }
    }

    /// Picking a USDT preset also switches to the chain it was saved for, so an
    /// address can't silently be reused on a different network.
    private func apply(_ p: WithdrawAddress) {
        store.networkKey = p.blockchainKey
        address = p.address
    }

    private func bookKey(_ b: STBeneficiary) -> String? { store.chainKey(of: b) }

    private func apply(_ b: STBeneficiary) {
        guard let dest = b.destination, let key = bookKey(b) else { return }
        store.networkKey = key
        address = dest
        beneficiaryID = b.id
    }

    /// Address-book entries usable here: have an address, and (USDT) sit on a chain
    /// the exchange lists. Pending ones are shown disabled — they still need the
    /// e-mail confirmation on the SafeTrade website.
    private var bookEntries: [STBeneficiary] {
        store.beneficiaries.filter { $0.destination != nil && store.network(forKey: bookKey($0)) != nil }
    }

    @ViewBuilder private var presetsMenu: some View {
        let hasAny = !bookEntries.isEmpty
            || (isPRL ? (!myWallets.isEmpty || !contacts.contacts.isEmpty) : !usdtPresets.isEmpty)
        if hasAny {
            Menu {
                if !bookEntries.isEmpty {
                    Section(Loc("SafeTrade 地址簿（免邮箱验证码）")) {
                        ForEach(bookEntries) { b in
                            let n = store.network(forKey: bookKey(b))
                            Button(isPRL ? b.title : "\(b.title) · \(n?.name ?? "")") { apply(b) }
                                .disabled(!b.isActive || n?.canWithdraw != true)
                        }
                    }
                }
                if isPRL {
                    if !myWallets.isEmpty {
                        Section(Loc("我的钱包")) {
                            ForEach(myWallets, id: \.address) { w in Button(w.name) { address = w.address } }
                        }
                    }
                    let people = contacts.contacts.filter { PRLAddress.isValid($0.address, network: .mainnet) }
                    if !people.isEmpty {
                        Section(Loc("通讯录")) {
                            ForEach(people) { c in Button(c.name) { address = c.address } }
                        }
                    }
                } else if !usdtPresets.isEmpty {
                    Section(Loc("常用地址")) {
                    ForEach(usdtPresets) { p in
                        let n = store.network(forKey: p.blockchainKey)
                        Button("\(p.name) · \(n?.name ?? p.blockchainKey)") { apply(p) }
                            .disabled(n?.canWithdraw != true)
                    }
                    }
                    Button(Loc("管理常用地址…")) { managingPresets = true }
                }
            } label: {
                Text(Loc("常用地址")).font(.caption.weight(.medium))
            }
            .menuStyle(.borderlessButton).fixedSize().tint(Pearl.accent)
        }
    }

    // MARK: pieces

    private var addressPlaceholder: String {
        if isPRL { return "prl1…" }
        guard let key = store.network?.blockchain_key.lowercased() else { return Loc("先选择网络") }
        if key.hasPrefix("tron") { return "T…" }
        if key.hasPrefix("spl") || key.hasPrefix("sol") { return "Solana" }
        return "0x…"
    }

    /// USDT chain picker: one tile per open chain with its fee and minimum, so the
    /// choice is visible at a glance. Deliberately starts with nothing selected: the
    /// receiving side must support the chain, and only the user knows which one it does.
    @ViewBuilder private var networkPicker: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.xs) {
            Text(Loc("网络")).font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Pearl.Space.sm),
                                GridItem(.flexible(), spacing: Pearl.Space.sm)],
                      spacing: Pearl.Space.sm) {
                ForEach(store.openNetworks) { n in networkTile(n) }
            }
            if store.network != nil {
                Text(Loc("请确认收款方支持这条链，选错网络资金可能找不回。"))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func networkTile(_ n: STCurrencyNetwork) -> some View {
        let selected = store.networkKey == n.blockchain_key
        let shape = RoundedRectangle(cornerRadius: Pearl.Radius.xs, style: .continuous)
        return Button {
            withAnimation(.snappy) { store.networkKey = n.blockchain_key }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(n.shortName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.subheadline)
                            .foregroundStyle(Pearl.accent)
                    }
                }
                Text(Loc("手续费 %@ · 最少 %@", fmt(n.fee(for: 0)), fmt(n.minAmount)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Pearl.Space.sm).padding(.vertical, Pearl.Space.xs + 2)
            .background(shape.fill(selected ? Pearl.accent.opacity(0.1) : Color.clear))
            .overlay(shape.strokeBorder(selected ? Pearl.accent : Color.secondary.opacity(0.25),
                                        lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.md) {
            HStack {
                Text(Loc("可提 %@", unit)).foregroundStyle(.secondary)
                Spacer()
                Text(fmt(available)).monospacedDigit().fontWeight(.semibold)
            }.font(.subheadline)

            if let e = store.loadError {
                HStack(alignment: .firstTextBaseline) {
                    Label(e, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    Spacer()
                    Button(Loc("重试")) { Task { await store.load() } }
                        .buttonStyle(.borderless).font(.caption.weight(.semibold)).tint(Pearl.accent)
                        .disabled(store.loadingInfo)
                }
            }

            if !isPRL { networkPicker }

            if let n = store.network, !n.canWithdraw {
                Label(Loc("SafeTrade 暂停了这条链的提现"), systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else if !store.networks.isEmpty && store.openNetworks.isEmpty {
                Label(Loc("SafeTrade 暂停了 %@ 提现", unit), systemImage: "pause.circle")
                    .font(.caption).foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Loc("收款地址")).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    presetsMenu
                }
                TextField(addressPlaceholder, text: $address, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    .focused($focused)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if !trimmedAddress.isEmpty && !addressValid && (isPRL || store.network != nil) {
                    Text(isPRL ? Loc("不是有效的 PRL 主网地址") : Loc("不是有效的 %@ 地址", store.network?.name ?? ""))
                        .font(.caption).foregroundStyle(.red)
                } else if let name = savedName {
                    Text(name).font(.caption).foregroundStyle(.secondary)
                } else if canSavePreset {
                    Button(isPRL ? Loc("加入通讯录") : Loc("保存为常用地址")) { presetName = ""; naming = true }
                        .buttonStyle(.borderless).font(.caption.weight(.medium)).tint(Pearl.accent)
                }
                if let note = store.bookNote {
                    Text(note).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(Loc("数量 (%@)", unit)).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if available > 0 {
                        Button(Loc("MAX %@", fmt(available))) { amount = fmt(available, floorTo: store.precision) }
                            .buttonStyle(.borderless).font(.caption.weight(.medium)).tint(Pearl.accent)
                    }
                }
                TextField("0.0", text: $amount).textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
                    .focused($focused)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
                if let p = amountProblem {
                    Text(p).font(.caption).foregroundStyle(.red)
                }
            }

            if let n = store.network {
                VStack(spacing: 3) {
                    row(Loc("手续费"), "\(fmt(fee)) \(unit)")
                    row(Loc("预计到账"), "\(fmt(received)) \(unit)")
                    if isPRL { row(Loc("最少提现"), "\(fmt(n.minAmount)) \(unit)") }   // USDT: shown on the chain tiles
                }
                .font(.subheadline)
            }
        }
        .pearlCard()
    }

    private var codesCard: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.md) {
            Text(Loc("安全验证")).font(.headline)
            if beneficiary == nil {
                codeField(Loc("邮箱验证码"), text: $emailCode, sendType: "email")
            }
            codeField(Loc("谷歌验证码（开启了 2FA 才需要）"), text: $otpCode, sendType: nil)
            if store.needsPhoneCode {
                codeField(Loc("短信验证码"), text: $phoneCode, sendType: "phone")
            }
            // SafeTrade keys may only withdraw with Enable Withdraw; the key's Trusted
            // IPs list gates every call it makes, withdrawals included.
            Text(Loc("API 密钥需在 SafeTrade 开启 Enable Withdraw；它的 Trusted IPs 白名单对所有请求都生效，不只是提现。"))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { focused = false; confirming = true } label: { Text(Loc("提现")) }
                .buttonStyle(.pearl(Pearl.brand))
                .disabled(!canSubmit)
        }
        .pearlCard()
    }

    @ViewBuilder private func codeField(_ title: String, text: Binding<String>, sendType: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: Pearl.Space.sm) {
                TextField("000000", text: Binding(
                    get: { text.wrappedValue },
                    set: { text.wrappedValue = String($0.filter(\.isNumber).prefix(6)) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospacedDigit())
                    .focused($focused)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    #endif
                if let sendType {
                    Button {
                        let ctx = codeSignature
                        Task { await store.sendCode(type: sendType, address: trimmedAddress,
                                                    amount: amountValue ?? 0, context: ctx) }
                    } label: {
                        if store.sendingCode == sendType { ProgressView().controlSize(.small) }
                        else if store.cooldown(sendType) > 0 { Text(Loc("%@ 秒", "\(store.cooldown(sendType))")).monospacedDigit() }
                        else { Text(Loc("获取验证码")) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!codeReady || store.sendingCode != nil || store.cooldown(sendType) > 0 || store.network == nil)
                }
            }
        }
    }

    @ViewBuilder private var statusMessages: some View {
        if store.unverified != nil {
            UnverifiedBanner(text: Loc("上一笔提现的结果还没确认，核对清楚前暂停提现。"),
                             checking: store.verifying,
                             recheck: { Task { await store.verifyUnverified() } },
                             dismiss: { store.dismissUnverified() })
        }
        if let issue = store.ipIssue { UntrustedIPCard(issue: issue) }
        TradeStatusLines(notice: store.notice, errors: [store.error])
    }

    @ViewBuilder private var historyCard: some View {
        if !store.history.isEmpty {
            VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                Text(Loc("提现记录")).font(.headline)
                VStack(spacing: 0) {
                    ForEach(store.history) { w in
                        historyRow(w).padding(.vertical, Pearl.Space.xs + 2)
                        if w.id != store.history.last?.id { Divider() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pearlCard()
        }
    }

    private func historyRow(_ w: STWithdraw) -> some View {
        HStack(alignment: .top, spacing: Pearl.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(w.amountText ?? "—") \(unit)" + (isPRL ? "" : store.network(forKey: w.blockchain_key).map { " · \($0.name)" } ?? ""))
                    .font(.callout.monospacedDigit())
                if let d = w.destination {
                    Text(shortAddr(d)).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let at = w.created_at?.date {
                    Text(at, format: .dateTime.month(.defaultDigits).day().hour().minute())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(stateLabel(w.stateValue)).font(.caption).foregroundStyle(stateColor(w.stateValue))
                if let tx = w.chainTxid,
                   let url = (store.network(forKey: w.blockchain_key) ?? store.network)?.explorerURL(txid: tx) {
                    Button(Loc("查看交易")) { openURL(url) }
                        .buttonStyle(.borderless).font(.caption).tint(Pearl.accent)
                }
            }
        }
    }

    // MARK: helpers

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    /// Plain decimal (no grouping, period separator, ≤ 8 dp) — also what MAX fills in,
    /// so it must stay parseable.
    private func fmt(_ d: Decimal, floorTo places: Int = 8) -> String {
        var v = d, r = Decimal()
        NSDecimalRound(&r, &v, places, .down)
        return NSDecimalNumber(decimal: r).stringValue
    }

    /// OpenDAX withdraw states → words.
    private func stateLabel(_ s: String) -> String {
        switch s {
        case "succeed", "success", "done", "completed": return Loc("已到账")
        case "canceled", "cancelled": return Loc("已取消")
        case "rejected", "failed", "errored": return Loc("失败")
        case "": return ""
        default: return Loc("处理中")
        }
    }

    private func stateColor(_ s: String) -> Color {
        switch s {
        case "succeed", "success", "done", "completed": return .green
        case "canceled", "cancelled", "rejected", "failed", "errored": return .red
        default: return .orange
        }
    }
}
