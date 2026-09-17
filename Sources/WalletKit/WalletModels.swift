import Foundation

// MARK: - Network

enum WalletNetwork: String, CaseIterable, Identifiable, Codable {
    case mainnet, testnet
    var id: String { rawValue }
    var label: String { self == .mainnet ? "Mainnet" : "Testnet" }
    var addressPrefix: String { self == .mainnet ? "prl1" : "tprl1" }
    var addressHRP: String { self == .mainnet ? "prl" : "tprl" }
    /// oyster JSON-RPC port (matches the desktop wallet's network-config.ts).
    var rpcPort: Int { 8335 }
    var defaultPeerPort: Int { self == .mainnet ? 44108 : 44112 }
}

// MARK: - Wallet list

/// One wallet on this device. The seed lives only in the Keychain; this record is the
/// non-secret index entry (persisted locally, never synced — seeds are device-only).
struct WalletRecord: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    /// Receive address at index 0 per network (`WalletNetwork.rawValue` → address),
    /// cached when the wallet is loaded so the switcher can tell wallets apart
    /// without opening each one's wallet db.
    var addresses: [String: String] = [:]

    init(id: String, name: String, addresses: [String: String] = [:]) {
        self.id = id; self.name = name; self.addresses = addresses
    }

    // Synthesized Decodable ignores property defaults, so a list saved before a field
    // existed would fail to decode as a whole. Decode optional-by-default fields leniently.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        addresses = try c.decodeIfPresent([String: String].self, forKey: .addresses) ?? [:]
    }
}

// MARK: - Amounts

/// User-typed PRL amounts — the one parser behind every amount field (转账, 捐赠).
enum PRLAmount {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Digits with at most one decimal mark and at most 8 decimals → the amount, else nil.
    /// A comma is accepted as the decimal mark (ru/vi/id keypads type one), and parsing
    /// uses a fixed POSIX locale so "1.5" is 1.5 whatever the device region. Zero parses;
    /// callers decide whether it is allowed.
    static func parse(_ raw: String) -> Decimal? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: { $0.isASCII && $0.isNumber }),
              text.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789.,").inverted) == nil
        else { return nil }
        let norm = text.replacingOccurrences(of: ",", with: ".")
        let parts = norm.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.count == 1 || parts[1].count <= BlockbookClient.decimals else { return nil }
        return Decimal(string: norm, locale: posix)
    }
}

enum PRLAddress {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let bech32mConstant = 0x2bc830a3

    static func isValid(_ address: String, network: WalletNetwork) -> Bool {
        validate(address, expectedHRP: network.addressHRP) != nil
    }

    static func isValidAnyNetwork(_ address: String) -> Bool {
        validate(address, expectedHRP: nil) != nil
    }

    private static func validate(_ raw: String, expectedHRP: String?) -> [UInt8]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 14, trimmed.count <= 90 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { return nil }
        let lower = trimmed.lowercased()
        guard trimmed == lower || trimmed == trimmed.uppercased() else { return nil }
        guard let sep = lower.lastIndex(of: "1") else { return nil }
        let hrp = String(lower[..<sep])
        guard expectedHRP.map({ hrp == $0 }) ?? (hrp == WalletNetwork.mainnet.addressHRP || hrp == WalletNetwork.testnet.addressHRP) else {
            return nil
        }
        let dataPart = lower[lower.index(after: sep)...]
        guard dataPart.count >= 7 else { return nil }
        let values = dataPart.compactMap { charset.firstIndex(of: $0) }
        guard values.count == dataPart.count else { return nil }
        guard polymod(hrpExpand(hrp) + values) == bech32mConstant else { return nil }
        let payload = Array(values.dropLast(6))
        guard payload.first == 1 else { return nil }
        guard let program = convertBits(Array(payload.dropFirst()), from: 5, to: 8, pad: false), program.count == 32 else {
            return nil
        }
        return program.map(UInt8.init)
    }

    private static func hrpExpand(_ hrp: String) -> [Int] {
        let scalars = hrp.unicodeScalars.map { Int($0.value) }
        return scalars.map { $0 >> 5 } + [0] + scalars.map { $0 & 31 }
    }

    private static func polymod(_ values: [Int]) -> Int {
        let generators = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk = 1
        for value in values {
            let top = chk >> 25
            chk = ((chk & 0x1ffffff) << 5) ^ value
            for i in 0..<5 where ((top >> i) & 1) == 1 {
                chk ^= generators[i]
            }
        }
        return chk
    }

    private static func convertBits(_ data: [Int], from: Int, to: Int, pad: Bool) -> [Int]? {
        var acc = 0
        var bits = 0
        let maxv = (1 << to) - 1
        let maxAcc = (1 << (from + to - 1)) - 1
        var ret: [Int] = []
        for value in data {
            guard value >= 0 && (value >> from) == 0 else { return nil }
            acc = ((acc << from) | value) & maxAcc
            bits += from
            while bits >= to {
                bits -= to
                ret.append((acc >> bits) & maxv)
            }
        }
        if pad {
            if bits > 0 { ret.append((acc << (to - bits)) & maxv) }
        } else {
            guard bits < from, ((acc << (to - bits)) & maxv) == 0 else { return nil }
        }
        return ret
    }
}

// MARK: - Transactions

enum TxDirection: String, Codable { case received, sent }

struct WalletTx: Identifiable, Codable, Hashable {
    var txid: String
    var direction: TxDirection
    var amount: Decimal       // PRL
    var fee: Decimal
    var confirmations: Int
    var time: Date
    var address: String
    var id: String { txid }
}

// MARK: - Balance snapshot

struct WalletBalance: Codable, Equatable {
    var total: Decimal
    var available: Decimal
    var unconfirmed: Decimal { max(0, total - available) }
    static let zero = WalletBalance(total: 0, available: 0)
}

// MARK: - Sync

enum SyncPhase: String, Codable { case idle, headers, filters, blocks, synced }

struct SyncProgress: Codable, Equatable {
    var headerHeight = 0
    var blockHeight = 0
    var bestPeerHeight = 0
    var synced = false
    var phase: SyncPhase = .idle
}
