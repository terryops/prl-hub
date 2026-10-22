import Foundation
import Testing
@testable import Pearl

/// 掉线提醒: what the app tells the worker about the user's monitors (alerts/src/watch.js
/// sanitizeWatch is the other end — it refuses the whole list over one bad entry).
struct OfflineAlertWireTests {
    private let addr = "prl1p8wznc8tkhlkjaq7v8ycugz93rgs8uezq6px7873934kh35nk9q2qlz0q9m"
    private let f2 = "https://www.f2pool.com/mining-user-prl/0123456789abcdef0123456789abcdef?user_name=My%20Rig"

    @Test func onlyMonitorsWithAnAlertAreSent() {
        let a = PoolWatch(pool: .kryptex, address: addr)
        var b = PoolWatch(pool: .alphaPool, address: addr)
        b.alias = "Garage"
        let list = OfflineAlertWire.list(watches: [a, b], minutes: [b.id: 30])
        #expect(list == [OfflineAlertWire(id: b.id.uuidString, pool: "AlphaPool", addr: addr, acct: nil, label: "Garage", after: 1800)])
    }

    /// The label is what the push says the workers belong to: the alias, else the pool's name.
    @Test func labelFallsBackToThePool() {
        let w = PoolWatch(pool: .luckyPool, address: addr)
        #expect(OfflineAlertWire.list(watches: [w], minutes: [w.id: 10]).first?.label == "Lucky Pool")
        var long = w
        long.alias = String(repeating: "长", count: 60)
        #expect(OfflineAlertWire.list(watches: [long], minutes: [w.id: 10]).first?.label.count == 40)
    }

    @Test func pausedMonitorsAndUnknownThresholdsAreLeftOut() {
        var paused = PoolWatch(pool: .kryptex, address: addr)
        paused.enabled = false
        let odd = PoolWatch(pool: .heroMiners, address: addr)
        #expect(OfflineAlertWire.list(watches: [paused, odd], minutes: [paused.id: 10, odd.id: 7]).isEmpty)
    }

    /// F2Pool is watched through its read-only page: the worker gets the key and the account
    /// name, never the URL.
    @Test func f2poolSendsKeyAndAccount() throws {
        let w = PoolWatch(pool: .f2pool, address: f2)
        let item = try #require(OfflineAlertWire.list(watches: [w], minutes: [w.id: 60]).first)
        #expect(item.addr == "0123456789abcdef0123456789abcdef")
        #expect(item.acct == "My Rig")
        #expect(item.after == 3600)
        #expect(item.payload["acct"] as? String == "My Rig")
        let bare = PoolWatch(pool: .f2pool, address: "https://www.f2pool.com/mining-user-prl/0123456789abcdef0123456789abcdef")
        let noAcct = try #require(OfflineAlertWire.list(watches: [bare], minutes: [bare.id: 10]).first)
        #expect(noAcct.acct == nil)
        #expect(noAcct.payload["acct"] == nil)
    }

    @Test func aCorruptedIdentifierIsSkippedNotSent() {
        let bad = PoolWatch(pool: .kryptex, address: "not an address")
        let good = PoolWatch(pool: .kryptex, address: addr)
        let list = OfflineAlertWire.list(watches: [bad, good], minutes: [bad.id: 10, good.id: 10])
        #expect(list.map(\.id) == [good.id.uuidString])
    }

    @Test func neverMoreThanTheWorkersCap() {
        let many = (0..<30).map { _ in PoolWatch(pool: .kryptex, address: addr) }
        let all = Dictionary(uniqueKeysWithValues: many.map { ($0.id, 10) })
        let list = OfflineAlertWire.list(watches: many, minutes: all)
        #expect(list.count == OfflineAlertStore.maxWatches)
        #expect(list.map(\.id) == many.prefix(OfflineAlertStore.maxWatches).map(\.id.uuidString))
    }

    /// The id must match the worker's /^[A-Za-z0-9-]{1,64}$/ and the address its
    /// /^prl1[0-9a-z]{20,100}$/ — a mismatch would fail every monitor's registration.
    @Test func wireMatchesTheWorkersPatterns() throws {
        let w = PoolWatch(pool: .pearlFortune, address: addr.uppercased())
        let item = try #require(OfflineAlertWire.list(watches: [w], minutes: [w.id: 15]).first)
        #expect(item.id.range(of: #"^[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil)
        #expect(item.addr.range(of: #"^prl1[0-9a-z]{20,100}$"#, options: .regularExpression) != nil)
        #expect(item.pool == "Pearl Fortune")
        #expect(OfflineAlertStore.choices.map { $0 * 60 } == [600, 900, 1800, 3600])
    }
}

