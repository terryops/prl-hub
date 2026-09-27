import Foundation
import Testing
@testable import Pearl

/// Real mainnet transactions (blockbook.pearlresearch.ai, block 119565) so the codec is
/// checked against what the node actually relays, witness data included.
enum TxFixtures {
    static let oneInputHex = "01000000000101e81047d98fce07a8c0df863f715c8b0f15ccdc1a2912b8897be27bdf655c48f54301000000ffffffff0249fa8a00000000002251208a9f2483038b6a647b8ee934d97c1e8f5549687fead2e08cd49d9e73f51c231fdbc046110000000022512053e71242e7e00be65197831601854b375cf92ff1c730527ba0b26d28c193c50101408b7b26806770924a7b77b2d1b1f72c9036313e9ae3efa5104aa2a3decdc5af3dded0616ecc681e02d90acee67838b77962b520129d66f6e64403715c78aefe1400000000"
    static let oneInputTxid = "998578dbea941fbe90fbc5335c314300bf07af568230d0239f29127688ad4e3e"
    static let fiveInputsHex = "0100000000010514272b97a5245faf8f6e91a43e57588d8777555f175ba4193eab97ec2913004c0000000000ffffffff652d22280fe4f2f7bb13503f188f8664561eaa21a38244689474d257069adc1d0100000000ffffffffbd315c42438b4e55502b4d27982c86197f5c75b97735ef3aa6316e6caf3888360000000000ffffffffb1416bf7411834a9c19ef2a907b44db6a8493b08e7b29770ae217eb70a4779970000000000ffffffffc7e5ea644dd75246fb03728bf744544e032fb25f7ba1a84b8df165ff40cc18680000000000ffffffff02dbbb25b6010000002251205fd440f720848d93bfafeb05220eb7822a5201dfe9f79294335ad7e54886d7e4005039278c0400002252200e84d5d2f780cd4fd9524c31af9c94ba3b19b08f483102c11bd9b1bb49253a7a0140ff58d72a9d708422d05d88bd04cd5c919f4c165c55340498ae1ad7c2496e972b26c351af588996ce119b0a4fc2a469f8e68b61064f2857515b2c8d4763efd263014038ccd3db7c43f50962b23171dd6b00d8ea6b1b7a5f6e3a899535cc96f0ff2d38a37c4c56cbbd672404364129365cb5de6d3b637ac6f8941ccdf7b3c3059c3fa20140283f908814ddce3af3ada41201341790ee79b1ff6a018de095a4436698f9e7b9dd8b4fc586da6cc9c06b4d30780534c39c1f4a3e0eaa2309a387910cdcfec4aa0140308ba925bcc783fc579a36446aa6f53fff40a273d9f5c4646c2bb099d0e9d62f06d3f38cc1ea7463b63036b542253c63b80aa7f974d2ab1b22c1cde79f3d526a0140ae90be54b6a9dad02648c57ce16df2844c726740af0cad18ab46215f97d8fde6194b163c1f294fc70a5bed04e23ef8abc8cdf54dfa510f899a8a11a8a208887600000000"
    static let fiveInputsTxid = "5e7bdfb4f846b072f20772b3843ae6795f3a5abdd1ae3d34b03df4b40bc0ce0a"
    static let coinbaseHex = "020000000001010000000000000000000000000000000000000000000000000000000000000000ffffffff27030dd301042477b86a2f706f6f6c2e6b7279707465782e636f6d2fc1573e59bf12190cad424e79ffffffff0245c323a735000000225120e31e8032a67b9af27dc279f448c003457bae6c5d28de7ee719bc87b6801ede170000000000000000266a24aa21a9edd8983965f6b7bdb83b76607e99f84912169efae110ce0fbfd5ecc007bf0bdb970120000000000000000000000000000000000000000000000000000000000000000000000000"
    static let coinbaseTxid = "e9ea9774622ceb8464eb26b9ceb53e6b33ef9485a758844ff73eb76b33654b78"
}

struct WalletTxTests {
    @Test func txidOfSegwitSpend() throws {
        let tx = try #require(RawTx(hex: TxFixtures.oneInputHex))
        #expect(tx.txid == TxFixtures.oneInputTxid)
        #expect(tx.inputs == [.init(txid: "f5485c65df7be27b89b812291adccc150f8b5c713f86dfc0a807ce8fd94710e8", vout: 323)])
        #expect(tx.outputs == [9_108_041, 289_849_563])
        // Blockbook reports a 94 369 sat fee for this tx: input 299 051 973 − outputs.
        #expect(299_051_973 - tx.outputs.reduce(0, +) == 94_369)
    }

