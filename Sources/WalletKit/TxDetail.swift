import Foundation

/// One transaction as an indexer sees it: what 交易详情 and 交易查询 show (the web's
/// transaction lookup, read straight from Blockbook like the rest of the wallet).
struct TxDetail: Sendable, Equatable {
    struct Row: Sendable, Equatable {
        /// nil for an output without exactly one address: OP_RETURN data (`isData`) or
        /// another nonstandard script.
        let address: String?
        let sat: Int64
        let isData: Bool
    }

    let txid: String
    let confirmations: Int
    /// nil while unconfirmed.
    let height: Int?
    /// The block's time; for a mempool tx, when the indexer first saw it.
    let time: Date?
    /// Sum of the outputs.
    let valueSat: Int64
    let feeSat: Int64
    let coinbase: Bool
    /// Empty for a coinbase.
    let inputs: [Row]
    let outputs: [Row]
    /// The signed tx as the indexer has it (for 重新广播); nil when it didn't send it.
    let hex: String?

    var confirmed: Bool { confirmations > 0 }

    /// Rows on `own` addresses first, each group in its original order.
    static func ownFirst(_ rows: [Row], own: Set<String>) -> [Row] {
        let mine = { (r: Row) in r.address.map(own.contains) ?? false }
        return rows.filter(mine) + rows.filter { !mine($0) }
    }

    /// What the tx did to `own` addresses (their outputs minus their inputs), in sat; nil
    /// when it touches none of them.
    func net(for own: Set<String>) -> Int64? {
        let mine = { (r: Row) in r.address.map(own.contains) ?? false }
        guard inputs.contains(where: mine) || outputs.contains(where: mine) else { return nil }
        return outputs.filter(mine).reduce(0) { $0 + $1.sat } - inputs.filter(mine).reduce(0) { $0 + $1.sat }
    }

    /// A txid typed or pasted as-is (any case, spaces around it), or inside an explorer link
    /// such as https://blockbook.pearlresearch.ai/tx/<txid>. nil when there is none.
    static func parseTxid(_ input: String) -> String? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // ASCII only: Character.isHexDigit would also take fullwidth digits.
        if s.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil { return s.lowercased() }
        guard let r = s.range(of: #"/tx/[0-9a-fA-F]{64}(?![0-9A-Za-z])"#, options: .regularExpression) else { return nil }
        return String(s[r].dropFirst(4)).lowercased()
    }

    /// The official explorer's page for `txid`.
    static func explorerURL(txid: String, network: WalletNetwork) -> URL {
        let base = network == .mainnet ? BlockbookClient.officialMainnet : BlockbookClient.officialTestnet
        return URL(string: "\(base)/tx/\(txid)")!
    }

    // MARK: Blockbook's /api/v2/tx/<txid>

    private struct Wire: Decodable {
        struct IO: Decodable {
            let addresses: [String]?
            let isAddress: Bool?
            let value: String?
            let hex: String?
            let coinbase: String?
        }
        let txid: String
        let vin: [IO]
        let vout: [IO]
        let blockHeight: Int?
        let confirmations: Int?
        let blockTime: Int?
        let value: String?
        let fees: String?
        let hex: String?
    }

    /// Blockbook's JSON for `txid`; nil when it isn't that transaction.
    static func parse(_ data: Data, txid: String) -> TxDetail? {
        guard let w = try? JSONDecoder().decode(Wire.self, from: data), w.txid.lowercased() == txid else { return nil }
        func sat(_ s: String?) -> Int64 { s.flatMap { Int64($0) } ?? 0 }
        func row(_ io: Wire.IO) -> Row {
            let addrs = io.addresses ?? []
            let address = io.isAddress != false && addrs.count == 1 ? addrs[0] : nil
            // An output script starting with OP_RETURN (0x6a) carries data, not coins.
            return Row(address: address, sat: sat(io.value), isData: address == nil && (io.hex?.hasPrefix("6a") ?? false))
        }
        let confirmations = max(0, w.confirmations ?? 0)
        let coinbase = w.vin.contains { $0.coinbase != nil }
        let outputs = w.vout.map(row)
        return TxDetail(
            txid: txid,
            confirmations: confirmations,
            // A mempool tx has no block yet (Blockbook reports height -1 or 0).
            height: confirmations > 0 ? w.blockHeight.flatMap { $0 > 0 ? $0 : nil } : nil,
            time: w.blockTime.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
            valueSat: w.value.map { sat($0) } ?? outputs.reduce(0) { $0 + $1.sat },
            feeSat: sat(w.fees),
            coinbase: coinbase,
            inputs: coinbase ? [] : w.vin.map(row),
            outputs: outputs,
            hex: w.hex.flatMap { $0.isEmpty ? nil : $0.lowercased() })
    }

    /// The copy to show of the ones the indexers returned: the furthest along (on 2026-10-20
    /// the official indexer showed a mined tx as unconfirmed for hours while its own block
    /// listed it); on a tie the first, ours.
    static func best(_ copies: [TxDetail]) -> TxDetail? {
        copies.enumerated().max { a, b in
            a.element.confirmations != b.element.confirmations
                ? a.element.confirmations < b.element.confirmations
                : a.offset > b.offset
        }?.element
    }
}

extension BlockbookClient {
    enum TxDetailLookup: Sendable, Equatable {
        case found(TxDetail)
        /// An indexer said it doesn't know the txid and none had it.
        case notFound
        /// No indexer gave a usable answer.
        case failed
    }

    /// One indexer's answer for a txid.
    enum TxCopy: Sendable { case found(TxDetail), missing, unknown }

    /// The answers of all indexers (in order of preference) → what to show.
    static func outcome(_ copies: [TxCopy]) -> TxDetailLookup {
        let found = copies.compactMap { c -> TxDetail? in if case .found(let t) = c { return t }; return nil }
        if let best = TxDetail.best(found) { return .found(best) }
        return copies.contains { if case .missing = $0 { return true }; return false } ? .notFound : .failed
    }

    /// `txid` from every indexer at once (see `TxDetail.best`). Not found when one of them
    /// says so and none has it — ours answers 503 while it catches up, which says nothing.
    func transactionDetail(txid: String) async -> TxDetailLookup {
        let copies = await withTaskGroup(of: (Int, TxCopy).self) { group in
            for (i, b) in allBases.enumerated() {
                group.addTask { (i, await txCopy(b, txid: txid)) }
            }
            var out: [(Int, TxCopy)] = []
            for await c in group { out.append(c) }
            return out.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return Self.outcome(copies)
    }

    private func txCopy(_ base: String, txid: String) async -> TxCopy {
        guard let url = URL(string: base + "/api/v2/tx/\(txid)") else { return .unknown }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.authorize(&req)
        guard let (data, resp) = try? await session.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return .unknown }
        if code == 200 { return TxDetail.parse(data, txid: txid).map(TxCopy.found) ?? .unknown }
        // Blockbook answers an unknown txid with 400 {"error":"Transaction '…' not found"}.
        guard code == 400 || code == 404 else { return .unknown }
        return String(decoding: data.prefix(4096), as: UTF8.self).localizedCaseInsensitiveContains("not found") ? .missing : .unknown
    }
}
