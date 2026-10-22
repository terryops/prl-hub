import Foundation
import Testing
@testable import Pearl

struct WebSharedParityTests {
    private let id = "A1B2C3D4-0000-4000-8000-000000000001"
    @Test func nativeEditsAndDeletesPreserveUnknownRemoteFields() throws {
        let row: [String: Any] = ["id": id, "name": "Friend", "address": "prl1" + String(repeating: "a", count: 38), "note": ""]
        let first = try WebSharedMerge.merge(local: ["contacts": [row]], remote: ["future": ["keep": true]], base: nil, now: 10)
        #expect(first.upload)
        var remote = first.config
        var contact = try #require((remote["contacts"] as? [[String: Any]])?.first)
        contact["future"] = "keep"; contact["name"] = "Browser"; contact["updated"] = 20
        remote["contacts"] = [contact]
        let adopted = try WebSharedMerge.merge(local: ["contacts": [row]], remote: remote, base: first.base, now: 30)
        #expect(!adopted.upload)
        #expect((adopted.native["contacts"] as? [[String: Any]])?.first?["name"] as? String == "Browser")
        let removed = try WebSharedMerge.merge(local: ["contacts": [[String: Any]]()], remote: adopted.config, base: adopted.base, now: 40)
        let tombstone = try #require((removed.config["contacts"] as? [[String: Any]])?.first)
        #expect(tombstone["deleted"] as? Bool == true)
        #expect(tombstone["future"] as? String == "keep")
        var stale = removed.config; stale["contacts"] = [contact]
        let repaired = try WebSharedMerge.merge(local: ["contacts": [[String: Any]]()], remote: stale, base: removed.base, now: 50)
        #expect((repaired.config["contacts"] as? [[String: Any]])?.first?["deleted"] as? Bool == true)
        contact["updated"] = 100
        stale["contacts"] = [contact]
        let restored = try WebSharedMerge.merge(local: ["contacts": [[String: Any]]()], remote: stale, base: removed.base, now: 110)
        #expect((restored.native["contacts"] as? [[String: Any]])?.first?["name"] as? String == "Browser")
    }
    @Test func settingsValidateBeforeWritingAndConvertUnits() throws {
        let suite = "WebSharedParityTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.2, forKey: "prl.elec")
        #expect(throws: (any Error).self) { try WebSharedMerge.apply(["calculator.electricity": 0.4, "fleetSettings.powerBudgetW": -1], to: defaults) }
        #expect(defaults.double(forKey: "prl.elec") == 0.2)
        _ = try WebSharedMerge.apply(["calculator.fee": 3.0, "calculator.networkHash": 2e18, "autoRefresh": false], to: defaults)
        #expect(defaults.double(forKey: "prl.fee") == 0.03)
        #expect(defaults.double(forKey: "prl.neth") == 2)
        #expect(!defaults.bool(forKey: "prl.auto"))
        defaults.set("__auto__", forKey: "currency.secondary"); defaults.set("ja", forKey: "app.language")
        #expect(WebSharedMerge.rentCurrency(defaults) == "JPY")
        #expect(throws: (any Error).self) { try WebSharedMerge.merge(local: ["contacts": []], remote: ["contacts": [["id": id], ["id": id]]], base: nil, now: 1) }
    }
    @Test func legacyDefaultsRemainLiveAndDeviceRentCurrencySurvivesDecoding() throws {
        let suite = "WebSharedParityTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2.0, forKey: "prl.price")
        #expect(WebSharedMerge.read(defaults)["calculator.price"] is NSNull)
        defaults.set(false, forKey: "prl.live")
        #expect(WebSharedMerge.read(defaults)["calculator.price"] as? Double == 2)
        let row: [String: Any] = ["id": id, "name": "Rental", "gpu": "RTX 4090", "count": 1, "rented": true, "hoursPerDay": 24.0, "rentDaily": 12.0, "rentCurrency": "USD", "rentFX": 1.0]
        _ = try WebSharedMerge.apply(["devices": [row]], to: defaults)
        let devices = try JSONDecoder().decode([Device].self, from: #require(defaults.data(forKey: "prl.devices")))
        #expect(devices.first?.rentCurrency == "USD")
        #expect(devices.first?.rentFX == 1)
    }
}

struct AccountProtocolTests {
    @Test func verifiedPRLAccountUnlocksWithoutAppleAndClearsOnLogout() {
        var rights = ProEntitlements()
        rights.useAccount("u_paid")
        #expect(!rights.unlocked)
        rights.updateAccount("u_paid", verifiedPro: true)
        #expect(rights.unlocked)
        #expect(!rights.apple)
        rights.apple = false // StoreKit's empty answer cannot remove PRL Pro.
        #expect(rights.unlocked)
        rights.useAccount(nil)
        #expect(!rights.unlocked)
        rights.updateAccount("u_paid", verifiedPro: true) // A late response after logout.
        #expect(!rights.unlocked)
    }
    @Test func accountSwitchAndRefundPreserveOnlyIndependentRights() {
        var rights = ProEntitlements(apple: true)
        rights.useAccount("u_a", verifiedPro: true)
        rights.apple = false // Apple refund leaves PRL active.
        #expect(rights.unlocked)
        rights.useAccount("u_b")
        rights.updateAccount("u_a", verifiedPro: true)
        #expect(!rights.unlocked)
        rights.apple = true
        rights.updateAccount("u_b", verifiedPro: false)
        rights.useAccount(nil)
        #expect(rights.unlocked) // Account logout leaves a local Apple purchase.
        rights.apple = false
        #expect(!rights.unlocked)
    }
    @Test func pkceBindsCallbackStateAndRejectsDuplicateParameters() {
        let verifier = AccountPKCE.random(), state = AccountPKCE.random(), code = AccountPKCE.random()
        #expect(verifier.count == 43)
        #expect(AccountPKCE.challenge(verifier).count == 43)
        #expect(AccountPKCE.challenge(verifier) != verifier)
        #expect(AccountPKCE.code(URL(string: "prlhub://account?code=\(code)&state=\(state)")!, state: state) == code)
        #expect(AccountPKCE.code(URL(string: "prlhub://account?code=\(code)&state=wrong")!, state: state) == nil)
        #expect(AccountPKCE.code(URL(string: "prlhub://account?code=\(code)&state=\(state)&state=\(state)")!, state: state) == nil)
    }
    @Test func accountWhitelistExcludesSecretsAndKeepsPublicContacts() {
        let clean = AccountConfig.clean(["seed": "private", "contacts": [["id": "contact", "updated": 1, "name": "Friend", "address": "public", "note": "", "privateKey": "private"]]])
        #expect(clean["seed"] == nil)
        #expect((clean["contacts"] as? [[String: Any]])?.first?["privateKey"] == nil)
        #expect((clean["contacts"] as? [[String: Any]])?.first?["name"] as? String == "Friend")
    }
}

struct WebLinkMonitorTests {
    private let addr = "prl1p8wznc8tkhlkjaq7v8ycugz93rgs8uezq6px7873934kh35nk9q2qlz0q9m"
    private let addr2 = "prl1pmkyxyht58rzhe7cj9ha7ncpm6r28x6g0htq93ffs5hsh7lqsxj7qw9pyjv"
    private let f2 = "https://www.f2pool.com/mining-user-prl/0123456789abcdef0123456789abcdef?user_name=My%20Rig"

    private func merge(_ watches: [PoolWatch], minutes: [UUID: Int] = [:], again: [UUID: Int] = [:], base: WebLinkBase = WebLinkBase(),
                       remote: [String: Any]?, now: Int64 = 5_000) -> WebLinkOutcome {
        WebLinkMerge.merge(local: WebLinkLocal(watches: watches, minutes: minutes, again: again, alerts: CloudAlerts(), window: nil),
                           base: base, remote: remote, timeZone: "Asia/Shanghai", lang: "en", now: now)
    }

    private func monitors(_ c: [String: Any]) -> [[String: Any]] { c["monitors"] as? [[String: Any]] ?? [] }

    private func entry(_ id: String, pool: String = "Kryptex", addr: String, label: String = "Kryptex",
                       alert: Bool = false, after: Int = 600, updated: Int64 = 1_000) -> [String: Any] {
        ["id": id, "updated": updated, "pool": pool, "addr": addr, "label": label, "alert": alert, "after": after]
    }

    @Test func theFirstSyncSendsTheAppsMonitors() throws {
        let a = PoolWatch(pool: .kryptex, address: addr)
        var b = PoolWatch(pool: .alphaPool, address: addr2)
        b.alias = "Garage"
        b.enabled = false
        let out = merge([a, b], minutes: [b.id: 30], remote: nil)
        #expect(out.upload)
        let sent = monitors(out.config)
        #expect(sent.count == 2)
        #expect(sent[0]["id"] as? String == a.id.uuidString)
        #expect(sent[0]["label"] as? String == "Kryptex")
        #expect(sent[0]["alert"] as? Bool == false)
        #expect(sent[0]["paused"] as? Bool == false)
        #expect(sent[1]["label"] as? String == "Garage")
        #expect(sent[1]["alert"] as? Bool == true)
        #expect(sent[1]["after"] as? Int == 1800)
        #expect(sent[1]["paused"] as? Bool == true)
        #expect(sent[1]["updated"] as? Int64 == 5_000)
        let order = try #require(out.config["monitorOrder"] as? [String: Any])
        #expect(order["ids"] as? [String] == [a.id.uuidString, b.id.uuidString])
        // A configuration no browser has saved yet still has to be one the web accepts.
        #expect((out.config["wallets"] as? [Any])?.isEmpty == true)
        #expect((out.config["rules"] as? [Any])?.isEmpty == true)
        #expect(out.local.watches == [a, b])
        #expect(JSONSerialization.isValidJSONObject(out.config))
    }

