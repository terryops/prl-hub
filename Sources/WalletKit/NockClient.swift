import Foundation

/// The Nockchain public gRPC API over gRPC-web (plain HTTPS POSTs, so URLSession is enough).
/// Messages are encoded and decoded by the Rust core; this type frames them and reads the
/// gRPC status the server puts in the trailer frame.
///
/// Two public nodes, both straight from the app (no Pearl Hub server in between):
/// - rpc.nockbox.org — Iris Wallet's node, HTTPS. First choice.
/// - 216.158.95.10:5556 — the node the official `nockchain-wallet` CLI uses by default
///   (crates/nockchain-wallet/src/connection.rs). Plain HTTP on a bare IP, allowed for this one
///   address in AccountInfo.plist (ATS covers IP addresses since iOS 17). Everything sent there
///   is public chain data or an already-signed tx, so a tampered reply can't redirect funds.
/// A node that fails (unreachable, 5xx, its gateway's "upstream connect error") moves to the
/// back of the line for a while — the same `BackendHealth` the PRL indexers use. Measured
/// 2026-10-21: rpc.nockbox.org's "upstream connect error" follows the client's IP (one exit
/// always got it while another never did), so a failed node sits out longer than a minute.
struct NockClient {
    static let nodes: [URL] = [
        URL(string: "https://rpc.nockbox.org")!,
        URL(string: "http://216.158.95.10:5556")!,
    ]
    /// Block explorer for "view on explorer" links.
    static func explorerURL(tx txId: String) -> URL? { URL(string: "https://nockscan.net/tx/\(txId)") }
    static func explorerURL(address: String) -> URL? { URL(string: "https://nockscan.net/address/\(address)") }

    /// How long a node that failed sits at the back of the line.
    static let bench: TimeInterval = 5 * 60

    let session: URLSession
    let nodes: [URL]
    init(session: URLSession = .shared, nodes: [URL] = NockClient.nodes) {
        self.session = session
        self.nodes = nodes
    }

    enum RPCError: LocalizedError {
        case http(Int)
        /// A non-OK gRPC status (code, message).
        case status(Int, String)
        case transport(String)
        case malformed

        var errorDescription: String? {
            switch self {
            case .http(let code): return Loc("Nockchain 节点暂时不可用（HTTP %@）", "\(code)")
            case .status(_, let m): return Loc("Nockchain 节点返回错误：%@", m)
            case .transport(let m): return Loc("无法连接 Nockchain 节点：%@", m)
            case .malformed: return Loc("Nockchain 节点返回的数据无法解析")
            }
        }
    }

    // MARK: Transport

