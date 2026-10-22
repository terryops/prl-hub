import Foundation

/// The Nockchain public gRPC API over gRPC-web (plain HTTPS POSTs, so URLSession is enough).
/// Messages are encoded and decoded by the Rust core; this type frames them and reads the
/// gRPC status the server puts in the trailer frame.
///
/// One public endpoint: rpc.nockbox.org (Iris Wallet's node). The CLI's default node is
/// plain HTTP, which ATS blocks and a wallet shouldn't use anyway.
struct NockClient {
    static let endpoint = URL(string: "https://rpc.nockbox.org")!
    /// Block explorer for "view on explorer" links.
    static func explorerURL(tx txId: String) -> URL? { URL(string: "https://nockscan.net/tx/\(txId)") }
    static func explorerURL(address: String) -> URL? { URL(string: "https://nockscan.net/address/\(address)") }

    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

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

    /// POST one unary gRPC-web call; returns the response message bytes.
    func unary(_ method: String, _ message: Data, timeout: TimeInterval = 20) async throws -> Data {
        var req = URLRequest(url: Self.endpoint.appendingPathComponent(method))
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

    /// A read (idempotent) call, retried twice on a transient failure.
    private func read(_ method: String, _ message: Data) async throws -> Data {
        var attempt = 0
        while true {
            do { return try await unary(method, message) }
            catch where Self.isTransient(error) && attempt < 2 && !Task.isCancelled {
                attempt += 1
                try await Task.sleep(for: .milliseconds(attempt == 1 ? 1_000 : 2_500))
            }
        }
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

    /// Encode with the core, call, decode with the core.
    private func rpc(_ method: String, encode: String, _ params: [String: Any], decode: String,
                     extra: [String: Any] = [:]) async throws -> [String: Any] {
        let req = try NockCore.call(encode, params)
        guard let body = (req["body"] as? String).flatMap({ Data(base64Encoded: $0) }) else { throw RPCError.malformed }
        let reply = try await read(method, body)
        var p = extra
        p["data"] = reply.base64EncodedString()
        return try NockCore.call(decode, p)
    }

    // MARK: Balance

    struct NotesPage {
        let height: UInt64
        let blockId: String?
        let notes: [NockNote]
    }

    /// Every note under one first-name (all pages), from one chain snapshot: if the tip moves
    /// between pages the read restarts, so a balance never mixes two heights.
    func notes(firstName: String, owner: String) async throws -> NotesPage {
        for _ in 0..<3 {
            var token = ""
            var notes: [NockNote] = []
            var height: UInt64?
            var blockId: String?
            var moved = false
            for _ in 0..<200 {   // 200 pages is far beyond any wallet; a loop guard, not a limit
                let page = try await rpc("nockchain.public.v2.NockchainService/WalletGetBalance",
                                         encode: "balanceRequest", ["firstName": firstName, "pageToken": token],
                                         decode: "decodeBalance", extra: ["address": owner])
                let h = (page["height"] as? NSNumber)?.uint64Value
                let b = page["blockId"] as? String
                if height == nil { height = h; blockId = b } else if h != height || b != blockId { moved = true; break }
                notes += (page["notes"] as? [[String: Any]] ?? []).compactMap(NockNote.init(json:))
                token = page["nextPageToken"] as? String ?? ""
                if token.isEmpty { break }
            }
            if moved { continue }
            guard let height else { throw RPCError.malformed }
            return NotesPage(height: height, blockId: blockId, notes: notes)
        }
        throw RPCError.transport(Loc("链上数据在变化，请稍后重试"))
    }

    // MARK: Send

    /// Hands a signed tx to the node. Returns normally only when the node acknowledged it.
    func send(body: Data) async throws {
        let reply = try await unary("nockchain.public.v2.NockchainService/WalletSendTransaction", body, timeout: 30)
        _ = try NockCore.call("decodeSend", ["data": reply.base64EncodedString()])
    }

    /// Whether the node holds the tx (mempool or chain).
    func accepted(txId: String) async throws -> Bool {
        let r = try await rpc("nockchain.public.v2.NockchainService/TransactionAccepted",
                              encode: "acceptedRequest", ["txId": txId], decode: "decodeAccepted")
        return r["accepted"] as? Bool ?? false
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

    /// nil when the node doesn't know the tx at all.
    func txDetails(txId: String) async throws -> TxDetails? {
        let r: [String: Any]
        do {
            r = try await rpc("nockchain.public.v2.NockchainBlockService/GetTransactionDetails",
                              encode: "txDetailsRequest", ["txId": txId], decode: "decodeTxDetails")
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
        var out: [UInt64: Date] = [:]
        var token = ""
        for _ in 0..<maxPages {
            let r = try await rpc("nockchain.public.v2.NockchainBlockService/GetBlocks",
                                  encode: "blocksRequest", ["limit": 500, "pageToken": token], decode: "decodeBlocks")
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
