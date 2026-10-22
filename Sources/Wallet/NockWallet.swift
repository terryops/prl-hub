import SwiftUI

// The NOCK (Nockchain) side of a wallet: same seed as PRL, its own address, balance,
// history and sends. Reached from the NOCK card on the wallet dashboard.

private func nockPrice(_ usd: Double) -> String {
    let digits = usd < 1 ? 4 : 2
    return "$" + usd.formatted(.number.precision(.fractionLength(digits)).locale(LocBundleHolder.shared.locale))
}

private func nockText(_ nicks: UInt64, decimals: Int = 6) -> String {
    NockCore.format(nicks: nicks, decimals: decimals) + " NOCK"
}

// MARK: - Dashboard card

/// One line on the PRL dashboard: the NOCK balance of the same seed, opening the NOCK page.
struct NockAssetCard: View {
    @ObservedObject var nock: NockWalletStore
    @ObservedObject private var price = NockPriceManager.shared
    @EnvironmentObject private var currency: CurrencyManager
    var surface: Color? = nil
    var secondary: Color = .secondary

    var body: some View {
        NavigationLink { NockWalletView(nock: nock) } label: {
            HStack(spacing: Pearl.Space.md) {
                NockBadge(size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "NOCK").font(.headline)
                    Text(price.usd.map(nockPrice) ?? "Nockchain")
                        .font(.caption).foregroundStyle(secondary).monospacedDigit()
                }
                Spacer(minLength: Pearl.Space.sm)
                VStack(alignment: .trailing, spacing: 2) {
                    if nock.hasBalance {
                        Text(NockCore.format(nicks: nock.balance.total, decimals: 4))
                            .font(.headline.monospacedDigit())
                            .opacity(nock.balanceIsCached ? 0.6 : 1)
                            .contentTransition(.numericText())
                        if let usd = price.value(ofNicks: nock.balance.total) {
                            Text(verbatim: "≈ " + currency.dual(usd))
                                .font(.caption.monospacedDigit()).foregroundStyle(secondary)
                        }
                    } else if nock.syncError != nil {
                        Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.6)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md, frosted: true, surface: surface)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(nock.hasBalance ? Loc("NOCK 余额 %@", nockText(nock.balance.total)) : Loc("NOCK 钱包"))
        .animation(.snappy, value: nock.balance)
    }
}

/// The NOCK mark: a hexagon glyph on the badge, so it never passes for the PRL pearl.
struct NockBadge: View {
    var size: CGFloat = 38
    var body: some View {
        PearlIconBadge(systemImage: "hexagon.fill", gradient: Pearl.sunrise, size: size)
    }
}

// MARK: - NOCK page

struct NockWalletView: View {
    @ObservedObject var nock: NockWalletStore
    @ObservedObject private var price = NockPriceManager.shared
    @EnvironmentObject private var currency: CurrencyManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var toast: String?
    /// DEBUG: SHOT_NOCK=receive|send|history pushes that screen (verification runs).
    @State private var shotPage: String? = {
        #if DEBUG
        let v = ProcessInfo.processInfo.environment["SHOT_NOCK"]
        return ["receive", "send", "history"].contains(v ?? "") ? v : nil
        #else
        return nil
        #endif
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: Pearl.Space.lg) {
                if !nock.coreOK {
                    Label(Loc("NOCK 钱包组件缺失，无法使用"), systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.red)
                }
                hero
                if let problem = nock.syncError {
                    Label(nock.lastSyncedAt.map { Loc("%@，显示的是 %@ 的数据", problem, $0.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(LocBundleHolder.shared.locale))) }
                          ?? Loc("%@，稍后自动重试", problem),
                          systemImage: "exclamationmark.icloud")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if nock.balance.locked > 0 { lockedNote }

                HStack(spacing: Pearl.Space.md) {
                    action(Loc("收款"), "qrcode") { NockReceiveView(nock: nock) }
                    action(Loc("转账"), "paperplane") { NockSendView(nock: nock) { toast = $0 } }
                    action(Loc("记录"), "clock.arrow.circlepath") { NockActivityView(nock: nock) }
                }

                recent

                PearlInfoRow(Loc("用的是同一套助记词：在 Nockchain 官方钱包或 Iris 钱包导入它，会看到同一个 NOCK 地址。"),
                             title: Loc("和 PRL 共用助记词"), systemImage: "key.horizontal")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .pearlScreenBackground()
        .navigationTitle(Loc("NOCK 钱包"))
        .refreshable { await nock.load(); await price.refreshIfStale() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await nock.refreshIfStale()
            await price.refreshIfStale()
            while !Task.isCancelled {
                try? await Task.sleep(for: nock.pollInterval)
                if Task.isCancelled { break }
                await nock.load()
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Label(toast, systemImage: "checkmark.seal.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, Pearl.Space.md).padding(.vertical, Pearl.Space.sm)
                    .background(.green.gradient, in: Capsule())
                    .padding(.top, Pearl.Space.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task { try? await Task.sleep(for: .seconds(2.2)); withAnimation { self.toast = nil } }
            }
        }
        .animation(.snappy, value: toast)
        .navigationDestination(item: $shotPage) { page in
            switch page {
            case "receive": NockReceiveView(nock: nock)
            case "send": NockSendView(nock: nock)
            default: NockActivityView(nock: nock)
            }
        }
    }

    private var hero: some View {
        PearlHero(gradient: Pearl.brandVivid, minHeight: 0, padding: Pearl.Space.md, showSparkle: false) {
            VStack(spacing: Pearl.Space.xs) {
                HStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Text(verbatim: "NOCK").font(.footnote.weight(.bold)).foregroundStyle(Pearl.onHeroChip.opacity(0.75))
                        Text(price.usd.map(nockPrice) ?? "—").font(.body.weight(.bold)).monospacedDigit()
                            .foregroundStyle(Pearl.heroChipPrice)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Pearl.heroChip, in: Capsule())
                }
                Group {
                    if nock.hasBalance {
                        (Text(NockCore.format(nicks: nock.balance.total, decimals: 4))
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                         + Text(verbatim: " NOCK")
                            .font(.system(.callout, design: .rounded).weight(.semibold))
                            .foregroundStyle(Pearl.onHero.opacity(0.85)))
                        .foregroundStyle(Pearl.onHero)
                        .opacity(nock.balanceIsCached ? 0.7 : 1)
                        .contentTransition(.numericText())
                    } else {
                        Text(verbatim: "—— NOCK")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                            .foregroundStyle(Pearl.onHero.opacity(0.45))
                    }
                }
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
                .padding(.top, -6)
                Group {
                    if nock.hasBalance, let usd = price.value(ofNicks: nock.balance.total) {
                        Text(verbatim: "≈ " + currency.dual(usd))
                    } else {
                        Text(Loc("同步余额…"))
                    }
                }
                .font(.callout.weight(.medium)).monospacedDigit()
                .foregroundStyle(Pearl.onHero.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Mining rewards wait 100 blocks (~4 hours) before they can be spent.
    private var lockedNote: some View {
        let wait = nock.blocksUntilNextUnlock.map { blocks -> String in
            let minutes = Int(Double(blocks) * NockWalletStore.blockSeconds / 60)
            return minutes >= 90 ? Loc("约 %@ 小时", "\(Int((Double(minutes) / 60).rounded()))") : Loc("约 %@ 分钟", "\(max(1, minutes))")
        }
        return PearlInfoRow(
            wait.map { Loc("其中 %@ 是挖矿收入，要等 100 个区块才能使用。下一笔解锁还要%@。", nockText(nock.balance.locked, decimals: 4), $0) }
                ?? Loc("其中 %@ 是挖矿收入，要等 100 个区块才能使用。", nockText(nock.balance.locked, decimals: 4)),
            title: Loc("可用 %@", nockText(nock.balance.available, decimals: 4)),
            systemImage: "lock.circle")
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
    }

    private var recent: some View {
        let rows = Array(nock.history.prefix(3))
        return VStack(alignment: .leading, spacing: Pearl.Space.xs) {
            HStack {
                Text(Loc("最近交易")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !rows.isEmpty {
                    NavigationLink { NockActivityView(nock: nock) } label: {
                        Text(Loc("全部")).font(.caption2).foregroundStyle(Pearl.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
            if rows.isEmpty {
                Text(nock.backendReady ? Loc("暂无交易记录") : Loc("同步中…")).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ForEach(rows) { tx in
                    NavigationLink { NockTxDetailView(nock: nock, txID: tx.id) } label: {
                        NockTxRow(tx: tx, confirmations: nock.confirmations(tx), compact: true)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md, frosted: true)
    }

    private func action<Dest: View>(_ title: String, _ icon: String, @ViewBuilder dest: () -> Dest) -> some View {
        NavigationLink(destination: dest()) {
            VStack(spacing: Pearl.Space.sm) {
                PearlIconBadge(systemImage: icon)
                Text(title).font(.callout.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md, frosted: true)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rows

struct NockTxRow: View {
    let tx: NockTx
    let confirmations: Int?
    var compact = false

    private var incoming: Bool { tx.kind != .sent }
    private var title: String {
        switch tx.kind {
        case .received: return Loc("收到")
        case .mined: return Loc("挖矿收入")
        case .sent: return Loc("发出")
        }
    }

    var body: some View {
        HStack(spacing: Pearl.Space.sm) {
            ZStack {
                Circle().fill((incoming ? Color.green : Color.orange).opacity(0.16))
                    .frame(width: compact ? 22 : 36, height: compact ? 22 : 36)
                Image(systemName: tx.kind == .mined ? "cube.fill" : incoming ? "arrow.down" : "arrow.up")
                    .font(compact ? .system(size: 10, weight: .bold) : .callout.weight(.bold))
                    .foregroundStyle(incoming ? .green : .orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(compact ? .caption.weight(.semibold) : .body)
                if !compact {
                    Text(tx.time.formatted(.dateTime.month().day().hour().minute().locale(LocBundleHolder.shared.locale)))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: Pearl.Space.xs)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text((incoming ? "+" : "-") + NockCore.format(nicks: tx.amount, decimals: 4))
                        .font((compact ? Font.caption : .callout).monospacedDigit().bold())
                        .foregroundStyle(tx.status == .failed ? Color.secondary : incoming ? Color.green : Color.primary)
                        .strikethrough(tx.status == .failed)
                    Text(verbatim: "NOCK").font(.caption2).foregroundStyle(.secondary)
                }
                .lineLimit(1).minimumScaleFactor(0.6)
                status
            }
            if compact {
                Text(RelTime(tx.time)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch tx.status {
        case .pending:
            Text(Loc("待确认")).font(.caption2).foregroundStyle(.orange)
        case .failed:
            Text(Loc("未上链")).font(.caption2).foregroundStyle(.secondary)
        case .confirmed:
            if let c = confirmations, c < 10 {
                Text(Loc("%@ 确认", "\(c)")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Receive

struct NockReceiveView: View {
    @ObservedObject var nock: NockWalletStore
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: Pearl.Space.lg) {
                if let addr = nock.address {
                    if let qr = QRCode.cgImage(from: addr) {
                        Image(decorative: qr, scale: 1)
                            .interpolation(.none).resizable().scaledToFit()
                            .frame(width: 220, height: 220)
                            .padding(Pearl.Space.md).background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: Pearl.Radius.md, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Pearl.Radius.md, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                    }
                    PearlSectionHeader(Loc("NOCK 收款地址 · Nockchain 主网"), systemImage: "qrcode")
                    Text(addr).font(.callout.monospaced()).multilineTextAlignment(.center).textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.sm)
                    Button {
                        copyToPasteboard(addr)
                        withAnimation { copied = true }
                        Task { try? await Task.sleep(for: .seconds(2)); withAnimation { copied = false } }
                    } label: {
                        Label(copied ? Loc("已复制") : Loc("复制地址"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.pearl)

                    PearlInfoRow(Loc("这个地址只收 NOCK。PRL 请用钱包首页的 PRL 收款地址，发错链会丢失。"),
                                 title: Loc("只能收 NOCK"), systemImage: "exclamationmark.shield")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PearlInfoRow(Loc("矿池的 NOCK 合并挖矿收益也可以填这个地址。挖矿收入要等 100 个区块（约 4 小时）才能使用。"),
                                 systemImage: "cube")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView(Loc("派生地址…")).frame(maxHeight: 240)
                }
            }
            .padding(Pearl.Space.screen).frame(maxWidth: 460).frame(maxWidth: .infinity)
        }
        .pearlScreenBackground()
        .navigationTitle(Loc("收 NOCK"))
    }
}

// MARK: - Send

struct NockSendView: View {
    @ObservedObject var nock: NockWalletStore
    var onSent: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var amount = ""
    @State private var preparing = false
    @State private var sending = false
    @State private var quotingMax = false
    @State private var prepared: NockPreparedSend?
    @State private var result: String?
    @State private var resultIsWarning = false
    /// The text MAX filled in: a send is a sweep only while the amount still equals it.
    @State private var maxString: String?

    /// Checked once per edit (an FFI round trip), not on every render.
    @State private var addressProblem: String?
    private var addr: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsed: Decimal? { NockCore.parseAmount(amount) }
    private var amountNicks: UInt64? { parsed.flatMap(NockCore.nicks(fromNock:)) }
    private var isMax: Bool { maxString != nil && amount == maxString }
    private var overBalance: Bool { !isMax && (amountNicks ?? 0) > nock.balance.available }
    private var canSend: Bool {
        !preparing && !sending && !addr.isEmpty && addressProblem == nil && (amountNicks ?? 0) > 0 && !overBalance
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                Text(nock.hasBalance ? Loc("可用余额 %@", nockText(nock.balance.available)) : Loc("同步余额…"))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.sm)

                VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                    Text(Loc("收款地址")).font(.headline)
                    TextField(Loc("NOCK 地址"), text: $address, axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                        .onChange(of: address, initial: true) { _, _ in
                            result = nil
                            addressProblem = addr.isEmpty ? nil : NockCore.addressProblem(addr)
                        }
                    if let p = addressProblem {
                        Text(NockCore.Failure(code: p, message: "").errorDescription ?? "")
                            .font(.caption).foregroundStyle(.red)
                    } else if !addr.isEmpty && addr == nock.address {
                        Text(Loc("这是你自己的 NOCK 地址")).font(.caption).foregroundStyle(.orange)
                    }
                }
                .pearlCard()

                VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                    HStack {
                        Text(Loc("金额 (NOCK)")).font(.headline)
                        Spacer()
                        Button { quoteMax() } label: {
                            if quotingMax { ProgressView().controlSize(.mini) } else { Text("MAX") }
                        }
                        .font(.caption)
                        .disabled(quotingMax || preparing || sending || nock.balance.available == 0)
                    }
                    TextField("0.0", text: $amount).textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .keyboardType(.decimalPad)
                        #endif
                        .onChange(of: amount) { _, _ in result = nil }
                    if overBalance {
                        Text(Loc("超过可用余额（手续费另计）")).font(.caption).foregroundStyle(.red)
                    } else if !amount.isEmpty && parsed == nil {
                        Text(Loc("金额最多支持 %@ 位小数", "\(NockCore.typedDecimals)")).font(.caption).foregroundStyle(.red)
                    }
                }
                .pearlCard()

                Button { prepare() } label: {
                    HStack(spacing: Pearl.Space.xs) {
                        if preparing || sending { ProgressView().controlSize(.small).tint(Pearl.onAccent) }
                        Text(sending ? Loc("签名并广播…") : preparing ? Loc("正在构建交易…") : Loc("发送"))
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.pearl)
                .disabled(!canSend)

                if let result {
                    Label(result, systemImage: resultIsWarning ? "exclamationmark.triangle" : "xmark.octagon")
                        .font(.callout).foregroundStyle(resultIsWarning ? .orange : .red).textSelection(.enabled)
                }
                PearlInfoRow(Loc("交易在本机签名（私钥不离开设备），经 Nockchain 公共节点广播。手续费按交易大小计算，确认前会显示。"),
                             systemImage: "lock.shield")
            }
            .padding(Pearl.Space.screen).frame(maxWidth: 520).frame(maxWidth: .infinity)
            .animation(.snappy, value: result)
        }
        .pearlScreenBackground()
        .navigationTitle(Loc("转 NOCK"))
        .sheet(item: $prepared) { p in NockSendConfirmSheet(send: p) { broadcast(p) } }
        .task { await nock.refreshIfStale() }
    }

    private func quoteMax() {
        quotingMax = true; result = nil
        Task {
            defer { quotingMax = false }
            do {
                let q = try await nock.maxSendQuote(to: addr)
                let s = NockCore.plainAmount(nicks: q.amount)
                amount = s; maxString = s
            } catch {
                resultIsWarning = false
                result = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func prepare() {
        guard let n = amountNicks else { return }
        preparing = true; result = nil
        Task {
            do {
                prepared = try await nock.prepareSend(to: addr, amount: n, sweep: isMax)
            } catch {
                resultIsWarning = false
                result = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            preparing = false
        }
    }

    private func broadcast(_ p: NockPreparedSend) {
        guard !sending else { return }
        prepared = nil
        sending = true; result = nil
        Task {
            let outcome = await nock.broadcast(p)
            sending = false
            switch outcome {
            case .sent:
                amount = ""; address = ""; maxString = nil
                onSent(Loc("已发送 ✓"))
                dismiss()
                await nock.load()
            case .failed(let m):
                resultIsWarning = false; result = m
            case .unverified(let m):
                resultIsWarning = true; result = m
            }
        }
    }
}

/// The receipt before a NOCK send leaves: amount, the address in groups, fee and total.
struct NockSendConfirmSheet: View {
    let send: NockPreparedSend
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                    VStack(spacing: Pearl.Space.xs) {
                        NockBadge(size: 52).padding(.bottom, Pearl.Space.xxs)
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(verbatim: NockCore.format(nicks: send.amount))
                                .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                            Text(verbatim: "NOCK").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .lineLimit(1).minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, Pearl.Space.xs)

                    if send.feeIsHigh {
                        Label(Loc("手续费占这笔金额的一成以上，请确认。"), systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.weight(.medium)).foregroundStyle(.orange)
                            .padding(Pearl.Space.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Pearl.Radius.xs, style: .continuous))
                    }

                    PearlReceiptSection(Loc("收款信息")) {
                        PearlReceiptAddress(label: Loc("收款地址"), address: send.recipient)
                        Divider()
                        PearlReceiptRow(Loc("网络"), "Nockchain")
                    }

                    PearlReceiptSection(Loc("金额")) {
                        PearlReceiptRow(Loc("发送"), nockText(send.amount))
                        Divider()
                        PearlReceiptRow(Loc("网络手续费"), nockText(send.fee), tint: send.feeIsHigh ? .orange : nil)
                        Divider()
                        PearlReceiptRow(Loc("合计"), nockText(send.amount + send.fee), total: true)
                    }

                    PearlInfoRow(Loc("NOCK 地址没有校验码，输错一位也可能是有效地址。请逐段核对收款地址。"),
                                 title: Loc("请核对地址"), systemImage: "exclamationmark.magnifyingglass")
                    PearlInfoRow(Loc("在本机签名，上链后不可撤销"), systemImage: "lock.shield")
                }
                .padding(Pearl.Space.screen)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .pearlScreenBackground()
            .safeAreaInset(edge: .bottom) {
                Button {
                    guard !confirmed else { return }
                    confirmed = true
                    onConfirm()
                } label: {
                    HStack(spacing: Pearl.Space.xs) {
                        Text(Loc("确认发送 %@", nockText(send.amount, decimals: 4)))
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.pearl)
                .frame(maxWidth: 520)
                .padding(.horizontal, Pearl.Space.screen)
                .padding(.vertical, Pearl.Space.sm)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .navigationTitle(Loc("确认转账"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Loc("取消")) { dismiss() } }
                    .noGlassBackground()
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 460, minHeight: 700)
        #endif
    }
}

// MARK: - History

struct NockActivityView: View {
    @ObservedObject var nock: NockWalletStore

    var body: some View {
        Group {
            if nock.history.isEmpty {
                if nock.backendReady {
                    PearlEmptyState(systemImage: "clock.arrow.circlepath", title: Loc("暂无交易记录"),
                                    message: Loc("你的收发记录会显示在这里"))
                } else {
                    VStack(spacing: Pearl.Space.md) {
                        if let problem = nock.syncError {
                            Label(Loc("%@，稍后自动重试", problem), systemImage: "exclamationmark.icloud")
                                .font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
                        } else {
                            ProgressView()
                            Text(Loc("同步中…")).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(Pearl.Space.screen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Pearl.Space.md) {
                        LazyVStack(spacing: 0) {
                            ForEach(nock.history) { tx in
                                NavigationLink { NockTxDetailView(nock: nock, txID: tx.id) } label: {
                                    NockTxRow(tx: tx, confirmations: nock.confirmations(tx))
                                        .padding(.vertical, Pearl.Space.sm)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if tx.id != nock.history.last?.id {
                                    Divider().padding(.leading, 36 + Pearl.Space.sm)
                                }
                            }
                        }
                        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
                        Text(Loc("记录由本机保存：收到的每一笔从本机第一次看到它时算起，换手机或重装后只能看到当前持有的部分。"))
                            .pearlExplanation(.footnote)
                            .padding(.horizontal, Pearl.Space.xs)
                    }
                    .padding(Pearl.Space.screen)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .pearlScreenBackground()
        .navigationTitle(Loc("NOCK 记录"))
        .task { await nock.refreshIfStale() }
        .refreshable { await nock.load() }
    }
}

struct NockTxDetailView: View {
    @ObservedObject var nock: NockWalletStore
    let txID: String
    @Environment(\.openURL) private var openURL

    private var tx: NockTx? { nock.history.first { $0.id == txID } }

    var body: some View {
        ScrollView {
            if let tx {
                VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                    VStack(spacing: Pearl.Space.xs) {
                        Text(verbatim: (tx.kind == .sent ? "-" : "+") + NockCore.format(nicks: tx.amount) + " NOCK")
                            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(tx.kind == .sent ? Color.primary : Color.green)
                            .lineLimit(1).minimumScaleFactor(0.5)
                        Text(statusText(tx)).font(.subheadline).foregroundStyle(tx.status == .pending ? .orange : .secondary)
                    }
                    .frame(maxWidth: .infinity)

                    PearlReceiptSection(Loc("详情")) {
                        PearlReceiptRow(Loc("类型"), kindText(tx))
                        Divider()
                        PearlReceiptRow(Loc("时间"), tx.time.formatted(.dateTime.year().month().day().hour().minute().locale(LocBundleHolder.shared.locale))
                                        + (tx.timeExact ? "" : " " + Loc("（估算）")))
                        if let h = tx.height {
                            Divider()
                            PearlReceiptRow(Loc("区块高度"), "\(h)")
                        }
                        if let fee = tx.fee {
                            Divider()
                            PearlReceiptRow(Loc("网络手续费"), nockText(fee))
                        }
                    }

                    if let to = tx.counterparty {
                        PearlReceiptSection(Loc("收款信息")) {
                            PearlReceiptAddress(label: Loc("发送至"), address: to)
                        }
                    }

                    if let id = tx.txId {
                        PearlReceiptSection(Loc("交易 ID")) {
                            Text(verbatim: id).font(.footnote.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 12)
                        }
                        HStack(spacing: Pearl.Space.lg) {
                            Button { copyToPasteboard(id) } label: { Label(Loc("复制交易 ID"), systemImage: "doc.on.doc") }
                            if let url = NockClient.explorerURL(tx: id) {
                                Button { openURL(url) } label: { Label(Loc("在浏览器中查看"), systemImage: "safari") }
                            }
                        }
                        .font(.callout.weight(.medium)).buttonStyle(.plain).foregroundStyle(Pearl.accent)
                    }
                }
                .padding(Pearl.Space.screen).frame(maxWidth: 560).frame(maxWidth: .infinity)
            } else {
                PearlEmptyState(systemImage: "questionmark.circle", title: Loc("找不到这笔记录"))
            }
        }
        .pearlScreenBackground()
        .navigationTitle(Loc("交易详情"))
    }

    private func kindText(_ tx: NockTx) -> String {
        switch tx.kind {
        case .received: return Loc("收到")
        case .mined: return Loc("挖矿收入")
        case .sent: return Loc("发出")
        }
    }

    private func statusText(_ tx: NockTx) -> String {
        switch tx.status {
        case .pending: return Loc("待确认")
        case .failed: return Loc("未上链：节点已丢弃这笔交易，金额已退回余额")
        case .confirmed:
            if let c = nock.confirmations(tx) { return Loc("%@ 确认", "\(c)") }
            return Loc("已确认")
        }
    }
}
