import Foundation
import CryptoKit

/// Just enough of the Bitcoin-style wire format (Pearl is a btcd fork) to read what the
/// wallet needs from a tx it signed itself: the txid, the outpoints it spends and its
/// output values. Every read is bounds-checked — truncated or garbled hex yields nil,
/// never a trap.
struct RawTx: Equatable, Sendable {
    struct Input: Equatable, Sendable {
        let txid: String
        let vout: Int
        var outpoint: String { "\(txid):\(vout)" }
    }

    /// Display txid: double-SHA256 of the witness-stripped serialization, byte-reversed.
    let txid: String
    let inputs: [Input]
    /// Output values in sat, in vout order.
    let outputs: [Int64]

    var outpoints: [String] { inputs.map(\.outpoint) }

    init?(hex: String) {
        guard let b = Self.bytes(hex), b.count > 10 else { return nil }
        var r = Reader(b: b)
        guard r.skip(4) else { return nil }                       // version
        var segwit = false
        if b[4] == 0, b[5] == 1 { segwit = true; r.i += 2 }       // marker + flag
        let bodyStart = r.i
        guard let nin = r.varint(), nin > 0 else { return nil }
        var inputs: [Input] = []
        for _ in 0..<nin {
            guard let prev = r.read(32), let vout = r.uint(4),
                  let sl = r.varint(), r.skip(sl), r.skip(4) else { return nil }
            inputs.append(Input(txid: Self.hexString(prev.reversed()), vout: Int(vout)))
        }
        guard let nout = r.varint() else { return nil }
        var outputs: [Int64] = []
        for _ in 0..<nout {
            guard let v = r.uint(8), v <= UInt64(Int64.max), let sl = r.varint(), r.skip(sl) else { return nil }
            outputs.append(Int64(v))
        }
        let bodyEnd = r.i
        if segwit {
            for _ in 0..<nin {
                guard let items = r.varint() else { return nil }
                for _ in 0..<items {
                    guard let l = r.varint(), r.skip(l) else { return nil }
                }
            }
        }
        guard let lockTime = r.read(4), r.i == b.count else { return nil }
        let stripped = Array(b[0..<4]) + Array(b[bodyStart..<bodyEnd]) + lockTime
        let hash = SHA256.hash(data: Data(SHA256.hash(data: Data(stripped))))
        txid = Self.hexString(Array(hash).reversed())
        self.inputs = inputs
        self.outputs = outputs
    }

    // MARK: fee / amount math

    /// Rough taproot key-spend vsize → fee (sat); slightly over-estimates so any
    /// leftover stays sub-dust and is absorbed into the fee rather than re-stranded.
    static func estimateFeeSat(inputs: Int, outputs: Int, feePerKB: Int64) -> Int64 {
        let vbytes = 11 + inputs * 58 + outputs * 43
        let fee = Double(vbytes) * Double(feePerKB) / 1000.0
        // Clamp before the Int64 conversion: a garbage feePerKB from the backend would
        // otherwise trap on overflow. Callers reserve this against the inputs, so an
        // absurd value just yields a large (finite) reservation that fails safely upstream.
        guard fee.isFinite, fee < Double(Int64.max - 1) else { return Int64.max - 1 }
        return Int64(fee) + 1
    }

    /// PRL → sat, nil when the amount isn't positive or has more than 8 decimals.
    static func satoshis(from amountPRL: Decimal) -> Int64? {
        guard amountPRL > 0 else { return nil }
        let scaled = amountPRL * pow(Decimal(10), BlockbookClient.decimals)
        var input = scaled
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        guard rounded == scaled else { return nil }
        let number = NSDecimalNumber(decimal: scaled)
        guard number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending else { return nil }
        return number.int64Value
    }

    static func prl(fromSat sat: Int64) -> Decimal {
        Decimal(sat) / pow(Decimal(10), BlockbookClient.decimals)
    }

    // MARK: parsing helpers

    private struct Reader {
        let b: [UInt8]
        var i = 0

        mutating func read(_ n: Int) -> [UInt8]? {
            guard n >= 0, n <= b.count - i else { return nil }
            defer { i += n }
            return Array(b[i..<i + n])
        }
        mutating func skip(_ n: Int) -> Bool { read(n) != nil }
        /// Little-endian unsigned integer of `n` bytes.
        mutating func uint(_ n: Int) -> UInt64? {
            guard let bytes = read(n) else { return nil }
            return bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        }
        mutating func varint() -> Int? {
            guard let n = uint(1) else { return nil }
            let v: UInt64?
            switch n {
            case 0..<0xfd: v = n
            case 0xfd: v = uint(2)
            case 0xfe: v = uint(4)
            default: v = uint(8)
            }
            // Any count or length beyond the remaining bytes is garbage; rejecting it here
            // also keeps the loops above from spinning on a huge bogus count.
            guard let v, v <= UInt64(b.count) else { return nil }
            return Int(v)
        }
    }

    private static func bytes(_ hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8](); out.reserveCapacity(chars.count / 2)
        var k = 0
        while k < chars.count {
            guard let hi = nibble(chars[k]), let lo = nibble(chars[k + 1]) else { return nil }
            out.append(hi << 4 | lo); k += 2
        }
        return out
    }
    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }
    private static func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
