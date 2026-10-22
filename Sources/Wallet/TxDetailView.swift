import SwiftUI

// MARK: - 交易详情 / 交易查询
//
// The app's version of the web's transaction lookup: status, txid (copyable), block facts,
// what it did to this wallet, and its inputs and outputs with the wallet's own first. Read
// straight from the indexers (ours, then the official one), like the rest of the wallet.

/// 交易详情: a transaction opened from 交易记录 or 最近交易.
struct TxDetailView: View {
    @ObservedObject var store: WalletStore
    let txid: String

    var body: some View {
        Form { TxDetailSections(store: store, txid: txid) }
            .formStyle(.grouped)
            .pearlListBackground()
            .navigationTitle(Loc("交易详情"))
    }
}

/// 交易查询: any transaction by txid or explorer link (交易记录's toolbar).
struct TxLookupView: View {
    @ObservedObject var store: WalletStore
    @State private var input = ""
    @State private var shown: String?
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                // A prompt, not a title: a Mac form draws a field's title beside it.
                TextField("", text: $input, prompt: Text(Loc("交易 ID（txid）或区块浏览器链接")))
                    .labelsHidden()
                    .accessibilityLabel(Loc("交易 ID（txid）或区块浏览器链接"))
                    .font(.callout.monospaced())
                    .focused($focused)
                    .onSubmit(submit)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.search)
                    #endif
                HStack {
                    Button {
                        guard let s = pasteboardString() else { return }
                        input = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        submit()
                    } label: { Label(Loc("粘贴"), systemImage: "doc.on.clipboard") }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button(Loc("查询"), action: submit)
                        .buttonStyle(.borderedProminent).tint(Pearl.plate)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if invalid {
                    Text(Loc("请输入交易 ID：64 位，由 0–9 和 a–f 组成。"))
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            .pearlListRowSurface()

            if let shown {
                TxDetailSections(store: store, txid: shown).id(shown)
            }
        }
        .formStyle(.grouped)
        .pearlListBackground()
        .navigationTitle(Loc("交易查询"))
        .onAppear { if shown == nil { focused = true } }
    }

    private func submit() {
        guard let txid = TxDetail.parseTxid(input) else { invalid = true; shown = nil; return }
        invalid = false
        input = txid
        shown = txid
        focused = false
    }

    private func pasteboardString() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}

/// One transaction as Form sections: status and txid, facts, 重新广播 while unconfirmed,
/// then inputs and outputs. Loads `txid` from every indexer and, while it is unconfirmed or
/// not indexed yet, again every 30 s.
struct TxDetailSections: View {
    @ObservedObject var store: WalletStore
    let txid: String
    @EnvironmentObject private var contacts: ContactsStore

    private enum Phase: Equatable { case loading, found(TxDetail), notFound, failed }
    private enum Resend: Equatable { case sent, known, rejected(String), unknown, notSent }

    @State private var phase: Phase = .loading
    @State private var copied = false
    @State private var sending = false
    @State private var resend: Resend?
    @State private var allInputs = false
    @State private var allOutputs = false

    /// Rows per side before 显示全部: a pool payout lists up to a thousand outputs.
    private static let firstRows = 10
    private static let refreshEvery: Duration = .seconds(30)

    private var locale: Locale { LocBundleHolder.shared.locale }
    private var detail: TxDetail? { if case .found(let t) = phase { return t }; return nil }

