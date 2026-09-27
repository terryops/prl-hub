import Foundation
import CryptoKit

/// Offline address checks for the USDT withdrawal chains. SafeTrade publishes no
/// address regexes for USDT (checked 2026-09-27), so the app is the only thing
/// between a mistyped address and a lost withdrawal: checksums, not just shapes.
enum ChainAddress {
    /// Ethereum and the EVM chains: 0x + 40 hex. A mixed-case address carries an
    /// EIP-55 checksum and must match it; all-lower / all-upper carries none.
    static func isValidEVM(_ a: String) -> Bool {
        guard a.range(of: "^0x[0-9a-fA-F]{40}$", options: .regularExpression) != nil else { return false }
        let hex = String(a.dropFirst(2))
        if hex == hex.lowercased() || hex == hex.uppercased() { return true }
        return eip55(hex.lowercased()) == hex
    }

    /// EIP-55 casing of a lowercase hex address: a letter is upper-cased when the
    /// matching nibble of keccak256(address) is ≥ 8.
    static func eip55(_ lowerHex: String) -> String {
        let hash = Keccak256.hash(Array(lowerHex.utf8))
        var out = ""
        for (i, ch) in lowerHex.enumerated() {
            let nibble = i % 2 == 0 ? hash[i / 2] >> 4 : hash[i / 2] & 0x0f
            out.append(ch.isLetter && nibble >= 8 ? Character(ch.uppercased()) : ch)
        }
        return out
    }

    /// TRON: base58check of 0x41 + 20 bytes, checksum = first 4 bytes of sha256².
    static func isValidTron(_ a: String) -> Bool {
        guard a.hasPrefix("T"), let b = base58Decode(a), b.count == 25, b[0] == 0x41 else { return false }
        let payload = Data(b[0..<21])
        let check = Data(SHA256.hash(data: Data(SHA256.hash(data: payload))))
        return check.prefix(4) == Data(b[21..<25])
    }

    /// Solana: base58 of a 32-byte public key.
    static func isValidSolana(_ a: String) -> Bool {
        guard (32...44).contains(a.count), let b = base58Decode(a) else { return false }
        return b.count == 32
    }

    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let alphabetIndex: [Character: Int] = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    /// Bitcoin-alphabet base58 → bytes (leading "1"s become leading zero bytes).
    static func base58Decode(_ s: String) -> [UInt8]? {
        guard !s.isEmpty else { return nil }
        var bytes: [UInt8] = []                      // big-endian magnitude
        for ch in s {
            guard var carry = alphabetIndex[ch] else { return nil }
            for j in stride(from: bytes.count - 1, through: 0, by: -1) {
                carry += Int(bytes[j]) * 58
                bytes[j] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xff), at: 0)
                carry >>= 8
            }
        }
        let zeros = s.prefix { $0 == "1" }.count
        return [UInt8](repeating: 0, count: zeros) + bytes
    }
}

/// Keccak-256 (the original Keccak padding Ethereum uses, not NIST SHA3-256) —
/// CryptoKit has no Keccak, and EIP-55 needs it.
enum Keccak256 {
    private static let roundConstants: [UInt64] = [
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
        0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
        0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
        0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
        0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    ]
    private static let rotations = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44]
    private static let lanes = [10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1]
    private static let rate = 136   // bytes: 1600-bit state − 2 × 256-bit capacity

    static func hash(_ input: [UInt8]) -> [UInt8] {
        var msg = input
        msg.append(0x01)
        while msg.count % rate != 0 { msg.append(0) }
        msg[msg.count - 1] |= 0x80
        var state = [UInt64](repeating: 0, count: 25)
        for block in stride(from: 0, to: msg.count, by: rate) {
            for i in 0..<(rate / 8) {
                var lane: UInt64 = 0
                for b in 0..<8 { lane |= UInt64(msg[block + i * 8 + b]) << (8 * UInt64(b)) }
                state[i] ^= lane
            }
            permute(&state)
        }
        var out: [UInt8] = []
        for i in 0..<4 {
            for b in 0..<8 { out.append(UInt8(truncatingIfNeeded: state[i] >> (8 * UInt64(b)))) }
        }
        return out
    }

    private static func rotl(_ x: UInt64, _ n: Int) -> UInt64 { (x << UInt64(n)) | (x >> UInt64(64 - n)) }

    private static func permute(_ s: inout [UInt64]) {
        var c = [UInt64](repeating: 0, count: 5)
        for round in 0..<24 {
            // θ
            for i in 0..<5 { c[i] = s[i] ^ s[i + 5] ^ s[i + 10] ^ s[i + 15] ^ s[i + 20] }
            for i in 0..<5 {
                let d = c[(i + 4) % 5] ^ rotl(c[(i + 1) % 5], 1)
                for j in stride(from: 0, to: 25, by: 5) { s[j + i] ^= d }
            }
            // ρ and π
            var t = s[1]
            for i in 0..<24 {
                let j = lanes[i]
                let next = s[j]
                s[j] = rotl(t, rotations[i])
                t = next
            }
            // χ
            for j in stride(from: 0, to: 25, by: 5) {
                for i in 0..<5 { c[i] = s[j + i] }
                for i in 0..<5 { s[j + i] ^= ~c[(i + 1) % 5] & c[(i + 2) % 5] }
            }
            // ι
            s[0] ^= roundConstants[round]
        }
    }
}
