import Foundation
import NockMobile

/// Swift side of the Nockchain wallet core (`tools/nock-mobile`, Rust → `NockMobile.xcframework`).
///
/// The same 12-word seed that opens the PRL wallet also opens a NOCK account, derived the way
/// the official `nockchain-wallet` and Iris do it, so the address here is the one those wallets
/// show for the seed. Everything chain-specific (keys, protobuf, lock matching, building and
/// signing) runs in Rust; this file only crosses the FFI. Nothing here touches the network.
enum NockCore {
    /// 1 NOCK = 2^16 nicks.
    static let nicksPerNock: UInt64 = 65_536

    /// A failure reported by the core. `code` is stable ("insufficient", "invalid_address", …).
    struct Failure: LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? {
            switch code {
            case "insufficient": return Loc("余额不足以支付金额和手续费")
            case "no_funds": return Loc("没有可用的 NOCK（挖矿收入要过 100 个区块才能使用）")
            case "invalid_address": return Loc("收款地址格式不正确")
            case "legacy_address": return Loc("这是旧版（v0）NOCK 地址，已不能收款，请向对方要新地址")
            case "zero_amount": return Loc("请输入金额")
            case "invalid_mnemonic": return Loc("助记词无效")
            case "server": return Loc("节点拒绝了请求：%@", message)
            default: return Loc("NOCK 钱包出错：%@", message)
            }
        }
    }

    /// One JSON request through `nock_call`. Blocking but pure CPU (signing a send is a few
    /// milliseconds) — still, call the signing paths off the main actor.
    static func call(_ op: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        try decode(raw(try request(op, params)))
    }

    /// The same call, run on a background thread (signing a sweep of many notes takes a
    /// moment). Only JSON bytes cross the actor boundary.
    static func callDetached(_ op: String, _ params: [String: Any]) async throws -> [String: Any] {
        let req = try request(op, params)
        let reply = await Task.detached(priority: .userInitiated) { raw(req) }.value
        return try decode(reply)
    }

    private static func request(_ op: String, _ params: [String: Any]) throws -> Data {
        var request = params
        request["op"] = op
        return try JSONSerialization.data(withJSONObject: request)
    }

    /// The reply JSON for one request (empty when the FFI returned nothing).
    private static func raw(_ request: Data) -> Data {
        let text = String(decoding: request, as: UTF8.self)
        guard let reply = text.withCString({ nock_call($0) }) else { return Data() }
        defer { nock_free(reply) }
        return Data(String(cString: reply).utf8)
    }

    private static func decode(_ reply: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw Failure(code: "ffi", message: "no reply")
        }
        if let ok = object["ok"] as? [String: Any] { return ok }
        throw Failure(code: object["code"] as? String ?? "ffi", message: object["error"] as? String ?? "malformed reply")
    }

    /// `true` if the embedded Rust core is reachable.
    static var isAvailable: Bool { (try? call("version"))?["version"] != nil }

    struct Account: Equatable, Codable {
        /// v1 address (base58 pubkey hash, ~55 chars).
        let address: String
        /// The lock commitments the node indexes notes by: plain payments, and mining
        /// rewards (pubkey hash + the 100-block coinbase timelock).
        let simpleFirstName: String
        let coinbaseFirstName: String
    }

    /// The NOCK account for a seed. Account 0 is the master key — the official wallet's
    /// default address and Iris's first account.
    static func account(mnemonic: String, index: Int = 0) throws -> Account {
        try account(from: call("derive", ["mnemonic": mnemonic, "account": index]))
    }

    /// Read-only view of any address (no key: balance and history only).
    static func watchAccount(address: String) throws -> Account {
        try account(from: call("watch", ["address": address.trimmingCharacters(in: .whitespacesAndNewlines)]))
    }

    private static func account(from r: [String: Any]) throws -> Account {
        guard let address = r["address"] as? String,
              let names = r["firstNames"] as? [String: Any],
              let simple = names["simple"] as? String,
              let coinbase = names["coinbase"] as? String else {
            throw Failure(code: "ffi", message: "malformed derive reply")
        }
        return Account(address: address, simpleFirstName: simple, coinbaseFirstName: coinbase)
    }

    /// Why `address` can't be paid (a `Failure.code`), or nil when it is a valid v1 address.
    /// v1 addresses carry no checksum: a typo that stays in range still validates, which is
    /// why the confirmation sheet shows the address in groups to check.
    static func addressProblem(_ address: String) -> String? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return "invalid_address" }
        guard let r = try? call("checkAddress", ["address": a]) else { return "invalid_address" }
        return (r["valid"] as? Bool) == true ? nil : (r["reason"] as? String ?? "invalid_address")
    }

    static func isValidAddress(_ address: String) -> Bool { addressProblem(address) == nil }

    // MARK: Amounts

    /// Exact: a nick is 2^-16 NOCK, which a Decimal holds without rounding.
    static func nock(fromNicks nicks: UInt64) -> Decimal {
        Decimal(nicks) / Decimal(nicksPerNock)
    }

    /// The nearest whole nick to a typed NOCK amount (nil if negative / too large).
    static func nicks(fromNock amount: Decimal) -> UInt64? {
        guard amount >= 0 else { return nil }
        var scaled = amount * Decimal(nicksPerNock)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded <= Decimal(UInt64.max / 2) else { return nil }
        return NSDecimalNumber(decimal: rounded).uint64Value
    }

    /// A user-typed NOCK amount: digits with at most one decimal mark (comma accepted) and
    /// at most `typedDecimals` decimals.
    static let typedDecimals = 6
    static func parseAmount(_ raw: String) -> Decimal? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: { $0.isASCII && $0.isNumber }),
              text.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789.,").inverted) == nil
        else { return nil }
        let norm = text.replacingOccurrences(of: ",", with: ".")
        let parts = norm.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.count == 1 || parts[1].count <= typedDecimals else { return nil }
        return Decimal(string: norm, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// The amount as the send form takes it ("1234.567812"): POSIX, ungrouped, rounded down to
    /// `typedDecimals` places so it always parses back.
    static func plainAmount(nicks: UInt64) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = typedDecimals
        f.roundingMode = .down
        return f.string(from: NSDecimalNumber(decimal: nock(fromNicks: nicks))) ?? "0"
    }

    /// "1,234.5678" — grouped, up to `decimals` places (a nick is ~0.000015 NOCK).
    static func format(nicks: UInt64, decimals: Int = 6) -> String {
        nock(fromNicks: nicks).formatted(.number.precision(.fractionLength(0...decimals))
            .rounded(rule: .down).locale(LocBundleHolder.shared.locale))
    }
}