    @Test func nothingMovesOnceBothSidesAgree() {
        let a = PoolWatch(pool: .kryptex, address: addr)
        let first = merge([a], minutes: [a.id: 10], remote: nil)
        let again = merge([a], minutes: [a.id: 10], base: first.base, remote: first.config, now: 9_000)
        #expect(!again.upload)
        #expect(again.local.watches == [a])
        #expect(again.local.minutes == [a.id: 10])
        #expect(again.base == first.base)
    }

    @Test func aMonitorAddedOnTheWebArrivesAndKeepsItsId() throws {
        let id = "0a1b2c3d-0000-4000-8000-00000000abcd"   // browsers write lowercase
        let remote: [String: Any] = ["monitors": [entry(id, addr: addr, label: "Farm", alert: true, after: 900)],
                                     "wallets": [Any](), "rules": [Any]()]
        let out = merge([], remote: remote)
        #expect(!out.upload)
        let w = try #require(out.local.watches.first)
        #expect(w.id == UUID(uuidString: id))
        #expect(w.pool == .kryptex && w.address == addr && w.alias == "Farm" && w.isEnabled)
        #expect(out.local.minutes == [w.id: 15])
        // …and the next sync neither sends it back nor respells the id.
        let again = merge(out.local.watches, minutes: out.local.minutes, base: out.base, remote: remote, now: 9_000)
        #expect(!again.upload)
        #expect(again.base.monitors.keys.map { $0 } == [id])
        // Even with the agreement lost, the id the web gave it is found again.
        let lost = merge(out.local.watches, minutes: out.local.minutes, remote: remote, now: 9_000)
        #expect(lost.local.watches.count == 1)
        #expect(monitors(lost.config).count == 1)
        #expect(monitors(lost.config)[0]["updated"] as? Int64 == 1_000)
        #expect(lost.base.monitors.keys.map { $0 } == [id])
    }

    @Test func aChangeHereGoesUpAndANewerOneThereComesDown() throws {
        var a = PoolWatch(pool: .kryptex, address: addr)
        let first = merge([a], remote: nil)
        a.alias = "Barn"
        let up = merge([a], base: first.base, remote: first.config, now: 9_000)
        #expect(up.upload)
        #expect(monitors(up.config)[0]["label"] as? String == "Barn")
        #expect(monitors(up.config)[0]["updated"] as? Int64 == 9_000)

        var theirs = up.config
        var m = monitors(theirs)
        m[0]["label"] = "Shed"
        m[0]["paused"] = true
        m[0]["alert"] = true
        m[0]["after"] = 3600
        m[0]["updated"] = Int64(12_000)
        theirs["monitors"] = m
        let down = merge([a], base: up.base, remote: theirs, now: 20_000)
        #expect(!down.upload)
        let w = try #require(down.local.watches.first)
        #expect(w.id == a.id && w.alias == "Shed" && !w.isEnabled)
        #expect(down.local.minutes == [a.id: 60])
    }

    /// A browser that renames a monitor back to the pool's own name clears the alias.
    @Test func theWebsDefaultLabelIsNoAlias() throws {
        var a = PoolWatch(pool: .kryptex, address: addr)
        a.alias = "Barn"
        let first = merge([a], remote: nil)
        var theirs = first.config
        var m = monitors(theirs)
        m[0]["label"] = "Kryptex"
        m[0]["updated"] = Int64(8_000)
        theirs["monitors"] = m
        let out = merge([a], base: first.base, remote: theirs, now: 9_000)
        #expect(out.local.watches.first?.alias == nil)
    }

    @Test func deletingHereLeavesATombstoneThere() {
        let a = PoolWatch(pool: .kryptex, address: addr), b = PoolWatch(pool: .alphaPool, address: addr2)
        let first = merge([a, b], remote: nil)
        let out = merge([b], base: first.base, remote: first.config, now: 9_000)
        #expect(out.upload)
        let gone = monitors(out.config)[0]
        #expect(gone["id"] as? String == a.id.uuidString)
        #expect(gone["deleted"] as? Bool == true)
        #expect(gone["updated"] as? Int64 == 9_000)
        #expect(gone["addr"] == nil)
        #expect(out.base.monitors[a.id.uuidString] == nil)
        // The tombstone is not sent a second time.
        #expect(!merge([b], base: out.base, remote: out.config, now: 12_000).upload)
    }

    @Test func deletingThereRemovesItHere() {
        let a = PoolWatch(pool: .kryptex, address: addr), b = PoolWatch(pool: .alphaPool, address: addr2)
        let first = merge([a, b], minutes: [a.id: 10], remote: nil)
        var theirs = first.config
        var m = monitors(theirs)
        m[0] = ["id": a.id.uuidString, "updated": Int64(8_000), "deleted": true]
        theirs["monitors"] = m
        let out = merge([a, b], minutes: [a.id: 10], base: first.base, remote: theirs, now: 9_000)
        #expect(!out.upload)
        #expect(out.local.watches == [b])
        #expect(out.local.minutes.isEmpty)
    }

    /// Changed here after the web deleted it: the later change wins and it comes back there.
    @Test func aLaterChangeHereOutlivesADeletionThere() {
        var a = PoolWatch(pool: .kryptex, address: addr)
        let first = merge([a], remote: nil)
        var theirs = first.config
        theirs["monitors"] = [["id": a.id.uuidString, "updated": Int64(8_000), "deleted": true] as [String: Any]]
        a.alias = "Kept"
        let out = merge([a], base: first.base, remote: theirs, now: 9_000)
        #expect(out.upload)
        #expect(out.local.watches == [a])
        #expect(monitors(out.config)[0]["deleted"] == nil)
        #expect(monitors(out.config)[0]["label"] as? String == "Kept")
    }

    @Test func theSameMonitorOnBothSidesBecomesOne() throws {
        let a = PoolWatch(pool: .kryptex, address: addr)
        let remote: [String: Any] = ["monitors": [entry("web-1", addr: addr, label: "Garage", alert: true, after: 3600)]]
        let out = merge([a], remote: remote)
        #expect(out.local.watches.count == 1)
        #expect(out.local.watches.first?.id == a.id)
        #expect(out.local.watches.first?.alias == "Garage")
        #expect(out.local.minutes == [a.id: 60])
        #expect(monitors(out.config).count == 1)
        #expect(monitors(out.config)[0]["id"] as? String == "web-1")
        #expect(out.base.monitors["web-1"]?.local == a.id)
        #expect(!merge(out.local.watches, minutes: out.local.minutes, base: out.base, remote: out.config, now: 9_000).upload)
    }

    /// A device signing in for the first time often holds an old iCloud copy of the account's
    /// monitors (same ids). The account's copy wins: a monitor switched back on elsewhere stays
    /// on, and one deleted elsewhere goes.
    @Test func aFirstSyncDoesNotUndoTheAccountsNewerChanges() throws {
        var paused = PoolWatch(pool: .kryptex, address: addr)
        paused.enabled = false
        paused.alias = "Barn"
        let gone = PoolWatch(pool: .alphaPool, address: addr2)
        let remote: [String: Any] = ["monitors": [
            entry(paused.id.uuidString, addr: addr, label: "Shed", updated: 3_000),
            ["id": gone.id.uuidString, "updated": Int64(4_000), "deleted": true],
        ]]
        let out = merge([paused, gone], minutes: [gone.id: 10], remote: remote)
        // Nothing of the account's monitors is overwritten (only the card order, which it lacks, goes up).
        let sent = monitors(out.config)
        #expect(sent.count == 2)
        #expect(sent[0]["updated"] as? Int64 == 3_000 && sent[0]["paused"] == nil && sent[0]["label"] as? String == "Shed")
        #expect(sent[1]["deleted"] as? Bool == true && sent[1]["updated"] as? Int64 == 4_000)
        let w = try #require(out.local.watches.first)
        #expect(out.local.watches.count == 1)
        #expect(w.id == paused.id && w.isEnabled && w.enabled == nil && w.alias == "Shed")
        #expect(out.local.minutes.isEmpty)
        #expect(out.base.monitors[paused.id.uuidString]?.updated == 3_000)
        #expect(!merge(out.local.watches, minutes: out.local.minutes, base: out.base, remote: out.config, now: 9_000).upload)
    }