struct OfflineAlertStorageTests {
    @Test func decodesChoicesAndDropsWhatItCannotUse() throws {
        let id = UUID()
        let json = #"{"\#(id.uuidString)":30,"not-a-uuid":10,"\#(UUID().uuidString)":7}"#
        #expect(OfflineAlertStore.decode(Data(json.utf8)) == [id: 30])
        #expect(OfflineAlertStore.decode(nil).isEmpty)
        #expect(OfflineAlertStore.decode(Data("[1,2]".utf8)).isEmpty)
    }

    /// A choice this build can't use (a threshold a newer version added) is kept aside as
    /// stored, so the next save writes it back instead of deleting it from iCloud.
    @Test func choicesThisBuildCannotUseAreKeptVerbatim() {
        let mine = UUID(), newer = UUID()
        let json = #"{"\#(mine.uuidString)":15,"\#(newer.uuidString)":120,"future-key":5}"#
        let (known, foreign) = OfflineAlertStore.split(Data(json.utf8))
        #expect(known == [mine: 15])
        #expect(foreign == [newer.uuidString: 120, "future-key": 5])
    }
}

/// One request, checked from both ends: the app must build exactly
/// Tests/Fixtures/alerts_put_body.json, and the worker's tests (alerts/test/watch.test.js)
/// send that same file to PUT /v1/devices/:token and expect it stored.
struct DeviceRegistrationBodyTests {
    @Test func matchesTheSampleTheWorkerIsTestedWith() throws {
        let addr = "prl1p8wznc8tkhlkjaq7v8ycugz93rgs8uezq6px7873934kh35nk9q2qlz0q9m"
        var above = PriceAlertRule(kind: .above, value: 1.2)
        above.id = "A1B2C3D4-0000-4000-8000-000000000001"
        var move = PriceAlertRule(kind: .move, value: 5, window: 3600)
        move.id = "A1B2C3D4-0000-4000-8000-000000000002"
        move.enabled = false
        move.repeats = true
        move.ack = 1_790_000_000
        var garage = PoolWatch(id: UUID(uuidString: "6F1B7C2A-1111-4C1C-9C43-000000000001")!, pool: .kryptex, address: addr)
        garage.alias = "Garage"
        let f2 = PoolWatch(id: UUID(uuidString: "6F1B7C2A-1111-4C1C-9C43-000000000002")!, pool: .f2pool,
                           address: "https://www.f2pool.com/mining-user-prl/0123456789abcdef0123456789abcdef?user_name=My%20Rig")
        let watches = OfflineAlertWire.list(watches: [garage, f2], minutes: [garage.id: 15, f2.id: 60])

        let body = PriceAlertStore.registrationBody(
            rules: [above.wire, move.wire], watches: watches, window: PushWindow(start: 480, end: 1380),
            timeZone: "Asia/Shanghai", env: "production", topic: "com.prl.wizard", lang: "zh-Hans", proJWS: "PRO_JWS")
        let sample = try JSONSerialization.jsonObject(with: try Fixture.data("alerts_put_body.json"))
        #expect(NSDictionary(dictionary: body).isEqual(sample))
    }

    /// Without the signed purchase the monitors are left out altogether (the worker then
    /// keeps what it has); with no window the key is an explicit null.
    @Test func leavesTheMonitorsOutWhenToldTo() throws {
        let body = PriceAlertStore.registrationBody(rules: [], watches: nil, window: nil, timeZone: "UTC",
                                                    env: "sandbox", topic: "com.prl.wizard", lang: "en", proJWS: nil)
        #expect(body["watches"] == nil)
        #expect(body["pro_jws"] == nil)
        #expect(body["window"] is NSNull)
        #expect((body["rules"] as? [Any])?.isEmpty == true)
        let cleared = PriceAlertStore.registrationBody(rules: [], watches: [], window: nil, timeZone: "UTC",
                                                       env: "sandbox", topic: "com.prl.wizard", lang: "en", proJWS: nil)
        #expect((cleared["watches"] as? [Any])?.isEmpty == true)
    }
}
