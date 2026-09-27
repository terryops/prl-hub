import Foundation
import Testing
@testable import Pearl

struct AmountTests {
    @Test func parsesDotAndComma() {
        #expect(PRLAmount.parse("1.5") == Decimal(string: "1.5"))
        #expect(PRLAmount.parse(" 1,25 ") == Decimal(string: "1.25"))
        #expect(PRLAmount.parse("0") == 0)
    }

    @Test func rejectsJunk() {
        #expect(PRLAmount.parse("") == nil)
        #expect(PRLAmount.parse(".") == nil)
        #expect(PRLAmount.parse("1.2.3") == nil)
        #expect(PRLAmount.parse("-1") == nil)
        #expect(PRLAmount.parse("1e5") == nil)
        #expect(PRLAmount.parse("0.123456789") == nil)   // 9 decimals > 8
    }
}