    var body: some View {
        header
            .task(id: txid) { await poll() }
        switch phase {
        case .loading:
            Section {
                ProgressView().frame(maxWidth: .infinity)
            }
            .pearlListRowSurface()
        case .notFound:
            Section {
                Label(Loc("没有找到这笔交易。刚发出的交易可能要稍等片刻才能查到。"), systemImage: "magnifyingglass")
                    .font(.callout).foregroundStyle(.orange)
            }
            .pearlListRowSurface()
        case .failed:
            Section {
                Label(Loc("操作未完成，请重试。"), systemImage: "exclamationmark.icloud")
                    .font(.callout).foregroundStyle(.orange)
                Button(Loc("重试")) { Task { phase = .loading; await load(quiet: false) } }
            }
            .pearlListRowSurface()
        case .found(let tx):
            let own = store.ownAddresses
            let labels = addressLabels(own: own)
            facts(tx, own: own)
            if !tx.confirmed, !tx.coinbase, let hex = tx.hex, RawTx(hex: hex)?.txid == tx.txid {
                rebroadcast(hex)
            }
            rows(Loc("输入"), TxDetail.ownFirst(tx.inputs, own: own), coinbase: tx.coinbase,
                 own: own, labels: labels, expanded: $allInputs)
            rows(Loc("输出"), TxDetail.ownFirst(tx.outputs, own: own), coinbase: false,
                 own: own, labels: labels, expanded: $allOutputs)
        }
    }

    // MARK: sections

    private var header: some View {
        Section {
            HStack {
                if let tx = detail {
                    Label(tx.confirmed ? Loc("已确认") : Loc("待确认"),
                          systemImage: tx.confirmed ? "checkmark.circle.fill" : "clock")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(tx.confirmed ? .green : .orange)
                }
                Spacer()
                Link(destination: TxDetail.explorerURL(txid: txid, network: store.network)) {
                    Label(Loc("区块浏览器"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless).font(.callout)
            }
            // The separator runs the row's full width whether or not the status is there yet.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            VStack(alignment: .leading, spacing: Pearl.Space.xs) {
                Text(Loc("交易 ID")).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: txid)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    copyToPasteboard(txid)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? Loc("已复制") : Loc("复制交易 ID"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless).font(.callout)
            }
            .padding(.vertical, 2)
        }
        .pearlListRowSurface()
    }

