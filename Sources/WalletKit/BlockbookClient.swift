import Foundation

/// Read/broadcast chain backend: Blockbook indexers (HTTPS → ATS-ok).
/// Uses the account **xpub** so balance / history / UTXOs aggregate across every
/// derived taproot address (verified: Blockbook derives `m/86'/808276'/0'/…` for
/// Pearl). Broadcast posts the on-device-signed tx.
///
/// Mainnet has two: Pearl Hub's own (node.pearlhub.net — refuses reads with a 503 while it
/// lags) and the official one. Reads try them in order; a broadcast and a tx lookup go to
/// both. On 2026-10-20 the official indexer kept showing a block's txs as unconfirmed for
/// hours, which no "is it reachable" failover could catch — hence a second, independent index.
/// One wallet refresh reads from one index only (`pinned(to:strict:)`), so its balance,
/// history and UTXOs can't come from two indexes that disagree.
struct BlockbookClient {
    static let decimals = 8
    static let ownMainnet = "https://node.pearlhub.net"
    static let officialMainnet = "https://blockbook.pearlresearch.ai"
    static let officialTestnet = "https://blockbook.testnet.pearlresearch.ai"

    /// Indexers reads try, in order of preference.
    let bases: [String]
    /// Every indexer of the network: broadcasts and tx lookups ask them all, pinned or not.
    let allBases: [String]
    /// The first choice (also the fee-cache key).
    var base: String { bases[0] }
    /// What every request goes through (a stub in tests).
    let session: URLSession
    init(network: WalletNetwork) {
        let list = network != .mainnet ? [Self.officialTestnet]
            : NodeAccess.enabled ? [Self.ownMainnet, Self.officialMainnet] : [Self.officialMainnet]
        self.init(bases: list, allBases: list, session: .shared)
    }
    /// Explicit indexers (tests).
    init(bases: [String], session: URLSession = .shared) { self.init(bases: bases, allBases: bases, session: session) }
    private init(bases: [String], allBases: [String], session: URLSession) {
        precondition(!bases.isEmpty)
        self.bases = bases
        self.allBases = allBases
        self.session = session
    }

    /// Reads from `base` first. `strict`: from it only — for the reads of one wallet refresh,
    /// which must not mix two indexes (a failed read then fails that refresh, and the next
    /// one starts over from whichever index answers). Otherwise the others stay the fallback.
    /// nil, or an indexer this network doesn't have, leaves the client as it is.
    func pinned(to base: String?, strict: Bool) -> BlockbookClient {
        guard let base, allBases.contains(base) else { return self }
        return BlockbookClient(bases: strict ? [base] : [base] + allBases.filter { $0 != base },
                               allBases: allBases, session: session)
    }

    /// Requests to our own indexer carry the app key; the gateway refuses anything else.
    static func authorize(_ req: inout URLRequest) {
        guard let url = req.url?.absoluteString, url.hasPrefix(ownMainnet + "/") else { return }
        req.setValue(NodeAccess.key, forHTTPHeaderField: NodeAccess.header)
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
        /// Refused before it reached any node (a gateway's key check, rate or size limit, an
        /// unknown path): certainly not relayed by this indexer.
        case notDelivered(String)
        var errorDescription: String? {
            switch self {
            case .rejected(let m), .transport(let m), .notDelivered(let m): return m
            }
        }
    }

    // MARK: helpers
    func get<T: Decodable>(_ path: String, as: T.Type, timeout: TimeInterval = 25) async throws -> T {
        try await get(path, timeout: timeout) { try JSONDecoder().decode(T.self, from: $0) }
    }

    /// GET `path` from the first indexer whose answer `parse` accepts; the others are the
    /// fallback. One in trouble (unreachable, 5xx, rate-limited, refusing the app key) goes to
    /// the back of the line for a while (`benchTime`). Not only the wallet's: the network chart
    /// and the pool cards' chain income read blocks and address history through here too, so
    /// the whole app sees the same chain. `session` lets the chart fetch its ~30 blocks over
    /// more connections.
    func get<T>(_ path: String, timeout: TimeInterval = 25, session: URLSession? = nil,
                parse: (Data) throws -> T) async throws -> T {
        try await fetch(path, timeout: timeout, session: session ?? self.session, parse: parse).value
    }