    @Test func txidAndOutpointsOfMultiInputSpend() throws {
        let tx = try #require(RawTx(hex: TxFixtures.fiveInputsHex))
        #expect(tx.txid == TxFixtures.fiveInputsTxid)
        #expect(tx.outpoints == [
            "4c001329ec97ab3e19a45b175f5577878d58573ea4916e8faf5f24a5972b2714:0",
            "1ddc9a0657d27494684482a321aa1e5664868f183f5013bbf7f2e40f28222d65:1",
            "368838af6c6e31a63aef3577b9755c7f19862c98274d2b50554e8b43425c31bd:0",
            "9779470ab77e21ae7097b2e7083b49a8b64db407a9f29ec1a9341841f76b41b1:0",
            "6818cc40ff65f18d4ba8a17b5fb22f034e5444f78b7203fb4652d74d64eae5c7:0",
        ])
        #expect(tx.outputs == [7_350_893_531, 5_000_000_000_000])
    }

    @Test func txidOfCoinbase() throws {
        let tx = try #require(RawTx(hex: TxFixtures.coinbaseHex))
        #expect(tx.txid == TxFixtures.coinbaseTxid)
        #expect(tx.outputs == [230_437_405_509, 0])
    }

    /// The same tx without its witness (legacy serialization) has the same txid.
    @Test func witnessStrippedSerializationKeepsTxid() throws {
        let hex = TxFixtures.oneInputHex
        // version | marker+flag | body (inputs+outputs) | witness | locktime
        let body = hex.dropFirst(12).prefix(hex.count - 12 - 8 - witnessHexLength(hex))
        let stripped = String(hex.prefix(8)) + body + String(hex.suffix(8))
        let tx = try #require(RawTx(hex: stripped))
        #expect(tx.txid == TxFixtures.oneInputTxid)
        #expect(tx.outputs == [9_108_041, 289_849_563])
    }

    @Test func rejectsTruncatedAndGarbledHex() {
        let hex = TxFixtures.fiveInputsHex
        for cut in stride(from: 2, to: hex.count, by: 38) {
            #expect(RawTx(hex: String(hex.prefix(cut))) == nil)
        }
        #expect(RawTx(hex: "") == nil)
        #expect(RawTx(hex: "zz" + hex.dropFirst(2)) == nil)
        #expect(RawTx(hex: String(hex.dropLast())) == nil)
        // A varint claiming far more inputs than the bytes that follow must not trap.
        #expect(RawTx(hex: "01000000" + "fe" + "ffffff7f" + "00") == nil)
        #expect(RawTx(hex: "01000000" + "ff" + "ffffffffffffffff") == nil)
    }

    @Test func outputValuesHelperMatchesCodec() {
        #expect(WalletStore.txOutputValues(TxFixtures.oneInputHex) == [9_108_041, 289_849_563])
        #expect(WalletStore.txOutputValues("0100") == [])
    }

    @Test func satoshiConversion() {
        #expect(RawTx.satoshis(from: Decimal(string: "1.5")!) == 150_000_000)
        #expect(RawTx.satoshis(from: Decimal(string: "0.00000001")!) == 1)
        #expect(RawTx.satoshis(from: Decimal(string: "0.000000001")!) == nil)
        #expect(RawTx.satoshis(from: 0) == nil)
        #expect(RawTx.prl(fromSat: 150_000_000) == Decimal(string: "1.5"))
    }

    @Test func feeEstimateClampsGarbage() {
        #expect(RawTx.estimateFeeSat(inputs: 1, outputs: 2, feePerKB: 1_000) == 156)
        // 58 097 vbytes × Int64.max sat/kB overflows Int64 — clamped, not trapped.
        #expect(RawTx.estimateFeeSat(inputs: 1_000, outputs: 2, feePerKB: .max) == .max - 1)
    }

    /// Hex length of the witness section of a one-input tx with a single 64-byte
    /// schnorr signature: item count (1) + length (1) + 64 bytes.
    private func witnessHexLength(_ hex: String) -> Int { (1 + 1 + 64) * 2 }
}
