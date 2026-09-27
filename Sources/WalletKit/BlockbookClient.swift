import Foundation

/// Read/broadcast chain backend: the public Blockbook indexer (HTTPS → ATS-ok).
/// Uses the account **xpub** so balance / history / UTXOs aggregate across every
/// derived taproot address (verified: Blockbook derives `m/86'/808276'/0'/…` for
/// Pearl). Broadcast posts the on-device-signed tx.
struct BlockbookClient {
    static let decimals = 8

    let base: String
    init(network: WalletNetwork) {
        base = network == .mainnet
            ? "https://blockbook.pearlresearch.ai"
            : "https://blockbook.testnet.pearlresearch.ai"
    }

    // MARK: wire types
    private struct XpubResponse: Decodable {
        let balance: String?
        let unconfirmedBalance: String?
        let txs: Int?              // tx COUNT (the list is `transactions`)
        let unconfirmedTxs: Int?
        let page: Int?
        let totalPages: Int?
        let transactions: [Tx]?
        let tokens: [Token]?
    }
    private struct Token: Decodable { let name: String? }
    private struct Tx: Decodable {
        let txid: String
        let blockTime: Int?
        let blockHeight: Int?
        let confirmations: Int?
        let fees: String?
        let vin: [IO]?
        let vout: [IO]?
    }
    private struct IO: Decodable { let addresses: [String]?; let value: String? }

    struct UTXO: Decodable, Equatable, Sendable {
        let txid: String
        let vout: Int
        let value: String
        let address: String?
        let confirmations: Int?
        var outpoint: String { "\(txid):\(vout)" }
    }

    /// One `/xpub/` round-trip: balance, a page of history and the xpub's own addresses.
    /// The xpub's balance and tx counts, without any transactions.
    struct XpubSummary: Sendable, Equatable {
        let confirmed: Decimal
        /// Net mempool delta — NEGATIVE while an outgoing tx is unconfirmed.
        let unconfirmed: Decimal
        let txCount: Int
        let unconfirmedTxs: Int
    }

    struct XpubAccount: Sendable {
        let confirmed: Decimal
        /// Net mempool delta — NEGATIVE while an outgoing tx is unconfirmed.
        let unconfirmed: Decimal
        let txs: [WalletTx]
        /// Every address Blockbook derived and saw used under this xpub (both chains).
        let addresses: Set<String>
        let hasMorePages: Bool
    }

    /// Output addresses of txs we spent from that the xpub doesn't list as its own,
    /// newest first — candidate stranded change (see `changeCandidates`).
    struct ChangeCandidates: Sendable {
        struct Candidate: Sendable, Equatable {
            let address: String
            /// The creating tx has ≥1 confirmation, so an EMPTY utxo set on this address
            /// is final (spent), not merely "change still unconfirmed".
            let confirmed: Bool
        }
        let candidates: [Candidate]
        /// Highest block among the scanned confirmed sends (the incremental-scan watermark:
        /// every send at or below it has been looked at).
        let maxHeight: Int?
    }

    enum TxLookup: Sendable { case found, notFound, unknown }

    enum BroadcastError: LocalizedError {
        /// The node answered and refused the tx — nothing was relayed.
        case rejected(String)
        /// No usable answer (timeout, dropped connection, proxy error page…). The tx may
        /// or may not have reached the node.
        case transport(String)
        var errorDescription: String? {
            switch self {
            case .rejected(let m), .transport(let m): return m
            }
        }
    }

    // MARK: helpers
    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private static func prl(_ s: String?) -> Decimal {
        guard let s, let v = Decimal(string: s) else { return 0 }
        return v / pow(Decimal(10), decimals)
    }
    private static func prlSum(_ values: [String?]) -> Decimal {
        let u = values.compactMap { $0 }.reduce(Decimal(0)) { $0 + (Decimal(string: $1) ?? 0) }
        return u / pow(Decimal(10), decimals)
    }

    // MARK: queries (by xpub)