    private func facts(_ tx: TxDetail, own: Set<String>) -> some View {
        Section {
            LabeledContent(Loc("确认数"), value: tx.confirmations.formatted(.number.locale(locale)))
            LabeledContent(Loc("区块"), value: tx.height.map { $0.formatted(.number.grouping(.never).locale(locale)) } ?? "—")
            LabeledContent(Loc("时间"), value: tx.time.map { $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)) } ?? "—")
            LabeledContent(Loc("输出总额")) { amount(tx.valueSat) }
            LabeledContent(Loc("网络手续费")) { amount(tx.feeSat) }
            if let net = tx.net(for: own) {
                LabeledContent(Loc("你的地址净收支")) { amount(net, signed: true) }
            }
        }
        .pearlListRowSurface()
    }

    private func rebroadcast(_ hex: String) -> some View {
        Section {
            switch resend {
            case .sent:
                Label(Loc("已重新广播，交易再次发往网络。"), systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            case .known:
                Label(Loc("网络中已有这笔交易。"), systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            case .rejected(let reason):
                VStack(alignment: .leading, spacing: Pearl.Space.xxs) {
                    Text(Loc("网络拒绝了这笔交易：")).font(.callout).foregroundStyle(.orange)
                    if !reason.isEmpty {
                        Text(verbatim: reason).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            case .unknown:
                Text(Loc("网络没有回应，无法确定交易是否已发出。可以先查询，或再广播一次：同一笔交易重复广播是安全的。"))
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .notSent:
                Text(Loc("操作未完成，请重试。")).font(.callout).foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
            if resend != .sent && resend != .known {
                Button {
                    Task { await send(hex) }
                } label: {
                    HStack(spacing: Pearl.Space.xs) {
                        if sending { ProgressView().controlSize(.small) }
                        Label(sending ? Loc("正在广播…") : Loc("重新广播"), systemImage: "paperplane")
                    }
                }
                .disabled(sending)
            }
        }
        .pearlListRowSurface()
    }

    private func rows(_ title: String, _ rows: [TxDetail.Row], coinbase: Bool, own: Set<String>,
                      labels: [String: String], expanded: Binding<Bool>) -> some View {
        let shown = expanded.wrappedValue ? rows : Array(rows.prefix(Self.firstRows))
        return Section {
            if coinbase {
                Text(Loc("Coinbase：新挖出的币")).font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, r in
                    row(r, own: own, labels: labels)
                }
                if rows.count > Self.firstRows {
                    Button(expanded.wrappedValue ? Loc("收起")
                           : Loc("显示全部") + " (\(rows.count.formatted(.number.locale(locale))))") {
                        expanded.wrappedValue.toggle()
                    }
                    .buttonStyle(.borderless).font(.callout)
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                if !coinbase { Text(rows.count.formatted(.number.locale(locale))).monospacedDigit() }
            }
        }
        .pearlListRowSurface()
    }

    private func row(_ r: TxDetail.Row, own: Set<String>, labels: [String: String]) -> some View {
        let mine = r.address.map(own.contains) ?? false
        return HStack(alignment: .firstTextBaseline, spacing: Pearl.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                if let a = r.address {
                    if let label = labels[a] {
                        Text(label).font(.caption.weight(.semibold))
                            .foregroundStyle(mine ? Pearl.accent : .primary).lineLimit(1)
                    }
                    Text(verbatim: a).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text(r.isData ? "OP_RETURN" : Loc("非标准脚本")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Pearl.Space.xs)
            amount(r.sat).fontWeight(mine ? .semibold : .regular)
        }
        .contextMenu {
            if let a = r.address {
                Button { copyToPasteboard(a) } label: { Label(Loc("复制地址"), systemImage: "doc.on.doc") }
            }
        }
    }

    // MARK: helpers

    private func amount(_ sat: Int64, signed: Bool = false) -> Text {
        let s = RawTx.prl(fromSat: sat).formatted(.number.precision(.fractionLength(0...8)).locale(locale))
        let text = Text(verbatim: (signed && sat > 0 ? "+" : "") + s + " PRL").font(.callout.monospacedDigit())
        guard signed else { return text }
        return text.foregroundColor(sat > 0 ? .green : sat < 0 ? .primary : .secondary)
    }

    /// Names for addresses this app knows: the open wallet's own (its name), the other
    /// wallets' first receive addresses, and contacts.
    private func addressLabels(own: Set<String>) -> [String: String] {
        var m: [String: String] = [:]
        for c in contacts.contacts { m[c.address.lowercased()] = c.name }
        for w in store.wallets { if let a = w.addresses[store.network.rawValue] { m[a] = w.name } }
        for a in own { m[a] = store.walletName }
        return m
    }

    // MARK: loading

    private func poll() async {
        await load(quiet: false)
        while !Task.isCancelled {
            if detail?.confirmed == true { return }
            try? await Task.sleep(for: Self.refreshEvery)
            if Task.isCancelled { return }
            await load(quiet: true)
        }
    }

    /// `quiet`: a background refresh — a failed one leaves what's on screen alone.
    private func load(quiet: Bool) async {
        let result = await BlockbookClient(network: store.network).transactionDetail(txid: txid)
        guard !Task.isCancelled else { return }
        switch result {
        case .found(let tx): phase = .found(tx)
        case .notFound: phase = .notFound
        case .failed: if !quiet && detail == nil { phase = .failed }
        }
    }

    private func send(_ hex: String) async {
        sending = true
        resend = nil
        defer { sending = false }
        do {
            _ = try await BlockbookClient(network: store.network).broadcast(hex)
            resend = .sent
        } catch let e as BlockbookClient.BroadcastError {
            switch e {
            case .rejected(let m): resend = BlockbookClient.isAlreadyKnown(m) ? .known : .rejected(m)
            case .transport: resend = .unknown
            case .notDelivered: resend = .notSent
            }
        } catch {
            resend = .unknown
        }
        if resend == .sent || resend == .known { await load(quiet: true) }
    }
}

extension WalletStore {
    /// The open wallet's addresses this app knows: the xpub's used ones, change found on the
    /// internal chain, and the current receive address.
    var ownAddresses: Set<String> {
        var s = xpubAddresses.union(change.owned)
        if let address { s.insert(address) }
        return s
    }
}