    /// POST one unary gRPC-web call to `node`; returns the response message bytes.
    func unary(_ method: String, _ message: Data, node: URL, timeout: TimeInterval = 20) async throws -> Data {
        var req = URLRequest(url: node.appendingPathComponent(method))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        req.setValue("application/grpc-web+proto", forHTTPHeaderField: "Accept")
        req.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        var framed = Data([0])
        var len = UInt32(message.count).bigEndian
        framed.append(Data(bytes: &len, count: 4))
        framed.append(message)
        req.httpBody = framed

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw RPCError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw RPCError.malformed }
        // Trailers-only replies (an error before any message) put the status in the headers.
        if let s = http.value(forHTTPHeaderField: "grpc-status"), let code = Int(s), code != 0 {
            // 14 UNAVAILABLE: the node's gateway couldn't reach the node ("upstream connect error").
            if code == 14 { throw RPCError.http(503) }
            throw RPCError.status(code, Self.decodeMessage(http.value(forHTTPHeaderField: "grpc-message")))
        }
        guard http.statusCode == 200 else { throw RPCError.http(http.statusCode) }
        return try Self.parseFrames(data)
    }

    /// Worth trying again shortly: the node or the path to it hiccuped (not a verdict).
    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case RPCError.transport: return true
        case RPCError.http(let code): return code == 429 || code >= 500
        case RPCError.status(let code, _): return code == 14 || code == 4   // UNAVAILABLE, DEADLINE_EXCEEDED
        default: return false
        }
    }

    /// Runs `body` against one node at a time, healthiest first, until one gets through. A
    /// transient failure benches that node and moves on to the next; any other error is that
    /// node's answer and ends it. When every node failed, one more round after a short pause.
    /// `body` gets the per-request timeout: shorter while another node is still left to try.
    func withNode<T>(_ body: (URL, TimeInterval) async throws -> T) async throws -> T {
        var lastError: Error = RPCError.malformed
        for round in 0..<2 {
            if round > 0 {
                try await Task.sleep(for: .milliseconds(1_500))
            }
            let order = await BackendHealth.shared.order(nodes.map(\.absoluteString)).compactMap(URL.init(string:))
            for (i, node) in order.enumerated() {
                try Task.checkCancellation()
                do {
                    return try await body(node, i < order.count - 1 ? 12 : 20)
                } catch {
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                    guard Self.isTransient(error) else { throw error }
                    await BackendHealth.shared.failed(node.absoluteString, for: Self.bench)
                    lastError = error
                }
            }
        }
        throw lastError
    }

    /// gRPC-web body: frames of [flag:1][length:4 BE][payload]; flag 0x80 = trailers.
    static func parseFrames(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        var i = 0
        var message: Data?
        var status: Int?
        var statusMessage = ""
        while i + 5 <= bytes.count {
            let flag = bytes[i]
            let len = Int(bytes[i + 1]) << 24 | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 8 | Int(bytes[i + 4])
            let start = i + 5, end = start + len
            guard end <= bytes.count else { throw RPCError.malformed }
            let payload = Data(bytes[start..<end])
            if flag & 0x80 != 0 {
                for line in String(decoding: payload, as: UTF8.self).split(whereSeparator: \.isNewline) {
                    let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 2 else { continue }
                    switch parts[0].lowercased() {
                    case "grpc-status": status = Int(parts[1])
                    case "grpc-message": statusMessage = decodeMessage(parts[1])
                    default: break
                    }
                }
            } else if message == nil {
                message = payload
            }
            i = end
        }
        if let status, status != 0 { throw status == 14 ? RPCError.http(503) : RPCError.status(status, statusMessage) }
        guard let message else { throw RPCError.malformed }
        return message
    }

    private static func decodeMessage(_ s: String?) -> String {
        guard let s else { return "" }
        return s.removingPercentEncoding ?? s
    }

    /// Encode with the core, call `node`, decode with the core.
    private func rpc(_ method: String, encode: String, _ params: [String: Any], decode: String,
                     extra: [String: Any] = [:], node: URL, timeout: TimeInterval) async throws -> [String: Any] {
        let req = try NockCore.call(encode, params)
        guard let body = (req["body"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw RPCError.malformed }
        let reply = try await unary(method, body, node: node, timeout: timeout)
        var p = extra
        p["data"] = reply.base64EncodedString()
        return try NockCore.call(decode, p)
    }

    /// `rpc` on whichever node answers.
    private func rpc(_ method: String, encode: String, _ params: [String: Any], decode: String,
                     extra: [String: Any] = [:]) async throws -> [String: Any] {
        try await withNode { node, timeout in
            try await rpc(method, encode: encode, params, decode: decode, extra: extra, node: node, timeout: timeout)
        }
    }

    // MARK: Balance

    struct NotesPage {
        let height: UInt64
        let blockId: String?
        let notes: [NockNote]
    }

    /// Every note under one first-name (all pages), from one chain snapshot of one node: if the
    /// tip moves between pages the read restarts, so a balance never mixes two heights (page
    /// tokens are that node's own, so a switch to another node starts over too).
    func notes(firstName: String, owner: String) async throws -> NotesPage {
        for _ in 0..<3 {
            let page: NotesPage? = try await withNode { node, timeout in
                var token = ""
                var notes: [NockNote] = []
                var height: UInt64?
                var blockId: String?
                for _ in 0..<200 {   // 200 pages is far beyond any wallet; a loop guard, not a limit
                    let page = try await rpc("nockchain.public.v2.NockchainService/WalletGetBalance",
                                             encode: "balanceRequest", ["firstName": firstName, "pageToken": token],
                                             decode: "decodeBalance", extra: ["address": owner], node: node, timeout: timeout)
                    let h = (page["height"] as? NSNumber)?.uint64Value
                    let b = page["blockId"] as? String
                    if height == nil { height = h; blockId = b } else if h != height || b != blockId { return nil }
                    notes += (page["notes"] as? [[String: Any]] ?? []).compactMap(NockNote.init(json:))
                    token = page["nextPageToken"] as? String ?? ""
                    if token.isEmpty { break }
                }
                guard let height else { throw RPCError.malformed }
                return NotesPage(height: height, blockId: blockId, notes: notes)
            }
            if let page { return page }
        }
        throw RPCError.transport(Loc("链上数据在变化，请稍后重试"))
    }

    // MARK: Send

    /// Hands a signed tx to every node at once (the same tx twice is harmless — one copy is
    /// "already known"). Returns normally when any node acknowledged it. Otherwise it throws an
    /// "already known" if a node had it, a refusal only when every node refused (`isRefusal`),
    /// and else the first error that leaves the outcome open.
    func send(body: Data) async throws {
        let errors: [Error?] = await withTaskGroup(of: Error?.self) { group in
            for node in nodes {
                group.addTask {
                    do {
                        let reply = try await unary("nockchain.public.v2.NockchainService/WalletSendTransaction",
                                                    body, node: node, timeout: 30)
                        _ = try NockCore.call("decodeSend", ["data": reply.base64EncodedString()])
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var out: [Error?] = []
            for await e in group {
                // One acknowledgement settles it; the other node keeps its copy either way.
                if e == nil { group.cancelAll(); return [nil] }
                out.append(e)
            }
            return out
        }
        let failures = errors.compactMap { $0 }
        guard failures.count == errors.count, let first = failures.first else { return }
        if let known = failures.first(where: NockWalletStore.isAlreadyKnown) { throw known }
        if failures.allSatisfy(NockWalletStore.isRefusal) { throw first }
        throw failures.first { !NockWalletStore.isRefusal($0) } ?? first
    }

    /// Whether any node holds the tx (mempool or chain): all are asked, a "no" from one isn't
    /// final while another may have it. Throws only when no node answered.
    func accepted(txId: String) async throws -> Bool {
        let answers: [Result<Bool, Error>] = await withTaskGroup(of: Result<Bool, Error>.self) { group in
            for node in nodes {
                group.addTask {
                    do {
                        let r = try await rpc("nockchain.public.v2.NockchainService/TransactionAccepted",
                                              encode: "acceptedRequest", ["txId": txId], decode: "decodeAccepted",
                                              node: node, timeout: 20)
                        return .success(r["accepted"] as? Bool ?? false)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var out: [Result<Bool, Error>] = []
            for await a in group {
                if case .success(true) = a { group.cancelAll(); return [a] }
                out.append(a)
            }
            return out
        }
        var answered = false
        for a in answers {
            if case .success(let yes) = a { if yes { return true }; answered = true }
        }
        if answered { return false }
        if case .failure(let e) = answers.first { throw e }
        throw RPCError.malformed
    }

    // MARK: Explorer

    struct TxDetails {
        let pending: Bool
        let height: UInt64?
        let time: Date?
        let fee: UInt64?
        let totalOutput: UInt64?
        let outputs: [(name: String, amount: UInt64?, lock: String)]
    }

    /// The tx as the nodes know it; nil only when every node answered "not found" (one that is
    /// behind mustn't turn a mined send into a lost one). Throws when no node had it and at
    /// least one couldn't be asked.
    func txDetails(txId: String) async throws -> TxDetails? {
        var failure: Error?
        var pending: TxDetails?
        for node in await BackendHealth.shared.order(nodes.map(\.absoluteString)).compactMap(URL.init(string:)) {
            do {
                guard let d = try await txDetails(txId: txId, node: node) else { continue }
                if !d.pending { return d }
                pending = d
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                if Self.isTransient(error) { await BackendHealth.shared.failed(node.absoluteString, for: Self.bench) }
                failure = failure ?? error
            }
        }
        if let pending { return pending }
        if let failure { throw failure }
        return nil
    }

    private func txDetails(txId: String, node: URL) async throws -> TxDetails? {
        let r: [String: Any]
        do {
            r = try await rpc("nockchain.public.v2.NockchainBlockService/GetTransactionDetails",
                              encode: "txDetailsRequest", ["txId": txId], decode: "decodeTxDetails",
                              node: node, timeout: 20)
        } catch let f as NockCore.Failure where f.code == "server" && f.message.lowercased().contains("not found") {
            return nil
        } catch RPCError.status(5, _) {   // NOT_FOUND
            return nil
        }
        if (r["pending"] as? Bool) == true {
            return TxDetails(pending: true, height: nil, time: nil, fee: nil, totalOutput: nil, outputs: [])
        }
        let outs = (r["outputs"] as? [[String: Any]] ?? []).map {
            (name: $0["name"] as? String ?? "", amount: UInt64($0["amount"] as? String ?? ""), lock: $0["lock"] as? String ?? "")
        }
        return TxDetails(pending: false,
                         height: (r["height"] as? NSNumber)?.uint64Value,
                         time: (r["time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                         fee: UInt64(r["fee"] as? String ?? ""),
                         totalOutput: UInt64(r["totalOutput"] as? String ?? ""),
                         outputs: outs)
    }

    /// Block timestamps from the tip down to `minHeight`, a page (500 blocks, ~21 h) per round
    /// trip, at most `maxPages` pages — heights older than that are left out.
    func blockTimes(downTo minHeight: UInt64, maxPages: Int = 4) async throws -> [UInt64: Date] {
        // One node for all pages: page tokens are that node's own.
        try await withNode { node, timeout in
            var out: [UInt64: Date] = [:]
            var token = ""
            for _ in 0..<maxPages {
                let r = try await rpc("nockchain.public.v2.NockchainBlockService/GetBlocks",
                                      encode: "blocksRequest", ["limit": 500, "pageToken": token], decode: "decodeBlocks",
                                      node: node, timeout: timeout)
                var lowest = UInt64.max
                for b in r["blocks"] as? [[String: Any]] ?? [] {
                    guard let h = (b["height"] as? NSNumber)?.uint64Value, let t = (b["time"] as? NSNumber)?.doubleValue else { continue }
                    out[h] = Date(timeIntervalSince1970: t)
                    lowest = min(lowest, h)
                }
                token = r["nextPageToken"] as? String ?? ""
                if lowest <= minHeight || token.isEmpty { break }
            }
            return out
        }
    }

    /// When block `height` was mined.
    func blockTime(height: UInt64) async throws -> Date {
        let r = try await rpc("nockchain.public.v2.NockchainBlockService/GetBlockDetails",
                              encode: "blockRequest", ["height": height], decode: "decodeBlock")
        guard let t = (r["time"] as? NSNumber)?.doubleValue else { throw RPCError.malformed }
        return Date(timeIntervalSince1970: t)
    }
}

/// One unspent NOCK note (UTXO) of this wallet, as the node reported it.
struct NockNote: Codable, Hashable, Identifiable {
    let nameFirst: String
    let nameLast: String
    /// Height of the block that created it.
    let originPage: UInt64
    /// nicks
    let assets: UInt64
    /// "simple" (a payment), "coinbase" (mining reward, 100-block lock), "timelock",
    /// "legacy" (pre-v1 note), "foreign" (not ours — shouldn't happen under our first-names).
    let kind: String
    /// First height it can be spent at (0 = no lock).
    let unlockHeight: UInt64
    let spendable: Bool
    /// base64 `common.v2.Note` — handed back to the core to spend it.
    let raw: String

    var id: String { "\(nameFirst)/\(nameLast)" }
    var isMiningReward: Bool { kind == "coinbase" || kind == "timelock" }

    init?(json j: [String: Any]) {
        guard let f = j["nameFirst"] as? String, let l = j["nameLast"] as? String,
              let a = UInt64(j["assets"] as? String ?? ""), let raw = j["raw"] as? String else { return nil }
        nameFirst = f; nameLast = l; assets = a; self.raw = raw
        originPage = (j["originPage"] as? NSNumber)?.uint64Value ?? 0
        kind = j["kind"] as? String ?? "foreign"
        unlockHeight = (j["unlockHeight"] as? NSNumber)?.uint64Value ?? 0
        spendable = j["spendable"] as? Bool ?? false
    }
}
