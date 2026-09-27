import SwiftUI

/// 充值: top up the SafeTrade account — pick the chain, then the deposit address (QR,
/// copy, memo), its minimum and confirmations, and recent deposits. For PRL a
/// 「从钱包转入」 opens the wallet's send screen with that address filled in.
struct DepositView: View {
    @ObservedObject var trade: SafeTradeStore
    @ObservedObject private var wallet = WalletStore.shared
    @StateObject private var store: DepositStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var copied: String?         // the value just copied (address or memo)

    init(trade: SafeTradeStore, currency: String) {
        self.trade = trade
        _store = StateObject(wrappedValue: DepositStore(currency: currency, trade: trade))
    }

    private var isPRL: Bool { store.currency == "prl" }
    private var unit: String { store.currency.uppercased() }
    /// The in-app wallet can pay the deposit itself: PRL, a mainnet wallet, unlocked.
    private var canSendFromWallet: Bool {
        isPRL && wallet.phase == .unlocked && wallet.network == .mainnet
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Pearl.Space.lg) {
                    if let issue = store.ipIssue { UntrustedIPCard(issue: issue) }
                    networkCard
                    if store.networkKey != nil { addressCard }
                    historyCard
                }
                .padding(Pearl.Space.screen)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle(Loc("充值 %@", unit))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Loc("关闭")) { dismiss() } }
                    .noGlassBackground()
            }
            .task { await store.load() }
            .refreshable { await store.load() }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 620)
        #endif
    }

    // MARK: chain

    @ViewBuilder private var networkCard: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            if store.networks.isEmpty {
                if store.loadingInfo {
                    HStack(spacing: Pearl.Space.xs) {
                        ProgressView().controlSize(.small)
                        Text(Loc("正在读取充值网络…")).font(.callout).foregroundStyle(.secondary)
                    }
                } else if let e = store.loadError {
                    Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if store.networks.count == 1, let n = store.networks.first {
                HStack {
                    Text(Loc("网络")).foregroundStyle(.secondary)
                    Spacer()
                    Text(n.name).fontWeight(.medium)
                }
                .font(.callout)
            } else {
                Text(Loc("网络")).font(.subheadline).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Pearl.Space.sm),
                                    GridItem(.flexible(), spacing: Pearl.Space.sm)],
                          spacing: Pearl.Space.sm) {
                    ForEach(store.networks) { n in networkTile(n) }
                }
                if store.networkKey == nil {
                    Text(Loc("先选择充值网络：要和转出方使用的网络一致。"))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let note = store.network?.maintenanceMessage {
                Label(Loc("SafeTrade 提示：%@", note), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard()
    }

    private func networkTile(_ n: STCurrencyNetwork) -> some View {
        let selected = store.networkKey == n.blockchain_key
        let shape = RoundedRectangle(cornerRadius: Pearl.Radius.xs, style: .continuous)
        return Button {
            withAnimation(.snappy) { store.select(n.blockchain_key) }
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
                Text(Loc("最少 %@", fmt(n.minDeposit)))
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

    // MARK: address

    @ViewBuilder private var addressCard: some View {
        VStack(spacing: Pearl.Space.md) {
            if let a = store.address, a.isReady {
                if let qr = QRCode.cgImage(from: a.plainAddress) {
                    Image(decorative: qr, scale: 1)
                        .interpolation(.none).resizable().scaledToFit()
                        .frame(width: 200, height: 200)
                        .padding(Pearl.Space.md).background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: Pearl.Radius.md, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Pearl.Radius.md, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                        .id(a.plainAddress)
                }
                copyRow(Loc("充值地址"), a.plainAddress, key: "address")
                if let memo = a.memo {
                    copyRow("Memo", memo, key: "memo")
                    Label(Loc("转账时必须同时填写这个 Memo，否则充值无法到账。"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                facts
                warning
                if isPRL { fromWallet(a.plainAddress) }
            } else if store.loadingAddress {
                HStack(spacing: Pearl.Space.xs) {
                    ProgressView().controlSize(.small)
                    Text(store.generating ? Loc("SafeTrade 正在生成充值地址…") : Loc("正在获取充值地址…"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if let e = store.addressError {
                VStack(spacing: Pearl.Space.sm) {
                    Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(Loc("重试")) { Task { await store.loadAddress() } }
                        .buttonStyle(.borderless).font(.callout.weight(.semibold)).tint(Pearl.accent)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .pearlCard()
    }

    private func copyRow(_ label: String, _ value: String, key: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: Pearl.Space.sm) {
                Text(value).font(.callout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button(copied == key ? Loc("已复制") : Loc("复制")) {
                    copyToPasteboard(value)
                    withAnimation { copied = key }
                    Task { try? await Task.sleep(for: .seconds(2)); withAnimation { if copied == key { copied = nil } } }
                }
                .buttonStyle(.borderless).font(.caption.weight(.semibold)).tint(Pearl.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Minimum, confirmations and fee for the chosen chain — what decides whether and
    /// when a deposit lands.
    @ViewBuilder private var facts: some View {
        if let n = store.network {
            VStack(spacing: 6) {
                if n.minDeposit > 0 { factRow(Loc("最少充值"), "\(fmt(n.minDeposit)) \(unit)") }
                if let c = n.min_confirmations, c > 0 { factRow(Loc("到账确认"), Loc("%d 个区块", c)) }
                if n.depositFee > 0 { factRow(Loc("充值手续费"), "\(fmt(n.depositFee)) \(unit)") }
            }
            .font(.callout)
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }

    private var warning: some View {
        Label(Loc("只能向这个地址充值 %@（%@ 网络）。转入其他币种或走错网络，资金可能无法找回。",
                  unit, store.network?.name ?? ""),
              systemImage: "exclamationmark.shield")
            .font(.caption).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// PRL from the in-app wallet: the send screen with this address filled in (the
    /// amount, fee and device check stay the user's).
    @ViewBuilder private func fromWallet(_ address: String) -> some View {
        if canSendFromWallet {
            NavigationLink {
                SendView(store: wallet, prefillAddress: address)
            } label: {
                Label(Loc("从钱包转入"), systemImage: "arrow.down.to.line")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pearl(Pearl.brand))
        } else if isPRL, wallet.phase == .locked {
            Text(Loc("解锁钱包后，可以从钱包直接转入。"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: history

    @ViewBuilder private var historyCard: some View {
        if !store.history.isEmpty {
            VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                Text(Loc("充值记录")).font(.headline)
                VStack(spacing: 0) {
                    ForEach(store.history) { d in
                        historyRow(d).padding(.vertical, Pearl.Space.xs + 2)
                        if d.id != store.history.last?.id { Divider() }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pearlCard()
        }
    }

    private func historyRow(_ d: STDeposit) -> some View {
        let chain = store.networks.first { $0.blockchain_key == d.blockchain_key }
        return HStack(alignment: .top, spacing: Pearl.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(d.amountText ?? "—") \(unit)" + (isPRL ? "" : chain.map { " · \($0.name)" } ?? ""))
                    .font(.callout.monospacedDigit())
                if let at = d.created_at?.date {
                    Text(at, format: .dateTime.month(.defaultDigits).day().hour().minute())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(statusLabel(d.status)).font(.caption).foregroundStyle(statusColor(d.status))
                if let tx = d.txid, !tx.isEmpty, let url = (chain ?? store.network)?.explorerURL(txid: tx) {
                    Button(Loc("查看交易")) { openURL(url) }
                        .buttonStyle(.borderless).font(.caption).tint(Pearl.accent)
                }
            }
        }
    }

    private func statusLabel(_ s: STDeposit.Status) -> String {
        switch s {
        case .credited: return Loc("已到账")
        case .processing: return Loc("处理中")
        case .feeRequired: return Loc("待付手续费")
        case .failed: return Loc("失败")
        }
    }

    private func statusColor(_ s: STDeposit.Status) -> Color {
        switch s {
        case .credited: return .green
        case .failed: return .red
        case .processing, .feeRequired: return .orange
        }
    }

    /// Plain decimal (no grouping, ≤ 8 dp).
    private func fmt(_ d: Decimal) -> String {
        var v = d, r = Decimal()
        NSDecimalRound(&r, &v, 8, .plain)
        return NSDecimalNumber(decimal: r).stringValue
    }
}
