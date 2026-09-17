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