    /// Balance + tx counts only (`details=basic`): a few hundred bytes, back in under a
    /// second. A history page is another matter — pool payouts carry hundreds of outputs,
    /// so one page of 25 measured 9 MB / 3.6 s — so the wallet shows this first and only
    /// re-reads the page when these numbers move.
    func summary(xpub: String) async throws -> XpubSummary {
        let r = try await get("/api/v2/xpub/\(xpub)?details=basic", as: XpubResponse.self)
        guard let balance = r.balance else { throw URLError(.cannotParseResponse) }
        return XpubSummary(confirmed: Self.prl(balance), unconfirmed: Self.prl(r.unconfirmedBalance),
                           txCount: r.txs ?? 0, unconfirmedTxs: r.unconfirmedTxs ?? 0)
    }

    /// Balance + one history page in a single request, so the two can never straddle an
    /// index update (balance from before a send, history already containing it). Pages
    /// of 10: the dashboard shows 3, and 交易记录 pages on with 加载更多 — each page of
    /// payouts is megabytes.
    /// `knownChange` are internal-chain change addresses the xpub token list doesn't
    /// recognise as ours (the stranded-change set). Folding them into `mine` stops the
    /// displayed "sent" amount from counting our own change as money paid to others.
    func account(xpub: String, page: Int = 1, pageSize: Int = 10, knownChange: Set<String> = []) async throws -> XpubAccount {
        let r = try await get("/api/v2/xpub/\(xpub)?details=txs&tokens=used&page=\(page)&pageSize=\(pageSize)", as: XpubResponse.self)
        guard let balance = r.balance else { throw URLError(.cannotParseResponse) }
        let addresses = Set((r.tokens ?? []).compactMap { $0.name })
        return XpubAccount(confirmed: Self.prl(balance),
                           unconfirmed: Self.prl(r.unconfirmedBalance),
                           txs: Self.mapTxs(r.transactions ?? [], mine: addresses.union(knownChange)),
                           addresses: addresses,
                           hasMorePages: (r.page ?? 1) < (r.totalPages ?? 1))
    }

    /// History of a SINGLE internal-chain change address. A send funded entirely by
    /// such change touches no xpub-derived address, so the `/xpub/` history above can
    /// NEVER report it — this per-address form is the only way to see those spends.
    /// `mine` is every address known to be ours (for direction/amounts). Also returns every
    /// output address in these txs that isn't in `mine`: candidate change of an
    /// internal-chain spend, equally invisible to `changeCandidates`' xpub scan.
    func history(address: String, mine: Set<String>) async throws -> (txs: [WalletTx], outAddrs: [String]) {
        let r = try await get("/api/v2/address/\(address)?details=txs&pageSize=50", as: XpubResponse.self)
        // Keep ONLY txs that SPENT from this change address (it appears in a vin). The
        // tx that CREATED the change address (this address is only an OUTPUT) is a past
        // outgoing send whose inputs are xpub-derived addresses NOT in `mine` — mapTxs
        // would classify it `.received` and merge it as a phantom incoming "+change PRL"
        // transaction that never happened. Such creating txs are already covered by the
        // xpub scan / changeCandidates, so dropping them here loses nothing.
        let raw = (r.transactions ?? []).filter { tx in
            (tx.vin ?? []).contains { ($0.addresses ?? []).contains(address) }
        }
        var outs: [String] = []
        for tx in raw {
            for o in tx.vout ?? [] {
                for a in (o.addresses ?? []) where !mine.contains(a) && !outs.contains(a) { outs.append(a) }
            }
        }
        return (Self.mapTxs(raw, mine: mine), outs)
    }