    /// `get`, and which indexer the answer came from.
    private func fetch<T>(_ path: String, timeout: TimeInterval, session: URLSession,
                          parse: (Data) throws -> T) async throws -> (value: T, base: String) {
        let order = await BackendHealth.shared.order(bases)
        var lastError: Error = URLError(.badServerResponse)
        for (i, b) in order.enumerated() {
            // Don't sit out the full timeout on a dead first choice when there's a fallback.
            let t = i < order.count - 1 ? min(timeout, 12) : timeout
            let data: Data
            do {
                data = try await getOnce(b + path, timeout: t, session: session)
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw error }
                if let bench = Self.benchTime(error) { await BackendHealth.shared.failed(b, for: bench) }
                lastError = error
                continue
            }
            // An answer `parse` can't use falls through to the next indexer, but never benches
            // this one: it answered, and whatever `parse` throws says nothing about its health.
            do { return (try parse(data), b) } catch { lastError = error }
        }
        throw lastError
    }

    private struct HTTPStatus: Error { let code: Int }

    private func getOnce(_ s: String, timeout: TimeInterval, session: URLSession) async throws -> Data {
        guard let url = URL(string: s) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.authorize(&req)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw HTTPStatus(code: code) }
        return data
    }

    /// How long to bench an indexer after `error`; nil when the error says nothing about the
    /// indexer's health. A timeout is a slow query, not a sick indexer: our gateway answers a
    /// 503 within seconds when our index is unhealthy, while a 5-year balance history or a
    /// 1000-tx change scan can simply take longer than the first choice's 12 s — benching for
    /// that would move the whole app to the other index. A refused app key (401/403) won't fix
    /// itself in a minute (an old build after a key rotation), so it sits out longer.
    static func benchTime(_ error: Error) -> TimeInterval? {
        if let h = error as? HTTPStatus {
            if h.code == 401 || h.code == 403 { return BackendHealth.keyRefusedBench }
            return h.code >= 500 || h.code == 429 || h.code == 0 ? BackendHealth.bench : nil
        }
        if let u = error as? URLError { return u.code == .timedOut ? nil : BackendHealth.bench }
        return nil
    }
    /// For tests.
    static func httpStatusError(_ code: Int) -> Error { HTTPStatus(code: code) }
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
        try await summaryFrom(xpub: xpub).summary
    }

    /// `summary`, and which indexer answered it — the one the rest of the refresh is pinned to.
    func summaryFrom(xpub: String) async throws -> (summary: XpubSummary, base: String) {
        let r = try await fetch("/api/v2/xpub/\(xpub)?details=basic", timeout: 25, session: session) { d in
            let r = try JSONDecoder().decode(XpubResponse.self, from: d)
            guard let balance = r.balance else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no balance")) }
            return XpubSummary(confirmed: Self.prl(balance), unconfirmed: Self.prl(r.unconfirmedBalance),
                               txCount: r.txs ?? 0, unconfirmedTxs: r.unconfirmedTxs ?? 0)
        }
        return (r.value, r.base)
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

    // MARK: fees (all rates in sat per 1000 vbytes)

    /// Floor ~1 sat/vB (the relay minimum); the ceiling guards against an absurd backend
    /// value inflating the fee (and overflowing the Double→Int64 fee math downstream).
    static let minFeePerKB: Int64 = 1_000
    static let maxFeePerKB: Int64 = 10_000_000
    /// Used when nothing at all could be learned about fees.
    static let fallbackFeePerKB: Int64 = 50_000

    /// The fee rate for a send. Never fails: missing data falls back step by step.
    /// Cached briefly so a MAX quote and the send right after it use the same rate.
    /// Concurrent callers (the send screen's prefetch and an early MAX tap) share one estimate;
    /// only one made from complete data is kept, so a moment offline can't pin the fallback rate.
    func estimateFeePerKB() async -> Int64 {
        await FeeRateCache.shared.rate(for: base) { [self] in
            async let fast = nodeFeeEstimate(blocks: 2)
            async let slow = nodeFeeEstimate(blocks: 6)
            async let medians = recentBlockMedianFees()
            let (f, sl, m) = await (fast, slow, medians)
            return (Self.chooseFeePerKB(fast: f, slow: sl, recentMedians: m), Self.feeDataComplete(fast: f, slow: sl, recentMedians: m))
        }
    }

    /// Whether a rate rests on everything `chooseFeePerKB` weighs: the 2-block estimate and
    /// something to cap it with. Anything less is used once but not cached.
    static func feeDataComplete(fast: Int64?, slow: Int64?, recentMedians: [Int64]) -> Bool {
        fast != nil && (slow != nil || !recentMedians.isEmpty)
    }

    /// The node's 2-block estimate is the default, but it can sit far above what blocks
    /// actually take: on 2026-10-20 the official node asked ~1 955 sat/vB while every recent
    /// block was including 1 sat/vB txs (its estimator was skewed by a mempool still holding
    /// txs mined hours earlier). So it's capped at the higher of the 6-block estimate and the
    /// median fee of recent blocks — real congestion raises both, a skewed estimator doesn't.
    static func chooseFeePerKB(fast: Int64?, slow: Int64?, recentMedians: [Int64]) -> Int64 {
        let cap = max(slow ?? 0, recentMedians.max() ?? 0)
        let rate: Int64
        if let fast { rate = cap > 0 ? min(fast, cap) : fast }
        else { rate = cap > 0 ? cap : fallbackFeePerKB }
        return min(maxFeePerKB, max(minFeePerKB, rate))
    }

    /// The node's estimate for confirming within `blocks` blocks (Blockbook returns PRL/kB);
    /// nil when the request fails or the node can't estimate (its "-1" sentinel).
    func nodeFeeEstimate(blocks: Int) async -> Int64? {
        struct R: Decodable { let result: String }
        guard let r = try? await get("/api/v1/estimatefee/\(blocks)", as: R.self, timeout: 10),
              let prlPerKB = Decimal(string: r.result), prlPerKB > 0 else { return nil }
        // Clamp before the Int64 conversion: 1 PRL/kB is already 10× the ceiling.
        let sat = (min(prlPerKB, 1) * pow(Decimal(10), BlockbookClient.decimals)) as NSDecimalNumber
        return sat.int64Value
    }

    /// Median fee rate of the txs in each of the last `count` blocks that had any besides the
    /// coinbase (`/feestats/` is ~150 bytes a block; the blocks themselves run to 600 kB).
    /// Empty when the tip or every block's stats couldn't be fetched.
    func recentBlockMedianFees(count: Int = 6) async -> [Int64] {
        struct Status: Decodable { struct BB: Decodable { let bestHeight: Int }; let blockbook: BB }
        struct FeeStats: Decodable { let txCount: Int; let decilesFeePerKb: [Int64] }
        guard let tip = (try? await get("/api/v2/", as: Status.self, timeout: 10))?.blockbook.bestHeight,
              tip > 0 else { return [] }
        return await withTaskGroup(of: Int64?.self) { group in
            for h in max(1, tip - count + 1)...tip {
                group.addTask {
                    guard let s = try? await get("/api/v2/feestats/\(h)", as: FeeStats.self, timeout: 10),
                          s.txCount > 0, s.decilesFeePerKb.count == 11 else { return nil }
                    let median = s.decilesFeePerKb[5]
                    return median > 0 ? median : nil
                }
            }
            var out: [Int64] = []
            for await m in group { if let m { out.append(m) } }
            return out
        }
    }

    /// Whether the indexer / node knows this tx (mempool or chain). `.unknown` when the
    /// question itself couldn't be answered.
    /// Asked of every indexer: found by any → found; "not found" only when all of them say so.
    func lookup(txid: String) async -> TxLookup {
        var allNotFound = true
        for b in allBases {
            switch await lookupOnce(b, txid: txid) {
            case .found: return .found
            case .notFound: continue
            case .unknown: allNotFound = false
            }
        }
        return allNotFound ? .notFound : .unknown
    }

    private func lookupOnce(_ base: String, txid: String) async -> TxLookup {
        guard let url = URL(string: base + "/api/v2/tx/\(txid)") else { return .unknown }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.authorize(&req)
        guard let (data, resp) = try? await session.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return .unknown }
        if code == 200 { return .found }
        // Blockbook: 400 {"error":"Transaction '…' not found"}
        let body = String(data: data, encoding: .utf8) ?? ""
        return body.localizedCaseInsensitiveContains("not found") ? .notFound : .unknown
    }

    /// Broadcast a raw signed tx to every indexer's node at once; returns the txid. Throws
    /// `BroadcastError`. Accepted by any → sent. Only when every node refused it is that a
    /// verdict; one refusing while another didn't answer stays "unknown" (the caller then
    /// looks the tx up) — a policy difference between node versions must not turn a tx the
    /// other node may have relayed into a "failed, try again".
    /// Returns as soon as one node has the tx (accepted, or "already have it"); the request to
    /// the other keeps going in the background, so a stuck indexer doesn't hold up the send.
    func broadcast(_ hex: String) async throws -> String {
        let (stream, sink) = AsyncStream.makeStream(of: (Int, Result<String, BroadcastError>).self)
        for (i, b) in allBases.enumerated() {
            Task {
                let r: Result<String, BroadcastError>
                do { r = .success(try await broadcastOnce(b, hex: hex)) }
                catch let e as BroadcastError { r = .failure(e) }
                catch { r = .failure(.transport(error.localizedDescription)) }
                sink.yield((i, r))
            }
        }
        var results = [Result<String, BroadcastError>?](repeating: nil, count: allBases.count)
        var answered = 0
        for await (i, r) in stream {
            results[i] = r
            answered += 1
            if Self.wentOut(r) || answered == allBases.count { break }
        }
        sink.finish()
        return try Self.combine(results.compactMap { $0 })
    }

    /// A node has the tx: it accepted it, or already had it.
    static func wentOut(_ r: Result<String, BroadcastError>) -> Bool {
        switch r {
        case .success: return true
        case .failure(.rejected(let m)): return isAlreadyKnown(m)
        case .failure: return false
        }
    }

    /// See `broadcast`. Results in order of preference. A request refused before it reached a
    /// node (`notDelivered`) says nothing about the tx, so the verdict rests on the others: one
    /// node's refusal stands when the other never saw the tx, and when no node saw it at all,
    /// it certainly didn't go out.
    static func combine(_ results: [Result<String, BroadcastError>]) throws -> String {
        var errors: [BroadcastError] = []
        for r in results {
            switch r {
            case .success(let txid): return txid
            case .failure(let e): errors.append(e)
            }
        }
        let detail = errors.map { $0.localizedDescription }.filter { !$0.isEmpty }.joined(separator: " / ")
        let reached = errors.filter { if case .notDelivered = $0 { return false }; return true }
        let messages = reached.map { e -> String in if case .rejected(let m) = e { return m }; return "" }
        if let known = messages.first(where: isAlreadyKnown) { throw BroadcastError.rejected(known) }
        if reached.isEmpty, !errors.isEmpty { throw BroadcastError.notDelivered(detail) }
        if !reached.isEmpty, messages.allSatisfy(isVerdict) { throw BroadcastError.rejected(messages[0]) }
        throw BroadcastError.transport(detail.isEmpty ? "broadcast failed" : detail)
    }

    /// Statuses meaning the request was turned away before any node saw it.
    static let refusedBeforeNode: Set<Int> = [401, 403, 404, 413, 429]

    /// A node's own verdict on a tx ("-26: …", "-25: …") — as opposed to a gateway's or
    /// proxy's complaint, which says nothing about the tx.
    static func isVerdict(_ message: String) -> Bool {
        message.range(of: #"^-\d+:"#, options: .regularExpression) != nil
    }

    private func broadcastOnce(_ base: String, hex: String) async throws -> String {
        struct R: Decodable { let result: String? }
        struct E: Decodable { let error: String? }
        var req = URLRequest(url: URL(string: base + "/api/v2/sendtx/")!)
        req.httpMethod = "POST"
        req.httpBody = Data(hex.utf8)
        req.timeoutInterval = 30
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        Self.authorize(&req)
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw BroadcastError.transport(error.localizedDescription) }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200, let r = try? JSONDecoder().decode(R.self, from: data), let txid = r.result {
            return txid
        }
        if Self.refusedBeforeNode.contains(code) {
            let msg = (try? JSONDecoder().decode(E.self, from: data))?.error ?? ""
            throw BroadcastError.notDelivered(msg.isEmpty ? "HTTP \(code)" : "\(msg) (HTTP \(code))")
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

/// The last fee rate per backend, kept for a couple of minutes: tapping MAX and then sending
/// reuse one rate, so the amount MAX filled in is what the confirmation shows. Callers asking
/// while an estimate is being made wait for that one instead of starting their own.
actor FeeRateCache {
    static let shared = FeeRateCache()
    static let lifetime: TimeInterval = 120
    private var entries: [String: (rate: Int64, at: Date)] = [:]
    private var inflight: [String: Task<(rate: Int64, keep: Bool), Never>] = [:]

    /// The cached rate for `key`, or `compute`'s — kept only when it says `keep`.
    func rate(for key: String, compute: @escaping @Sendable () async -> (rate: Int64, keep: Bool)) async -> Int64 {
        if let e = entries[key], Date().timeIntervalSince(e.at) < Self.lifetime { return e.rate }
        if let running = inflight[key] { return await running.value.rate }
        let task = Task { await compute() }
        inflight[key] = task
        let r = await task.value
        inflight[key] = nil
        if r.keep { entries[key] = (r.rate, Date()) }
        return r.rate
    }
}

/// Indexers that just failed, benched for a while so reads don't keep waiting on them.
actor BackendHealth {
    static let shared = BackendHealth()
    static let bench: TimeInterval = 60
    /// After the indexer refused the app key.
    static let keyRefusedBench: TimeInterval = 600
    private var benchedUntil: [String: Date] = [:]

    /// `bases` with any benched ones moved to the end (never dropped — they're still a fallback).
    func order(_ bases: [String]) -> [String] {
        let now = Date()
        let benched = Set(bases.filter { b in benchedUntil[b].map { $0 > now } ?? false })
        return bases.filter { !benched.contains($0) } + bases.filter { benched.contains($0) }
    }
    func failed(_ base: String, for duration: TimeInterval = BackendHealth.bench) {
        benchedUntil[base] = Date().addingTimeInterval(duration)
    }
}