    /// …but what was set up on this device alone is added to the account's copy.
    @Test func aFirstSyncAddsAnAliasAndAnAlertOnlyThisDeviceHas() throws {
        var a = PoolWatch(pool: .kryptex, address: addr)
        a.alias = "Barn"
        let remote: [String: Any] = ["monitors": [entry(a.id.uuidString, addr: addr, label: "Kryptex", updated: 3_000)]]
        let out = merge([a], minutes: [a.id: 30], remote: remote)
        #expect(out.upload)
        let sent = monitors(out.config)[0]
        #expect(sent["label"] as? String == "Barn")
        #expect(sent["alert"] as? Bool == true && sent["after"] as? Int == 1800)
        #expect(sent["updated"] as? Int64 == 5_000)
        #expect(out.local.watches.first?.alias == "Barn" && out.local.minutes == [a.id: 30])
    }

    /// What this build can't read — a pool a later version added, a field it doesn't know —
    /// goes back exactly as it came.
    @Test func whatItCannotReadItLeavesAlone() throws {
        var a = PoolWatch(pool: .kryptex, address: addr)
        let first = merge([a], remote: nil)
        var theirs = first.config
        var m = monitors(theirs)
        m[0]["color"] = "red"
        m.append(["id": "future", "updated": Int64(2_000), "pool": "NewPool", "addr": "x", "label": "?", "alert": false, "after": 600])
        theirs["monitors"] = m
        theirs["devices"] = [["id": "d1"]]
        a.alias = "Barn"
        let out = merge([a], base: first.base, remote: theirs, now: 9_000)
        #expect(out.upload)
        let sent = monitors(out.config)
        #expect(sent[0]["label"] as? String == "Barn")
        #expect(sent[0]["color"] as? String == "red")
        #expect(sent[1]["pool"] as? String == "NewPool")
        #expect((out.config["devices"] as? [[String: Any]])?.first?["id"] as? String == "d1")
        #expect(out.local.watches.count == 1)
    }

    /// 掉线提醒's reminder travels with the monitor, in seconds, only while the alert is on.
    @Test func theReminderGoesUpAndComesDown() throws {
        let a = PoolWatch(pool: .kryptex, address: addr)
        let first = merge([a], minutes: [a.id: 120], again: [a.id: 60], remote: nil)
        #expect(monitors(first.config)[0]["after"] as? Int == 7200)
        #expect(monitors(first.config)[0]["again"] as? Int == 3600)
        #expect(!merge([a], minutes: [a.id: 120], again: [a.id: 60], base: first.base, remote: first.config, now: 9_000).upload)

        // Switched off here: the key goes.
        let off = merge([a], minutes: [a.id: 120], base: first.base, remote: first.config, now: 9_000)
        #expect(off.upload)
        #expect(monitors(off.config)[0]["again"] == nil)

        // Changed on the web: it comes down.
        var theirs = first.config
        var m = monitors(theirs)
        m[0]["again"] = 14400
        m[0]["updated"] = Int64(12_000)
        theirs["monitors"] = m
        let down = merge([a], minutes: [a.id: 120], again: [a.id: 60], base: first.base, remote: theirs, now: 13_000)
        #expect(!down.upload)
        #expect(down.local.again == [a.id: 240])

        // The alert switched off on the web: this side keeps its reminder for when it is back on.
        m[0]["alert"] = false
        m[0]["again"] = nil
        m[0]["updated"] = Int64(14_000)
        theirs["monitors"] = m
        let quiet = merge([a], minutes: [a.id: 120], again: [a.id: 60], base: first.base, remote: theirs, now: 15_000)
        #expect(quiet.local.minutes.isEmpty)
        #expect(quiet.local.again == [a.id: 60])

        // A delay this build doesn't offer: left alone on both sides.
        m[0]["alert"] = true
        m[0]["again"] = 999
        theirs["monitors"] = m
        let odd = merge([a], minutes: [a.id: 120], again: [a.id: 60], base: first.base, remote: theirs, now: 15_000)
        #expect(!odd.upload)
        #expect(odd.local.again == [a.id: 60])
    }

    /// An older build (2.0, or a browser tab from before reminders) rewrites the monitors
    /// without the field it doesn't know, leaving their stamps alone: this side says it again.
    @Test func aReminderAnOlderBuildDroppedIsSentAgain() throws {
        let a = PoolWatch(pool: .kryptex, address: addr)
        let first = merge([a], minutes: [a.id: 30], again: [a.id: 120], remote: nil)
        var theirs = first.config
        var m = monitors(theirs)
        m[0]["again"] = nil
        theirs["monitors"] = m
        let out = merge([a], minutes: [a.id: 30], again: [a.id: 120], base: first.base, remote: theirs, now: 9_000)
        #expect(out.upload)
        #expect(monitors(out.config)[0]["again"] as? Int == 7200)
        #expect(monitors(out.config)[0]["updated"] as? Int64 == 9_000)
        #expect(out.local.again == [a.id: 120])
        // A change the web did make (a newer stamp) still wins.
        m[0]["updated"] = Int64(8_000)
        theirs["monitors"] = m
        let theirsWins = merge([a], minutes: [a.id: 30], again: [a.id: 120], base: first.base, remote: theirs, now: 9_000)
        #expect(!theirsWins.upload)
        #expect(theirsWins.local.again.isEmpty)
    }

    @Test func theWebsLimitOfTwentyIsNeverPassed() {
        let full = (0..<20).map { i in entry("web-\(i)", pool: "NewPool", addr: "x\(i)") }
        let a = PoolWatch(pool: .kryptex, address: addr)
        let out = merge([a], remote: ["monitors": full])
        #expect(!out.upload)
        #expect(monitors(out.config).count == 20)
        #expect(out.local.watches == [a])
        #expect(out.base.monitors.isEmpty)
    }

    @Test func cardOrderIsOneValueAndTheLaterChangeWins() throws {
        let a = PoolWatch(pool: .kryptex, address: addr), b = PoolWatch(pool: .alphaPool, address: addr2)
        let first = merge([a, b], remote: nil)
        // Reordered here.
        let up = merge([b, a], base: first.base, remote: first.config, now: 9_000)
        #expect(up.upload)
        let sent = try #require(up.config["monitorOrder"] as? [String: Any])
        #expect(sent["ids"] as? [String] == [b.id.uuidString, a.id.uuidString])
        #expect(sent["updated"] as? Int64 == 9_000)
        // Reordered there, later.
        var theirs = up.config
        theirs["monitorOrder"] = ["ids": [a.id.uuidString, b.id.uuidString], "updated": Int64(12_000)] as [String: Any]
        let down = merge([b, a], base: up.base, remote: theirs, now: 20_000)
        #expect(!down.upload)
        #expect(down.local.watches == [a, b])
        // One added here doesn't count as reordering: the web's order stands, the new one last.
        let c = PoolWatch(pool: .luckyPool, address: addr)
        let added = merge([c, a, b], base: down.base, remote: theirs, now: 30_000)
        #expect(added.local.watches == [a, b, c])
        #expect((added.config["monitorOrder"] as? [String: Any])?["updated"] as? Int64 == 12_000)
    }

    @Test func f2poolTravelsAsKeyAndAccount() throws {
        let w = PoolWatch(pool: .f2pool, address: f2)
        let out = merge([w], remote: nil)
        let sent = monitors(out.config)[0]
        #expect(sent["addr"] as? String == "0123456789abcdef0123456789abcdef")
        #expect(sent["acct"] as? String == "My Rig")
        // …and one a browser added becomes the page link the app stores.
        let remote: [String: Any] = ["monitors": [["id": "web-f2", "updated": Int64(1_000), "pool": "F2Pool",
                                                   "addr": "0123456789abcdef0123456789abcdef", "acct": "My Rig",
                                                   "label": "F2Pool", "alert": false, "after": 600] as [String: Any]]]
        let back = merge([], remote: remote)
        #expect(back.local.watches.first?.address == f2)
        #expect(back.local.watches.first?.alias == nil)
    }
}

struct WebLinkAlertTests {
    private func rule(_ id: String = "r1", _ kind: PriceAlertRule.Kind = .above, _ value: Double = 1.5, window: Int = 0,
                      enabled: Bool = true, changedAt: TimeInterval = 100, fired: TimeInterval = 0,
                      ack: TimeInterval = 0) -> CloudAlertRule {
        CloudAlertRule(id: id, kind: kind, value: value, window: window, enabled: enabled, changedAt: changedAt, fired: fired, ack: ack)
    }

    private func entry(_ id: String = "r1", kind: String = "above", value: Double = 1.5, window: Int = 0,
                       enabled: Bool = true, seen: Int = 0, updated: Int64) -> [String: Any] {
        ["id": id, "updated": updated, "kind": kind, "value": value, "window": window, "enabled": enabled, "seen_fired": seen]
    }

    /// What PriceAlertStore does with the copy the web's changes arrive as.
    private func adopted(_ local: [CloudAlertRule], _ incoming: CloudAlerts?, removed: [String: TimeInterval] = [:]) -> PriceAlertSync.Merged {
        PriceAlertSync.merge(local: local.map(PriceAlertRule.init(cloud:)), removed: removed, cloud: incoming, incoming: true)
    }

