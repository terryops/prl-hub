import Foundation
import Testing
@testable import Pearl

@MainActor
struct WalletLogicTests {
    @Test func phraseNormalization() {
        #expect(WalletStore.normalizedPhrase("  Abandon\tabandon\n\nABOUT  ") == "abandon abandon about")
        #expect(WalletStore.normalizedPhrase("a  b   c") == "a b c")
        #expect(WalletStore.normalizedPhrase("") == "")
    }

    @Test func fingerprintIgnoresSpellingButNotWords() {
        let a = WalletStore.fingerprint(of: "legal winner thank year wave sausage worth useful legal winner thank yellow")
        let b = WalletStore.fingerprint(of: " Legal  winner thank year wave sausage worth useful legal winner thank\nyellow ")
        let c = WalletStore.fingerprint(of: "legal winner thank year wave sausage worth useful legal winner yellow thank")
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 64)
    }

    @Test func alreadyKnownBroadcastsCountAsSent() {
        #expect(BlockbookClient.isAlreadyKnown("-27: TX rejected: transaction already exists in blockchain"))
        #expect(BlockbookClient.isAlreadyKnown("-26: already have transaction 1234"))
        #expect(BlockbookClient.isAlreadyKnown("txn-already-in-mempool"))
        #expect(!BlockbookClient.isAlreadyKnown("-26: TX rejected: transaction has insufficient fee"))
        #expect(!BlockbookClient.isAlreadyKnown("-22: TX decode failed: unexpected EOF"))
    }

    @Test func changeCacheRoundTrip() {
        let prefix = "test.change.\(UUID().uuidString)."
        defer { ChangeChainCache.remove(prefix: prefix) }
        var c = ChangeChainCache()
        c.owned = ["prl1a", "prl1b"]
        c.foreign = ["prl1c"]
        c.empty = ["prl1d"]
        c.retired = ["prl1b", "prl1zz"]          // not owned → dropped on load
        c.scanHeight = 119_565
        c.balance = WalletBalance(total: Decimal(string: "1.5")!, available: 1)
        c.archive = [WalletTx(txid: "ab", direction: .sent, amount: 2, fee: Decimal(string: "0.0001")!,
                              confirmations: 120, time: Date(timeIntervalSince1970: 1_790_000_000),
                              address: "prl1x", height: 119_000)]
        c.save(prefix: prefix, network: .mainnet)

        let back = ChangeChainCache.load(prefix: prefix, network: .mainnet)
        #expect(back.owned == c.owned)
        #expect(back.foreign == c.foreign)
        #expect(back.empty == c.empty)
        #expect(back.retired == ["prl1b"])
        #expect(back.active == ["prl1a"])
        #expect(back.scanHeight == 119_565)
        #expect(back.balance == c.balance)
        #expect(back.archive == c.archive)
        // Other networks are separate.
        #expect(ChangeChainCache.load(prefix: prefix, network: .testnet) == ChangeChainCache())
    }

    @Test func staleCacheVersionStartsEmpty() {
        let prefix = "test.change.\(UUID().uuidString)."
        defer { ChangeChainCache.remove(prefix: prefix) }
        var c = ChangeChainCache()
        c.owned = ["prl1a"]
        c.save(prefix: prefix, network: .mainnet)
        UserDefaults.standard.set(ChangeChainCache.version - 1, forKey: "\(prefix)mainnet.ver")
        #expect(ChangeChainCache.load(prefix: prefix, network: .mainnet) == ChangeChainCache())
    }
}