    /// Shared wire→model mapping for both history forms. `mine` is every address
    /// known to be ours in the caller's context.
    private static func mapTxs(_ txs: [Tx], mine: Set<String>) -> [WalletTx] {
        func isMine(_ io: IO) -> Bool { (io.addresses ?? []).contains { mine.contains($0) } }
        // Best-effort counterparty: the LARGEST output (the destination usually
        // dwarfs the change), not just the first in arbitrary vout order.
        func largestAddr(_ ios: [IO]) -> String {
            ios.max { (Decimal(string: $0.value ?? "0") ?? 0) < (Decimal(string: $1.value ?? "0") ?? 0) }?
                .addresses?.first ?? ""
        }
        return txs.map { tx in
            let sent = (tx.vin ?? []).contains(where: isMine)
            let mineOuts = (tx.vout ?? []).filter(isMine)
            let otherOuts = (tx.vout ?? []).filter { !isMine($0) }
            let amount = sent ? BlockbookClient.prlSum(otherOuts.map { $0.value })
                              : BlockbookClient.prlSum(mineOuts.map { $0.value })
            // sent → the largest external (non-change) output as the destination;
            // a pure self-send has no external output, so leave it blank instead of
            // showing one of our own addresses. received → the address of ours that got it.
            let addr = sent ? largestAddr(otherOuts) : largestAddr(mineOuts)
            let time = tx.blockTime.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil } ?? Date()
            let confirmations = tx.confirmations ?? 0
            return WalletTx(txid: tx.txid, direction: sent ? .sent : .received, amount: amount,
                            fee: BlockbookClient.prl(tx.fees), confirmations: confirmations,
                            time: time, address: addr,
                            height: confirmations > 0 ? tx.blockHeight.flatMap { $0 > 0 ? $0 : nil } : nil)
        }
    }

    func utxos(xpub: String) async throws -> [UTXO] {
        // Spend only CONFIRMED UTXOs (≥1 conf): never chain a send off an unconfirmed
        // parent (which RBF/eviction could invalidate), and keep the spendable set
        // consistent with the confirmed `available` balance. Blockbook already drops
        // outputs spent by a mempool tx.
        let all = try await get("/api/v2/utxo/\(xpub)", as: [UTXO].self)
        return all.filter { ($0.confirmations ?? 0) >= 1 }
    }

    /// Confirmed UTXOs on a SINGLE address. The `/utxo/{address}` form omits the
    /// `address` field in each item, so the caller supplies it when spending.
    /// Used by stranded-change recovery (those addresses aren't in the xpub scan).
    func utxos(address: String) async throws -> [UTXO] {
        let all = try await get("/api/v2/utxo/\(address)", as: [UTXO].self)
        return all.filter { ($0.confirmations ?? 0) >= 1 }
    }

    /// Output addresses that received funds in a tx WE spent from, yet the xpub
    /// scan doesn't recognise as ours — i.e. candidate stranded-change addresses
    /// (mixed with genuine external recipients; ownership is settled afterwards by
    /// trying to sign). This is how we rediscover change the xpub scan can't see.
    /// `extra` are caller-supplied candidates (outputs of internal-chain spends the
    /// xpub history can't show); they're filtered against the xpub's own token set
    /// here so an external receive address can never be mis-offered as change.
    /// `fromHeight` limits the scan to txs mined at or after that block (the incremental
    /// scan); nil scans the whole history.
    ///
    /// `filter=inputs`: only txs spending from this xpub — the only ones that can hold
    /// our change. A mining wallet's history is almost all pool payouts of ~1000 outputs
    /// (~350 KB each): unfiltered, a 2,276-tx wallet made this a ~370 MB read that timed
    /// out and was retried on every load; filtered it was 24 txs / 0.5 MB. The token
    /// list (our addresses) is unaffected by the filter.
    func changeCandidates(xpub: String, fromHeight: Int?, extra: [String] = []) async throws -> ChangeCandidates {
        let from = fromHeight.map { "&from=\($0)" } ?? ""
        let r = try await get("/api/v2/xpub/\(xpub)?details=txs&tokens=used&filter=inputs&pageSize=1000\(from)", as: XpubResponse.self)
        let mine = Set((r.tokens ?? []).compactMap { $0.name })
        let txs = r.transactions ?? []
        // Without the xpub's own addresses every receive address would look like change and
        // get trial-signed as "ours" — double counting it. Refuse rather than guess (a
        // brand-new wallet has neither, and nothing to scan).
        guard !mine.isEmpty || (txs.isEmpty && extra.isEmpty) else { throw URLError(.cannotParseResponse) }
        var seen = Set<String>()
        var candidates: [ChangeCandidates.Candidate] = []
        for a in extra where !mine.contains(a) && seen.insert(a).inserted {
            candidates.append(.init(address: a, confirmed: false))
        }
        var maxHeight: Int?
        for tx in txs {     // newest first
            let confirmed = (tx.confirmations ?? 0) >= 1
            if confirmed, let h = tx.blockHeight, h > 0 { maxHeight = max(maxHeight ?? h, h) }
            let weSpent = (tx.vin ?? []).contains { io in (io.addresses ?? []).contains { mine.contains($0) } }
            guard weSpent else { continue }
            for o in tx.vout ?? [] {
                for a in (o.addresses ?? []) where !mine.contains(a) && seen.insert(a).inserted {
                    candidates.append(.init(address: a, confirmed: confirmed))
                }
            }
        }
        return ChangeCandidates(candidates: candidates, maxHeight: maxHeight)
    }

    /// Recommended fee in sat per 1000 vbytes (Blockbook returns PRL/kB).
    func estimateFeePerKB() async throws -> Int64 {
        struct R: Decodable { let result: String }
        let r = try await get("/api/v1/estimatefee/2", as: R.self)
        // A non-positive value (incl. the node's "-1" can't-estimate sentinel) → a sane default.
        let parsed = Decimal(string: r.result) ?? -1
        let prlPerKB = parsed > 0 ? parsed : Decimal(string: "0.0005")!
        let satPerKB = (prlPerKB * pow(Decimal(10), BlockbookClient.decimals)) as NSDecimalNumber
        // Floor ~1 sat/vB; ceiling guards against an absurd backend value inflating the fee
        // reservation (and overflowing the Double→Int64 fee math downstream).
        return min(10_000_000, max(1000, satPerKB.int64Value))
    }

    /// Whether the indexer / node knows this tx (mempool or chain). `.unknown` when the
    /// question itself couldn't be answered.
    func lookup(txid: String) async -> TxLookup {
        guard let url = URL(string: base + "/api/v2/tx/\(txid)") else { return .unknown }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return .unknown }
        if code == 200 { return .found }
        // Blockbook: 400 {"error":"Transaction '…' not found"}
        let body = String(data: data, encoding: .utf8) ?? ""
        return body.localizedCaseInsensitiveContains("not found") ? .notFound : .unknown
    }

    /// Broadcast a raw signed tx; returns the txid. Throws `BroadcastError`.
    func broadcast(_ hex: String) async throws -> String {
        struct R: Decodable { let result: String? }
        struct E: Decodable { let error: String? }
        var req = URLRequest(url: URL(string: base + "/api/v2/sendtx/")!)
        req.httpMethod = "POST"
        req.httpBody = Data(hex.utf8)
        req.timeoutInterval = 30
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw BroadcastError.transport(error.localizedDescription) }
        if (resp as? HTTPURLResponse)?.statusCode == 200,
           let r = try? JSONDecoder().decode(R.self, from: data), let txid = r.result {
            return txid
        }
        // Only a JSON error from Blockbook is the node's verdict; anything else (a proxy's
        // HTML page, an empty 502) says nothing about whether the tx got through.
        if let msg = (try? JSONDecoder().decode(E.self, from: data))?.error, !msg.isEmpty {
            throw BroadcastError.rejected(msg)
        }
        throw BroadcastError.transport(String(data: data, encoding: .utf8).map { String($0.prefix(160)) } ?? "broadcast failed")
    }

    /// A rejection that only says the node already has this tx (a retry of a broadcast
    /// whose first response was lost) — i.e. the send DID go out.
    static func isAlreadyKnown(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("already have") || m.contains("already exists")
            || m.contains("already in block chain") || m.contains("txn-already")
    }
}
