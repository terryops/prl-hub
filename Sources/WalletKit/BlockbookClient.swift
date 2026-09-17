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
        let balance: String
        let unconfirmedBalance: String?
        let txs: Int?
        let transactions: [Tx]?
        let tokens: [Token]?
    }
    private struct Token: Decodable { let name: String? }
    private struct Tx: Decodable {
        let txid: String
        let blockTime: Int?
        let confirmations: Int?
        let fees: String?
        let vin: [IO]?
        let vout: [IO]?
    }
    private struct IO: Decodable { let addresses: [String]?; let value: String? }

    struct UTXO: Decodable {
        let txid: String
        let vout: Int
        let value: String
        let address: String?
        let confirmations: Int?
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
    func balance(xpub: String) async throws -> WalletBalance {
        let r = try await get("/api/v2/xpub/\(xpub)?details=basic", as: XpubResponse.self)
        let confirmed = BlockbookClient.prl(r.balance)
        // Blockbook's unconfirmedBalance is NEGATIVE while an outgoing tx sits in
        // the mempool. Fold the full delta into `total`, but subtract any pending
        // OUTFLOW from `available` so the send guard / MAX can't offer coins that
        // are already committed to an unconfirmed spend.
        let unconfirmed = BlockbookClient.prl(r.unconfirmedBalance)
        let available = max(0, confirmed + min(0, unconfirmed))
        return WalletBalance(total: confirmed + unconfirmed, available: available)
    }

    /// `knownChange` are internal-chain change addresses the xpub token list doesn't
    /// recognise as ours (the stranded-change set). Folding them into `mine` stops the
    /// displayed "sent" amount from counting our own change as money paid to others.
    func history(xpub: String, page: Int = 1, pageSize: Int = 25, knownChange: Set<String> = []) async throws -> [WalletTx] {
        let r = try await get("/api/v2/xpub/\(xpub)?details=txs&tokens=used&page=\(page)&pageSize=\(pageSize)", as: XpubResponse.self)
        var mine = Set((r.tokens ?? []).compactMap { $0.name })
        mine.formUnion(knownChange)
        return Self.mapTxs(r.transactions ?? [], mine: mine)
    }

    /// History of a SINGLE internal-chain change address. A send funded entirely by
    /// such change touches no xpub-derived address, so the `/xpub/` history above can
    /// NEVER report it — this per-address form is the only way to see those spends.
    /// `mine` is the owned-change set (for direction/amounts). Also returns every
    /// output address in these txs that isn't in `mine`: candidate change of an
    /// internal-chain spend, equally invisible to `changeCandidates`' xpub scan.
    func history(address: String, mine: Set<String>) async throws -> (txs: [WalletTx], outAddrs: Set<String>) {
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
        var outs = Set<String>()
        for tx in raw {
            for o in tx.vout ?? [] {
                for a in (o.addresses ?? []) where !mine.contains(a) { outs.insert(a) }
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
            return WalletTx(txid: tx.txid, direction: sent ? .sent : .received, amount: amount,
                            fee: BlockbookClient.prl(tx.fees), confirmations: tx.confirmations ?? 0,
                            time: time, address: addr)
        }
    }

    func utxos(xpub: String) async throws -> [UTXO] {
        // Spend only CONFIRMED UTXOs (≥1 conf): never chain a send off an unconfirmed
        // parent (which RBF/eviction could invalidate), and keep the spendable set
        // consistent with the confirmed `available` balance.
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
    func changeCandidates(xpub: String, extra: Set<String> = []) async throws -> [String] {
        let r = try await get("/api/v2/xpub/\(xpub)?details=txs&tokens=used&pageSize=1000", as: XpubResponse.self)
        let mine = Set((r.tokens ?? []).compactMap { $0.name })
        var candidates = Set<String>()
        for tx in r.transactions ?? [] {
            let weSpent = (tx.vin ?? []).contains { io in (io.addresses ?? []).contains { mine.contains($0) } }
            guard weSpent else { continue }
            for o in tx.vout ?? [] {
                for a in (o.addresses ?? []) where !mine.contains(a) { candidates.insert(a) }
            }
        }
        for a in extra where !mine.contains(a) { candidates.insert(a) }
        return Array(candidates)
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

    /// Broadcast a raw signed tx; returns the txid.
    func broadcast(_ hex: String) async throws -> String {
        struct R: Decodable { let result: String? }
        struct E: Decodable { let error: String? }
        var req = URLRequest(url: URL(string: base + "/api/v2/sendtx/")!)
        req.httpMethod = "POST"
        req.httpBody = Data(hex.utf8)
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(R.self, from: data), let txid = r.result else {
            let msg = (try? JSONDecoder().decode(E.self, from: data))?.error ?? (String(data: data, encoding: .utf8) ?? "broadcast failed")
            throw NSError(domain: "Blockbook", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return txid
    }
}