    @Test func alertsGoUpWithTheirStateAndStamp() throws {
        let fired = rule("r2", .move, 5, window: 3600, changedAt: 100, fired: 250, ack: 0)
        let out = WebLinkMerge.rules(local: CloudAlerts(rules: [rule(changedAt: 100.0004), fired]), remote: [], now: 900_000)
        #expect(out.changed && out.incoming == nil)
        #expect(out.remote[0]["kind"] as? String == "above")
        #expect(out.remote[0]["value"] as? Double == 1.5)
        #expect(out.remote[0]["enabled"] as? Bool == true)
        #expect(out.remote[0]["updated"] as? Int64 == 100_001)      // rounded up, never older than the change
        // A one-shot alert that fired is off, as of that firing.
        #expect(out.remote[1]["enabled"] as? Bool == false)
        #expect(out.remote[1]["updated"] as? Int64 == 250_000)
        #expect(out.remote[1]["seen_fired"] as? Int == 250)
        #expect(out.remote[1]["window"] as? Int == 3600)
    }

    @Test func repeatingAlertsStayOnAndTheirFiringsDoNotOutrankUserEdits() throws {
        var r = rule(changedAt: 100, fired: 250)
        r.repeats = true
        let sent = WebLinkMerge.rules(local: CloudAlerts(rules: [r]), remote: [], now: 900_000)
        #expect(sent.remote[0]["repeat"] as? Bool == true)
        #expect(sent.remote[0]["enabled"] as? Bool == true)
        #expect(sent.remote[0]["updated"] as? Int64 == 100_000)
        var webEdit = entry(enabled: true, seen: 250, updated: 200_000)
        webEdit["repeat"] = false
        let changed = WebLinkMerge.rules(local: CloudAlerts(rules: [r]), remote: [webEdit], now: 900_000)
        let once = try #require(adopted([r], changed.incoming).rules.first)
        #expect(!once.isRepeating && once.isOn && once.ack == 250)
        webEdit["repeat"] = true
        webEdit["updated"] = Int64(300_000)
        let back = WebLinkMerge.rules(local: CloudAlerts(rules: [once.cloud]), remote: [webEdit], now: 950_000)
        #expect(adopted([once.cloud], back.incoming).rules.first?.isRepeating == true)
        #expect((AccountConfig.clean(["rules": [webEdit]])["rules"] as? [[String: Any]])?.first?["repeat"] as? Bool == true)
    }

    @Test func nothingMovesOnceBothSidesAgree() {
        let local = CloudAlerts(rules: [rule()])
        let first = WebLinkMerge.rules(local: local, remote: [], now: 900_000)
        let again = WebLinkMerge.rules(local: local, remote: first.remote, now: 950_000)
        #expect(!again.changed && again.incoming == nil)
    }

    @Test func anAlertAddedOnTheWebArrives() throws {
        let out = WebLinkMerge.rules(local: CloudAlerts(), remote: [entry("w1", kind: "below", value: 0.8, updated: 200_000)], now: 900_000)
        #expect(!out.changed)
        let got = adopted([], out.incoming)
        #expect(got.rules.count == 1)
        #expect(got.rules[0].id == "w1" && got.rules[0].kind == .below && got.rules[0].value == 0.8 && got.rules[0].isOn)
        #expect(got.rules[0].changedAt == 200)
    }

    /// 到达目标价 goes both ways: up to the web as "reach", and back as one.
    @Test func reachAlertsRoundTrip() throws {
        let up = WebLinkMerge.rules(local: CloudAlerts(rules: [rule("r9", .reach, 0.6)]), remote: [], now: 900_000)
        #expect(up.changed && up.remote.first?["kind"] as? String == "reach")
        #expect(up.remote.first?["window"] as? Int == 0)
        let down = WebLinkMerge.rules(local: CloudAlerts(), remote: [entry("w9", kind: "reach", value: 0.6, updated: 200_000)], now: 900_000)
        let got = adopted([], down.incoming)
        #expect(got.rules.count == 1 && got.rules[0].kind == .reach && got.rules[0].value == 0.6 && got.rules[0].isOn)
    }

    @Test func switchedBackOnThereIsOnHere() throws {
        let off = rule(fired: 250, ack: 0)                           // fired, so off
        let out = WebLinkMerge.rules(local: CloudAlerts(rules: [off]),
                                     remote: [entry(enabled: true, seen: 250, updated: 400_000)], now: 900_000)
        #expect(!out.changed)
        let got = try #require(adopted([off], out.incoming).rules.first)
        #expect(got.isOn)
        #expect(got.ack == 250 && got.changedAt == 400)
    }

    @Test func firedThereIsOffHereWithoutCountingAsAChange() throws {
        let on = rule()
        let out = WebLinkMerge.rules(local: CloudAlerts(rules: [on]),
                                     remote: [entry(enabled: false, seen: 300, updated: 301_000)], now: 900_000)
        #expect(!out.changed)
        let got = try #require(adopted([on], out.incoming).rules.first)
        #expect(!got.isOn)
        #expect(got.enabled && got.fired == 300 && got.changedAt == 100)
        // The two sides now agree; nothing bounces back.
        let again = WebLinkMerge.rules(local: CloudAlerts(rules: [got.cloud]),
                                       remote: [entry(enabled: false, seen: 300, updated: 301_000)], now: 950_000)
        #expect(!again.changed && again.incoming == nil)
    }

    @Test func switchedOffThereIsOffHere() throws {
        let on = rule()
        let out = WebLinkMerge.rules(local: CloudAlerts(rules: [on]),
                                     remote: [entry(enabled: false, updated: 400_000)], now: 900_000)
        let got = try #require(adopted([on], out.incoming).rules.first)
        #expect(!got.enabled && got.changedAt == 400)
    }

    @Test func aLaterSwitchHereGoesUp() {
        let off = rule(enabled: false, changedAt: 500)
        let out = WebLinkMerge.rules(local: CloudAlerts(rules: [off]), remote: [entry(enabled: true, updated: 400_000)], now: 900_000)
        #expect(out.changed && out.incoming == nil)
        #expect(out.remote[0]["enabled"] as? Bool == false)
        #expect(out.remote[0]["updated"] as? Int64 == 500_000)
    }

    /// Another condition is another alert: what the old one had fired doesn't carry over.
    @Test func editedThereReplacesTheConditionHere() throws {
        let old = rule(fired: 250, ack: 0)
        let out = WebLinkMerge.rules(local: CloudAlerts(rules: [old]),
                                     remote: [entry(value: 2.25, enabled: true, seen: 250, updated: 400_000)], now: 900_000)
        let got = try #require(adopted([old], out.incoming).rules.first)
        #expect(got.value == 2.25 && got.isOn && got.fired == nil && got.ack == nil)
    }

    @Test func deletedThereIsDeletedHere() {
        let r = rule(changedAt: 100.0004)
        let out = WebLinkMerge.rules(local: CloudAlerts(rules: [r]),
                                     remote: [["id": "r1", "updated": Int64(100_001), "deleted": true]], now: 900_000)
        #expect(!out.changed)
        #expect(adopted([r], out.incoming).rules.isEmpty)
    }

    @Test func deletedHereLeavesATombstoneUnlessItChangedThereSince() throws {
        let gone = CloudAlerts(rules: [], removed: ["r1": 300])
        let out = WebLinkMerge.rules(local: gone, remote: [entry(updated: 200_000)], now: 900_000)
        #expect(out.changed && out.incoming == nil)
        #expect(out.remote[0]["deleted"] as? Bool == true)
        #expect(out.remote[0]["updated"] as? Int64 == 300_000)
        #expect(!WebLinkMerge.rules(local: gone, remote: out.remote, now: 950_000).changed)

        let later = WebLinkMerge.rules(local: gone, remote: [entry(value: 3, updated: 400_000)], now: 900_000)
        #expect(!later.changed)
        let back = adopted([], later.incoming, removed: ["r1": 300])
        #expect(back.rules.count == 1 && back.rules[0].value == 3)
    }

    /// The same alert set up on both sides before they were linked would push twice.
    @Test func theSameConditionOnBothSidesIsOneAlert() {
        let mine = rule("app-1")
        let out = WebLinkMerge.rules(local: CloudAlerts(rules: [mine]), remote: [entry("web-1", updated: 200_000)], now: 900_000)
        #expect(out.changed && out.incoming == nil)
        #expect(out.remote.count == 2)
        #expect(out.remote[0]["id"] as? String == "web-1" && out.remote[0]["deleted"] as? Bool == true)
        #expect(out.remote[1]["id"] as? String == "app-1" && out.remote[1]["deleted"] == nil)
    }

    @Test func whatTheWebWouldRefuseStaysHere() {
        let odd = rule("has space")                                   // not an id the web accepts
        let full = (0..<20).map { entry("w\($0)", kind: "future", updated: 1) }
        #expect(!WebLinkMerge.rules(local: CloudAlerts(rules: [odd]), remote: [], now: 1).changed)
        let out = WebLinkMerge.rules(local: CloudAlerts(rules: [rule()]), remote: full, now: 1)
        #expect(!out.changed && out.remote.count == 20 && out.incoming == nil)
    }
}

struct WebLinkWindowTests {
    private func merge(_ window: PushWindow?, base: WebLinkBase = WebLinkBase(), remote: [String: Any]?, now: Int64 = 5_000) -> WebLinkOutcome {
        WebLinkMerge.merge(local: WebLinkLocal(watches: [], minutes: [:], alerts: CloudAlerts(), window: window),
                           base: base, remote: remote, timeZone: "Asia/Shanghai", lang: "zh-Hans", now: now)
    }

