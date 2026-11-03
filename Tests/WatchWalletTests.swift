import Foundation
import Testing
@testable import Pearl

/// Canned Blockbook `/address/` answers for the read-only wallet tests, keyed by path so both
/// indexers (ours and the official one) give the same reply. Its own class rather than
/// `StubURLProtocol`, so another suite's `reset()` can't pull these replies away mid-test.
final class WatchStubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Data] = [:]

    static func answer(_ address: String, with json: String) {
        lock.lock(); defer { lock.unlock() }
        replies["/api/v2/address/\(address)"] = Data(json.utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return replies[request.url?.path ?? ""] != nil
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let body = Self.replies[request.url?.path ?? ""] ?? Data()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Read-only wallets: an address with no seed, listed with the other wallets (设置 → 管理钱包,
/// the toolbar switcher) and read through Blockbook's `/address/` endpoint.
@MainActor
struct WatchWalletTests {
    // Public addresses (the donation wallet's, and a payout of it), plus the same keys on testnet.
    static let mainA = "prl1pmkyxyht58rzhe7cj9ha7ncpm6r28x6g0htq93ffs5hsh7lqsxj7qw9pyjv"
    static let mainB = "prl1pj28m69zrlduk2y5gwsvuyrs69kdc9ad4h9nul3rr42qlwwdc7jrq887tul"
    static let testA = "tprl1pmkyxyht58rzhe7cj9ha7ncpm6r28x6g0htq93ffs5hsh7lqsxj7q9296de"
    static let testB = "tprl1pj28m69zrlduk2y5gwsvuyrs69kdc9ad4h9nul3rr42qlwwdc7jrqvg64r2"
    static let outsider = "prl1paq33sk7pmxwxmdmdktskxlhrlgsr9satfwul4m352w6vl6najh2stduuqg"

    /// 4 PRL confirmed, one unconfirmed send of 0.7 PRL (change back to the same address), one
    /// confirmed receipt of 1.5 PRL; a second page exists.
    static func page(for a: String) -> String {
        """
        {"page":1,"totalPages":2,"address":"\(a)","balance":"400000000","unconfirmedBalance":"-71000000",
         "unconfirmedTxs":1,"txs":3,"transactions":[
          {"txid":"\(String(repeating: "a", count: 64))","blockHeight":-1,"confirmations":0,"blockTime":1761500000,"fees":"1000000",
           "vin":[{"addresses":["\(a)"],"value":"200000000"}],
           "vout":[{"addresses":["\(outsider)"],"value":"70000000"},{"addresses":["\(a)"],"value":"129000000"}]},
          {"txid":"\(String(repeating: "b", count: 64))","blockHeight":130000,"confirmations":5,"blockTime":1761400000,"fees":"500",
           "vin":[{"addresses":["\(outsider)"],"value":"150000500"}],
           "vout":[{"addresses":["\(a)"],"value":"150000000"}]}
        ]}
        """
    }

    private static func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WatchStubProtocol.self]
        return URLSession(configuration: config)
    }

    @Test func recordsFromBeforeReadOnlyWalletsStillDecode() throws {
        let old = Data(#"[{"id":"primary","name":"Pearl Wallet","addresses":{"mainnet":"\#(Self.mainA)"}}]"#.utf8)
        let records = try JSONDecoder().decode([WalletRecord].self, from: old)
        #expect(records.first?.isWatchOnly == false)
        let watch = WalletRecord(id: "w", name: "Pool", addresses: ["mainnet": Self.mainB], watchAddress: Self.mainB)
        let back = try JSONDecoder().decode(WalletRecord.self, from: JSONEncoder().encode(watch))
        #expect(back == watch && back.isWatchOnly)
    }

    @Test func addressNetworkIsRecognised() {
        #expect(PRLAddress.network(of: Self.mainA) == .mainnet)
        #expect(PRLAddress.network(of: Self.testA) == .testnet)
        #expect(PRLAddress.network(of: "prl1notanaddress") == nil)
    }

    /// Directions and amounts as seen from the one watched address: change back to it isn't
    /// "sent", and the balance includes the mempool delta.
    @Test func addressHistoryIsReadFromTheWatchedAddressesPointOfView() async throws {
        WatchStubProtocol.answer(Self.mainA, with: Self.page(for: Self.mainA))
        let bb = BlockbookClient(bases: ["https://bb.watch.test"], session: Self.stubbedSession())
        let summary = try await bb.summaryFrom(address: Self.mainA)
        #expect(summary.summary.confirmed == 4 && summary.summary.unconfirmed == Decimal(string: "-0.71"))
        #expect(summary.summary.txCount == 3 && summary.base == "https://bb.watch.test")

        let account = try await bb.account(address: Self.mainA)
        #expect(account.hasMorePages)
        #expect(account.txs.count == 2)
        let sent = try #require(account.txs.first)
        #expect(sent.direction == .sent && sent.amount == Decimal(string: "0.7") && sent.address == Self.outsider)
        #expect(sent.fee == Decimal(string: "0.01") && sent.confirmations == 0 && sent.height == nil)
        let received = try #require(account.txs.last)
        #expect(received.direction == .received && received.amount == Decimal(string: "1.5"))
        #expect(received.address == Self.mainA && received.height == 130000)
    }

    /// The widget reads a read-only wallet's balance from `/address/` (it gets the address where
    /// a seed wallet hands it an xpub).
    @Test func widgetReadsAWatchedAddress() async {
        URLProtocol.registerClass(WatchStubProtocol.self)
        WatchStubProtocol.answer(Self.mainB, with: Self.page(for: Self.mainB))
        let balance = await WidgetFetch.balancePRL(xpub: Self.mainB, network: "mainnet")
        #expect(balance.map { abs($0 - 3.29) < 1e-9 } == true)
    }

    /// Read-only wallets go to the web's wallet page like the others (its first address + name).
    @Test func readOnlyWalletsSyncToTheWebLikeTheOthers() {
        let rows = WebSharedMerge.walletRows([WalletRecord(id: "w", name: "Pool", addresses: ["mainnet": Self.mainB],
                                                           watchAddress: Self.mainB)])
        #expect(rows.count == 1 && rows.first?["addr"] as? String == Self.mainB)
    }

    /// Add → load → duplicate → second wallet → switch → lock/unlock → remove, with no seed and
    /// no Keychain item anywhere. Runs on a throwaway store; the wallet list it saves is put back.
    @Test func readOnlyWalletLifecycle() async throws {
        let d = UserDefaults.standard
        let keys = ["wallet.list", "wallet.active", "wallet.locked"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        URLProtocol.registerClass(WatchStubProtocol.self)

        let store = WalletStore()
        let (a, b) = store.network == .mainnet ? (Self.mainA, Self.mainB) : (Self.testA, Self.testB)
        WatchStubProtocol.answer(a, with: Self.page(for: a))
        WatchStubProtocol.answer(b, with: Self.page(for: b))

        #expect(!store.commitWatchWallet(name: "x", address: "prl1notanaddress"))
        #expect(store.lastError != nil && store.wallets.isEmpty)

        // Pasted with stray spaces, in capitals (as a QR code carries it): stored lower-case.
        #expect(store.commitWatchWallet(name: "  ", address: "  \(a.uppercased())\n"))
        let first = try #require(store.activeRecord)
        #expect(first.watchAddress == a && first.addresses[store.network.rawValue] == a)
        #expect(first.name == Loc("只读钱包"))
        #expect(store.phase == .unlocked && store.isWatchOnly && store.mnemonic == nil && store.watchAddress == a)
        defer {
            for id in store.wallets.map(\.id) {
                for net in WalletNetwork.allCases { d.removeObject(forKey: "change.\(id).\(net.rawValue).lastBalance") }
            }
        }

        await store.loadChain()
        #expect(store.address == a)
        #expect(store.balance.total == Decimal(string: "3.29"))
        #expect(store.historyReady && store.txs.count == 2 && store.historyHasMore)
        #expect(store.ownAddresses == [a])

        // The same address again opens the existing entry instead of adding one.
        #expect(store.commitWatchWallet(name: "dup", address: a))
        #expect(store.wallets.count == 1)

        #expect(store.commitWatchWallet(name: "Pool", address: b))
        #expect(store.wallets.count == 2 && store.walletName == "Pool" && store.watchAddress == b)
        #expect(store.switchWallet(to: first.id) && store.watchAddress == a)

        store.authenticateOverride = { _ in true }
        store.lock()
        #expect(store.phase == .locked && store.watchAddress == nil)
        await store.unlock()
        #expect(store.phase == .unlocked && store.watchAddress == a)

        // Removing the open one opens the other — nothing to delete from the Keychain.
        #expect(store.removeWallet(id: first.id))
        #expect(store.wallets.count == 1 && store.watchAddress == b && store.phase == .unlocked)
        #expect(d.object(forKey: "change.\(first.id).\(store.network.rawValue).lastBalance") == nil)
    }
}

/// The web's 钱包 page and the app's read-only wallets, both ways (`WebSharedMerge.wallets`).
struct WebReadOnlyWalletSyncTests {
    private let a = "prl1" + String(repeating: "a", count: 38)
    private let b = "prl1" + String(repeating: "b", count: 38)
    private let c = "prl1" + String(repeating: "c", count: 38)
    private func live(_ config: [String: Any]) -> [[String: Any]] {
        ((config["wallets"] as? [[String: Any]]) ?? []).filter { $0["deleted"] as? Bool != true }
    }
    private func seed(_ addr: String, _ name: String) -> WalletRecord { WalletRecord(id: UUID().uuidString, name: name, addresses: ["mainnet": addr]) }
    private func watch(_ addr: String, _ name: String) -> WalletRecord {
        WalletRecord(id: UUID().uuidString, name: name, addresses: ["mainnet": addr], watchAddress: addr)
    }
    private func entry(_ config: [String: Any], _ addr: String) -> [String: Any]? { live(config).first { $0["addr"] as? String == addr } }

    /// An address added on the web arrives as a read-only wallet, once; taking it in adds no twin there.
    @Test func webAddressesBecomeReadOnlyWalletsHere() throws {
        let web: [String: Any] = ["wallets": [["id": "4b0c0f5e-0000-4000-8000-000000000001", "updated": 5, "addr": b, "label": "Pool B"]]]
        let first = try WebSharedMerge.merge(local: ["wallets": WebSharedMerge.walletRows([seed(a, "Main")])], remote: web, base: nil, now: 10)
        #expect(first.wallets.added == [.init(addr: b, label: "Pool B")])
        #expect(first.wallets.renamed.isEmpty && first.wallets.removed.isEmpty)
        // Next sync, with the wallet now here: nothing to send, nothing new, still one entry for b.
        let local = WebSharedMerge.walletRows([seed(a, "Main"), watch(b, "Pool B")])
        let next = try WebSharedMerge.merge(local: ["wallets": local], remote: first.config, base: first.base, now: 20)
        #expect(!next.upload && next.wallets.isEmpty)
        #expect(live(next.config).count == 2)
    }

    /// Another device's wallet (an entry with the app's own id scheme) comes in the same way.
    @Test func anotherDevicesWalletComesInReadOnly() throws {
        let mac = try WebSharedMerge.merge(local: ["wallets": WebSharedMerge.walletRows([seed(c, "Mac")])], remote: [:], base: nil, now: 10)
        let phone = try WebSharedMerge.merge(local: ["wallets": WebSharedMerge.walletRows([seed(a, "Phone")])], remote: mac.config, base: nil, now: 20)
        #expect(phone.wallets.added == [.init(addr: c, label: "Mac")])
        let after = try WebSharedMerge.merge(local: ["wallets": WebSharedMerge.walletRows([seed(a, "Phone"), watch(c, "Mac")])],
                                             remote: phone.config, base: phone.base, now: 30)
        #expect(!after.upload && after.wallets.isEmpty && live(after.config).count == 2)
    }

    @Test func renamesTravelBothWaysAndTheWebWinsATie() throws {
        let id = "4b0c0f5e-0000-4000-8000-000000000002"
        let first = try WebSharedMerge.merge(local: ["wallets": [[String: Any]]()],
                                             remote: ["wallets": [["id": id, "updated": 5, "addr": b, "label": "B"]]], base: nil, now: 10)
        // Renamed here → renamed there.
        let mine = try WebSharedMerge.merge(local: ["wallets": WebSharedMerge.walletRows([watch(b, "B here")])],
                                            remote: first.config, base: first.base, now: 20)
        #expect(mine.upload && entry(mine.config, b)?["label"] as? String == "B here")
        #expect(mine.wallets.isEmpty)
        // Renamed there → renamed here.
        var remote = mine.config
        remote["wallets"] = (remote["wallets"] as? [[String: Any]] ?? []).map { var r = $0; r["label"] = "B web"; r["updated"] = 99; return r }
        let theirs = try WebSharedMerge.merge(local: ["wallets": WebSharedMerge.walletRows([watch(b, "B here")])],
                                              remote: remote, base: mine.base, now: 100)
        #expect(theirs.wallets.renamed == [b: "B web"] && !theirs.upload)
        // Both renamed: the web's name is taken.
        let both = try WebSharedMerge.merge(local: ["wallets": WebSharedMerge.walletRows([watch(b, "B again")])],
                                            remote: remote, base: mine.base, now: 100)
        #expect(both.wallets.renamed == [b: "B web"])
    }

    @Test func removalsTravelBothWays() throws {
        let id = "4b0c0f5e-0000-4000-8000-000000000003"
        let first = try WebSharedMerge.merge(local: ["wallets": [[String: Any]]()],
                                             remote: ["wallets": [["id": id, "updated": 5, "addr": b, "label": "B"]]], base: nil, now: 10)
        let linked = try WebSharedMerge.merge(local: ["wallets": WebSharedMerge.walletRows([watch(b, "B")])],
                                              remote: first.config, base: first.base, now: 20)
        // Removed here → a tombstone there.
        let gone = try WebSharedMerge.merge(local: ["wallets": [[String: Any]]()], remote: linked.config, base: linked.base, now: 30)
        #expect(gone.upload && live(gone.config).isEmpty)
        // Removed there → removed here.
        let tomb: [String: Any] = ["wallets": [["id": id, "updated": 50, "deleted": true]]]
        let there = try WebSharedMerge.merge(local: ["wallets": WebSharedMerge.walletRows([watch(b, "B")])], remote: tomb, base: linked.base, now: 60)
        #expect(there.wallets.removed == [b] && !there.upload)
    }

    /// A read-only wallet added here goes to the web and then follows it like the others.
    @Test func aReadOnlyWalletAddedHereFollowsTheWebAfterwards() throws {
        let rows = WebSharedMerge.walletRows([watch(c, "C")])
        let pushed = try WebSharedMerge.merge(local: ["wallets": rows], remote: [:], base: nil, now: 10)
        #expect(pushed.upload && entry(pushed.config, c)?["label"] as? String == "C")
        #expect(pushed.wallets.isEmpty)
        #expect((pushed.config["wallets"] as? [[String: Any]])?.first?["watch"] == nil)   // the flag stays here
        var remote = pushed.config
        remote["wallets"] = (remote["wallets"] as? [[String: Any]] ?? []).map { ["id": $0["id"]!, "updated": 80, "deleted": true] }
        let removed = try WebSharedMerge.merge(local: ["wallets": rows], remote: remote, base: pushed.base, now: 90)
        #expect(removed.wallets.removed == [c])
    }

    /// A wallet with its seed here only ever pushes: the web removing or renaming it changes nothing here.
    @Test func aWalletWithItsSeedHereNeverFollowsTheWeb() throws {
        let rows = WebSharedMerge.walletRows([seed(a, "Main")])
        let pushed = try WebSharedMerge.merge(local: ["wallets": rows], remote: [:], base: nil, now: 10)
        var remote = pushed.config
        remote["wallets"] = (remote["wallets"] as? [[String: Any]] ?? []).map { var r = $0; r["label"] = "Renamed"; r["updated"] = 50; return r }
        let renamed = try WebSharedMerge.merge(local: ["wallets": rows], remote: remote, base: pushed.base, now: 60)
        #expect(renamed.wallets.isEmpty && !renamed.upload)
        remote["wallets"] = (remote["wallets"] as? [[String: Any]] ?? []).map { ["id": $0["id"]!, "updated": 70, "deleted": true] }
        let removed = try WebSharedMerge.merge(local: ["wallets": rows], remote: remote, base: pushed.base, now: 80)
        #expect(removed.wallets.isEmpty && !removed.upload)
    }
}

/// `WalletStore.applyWebWallets`: what the web changed, applied to the wallet list.
@MainActor
struct ApplyWebWalletsTests {
    @Test func addsRenamesAndRemovesReadOnlyWalletsOnly() async throws {
        let d = UserDefaults.standard
        let keys = ["wallet.list", "wallet.active", "wallet.locked"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        d.removeObject(forKey: "wallet.list"); d.removeObject(forKey: "wallet.active")
        URLProtocol.registerClass(WatchStubProtocol.self)
        let (a, b) = (WatchWalletTests.mainA, WatchWalletTests.mainB)
        WatchStubProtocol.answer(a, with: WatchWalletTests.page(for: a))
        WatchStubProtocol.answer(b, with: WatchWalletTests.page(for: b))

        let store = WalletStore()
        store.bootstrap()
        try #require(store.phase == .noWallet)   // the test host has no wallet
        defer {
            for id in store.wallets.map(\.id) {
                for net in WalletNetwork.allCases { d.removeObject(forKey: "change.\(id).\(net.rawValue).lastBalance") }
            }
        }
        // Added on the web, with nothing open here: the first one opens.
        #expect(store.applyWebWallets(WebWalletChanges(added: [.init(addr: a, label: "Web A"), .init(addr: b, label: "Web B"),
                                                              .init(addr: a, label: "Twin")])))
        #expect(store.wallets.map(\.name) == ["Web A", "Web B"])
        #expect(store.phase == .unlocked && store.watchAddress == a)
        #expect(!store.applyWebWallets(WebWalletChanges(added: [.init(addr: b, label: "Again")])))   // already here

        #expect(store.applyWebWallets(WebWalletChanges(renamed: [b: "Pool B"])))
        #expect(store.wallets.last?.name == "Pool B")

        // Removed on the web: the open one goes and the other opens.
        #expect(store.applyWebWallets(WebWalletChanges(removed: [a])))
        #expect(store.wallets.map(\.name) == ["Pool B"] && store.watchAddress == b)
    }
}
