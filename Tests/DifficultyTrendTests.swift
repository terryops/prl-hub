import Foundation
import Testing
@testable import Pearl

private actor HistoryTestLoader {
    let value: SharedNetworkHistory
    private(set) var calls = 0
    init(_ value: SharedNetworkHistory) { self.value = value }
    func load() async throws -> SharedNetworkHistory {
        calls += 1
        try await Task.sleep(for: .milliseconds(40))
        return value
    }
}

/// 近7天 / 7天前 and the monthly growth read the difficulty that long ago, not the window means
/// every source reports (same cases as the Web's parity.test.ts "against the difficulty that long ago").
struct DifficultyTrendTests {
    private let day = 86_400.0
    private var now: Double { 10 * day }
    /// Climbing 1 per day from 10 (7 days back) to 17 now: the 7-day mean is 13.5, 3d 15.5, 24h 16.5.
    private var points: [SharedNetworkHistory.Point] {
        (0..<8).map { .init(ts: now - Double(7 - $0) * day, difficulty: 10 + Double($0)) }
    }

    @Test func historySampleFirstThenTheSteadyTrendStart() {
        #expect(difficultyAgo(now: 17, mean: 13.5, window: 7 * day, at: now, history: points) == 10)
        #expect(difficultyAgo(now: 17, mean: 16.5, window: day, at: now, history: points) == 16)
        // Without history the start of a steady trend with that mean: exact on a straight line.
        #expect(difficultyAgo(now: 17, mean: 13.5, window: 7 * day, at: now) == 10)
        #expect(difficultyAgo(now: 17, mean: 15.5, window: 3 * day, at: now) == 14)
        // A sample further than a twentieth of the window from the target is not used.
        #expect(difficultyAgo(now: 17, mean: 13.5, window: 7 * day, at: now, history: Array(points.dropFirst())) == 10)
        #expect(difficultyAgo(now: 17, mean: 13.5, window: 7 * day, at: now,
                              history: [.init(ts: now - 7 * day, difficulty: 9)]) == 9)
        // A mean under half of now has no start; no mean and no sample, nothing.
        #expect(difficultyAgo(now: 17, mean: 8, window: 7 * day, at: now) == nil)
        #expect(difficultyAgo(now: 17, mean: nil, window: 7 * day, at: now) == nil)
    }

    @Test func trendAndMonthlyGrowthFromTheLiveNumbers() {
        // 2026-10-25 production: now 45.89M; means 24h 45.41M, 3d 44.06M, 7d 41.59M; history 7 days
        // back 37.51M. Before: 近7天 +10.35% and +44.4%/month from the mean.
        var c = Config()
        applyDifficultyTrend(&c, now: 45_893_517.86, at: 1_792_894_887,
                             means: (45_409_597.08, 44_055_976.23, 41_588_752.06),
                             history: [.init(ts: 1_792_290_087, difficulty: 37_507_299.93)])
        #expect(c.diff7 == 37_507_299.93)
        #expect(abs(c.diffChange(vs: c.diff7) - 22.36) < 0.01)
        #expect(abs(c.diffGrowthMonthly - 22.357 * 30 / 7) < 0.05)
        // No sample near 24h / 3d back: those take 2 × mean − now.
        #expect(abs(c.diff24 - (2 * 45_409_597.08 - 45_893_517.86)) < 1e-3)
        #expect(abs(c.diff3 - (2 * 44_055_976.23 - 45_893_517.86)) < 1e-3)

        var noHistory = Config()
        applyDifficultyTrend(&noHistory, now: 45.92e6, at: 1_792_894_887, means: (nil, nil, 41.58e6))
        #expect(abs(noHistory.diff7 - 37.24e6) < 1)
        #expect(abs(noHistory.diffGrowthMonthly - (45.92 / 37.24 - 1) * 30 / 7 * 100) < 1e-6)
    }

    @Test func edgeCasesKeepOrCap() {
        var c = Config()
        c.diff24 = 1; c.diff3 = 2; c.diff7 = 3; c.diffGrowthMonthly = 7
        // A source without means or samples leaves the last trend alone.
        applyDifficultyTrend(&c, now: 4, at: now, means: (nil, nil, nil))
        #expect(c.diffNow == 4 && c.diff24 == 1 && c.diff3 == 2 && c.diff7 == 3)
        #expect(abs(c.diffGrowthMonthly - (4.0 / 3 - 1) * 30 / 7 * 100) < 1e-9)
        // Twice the 7-day mean or more: no start to show, and the growth is at its cap.
        applyDifficultyTrend(&c, now: 20, at: now, means: (19, 15, 9))
        #expect(c.diff7 == 0 && !c.hasDiffTrend)
        #expect(c.diff24 == 18 && c.diff3 == 10)
        #expect(c.diffGrowthMonthly == 200)
        // Falling difficulty: the start is above now, the growth negative (floored at −20).
        applyDifficultyTrend(&c, now: 10, at: now, means: (10.5, 11, 12))
        #expect(c.diff7 == 14)
        #expect(c.diffGrowthMonthly == -20)
    }

    @Test func historyReplyDecodesTheWorkersShape() throws {
        let data = Data("""
        {"ok":true,"source":"blockbook","span":"7d","window":200,"points":[
          {"height":129460,"ts":1792290087,"difficulty":37507299.92646471,"hashrate":62554708713265470000,"blockTime":167.995},
          {"height":129461,"ts":1792290825,"difficulty":37485920.5720934,"hashrate":null,"blockTime":null},
          {"height":129462,"ts":1792291000,"difficulty":null,"hashrate":null,"blockTime":null},
          null],
         "avgBlockTime":161.3,"firstHeight":129460,"lastHeight":129462,"sampled":true}
        """.utf8)
        let history = try JSONDecoder().decode(SharedNetworkHistory.self, from: data)
        #expect(history.points.map(\.ts) == [1_792_290_087, 1_792_290_825])
        #expect(history.points.first?.difficulty == 37_507_299.92646471)
        // An unreadable reply has no samples rather than failing the refresh.
        let broken = try JSONDecoder().decode(SharedNetworkHistory.self, from: Data(#"{"points":"x"}"#.utf8))
        #expect(broken.points.isEmpty)
    }

    @Test func historyIsSharedAndCachedForFiveMinutes() async throws {
        let loader = HistoryTestLoader(SharedNetworkHistory(points: points))
        let data = SharedPublicData(load: { throw URLError(.notConnectedToInternet) },
                                    loadHistory: { try await loader.load() })
        let t0 = Date()
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<6 { group.addTask { try await data.networkHistory(at: t0).points.count } }
            for try await count in group { #expect(count == 8) }
        }
        #expect(await loader.calls == 1)
        _ = try await data.networkHistory(at: t0.addingTimeInterval(299))
        #expect(await loader.calls == 1)
        _ = try await data.networkHistory(at: t0.addingTimeInterval(301))
        #expect(await loader.calls == 2)
        _ = try await data.networkHistory(force: true, at: t0.addingTimeInterval(302))
        #expect(await loader.calls == 3)
    }
}