    @Test func theFirstSyncTakesTheWebsHoursUnlessTheAppHasItsOwn() throws {
        let theirs: [String: Any] = ["window": ["start": 480, "end": 1320, "tz": "Europe/Berlin"] as [String: Any], "settingsUpdated": 100]
        let adopted = merge(nil, remote: theirs)
        #expect(!adopted.upload)
        #expect(adopted.local.window == PushWindow(start: 480, end: 1320))

        let mine = merge(PushWindow(start: 540, end: 60), remote: theirs)
        #expect(mine.upload)
        let sent = try #require(mine.config["window"] as? [String: Any])
        #expect(sent["start"] as? Int == 540 && sent["end"] as? Int == 60 && sent["tz"] as? String == "Asia/Shanghai")
        #expect(mine.config["settingsUpdated"] as? Int64 == 5_000)
    }

    @Test func afterThatWhicheverSideChangedIsFollowed() throws {
        let agreed: [String: Any] = ["window": ["start": 480, "end": 1320, "tz": "Asia/Shanghai"] as [String: Any], "settingsUpdated": Int64(9_000)]
        let base = merge(nil, remote: agreed).base
        // Unchanged on both sides.
        #expect(!merge(PushWindow(start: 480, end: 1320), base: base, remote: agreed).upload)
        // Back to all day here: the web's stamp must move past the one it has.
        let cleared = merge(nil, base: base, remote: agreed)
        #expect(cleared.upload)
        #expect(cleared.config["window"] is NSNull)
        #expect(cleared.config["settingsUpdated"] as? Int64 == 9_001)
        // Changed there.
        var theirs = agreed
        theirs["window"] = NSNull()
        let followed = merge(PushWindow(start: 480, end: 1320), base: base, remote: theirs)
        #expect(!followed.upload)
        #expect(followed.local.window == nil)
    }

    @Test func aCodeNoBrowserHasUsedGetsNothingUntilThereIsSomethingToSend() {
        let out = merge(nil, remote: nil)
        #expect(!out.upload)
        #expect(out.base.windowKnown)
        #expect(out.config["lang"] as? String == "zh-Hans")
    }
}

/// One configuration, checked from both ends: the app must build exactly
/// Tests/Fixtures/weblink_config.json on a first sync, and the web's tests
/// (prl-hub-web's web/test/weblink.test.ts) feed that same file to the validator every browser runs
/// (`normalizeConfig`) — which rejects the whole configuration over one bad entry.
struct WebLinkConfigSampleTests {
    @Test func matchesTheSampleTheWebIsTestedWith() throws {
        var garage = PoolWatch(id: UUID(uuidString: "6F1B7C2A-1111-4C1C-9C43-000000000001")!, pool: .kryptex,
                               address: "prl1p8wznc8tkhlkjaq7v8ycugz93rgs8uezq6px7873934kh35nk9q2qlz0q9m")
        garage.alias = "Garage"
        let f2 = PoolWatch(id: UUID(uuidString: "6F1B7C2A-1111-4C1C-9C43-000000000002")!, pool: .f2pool,
                           address: "https://www.f2pool.com/mining-user-prl/0123456789abcdef0123456789abcdef?user_name=My%20Rig")
        var paused = PoolWatch(id: UUID(uuidString: "6F1B7C2A-1111-4C1C-9C43-000000000003")!, pool: .alphaPool,
                               address: "prl1pmkyxyht58rzhe7cj9ha7ncpm6r28x6g0htq93ffs5hsh7lqsxj7qw9pyjv")
        paused.enabled = false
        let alerts = CloudAlerts(rules: [
            CloudAlertRule(id: "A1B2C3D4-0000-4000-8000-000000000001", kind: .above, value: 1.2, window: 0, enabled: true,
                           changedAt: 1_790_000_000.5, fired: 0, ack: 0),
            CloudAlertRule(id: "A1B2C3D4-0000-4000-8000-000000000002", kind: .move, value: 5, window: 3600, enabled: true,
                           changedAt: 1_790_000_000, fired: 1_790_000_100, ack: 0),
        ])
        let out = WebLinkMerge.merge(
            local: WebLinkLocal(watches: [garage, f2, paused], minutes: [garage.id: 15], alerts: alerts,
                                window: PushWindow(start: 480, end: 1380)),
            base: WebLinkBase(), remote: nil, timeZone: "Asia/Shanghai", lang: "zh-Hans", now: 1_790_000_300_000)
        #expect(out.upload)
        let sample = try JSONSerialization.jsonObject(with: try Fixture.data("weblink_config.json"))
        #expect(NSDictionary(dictionary: out.config).isEqual(sample))
        // What goes over the wire is this, serialized: it must survive that unchanged.
        let wire = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: out.config))
        #expect((wire as? NSDictionary)?.isEqual(sample) == true)
    }
}


