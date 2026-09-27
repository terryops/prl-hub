import Foundation
import Testing
@testable import Pearl

struct SafeTradeMarketRulesTests {
    private let rules = SafeTradeMarketRules.prlusdt

    @Test func decodesLiveMarketInfo() throws {
        let json = #"{"id":"prlusdt","amount_precision":4,"price_precision":2,"min_price":"0.01","max_price":"100000","min_amount":"2","state":"enabled"}"#
        let r = try JSONDecoder().decode(SafeTradeMarketRules.self, from: Data(json.utf8))
        #expect(r == .prlusdt)
    }

    @Test func checksPrecisionAndMinimums() {
        #expect(rules.problem(amountText: "10", priceText: "1.47") == nil)
        #expect(rules.problem(amountText: "10", priceText: "1.475") == .priceDecimals(2))
        #expect(rules.problem(amountText: "10", priceText: "1.470") == nil)          // trailing zero is fine
        #expect(rules.problem(amountText: "10.12345", priceText: nil) == .amountDecimals(4))
        #expect(rules.problem(amountText: "1,5", priceText: nil) == .belowMinAmount(2))
        #expect(rules.problem(amountText: "10", priceText: "0.001") == .priceDecimals(2))
        #expect(rules.problem(amountText: "10", priceText: "200000") == .priceOutOfRange(Decimal(string: "0.01")!, 100000))
        #expect(rules.problem(amountText: "", priceText: "") == nil)                  // empty = the form's concern
    }

    @Test func decimalPlacesAndFloor() {
        #expect(SafeTradeMarketRules.decimalPlaces("1.2300") == 2)
        #expect(SafeTradeMarketRules.decimalPlaces("7") == 0)
        #expect(SafeTradeMarketRules.decimalPlaces("0,125") == 3)
        #expect(SafeTradeMarketRules.floor(12.34567, places: 4) == 12.3456)
    }
}

struct SafeTradeBookTests {
    // Live prlusdt book shape (2026-09-27): asks ascending, bids descending.
    private let depthJSON = #"{"asks":[["1.48","5591.0758"],["1.49","20676.3443"],["1.5","53247.9385"]],"bids":[["1.47","735.0569"],["1.46","7007.2493"]],"sequence":3430251}"#

    @Test func decodesDepth() throws {
        let d = try JSONDecoder().decode(STDepth.self, from: Data(depthJSON.utf8))
        #expect(d.asks.first == STBookLevel(price: 1.48, amount: 5591.0758))
        #expect(d.bids.first == STBookLevel(price: 1.47, amount: 735.0569))
        #expect(d.asks.count == 3 && d.bids.count == 2)
    }

    @Test func averagePriceWalksTheBook() throws {
        let d = try JSONDecoder().decode(STDepth.self, from: Data(depthJSON.utf8))
        // Inside the first level: that level's price.
        #expect(SafeTradeBook.averagePrice(for: 100, levels: d.asks) == 1.48)
        // Across two levels: weighted.
        let avg = try #require(SafeTradeBook.averagePrice(for: 6000, levels: d.asks))
        #expect(abs(avg - (5591.0758 * 1.48 + 408.9242 * 1.49) / 6000) < 1e-9)
        // More than the visible book: can't estimate.
        #expect(SafeTradeBook.averagePrice(for: 1_000_000, levels: d.bids) == nil)
        #expect(SafeTradeBook.averagePrice(for: 0, levels: d.asks) == nil)
    }

    @Test func affordableAmountKeepsAMargin() throws {
        let d = try JSONDecoder().decode(STDepth.self, from: Data(depthJSON.utf8))
        let got = SafeTradeBook.affordableAmount(quote: 100, asks: d.asks, tick: 0.01)
        // 100 USDT less the 0.1% fee, at one tick above the best ask.
        #expect(abs(got - 100 * 0.999 / 1.49) < 1e-9)
        #expect(got * 1.48 < 100)                         // never more than the balance buys
        #expect(SafeTradeBook.affordableAmount(quote: 0, asks: d.asks, tick: 0.01) == 0)
    }
}

struct SafeTradeTraceTests {
    @Test func readsTheIPLine() {
        let body = "fl=618f79\nh=safetrade.com\nip=2605:52c0:2:b43:b037:29ff:fe00:f59a\nts=1790474922.000\n"
        #expect(SafeTradeTrace.ip(in: body) == "2605:52c0:2:b43:b037:29ff:fe00:f59a")
        #expect(SafeTradeTrace.ip(in: "h=x\nip=203.0.113.9\n") == "203.0.113.9")
        #expect(SafeTradeTrace.ip(in: "h=x\n") == nil)
    }
}

struct ChainAddressTests {
    @Test func keccak256KnownVectors() {
        func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
        #expect(hex(Keccak256.hash([])) == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        #expect(hex(Keccak256.hash(Array("abc".utf8))) == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
        // Longer than one 136-byte block.
        let long = [UInt8](repeating: 0x61, count: 200)
        #expect(Keccak256.hash(long).count == 32)
    }

    @Test func eip55() {
        // Test vectors from EIP-55.
        for a in ["0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
                  "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB", "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb"] {
            #expect(ChainAddress.isValidEVM(a), "\(a)")
            #expect(ChainAddress.isValidEVM(a.lowercased().replacingOccurrences(of: "0X", with: "0x")))
        }
        // One letter's case flipped breaks the checksum.
        #expect(!ChainAddress.isValidEVM("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAeD"))
        #expect(!ChainAddress.isValidEVM("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeA"))
    }

    @Test func tronAndSolana() {
        #expect(ChainAddress.isValidTron("TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"))
        #expect(!ChainAddress.isValidTron("TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6u"))   // checksum
        #expect(!ChainAddress.isValidTron("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"))
        #expect(ChainAddress.isValidSolana("EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"))
        #expect(ChainAddress.isValidSolana("So11111111111111111111111111111111111111112"))
        #expect(!ChainAddress.isValidSolana("EPjFWdd5AufqSSqeM2qN1xzybapC8G4w"))   // decodes to 24 bytes
        #expect(!ChainAddress.isValidSolana("0OIl"))
        #expect(ChainAddress.base58Decode("1112") == [0, 0, 0, 1])
    }
}
