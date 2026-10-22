import Foundation
import Testing
@testable import Pearl

struct GPUCatalogTests {
    @Test func bundledTableIsTheSharedFile() throws {
        #expect(GPUS.count == 27)
        #expect(Set(GPUS.map(\.name)).count == 27)
        #expect(GPUS.allSatisfy { $0.pearl > 0 && $0.watts > 0 })
        let g = try #require(gpu("RTX 5090"))
        #expect(g.pearl == 400 && g.watts == 525 && g.price == 2200 && g.rentDefault == 120)
        #expect(gpu("RTX 4090")?.pearl == 293)
    }
}