@MainActor
struct AccountMiningSyncTests {
    private func defaults(_ suite: String) throws -> UserDefaults { try #require(UserDefaults(suiteName: suite)) }

    @Test func cabinetPowerRequiresExplicitOptInAndRetainsBudget() throws {
        let suite = "AccountMiningSyncTests.power." + UUID().uuidString, d = try defaults(suite)
        defer { d.removePersistentDomain(forName: suite) }
        d.set(6500.0, forKey: "prl.budget") // An existing budget is not an opt-in.
        d.set(true, forKey: "prl.fxManual")
        let store = PRLStore(defaults: d, onChange: { _ in })
        #expect(!store.powerBudgetEnabled && store.powerBudgetW == 6500)
        store.powerBudgetEnabled = true
        store.flushPending()
        #expect(d.bool(forKey: "prl.budgetEnabled"))
        let restored = PRLStore(defaults: d, onChange: { _ in })
        #expect(restored.powerBudgetEnabled && restored.powerBudgetW == 6500)
        store.powerBudgetEnabled = false
        store.flushPending(); restored.reloadPrefs()
        #expect(!restored.powerBudgetEnabled && restored.powerBudgetW == 6500)
        #expect(WebSharedMerge.read(d)["fleetSettings.powerBudgetEnabled"] as? Bool == false)
        #expect(!WebSharedMerge.validSetting("fleetSettings.powerBudgetEnabled", "true"))
        #expect(CloudSync.syncedKeys.contains("prl.budgetEnabled"))
    }

    @Test func fleetAndManualInputsSurviveAnotherDeviceAndRemoteEdits() throws {
        let aSuite = "AccountMiningSyncTests.a." + UUID().uuidString
        let bSuite = "AccountMiningSyncTests.b." + UUID().uuidString
        let a = try defaults(aSuite), b = try defaults(bSuite)
        defer { a.removePersistentDomain(forName: aSuite); b.removePersistentDomain(forName: bSuite) }
        let owned = Device(name: "Garage", gpu: "RTX 5090", count: 4, hoursPerDay: 18)
        let rental = Device(name: "Cloud", gpu: "RTX 4090", count: 1, rented: true, hoursPerDay: 12,
                            customPearl: 310, rentDaily: 24, rentCurrency: "USD", rentFX: 1,
                            sourceKey: "Kryptex|prl1public|worker")
        a.set(try JSONEncoder().encode([owned, rental]), forKey: "prl.devices")
        a.set(try JSONEncoder().encode(["RTX 4090": 12.0]), forKey: "prl.rents")
        for (key, value) in ["prl.price": 1.5, "prl.neth": 20.0, "prl.pu": 0.04, "prl.diffGrowth": 15.0,
                             "prl.elec": 0.2, "prl.fee": 0.02, "prl.budget": 6000.0, "prl.syncW": 2.2,
                             "prl.fx": 150.0] { a.set(value, forKey: key) }
        for (key, value) in ["prl.live": false, "prl.selfDilution": true, "prl.fxManual": true,
                             "prl.rentEnabled": false, "prl.rentCovers": false, "prl.auto": true, "prl.budgetEnabled": true] { a.set(value, forKey: key) }
        a.set("USD", forKey: "prl.rentCcy"); a.set(1.0, forKey: "prl.rentFX")
        a.set(SortKey.effic.rawValue, forKey: "prl.sort"); a.set("RTX 5090", forKey: "prl.selected")
        a.set("ja", forKey: "app.language"); a.set("JPY", forKey: "currency.secondary")
        let first = try WebSharedMerge.merge(local: WebSharedMerge.read(a), remote: WebLinkMerge.emptyConfig(lang: "ja"), base: nil, now: 100)
        let wire = AccountConfig.clean(first.config)
        #expect((wire["fleetSettings"] as? [String: Any])?["sortKey"] as? String == "efficiency")
        #expect((wire["fleetSettings"] as? [String: Any])?["selectedGPU"] as? String == "RTX 5090")
        #expect((wire["fleetSettings"] as? [String: Any])?["powerBudgetEnabled"] as? Bool == true)
        // The other device chose its language too (one that follows the system keeps doing so).
        b.set("en", forKey: "app.language")
        let received = try WebSharedMerge.merge(local: WebSharedMerge.read(b), remote: wire, base: nil, now: 200)
        #expect(!received.upload)
        _ = try WebSharedMerge.apply(received.native, to: b)
        // The pinned rate is 1 USD in the first device's currency: it stays there.
        #expect((wire["fleetSettings"] as? [String: Any])?["manualFX"] == nil && b.object(forKey: "prl.fx") == nil)
        #expect(b.bool(forKey: "prl.fxManual"))
        #expect(PRLStore.loadDevices(b).map(\.id) == [owned.id, rental.id])
        let gotRental = try #require(PRLStore.loadDevices(b).last)
        #expect(gotRental.sourceKey == rental.sourceKey && gotRental.rentDaily == 24 && gotRental.hoursPerDay == 12)
        #expect(b.double(forKey: "prl.fee") == 0.02 && b.double(forKey: "prl.neth") == 20)
        #expect(b.string(forKey: "prl.sort") == SortKey.effic.rawValue)
        #expect(b.string(forKey: "prl.selected") == "RTX 5090")
        #expect(b.bool(forKey: "prl.budgetEnabled"))
        #expect(b.string(forKey: "prl.rentCcy") == "USD")
        #expect(PRLStore.loadRents(b)["RTX 4090"] == 12)
        let original = WebSharedMerge.read(a), copied = WebSharedMerge.read(b)
        #expect(WebSharedMerge.encoded(original.filter { $0.key != "devices" }) == WebSharedMerge.encoded(copied.filter { $0.key != "devices" }))
        let originalRows = try #require(original["devices"] as? [[String: Any]])
        let copiedRows = try #require(copied["devices"] as? [[String: Any]])
        #expect(WebSharedMerge.encoded(originalRows.map { WebSharedMerge.content($0, section: "devices") }) == WebSharedMerge.encoded(copiedRows.map { WebSharedMerge.content($0, section: "devices") }))
        let unchanged = try WebSharedMerge.merge(local: copied, remote: wire, base: received.base, now: 250)
        #expect(!unchanged.upload)

        var edited = PRLStore.loadDevices(b)
        edited[1].name = "Renamed cloud"; edited[1].rentDaily = 30
        b.set(try JSONEncoder().encode(edited), forKey: "prl.devices")
        b.set(SortKey.rentNet.rawValue, forKey: "prl.sort")
        let uploaded = try WebSharedMerge.merge(local: WebSharedMerge.read(b), remote: wire, base: received.base, now: 300)
        #expect(uploaded.upload)
        let back = try WebSharedMerge.merge(local: WebSharedMerge.read(a), remote: uploaded.config, base: first.base, now: 400)
        #expect(!back.upload)
        _ = try WebSharedMerge.apply(back.native, to: a)
        #expect(PRLStore.loadDevices(a).last?.name == "Renamed cloud")
        #expect(PRLStore.loadDevices(a).last?.rentDaily == 30)
        #expect(a.string(forKey: "prl.sort") == SortKey.rentNet.rawValue)

        b.set(try JSONEncoder().encode([Device]()), forKey: "prl.devices")
        let deleted = try WebSharedMerge.merge(local: WebSharedMerge.read(b), remote: uploaded.config, base: uploaded.base, now: 500)
        let removed = try WebSharedMerge.merge(local: WebSharedMerge.read(a), remote: deleted.config, base: back.base, now: 600)
        _ = try WebSharedMerge.apply(removed.native, to: a)
        #expect(PRLStore.loadDevices(a).isEmpty)
        #expect(!removed.upload)
    }

    @Test func sourceRentCurrencyAndFXSurviveWithoutAFetchedRateTable() throws {
        let suite = "AccountMiningSyncTests.rent." + UUID().uuidString, d = try defaults(suite)
        defer { d.removePersistentDomain(forName: suite) }
        d.set("USD", forKey: "currency.secondary"); d.set(7.2, forKey: "prl.fx")
        let rents: [String: Any] = ["RTX 4090": ["daily": 1500.0, "currency": "JPY", "fx": 150.0]]
        _ = try WebSharedMerge.apply(["fleetSettings.rents": rents], to: d)
        #expect(d.string(forKey: "prl.rentCcy") == "JPY")
        #expect(d.double(forKey: "prl.rentFX") == 150)
        #expect(WebSharedMerge.encoded(WebSharedMerge.read(d)["fleetSettings.rents"]!) == WebSharedMerge.encoded(rents))
        _ = try WebSharedMerge.apply(["fleetSettings.rents": [String: [String: Any]]()], to: d)
        #expect(PRLStore.loadRents(d).isEmpty)
    }

    /// A device set to follow the system language keeps doing so: it neither takes the
    /// account's language nor uploads one. Choosing a language makes it sync again.
    @Test func followingTheSystemLanguageSurvivesASync() throws {
        let suite = "AccountMiningSyncTests.lang." + UUID().uuidString, d = try defaults(suite)
        defer { d.removePersistentDomain(forName: suite) }
        let remote = WebLinkMerge.emptyConfig(lang: "zh-Hans")
        for stored in [nil, "system"] as [String?] {
            if let stored { d.set(stored, forKey: "app.language") }
            let out = try WebSharedMerge.merge(local: WebSharedMerge.read(d), remote: remote, base: nil, now: 100)
            #expect(!out.upload && out.native["lang"] == nil && out.base.settings["lang"] == nil)
            #expect(out.config["lang"] as? String == "zh-Hans")
            #expect(try !WebSharedMerge.apply(out.native, to: d).contains("app.language"))
        }
        d.set("ja", forKey: "app.language")
        let first = try WebSharedMerge.merge(local: WebSharedMerge.read(d), remote: remote, base: nil, now: 200)
        #expect(first.native["lang"] as? String == "zh-Hans")
        _ = try WebSharedMerge.apply(first.native, to: d)
        d.set("ja", forKey: "app.language")
        let edited = try WebSharedMerge.merge(local: WebSharedMerge.read(d), remote: first.config, base: first.base, now: 300)
        #expect(edited.upload && edited.config["lang"] as? String == "ja")
        // Back to following the system: the account keeps its language, and so does this device.
        d.set("system", forKey: "app.language")
        let back = try WebSharedMerge.merge(local: WebSharedMerge.read(d), remote: edited.config, base: edited.base, now: 400)
        #expect(!back.upload && back.native["lang"] == nil && back.config["lang"] as? String == "ja")
    }

    /// One setting that can't be shared — a slider parked outside the account's range here,
    /// a null or out-of-range value written there — is left alone on both sides, and the
    /// rest of the configuration still syncs.
    @Test func oneSettingThatCannotBeSharedDoesNotStopTheRest() throws {
        let suite = "AccountMiningSyncTests.invalid." + UUID().uuidString, d = try defaults(suite)
        defer { d.removePersistentDomain(forName: suite) }
        d.set(false, forKey: "prl.live"); d.set(0.0, forKey: "prl.price")
        d.set(0.02, forKey: "prl.fee"); d.set(6000.0, forKey: "prl.budget"); d.set(0.3, forKey: "prl.elec")
        var remote = WebLinkMerge.emptyConfig(lang: "en")
        remote["calculator"] = ["fee": NSNull(), "electricity": 0.1] as [String: Any]
        remote["fleetSettings"] = ["powerBudgetW": 0.0, "syncWPerTH": 2.5] as [String: Any]
        let out = try WebSharedMerge.merge(local: WebSharedMerge.read(d), remote: remote, base: nil, now: 100)
        // The parked slider is neither uploaded nor replaced.
        #expect(WebSharedMerge.value("calculator.price", in: out.config) == nil && out.native["calculator.price"] == nil)
        // What the account holds that this build can't read stays there, unadopted.
        #expect(out.native["calculator.fee"] == nil && out.native["fleetSettings.powerBudgetW"] == nil)
        #expect(WebSharedMerge.value("calculator.fee", in: out.config) is NSNull)
        #expect(out.native["calculator.electricity"] as? Double == 0.1 && out.native["fleetSettings.syncWPerTH"] as? Double == 2.5)
        let changed = try WebSharedMerge.apply(out.native, to: d)
        #expect(changed.contains("prl.elec") && changed.contains("prl.syncW"))
        #expect(d.double(forKey: "prl.price") == 0 && d.double(forKey: "prl.fee") == 0.02 && d.double(forKey: "prl.budget") == 6000)
        // Nothing was agreed for the skipped settings, so the next sync doesn't push them either.
        let again = try WebSharedMerge.merge(local: WebSharedMerge.read(d), remote: out.config, base: out.base, now: 200)
        #expect(!again.upload)
        // Moving the slider back into range uploads it.
        d.set(1.5, forKey: "prl.price")
        let moved = try WebSharedMerge.merge(local: WebSharedMerge.read(d), remote: out.config, base: out.base, now: 300)
        #expect(moved.upload && WebSharedMerge.value("calculator.price", in: moved.config) as? Double == 1.5)
        #expect(!WebSharedMerge.validSetting("fleetSettings.rents", ["RTX 4090": ["daily": -1.0, "currency": "USD"]]))
        #expect(WebSharedMerge.validSetting("fleetSettings.rents", ["RTX 4090": ["daily": 12.0, "currency": "JPY", "fx": 150.0]]))
    }

    /// The web's own pinned rate is carried through untouched when the app uploads.
    @Test func theWebsManualRateIsLeftAlone() throws {
        let suite = "AccountMiningSyncTests.fx." + UUID().uuidString, d = try defaults(suite)
        defer { d.removePersistentDomain(forName: suite) }
        d.set(0.92, forKey: "prl.fx"); d.set(0.25, forKey: "prl.elec")
        var remote = WebLinkMerge.emptyConfig(lang: "en")
        remote["fleetSettings"] = ["fxManual": true, "manualFX": 7.1] as [String: Any]
        let out = try WebSharedMerge.merge(local: WebSharedMerge.read(d), remote: remote, base: nil, now: 100)
        #expect(out.upload)   // the electricity price goes up
        _ = try WebSharedMerge.apply(out.native, to: d)
        #expect(d.double(forKey: "prl.fx") == 0.92 && d.bool(forKey: "prl.fxManual"))
        let wire = AccountConfig.clean(out.config)
        #expect((wire["fleetSettings"] as? [String: Any])?["manualFX"] as? Double == 7.1)
    }

    /// The session can vanish while the app still holds the account's preferences (a backup
    /// restored onto a new phone). They are kept as the account's, so signing in again does
    /// not bring back the copy from the first login and report everything since as deleted.
    @Test func aLostSessionKeepsTheAccountsLatestPreferences() throws {
        let suite = "AccountMiningSyncTests.lost." + UUID().uuidString, d = try defaults(suite)
        defer { d.removePersistentDomain(forName: suite) }
        d.set("u_a", forKey: "account.current")
        d.set(["prl.elec": 0.1], forKey: "account.prefs.u_a")           // as of the first login
        d.set(["prl.elec": 0.3], forKey: "account.prefs.guest")
        d.set(0.9, forKey: "prl.elec"); d.set(Data([1, 2, 3]), forKey: PoolStore.watchesKey)   // added since
        var announced = 0
        #expect(AccountPreferences.adopt(nil, defaults: d) { announced += 1 })
        #expect(announced == 1 && d.string(forKey: "account.current") == nil)
        #expect(d.double(forKey: "prl.elec") == 0.3 && d.data(forKey: PoolStore.watchesKey) == nil)
        let kept = try #require(d.dictionary(forKey: "account.prefs.u_a"))
        #expect(kept["prl.elec"] as? Double == 0.9 && kept[PoolStore.watchesKey] as? Data == Data([1, 2, 3]))
        // Nobody signed in and nobody was: nothing to do.
        #expect(!AccountPreferences.adopt(nil, defaults: d) { announced += 1 })
        // Signing in again finds what the account had.
        #expect(AccountPreferences.adopt("u_a", defaults: d))
        #expect(d.double(forKey: "prl.elec") == 0.9 && d.data(forKey: PoolStore.watchesKey) == Data([1, 2, 3]))
        #expect(d.string(forKey: "account.current") == "u_a" && !AccountPreferences.adopt("u_a", defaults: d))
        // A switch that was cut short is finished from the snapshot taken for it.
        d.set(["prl.elec": 0.5], forKey: "account.prefs.u_b"); d.set("u_b", forKey: "account.pendingPrefs")
        #expect(AccountPreferences.adopt("u_b", defaults: d))
        #expect(d.double(forKey: "prl.elec") == 0.5 && d.string(forKey: "account.pendingPrefs") == nil)
    }

    @Test func everyMiningPreferenceUsesAccountOwnershipWhenSignedIn() throws {
        let suite = "AccountMiningSyncTests.owner." + UUID().uuidString, d = try defaults(suite)
        defer { d.removePersistentDomain(forName: suite) }
        let keys = ["prl.devices", "prl.rents", "prl.rentCcy", "prl.rentFX", "prl.elec", "prl.fee", "prl.budget", "prl.budgetEnabled",
                    "prl.syncW", "prl.selfDilution", "prl.fxManual", "prl.live", "prl.rentEnabled",
                    "prl.rentCovers", "prl.auto", "prl.price", "prl.neth", "prl.pu", "prl.diffGrowth", "prl.sort", "prl.selected"]
        #expect(keys.allSatisfy { !CloudSync.accountOwns($0, defaults: d) })
        d.set("u_miner", forKey: "account.current")
        #expect(keys.allSatisfy { CloudSync.accountOwns($0, defaults: d) })
        // The rate is this device's own, signed in or not.
        #expect(!CloudSync.accountOwns("prl.fx", defaults: d) && !AccountPreferences.keys.contains("prl.fx"))
        #expect(!CloudSync.accountOwns("wallet.network", defaults: d))
        #expect(!AccountPreferences.keys.contains("wallet.seed"))
    }

    @Test @MainActor func hiddenMiningStoreSwitchesAllDataAndFlushesPendingManualEdits() throws {
        let suite = "AccountMiningSyncTests.switch." + UUID().uuidString, d = try defaults(suite)
        defer { d.removePersistentDomain(forName: suite) }
        d.set(true, forKey: "prl.fxManual")
        d.set(false, forKey: "prl.live")
        var saved = Set<String>()
        let store = PRLStore(defaults: d, onChange: { saved.insert($0) })
        store.devices = [Device(name: "Local rig", gpu: "RTX 5090", count: 2)]
        store.cfg.price = 3; store.cfg.nethashEH = 10; store.cfg.perUnit = 0.03
        store.cfg.diffGrowthMonthly = 20; store.sortKey = .pearl; store.selected = "RTX 5090"
        store.flushPending()
        #expect(Set(["prl.price", "prl.neth", "prl.pu", "prl.diffGrowth", "prl.sort", "prl.selected"]).isSubset(of: saved))
        AccountPreferences.snapshot(nil, defaults: d)
        AccountPreferences.restore("u_new", defaults: d); d.set("u_new", forKey: "account.current")
        store.reloadDevices(); store.reloadPrefs()
        #expect(store.devices.isEmpty && store.live)
        #expect(store.cfg.price == Config().price && store.cfg.diffGrowthMonthly == Config().diffGrowthMonthly)
        #expect(store.sortKey == .ownNet && store.selected == "RTX 5070")
        AccountPreferences.restore(nil, defaults: d); d.removeObject(forKey: "account.current")
        store.reloadDevices(); store.reloadPrefs()
        #expect(store.devices.first?.name == "Local rig")
        #expect(store.cfg.price == 3 && store.cfg.nethashEH == 10 && store.cfg.diffGrowthMonthly == 20)
        #expect(store.sortKey == .pearl && store.selected == "RTX 5090")
    }

    @Test @MainActor func alertsReplaceThePreviousAccountCacheInsteadOfMergingIt() throws {
        let suite = "AccountMiningSyncTests.alerts." + UUID().uuidString, d = try defaults(suite)
        defer { d.removePersistentDomain(forName: suite) }
        d.set(false, forKey: "alerts.pushHere")
        let guest = PriceAlertRule(id: "guest", kind: .above, value: 2, window: 0, changedAt: 100)
        d.set(try JSONEncoder().encode([guest]), forKey: "alerts.rules")
        d.set(CloudAlerts(rules: [guest.cloud]).encoded(), forKey: "alerts.sync")
        AccountPreferences.snapshot(nil, defaults: d)
        let store = PriceAlertStore(defaults: d)
        #expect(store.rules.map(\.id) == ["guest"])
        AccountPreferences.restore("u_a", defaults: d); d.set("u_a", forKey: "account.current")
        let account = PriceAlertRule(id: "account", kind: .below, value: 1, window: 0, changedAt: 200)
        d.set(CloudAlerts(rules: [account.cloud]).encoded(), forKey: "alerts.sync")
        store.cloudDidUpdate()
        #expect(store.rules.map(\.id) == ["account"])
        AccountPreferences.snapshot("u_a", defaults: d)
        AccountPreferences.restore("u_b", defaults: d); d.set("u_b", forKey: "account.current")
        store.cloudDidUpdate()
        #expect(store.rules.isEmpty)
        AccountPreferences.restore(nil, defaults: d); d.removeObject(forKey: "account.current")
        store.cloudDidUpdate()
        #expect(store.rules.map(\.id) == ["guest"])
        #expect(CloudAlerts.decode(d.data(forKey: "alerts.sync"))?.rules.map(\.id) == ["guest"])
    }
}


struct ProDataSyncTests {
    @Test func freeAccountsCannotSyncThroughICloud() throws {
        let suite = "ProDataSyncTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!CloudSync.canSync(defaults: defaults))
        defaults.set("u_free", forKey: "account.current")
        #expect(!CloudSync.canSync(defaults: defaults))
        defaults.set(true, forKey: "pro.accountSync")
        #expect(CloudSync.canSync(defaults: defaults))
        defaults.set(false, forKey: "pro.accountSync")
        #expect(!CloudSync.canSync(defaults: defaults))
        defaults.set(true, forKey: "pro.unlocked")
        #expect(CloudSync.canSync(defaults: defaults))
        defaults.set(false, forKey: "pro.unlocked")
        defaults.removeObject(forKey: "account.current")
        defaults.set(true, forKey: "pro.accountSync")
        #expect(!CloudSync.canSync(defaults: defaults))
    }
}

struct WebWalletSyncTests {
    private let a = "prl1" + String(repeating: "a", count: 38)
    private let b = "prl1" + String(repeating: "b", count: 38)
    private func live(_ config: [String: Any]) -> [[String: Any]] {
        ((config["wallets"] as? [[String: Any]]) ?? []).filter { $0["deleted"] as? Bool != true }
    }

    @Test func theAppsWalletsShowOnTheWebOnceAndOneWay() throws {
        let rows = WebSharedMerge.walletRows([
            WalletRecord(id: "primary", name: "Main", addresses: ["mainnet": a]),
            WalletRecord(id: "t", name: "Testnet only", addresses: ["testnet": "tprl1" + String(repeating: "c", count: 38)]),
            WalletRecord(id: "dup", name: "Same seed again", addresses: ["mainnet": a]),
        ])
        #expect(rows.count == 1)
        let first = try WebSharedMerge.merge(local: ["wallets": rows], remote: [:], base: nil, now: 10)
        #expect(first.upload)
        #expect(live(first.config).map { [$0["addr"] as? String, $0["label"] as? String] } == [[a, "Main"]])
        #expect(first.native["wallets"] == nil)          // nothing comes back into the app
        let again = try WebSharedMerge.merge(local: ["wallets": rows], remote: first.config, base: first.base, now: 20)
        #expect(!again.upload)
    }

    @Test func theIdComesFromTheAddressSoTwoDevicesShareOneEntry() throws {
        let phone = WebSharedMerge.walletRows([WalletRecord(id: "primary", name: "Phone", addresses: ["mainnet": a])])
        let mac = WebSharedMerge.walletRows([WalletRecord(id: UUID().uuidString.lowercased(), name: "Mac", addresses: ["mainnet": a])])
        let other = WebSharedMerge.walletRows([WalletRecord(id: "primary", name: "Other", addresses: ["mainnet": b])])
        #expect(phone[0]["id"] as? String == mac[0]["id"] as? String)
        #expect(phone[0]["id"] as? String != other[0]["id"] as? String)
        #expect((phone[0]["id"] as? String)?.range(of: "^[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil)
        let fromPhone = try WebSharedMerge.merge(local: ["wallets": phone], remote: [:], base: nil, now: 10)
        let fromMac = try WebSharedMerge.merge(local: ["wallets": mac], remote: fromPhone.config, base: nil, now: 20)
        #expect(live(fromMac.config).count == 1)
    }

    @Test func aWatchAlreadyThereGetsNoTwinAndTheWebsCapHolds() throws {
        let own = ["id": "web-1", "updated": 5, "addr": a, "label": "Mine"] as [String: Any]
        let rows = WebSharedMerge.walletRows([WalletRecord(id: "1", name: "A", addresses: ["mainnet": a]),
                                              WalletRecord(id: "2", name: "B", addresses: ["mainnet": b])])
        let r = try WebSharedMerge.merge(local: ["wallets": rows], remote: ["wallets": [own]], base: nil, now: 10)
        #expect(live(r.config).map { $0["addr"] as? String } == [a, b])
        let full = (0..<10).map { ["id": "web-\($0)", "updated": 5, "addr": "prl1" + String(repeating: "q", count: 37) + "\($0)", "label": "x"] as [String: Any] }
        let capped = try WebSharedMerge.merge(local: ["wallets": rows], remote: ["wallets": full], base: nil, now: 10)
        #expect(!capped.upload && live(capped.config).count == 10)
    }

    @Test func renamedOrRemovedThereStaysUntilTheWalletChangesHere() throws {
        let rows = WebSharedMerge.walletRows([WalletRecord(id: "1", name: "A", addresses: ["mainnet": a])])
        let first = try WebSharedMerge.merge(local: ["wallets": rows], remote: [:], base: nil, now: 10)
        var remote = first.config
        var entry = try #require((remote["wallets"] as? [[String: Any]])?.first)
        entry = ["id": entry["id"]!, "updated": 50, "deleted": true]
        remote["wallets"] = [entry]
        let kept = try WebSharedMerge.merge(local: ["wallets": rows], remote: remote, base: first.base, now: 60)
        #expect(!kept.upload && live(kept.config).isEmpty)
        let renamed = WebSharedMerge.walletRows([WalletRecord(id: "1", name: "A2", addresses: ["mainnet": a])])
        let back = try WebSharedMerge.merge(local: ["wallets": renamed], remote: remote, base: kept.base, now: 70)
        #expect(back.upload && live(back.config).map { $0["label"] as? String } == ["A2"])
    }

    @Test func aWalletRemovedHereLeavesATombstoneThere() throws {
        let rows = WebSharedMerge.walletRows([WalletRecord(id: "1", name: "A", addresses: ["mainnet": a])])
        let first = try WebSharedMerge.merge(local: ["wallets": rows], remote: ["wallets": [["id": "web-1", "updated": 5, "addr": b, "label": "Mine"]]], base: nil, now: 10)
        let gone = try WebSharedMerge.merge(local: ["wallets": [[String: Any]]()], remote: first.config, base: first.base, now: 20)
        #expect(gone.upload)
        #expect(live(gone.config).map { $0["id"] as? String } == ["web-1"])   // the web's own entry stays
        let tomb = try #require((gone.config["wallets"] as? [[String: Any]])?.first { $0["deleted"] as? Bool == true })
        #expect(Set(tomb.keys) == ["id", "updated", "deleted"])
    }

    @Test func longNamesFitTheWebsFortyUnits() {
        let rows = WebSharedMerge.walletRows([WalletRecord(id: "1", name: String(repeating: "钱", count: 39) + "😀😀", addresses: ["mainnet": a])])
        let label = rows.first?["label"] as? String ?? ""
        #expect(label.utf16.count <= 40 && label.hasPrefix(String(repeating: "钱", count: 39)))
    }

    @Test func readTakesTheWalletListAndLeavesAnUnreadableOneAlone() throws {
        let suite = "weblink-wallets-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect((WebSharedMerge.read(defaults)["wallets"] as? [[String: Any]])?.isEmpty == true)
        defaults.set(try JSONEncoder().encode([WalletRecord(id: "1", name: "A", addresses: ["mainnet": a])]), forKey: "wallet.list")
        #expect((WebSharedMerge.read(defaults)["wallets"] as? [[String: Any]])?.first?["addr"] as? String == a)
        defaults.set(Data("[{\"future\":1}]".utf8), forKey: "wallet.list")
        #expect(WebSharedMerge.read(defaults)["wallets"] == nil)
        #expect(!WebSharedMerge.nativeKeys.contains("wallet.list"))   // never swapped per account
    }
}

/// Sign in once, on every device: when a signed-in device leaves a fresh ticket in iCloud
/// Keychain, and which ticket a device that isn't signed in may use.
struct DeviceTicketTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ticket(user: String = "u_me", device: String = "phone", age: TimeInterval = 0,
                        life: TimeInterval = 30 * 86400) -> DeviceTicket {
        let issued = now.addingTimeInterval(-age)
        return DeviceTicket(user: user, email: "me@example.com", ticket: String(repeating: "t", count: 43),
                            device: device, issued: issued, expires: issued.addingTimeInterval(life))
    }

    @Test func roundTripsThroughTheKeychainText() throws {
        let t = ticket()
        let text = try #require(t.encoded)
        #expect(DeviceTicket.decode(text) == t)
        #expect(DeviceTicket.decode("not json") == nil)
    }

    @Test func aSignedInDeviceRenewsItsAccountsTicketWeekly() {
        #expect(DeviceTicket.needsIssue(nil, user: "u_me", now: now))
        #expect(!DeviceTicket.needsIssue(ticket(age: 86400), user: "u_me", now: now))
        // Issued by another device of the same account: renewed all the same once it's a week old.
        #expect(!DeviceTicket.needsIssue(ticket(device: "mac", age: 6 * 86400), user: "u_me", now: now))
        #expect(DeviceTicket.needsIssue(ticket(device: "mac", age: 7 * 86400), user: "u_me", now: now))
        // About to run out.
        #expect(DeviceTicket.needsIssue(ticket(age: 0, life: 3600), user: "u_me", now: now))
    }

    @Test func anotherAccountsLiveTicketIsLeftAlone() {
        #expect(!DeviceTicket.needsIssue(ticket(user: "u_other", age: 20 * 86400), user: "u_me", now: now))
        #expect(DeviceTicket.needsIssue(ticket(user: "u_other", age: 30 * 86400), user: "u_me", now: now))
    }

    @Test func onlyAnotherInstallationsTicketInDateIsUsable() {
        #expect(DeviceTicket.usable(nil, device: "mac", now: now) == nil)
        #expect(DeviceTicket.usable(ticket(), device: "mac", now: now) == ticket())
        #expect(DeviceTicket.usable(ticket(), device: nil, now: now) == ticket())   // never signed in here
        #expect(DeviceTicket.usable(ticket(), device: "phone", now: now) == nil)    // its own
        #expect(DeviceTicket.usable(ticket(age: 30 * 86400), device: "mac", now: now) == nil)
    }
}
