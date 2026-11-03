import Foundation
import Combine

/// NOCK amounts in nicks (1 NOCK = 65 536 nicks).
struct NockBalance: Codable, Equatable {
    /// Everything the wallet holds, including mining rewards still locked and change from
    /// sends not yet mined.
    var total: UInt64
    /// Spendable now.
    var available: UInt64
    /// Mining rewards inside their 100-block lock.
    var locked: UInt64
    static let zero = NockBalance(total: 0, available: 0, locked: 0)
}

/// One row of the NOCK history. The node has no per-address history, so the wallet keeps
/// its own: a row per note it sees arrive, plus the sends it broadcast.
struct NockTx: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case received, mined, sent }
    enum Status: String, Codable { case pending, confirmed, failed }
    /// The txid for a send; "note:<name>" for a note that arrived.
    let id: String
    var kind: Kind
    /// nicks — sent to the recipient, or received.
    var amount: UInt64
    var fee: UInt64?
    /// Recipient of a send.
    var counterparty: String?
    var txId: String?
    var height: UInt64?
    var time: Date
    /// `time` is the block's own timestamp (false: estimated from the height, fetched later).
    var timeExact: Bool
    var status: Status
}

/// A signed NOCK send awaiting the user's confirmation (nothing has left the device yet).
struct NockPreparedSend: Identifiable {
    let txId: String
    let recipient: String
    let amount: UInt64
    let fee: UInt64
    let change: UInt64
    /// What comes back to this wallet: the change, or — sent to itself — everything but the fee.
    let returning: UInt64
    let sweep: Bool
    let body: Data
    let inputs: [String]
    let changeNotes: [String]
    let walletID: String
    let generation: Int
    let createdAt = Date()
    var id: String { txId }
    /// Worth a second look: the fee is a tenth of the amount or more.
    var feeIsHigh: Bool { amount > 0 && fee * 10 >= amount }
}

/// Drives the NOCK side of the open wallet. The account comes from the same seed as the PRL
/// wallet (read from `WalletStore` while it is unlocked); chain state from the public nodes in
/// `NockClient.nodes` (rpc.nockbox.org, then the official CLI's node).
/// Per-wallet state (address, last balance, history, sends in flight) is kept locally and
/// never synced — like the seed it belongs to.
@MainActor
final class NockWalletStore: ObservableObject {
    static let shared = NockWalletStore()

    @Published private(set) var account: NockCore.Account?
    @Published private(set) var balance: NockBalance = .zero
    @Published private(set) var notes: [NockNote] = []
    @Published private(set) var history: [NockTx] = []
    @Published private(set) var tipHeight: UInt64?
    /// A fresh read landed this session.
    @Published private(set) var backendReady = false
    /// What's shown is last session's snapshot, until the first fresh read.
    @Published private(set) var balanceIsCached = false
    @Published private(set) var syncError: String?
    private(set) var lastSyncedAt: Date?

    /// NOCK is opt-in (设置 → 钱包, this device only). Off: no NOCK key is derived, no node is
    /// asked, and the wallet page has no NOCK entry. Saved NOCK history stays for when it's
    /// switched back on.
    @Published private(set) var enabled: Bool
    nonisolated static let enabledKey = "nock.enabled"

    var hasBalance: Bool { backendReady || balanceIsCached }
    /// This wallet uses NOCK: it has fetched its address from the receive page, or holds or
    /// has held NOCK. The wallet page then shows the NOCK card where it otherwise shows only a
    /// one-line link at the bottom.
    var inUse: Bool { state.addressShown || balance.total > 0 || !history.isEmpty }

    /// The receive page is showing the address.
    func markAddressShown() {
        guard walletID != nil, address != nil, !state.addressShown else { return }
        objectWillChange.send()
        state.addressShown = true
        persist()
    }
    var address: String? { account?.address ?? state.address }
    /// The Rust core is linked (checked once — it can't change while running).
    private static let coreAvailable = NockCore.isAvailable
    var coreOK: Bool { Self.coreAvailable }
    var hasPendingSend: Bool { state.pending.contains { $0.status == .pending } }
    var hasUnverifiedSend: Bool { state.pending.contains { $0.status == .pending && !$0.verified } }
    /// Poll faster while a send waits for its block (~150 s apart).
    var pollInterval: Duration { hasPendingSend ? .seconds(20) : .seconds(60) }

    /// Seconds between blocks since Aletheia — only to estimate a time until the real one loads.
    nonisolated static let blockSeconds: TimeInterval = 150
    nonisolated static let preparedLifetime: TimeInterval = 600
    /// An unconfirmed send the node no longer knows after this long has been dropped.
    nonisolated static let dropAfter: TimeInterval = 30 * 60
    nonisolated static let historyLimit = 1_000
    /// How often nockscan is asked again while nothing new arrived (a new note, a settled send
    /// or a pull to refresh ask at once), and how often the whole history is re-read.
    nonisolated static let scanEvery: TimeInterval = 5 * 60
    nonisolated static let fullScanEvery: TimeInterval = 24 * 3600

    private let client = NockClient()
    private let scan = NockScan()
    /// Last nockscan read this session (nil: not yet — the first load reads it).
    private var scanAt: Date?
    /// A NOCK page was opened this session: read the history even when this device has no sign
    /// of NOCK use.
    private var historyRequested = false
    private var forceScanNext = false
    private var walletID: String?
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var loadAgain = false
    private var lastLoadAt: Date?
    private var subscriptions: Set<AnyCancellable> = []
    private var blockTimes: [UInt64: Date] = [:]
    private var retriedFirstLoad = false

    // MARK: Persisted per-wallet state

    struct PendingSend: Codable, Hashable {
        let txId: String
        let recipient: String
        let amount: UInt64
        let fee: UInt64
        /// What comes back to this wallet once mined: the change (or, sent to self, all but the fee).
        let returningNicks: UInt64
        let inputs: [String]
        /// Our own outputs of this tx — they arrive as notes but aren't income.
        let changeNotes: [String]
        let createdAt: Date
        /// The node acknowledged it (false: the broadcast's outcome is unknown).
        var verified: Bool
        var status: NockTx.Status
    }

    struct State: Codable {
        var address: String?
        var balance: NockBalance?
        var tip: UInt64?
        var history: [NockTx] = []
        /// Notes already accounted for (a row, or our own change) → when last seen. Kept a few
        /// days after a note goes, so one that drops out of a single read doesn't come back as
        /// a second "received" row.
        var seen: [String: Date] = [:]
        var pending: [PendingSend] = []
        var syncedAt: Date?
        /// The receive page showed this wallet's NOCK address (the user went to get it).
        var addressShown = false
        /// Last time nockscan's history for the address was read to the end (or to the limit).
        var fullScanAt: Date?

        init() {}
        // Lenient: a field added later must not make an older saved state unreadable.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            address = try c.decodeIfPresent(String.self, forKey: .address)
            balance = try c.decodeIfPresent(NockBalance.self, forKey: .balance)
            tip = try c.decodeIfPresent(UInt64.self, forKey: .tip)
            history = try c.decodeIfPresent([NockTx].self, forKey: .history) ?? []
            seen = try c.decodeIfPresent([String: Date].self, forKey: .seen) ?? [:]
            pending = try c.decodeIfPresent([PendingSend].self, forKey: .pending) ?? []
            syncedAt = try c.decodeIfPresent(Date.self, forKey: .syncedAt)
            addressShown = try c.decodeIfPresent(Bool.self, forKey: .addressShown) ?? false
            fullScanAt = try c.decodeIfPresent(Date.self, forKey: .fullScanAt)
        }

        /// Same test as `inUse`, on a saved state.
        var usesNock: Bool { addressShown || (balance?.total ?? 0) > 0 || !history.isEmpty }
    }
    nonisolated static let seenRetention: TimeInterval = 3 * 86_400

    private var state = State()
    private static func stateKey(_ id: String) -> String { "nock.state.\(id)" }

    private init() {
        var on = Self.initialEnabled(.standard)
        #if DEBUG
        // Screenshot / verification runs that open NOCK need it on (and must not save that).
        let env = ProcessInfo.processInfo.environment
        if env["SHOT_NOCK"] != nil || env["SHOT_NOCK_WATCH"] != nil { on = true }
        if let forced = env["SHOT_NOCK_ENABLED"] { on = forced == "1" }
        #endif
        enabled = on
        let wallet = WalletStore.shared
        wallet.$activeWalletID.combineLatest(wallet.$mnemonic)
            .receive(on: RunLoop.main)
            .sink { [weak self] id, mnemonic in self?.walletChanged(id: id, mnemonic: mnemonic) }
            .store(in: &subscriptions)
    }

    private func walletChanged(id: String?, mnemonic: String?) {
        if id != walletID {
            persist()
            walletID = id
            generation += 1
            loadTask?.cancel(); loadTask = nil; loadAgain = false; lastLoadAt = nil; retriedFirstLoad = false
            // historyRequested stays: the page asking may have appeared before this switch
            // was delivered (the subscription hops through the main run loop).
            scanAt = nil; forceScanNext = false
            account = nil; backendReady = false; syncError = nil; tipHeight = nil
            state = id.flatMap(Self.loadState) ?? State()
            publishState()
        }
        guard enabled, let mnemonic, let id else { return }
        guard account == nil else { return }
        let gen = generation
        #if DEBUG
        // Screenshot / verification runs: show a real mainnet address's notes (read-only).
        let watch = ProcessInfo.processInfo.environment["SHOT_NOCK_WATCH"]
        #else
        let watch: String? = nil
        #endif
        Task.detached(priority: .userInitiated) {
            let derived = watch.flatMap { try? NockCore.watchAccount(address: $0) } ?? (try? NockCore.account(mnemonic: mnemonic))
            await MainActor.run { [weak self] in
                // Switching wallets publishes the new id before the new seed, so a derivation
                // can start from the previous wallet's seed: apply only the one that matches
                // the wallet open right now.
                guard let self, self.generation == gen, self.walletID == id, self.account == nil, let derived,
                      WalletStore.shared.activeWalletID == id, WalletStore.shared.mnemonic == mnemonic else { return }
                if let cached = self.state.address, cached != derived.address {
                    // Defensive: a cache that belongs to another key must not leak into this one.
                    self.state = State()
                }
                self.state.address = derived.address
                self.account = derived
                self.persist()
                Task { await self.load() }
            }
        }
    }

    /// Whether NOCK starts on: as last set here; before that ever happened (the first run of the
    /// build that made NOCK opt-in) on only where a wallet on this device already uses it, so
    /// nobody loses sight of NOCK they hold.
    static func initialEnabled(_ d: UserDefaults) -> Bool {
        if let on = d.object(forKey: enabledKey) as? Bool { return on }
        let on = d.dictionaryRepresentation().keys.contains { key in
            guard key.hasPrefix("nock.state."), let data = d.data(forKey: key),
                  let s = try? JSONDecoder().decode(State.self, from: data) else { return false }
            return s.usesNock
        }
        #if DEBUG
        if Keychain.isMemoryOnly { return on }   // screenshot runs share the real defaults
        #endif
        d.set(on, forKey: enabledKey)
        d.removeObject(forKey: "nock.linkHidden")   // the wallet page's old "close the NOCK line"
        return on
    }

    /// 设置 → 钱包 → NOCK 钱包.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        #if DEBUG
        if !Keychain.isMemoryOnly { UserDefaults.standard.set(on, forKey: Self.enabledKey) }
        #else
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        #endif
        if on {
            // Derive this wallet's NOCK key now (and read its balance), as unlocking does.
            let wallet = WalletStore.shared
            walletChanged(id: wallet.activeWalletID, mnemonic: wallet.mnemonic)
        } else {
            // Stop, as removing the wallet does — but the saved state stays for switching back
            // on. An in-flight derivation or read lands on a newer generation and is dropped.
            persist()
            generation += 1
            loadTask?.cancel(); loadTask = nil; loadAgain = false; lastLoadAt = nil; retriedFirstLoad = false
            scanAt = nil; forceScanNext = false; historyRequested = false
            account = nil; backendReady = false; syncError = nil; tipHeight = nil; notes = []
            lastSyncedAt = nil; blockTimes = [:]
            publishState()
        }
    }

    /// The wallet was removed from this device: its NOCK address, history and sends go too.
    func forgetWallet(_ id: String) {
        UserDefaults.standard.removeObject(forKey: Self.stateKey(id))
        guard walletID == id else { return }
        walletID = nil   // so the switch to the next wallet doesn't write this state back
        generation += 1
        loadTask?.cancel(); loadTask = nil; loadAgain = false; lastLoadAt = nil
        scanAt = nil; forceScanNext = false
        account = nil; backendReady = false; syncError = nil; tipHeight = nil; notes = []
        state = State()
        publishState()
    }

    private static func loadState(_ id: String) -> State? {
        guard let data = UserDefaults.standard.data(forKey: stateKey(id)) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func persist() {
        guard let id = walletID else { return }
        #if DEBUG
        if Keychain.isMemoryOnly { return }   // screenshot runs share the real defaults
        #endif
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey(id))
        }
    }

    private func publishState() {
        history = sortedHistory(state.history)
        if let b = state.balance, !backendReady {
            balance = b
            balanceIsCached = true
            lastSyncedAt = state.syncedAt
            tipHeight = state.tip
        } else if !backendReady {
            balance = .zero
            balanceIsCached = false
        }
    }

    private func sortedHistory(_ h: [NockTx]) -> [NockTx] {
        h.sorted { a, b in
            if (a.status == .pending) != (b.status == .pending) { return a.status == .pending }
            return a.time > b.time
        }
    }

    // MARK: Loading

    func refreshIfStale() async {
        if let at = lastLoadAt, Date().timeIntervalSince(at) < 30 { return }
        await load()
    }

    /// The NOCK page is on screen: its history is wanted even when nothing on this device says
    /// the wallet uses NOCK (it may all have come and gone on another device).
    func wantHistory() {
        guard !historyRequested else { return }
        historyRequested = true
        if scanAt == nil { lastLoadAt = nil }   // so the page's refreshIfStale reads it now
    }

    /// Single-flight: callers join the running load; a call mid-load schedules one more pass.
    /// `forceScan` (pull to refresh) also re-reads the history from nockscan.
    func load(forceScan: Bool = false) async {
        guard account != nil else { return }
        if forceScan { forceScanNext = true }
        if let task = loadTask {
            loadAgain = true
            await task.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.loadAgain = false
                await self.loadOnce()
            } while self.loadAgain && !Task.isCancelled
        }
        loadTask = task
        await task.value
        if loadTask == task { loadTask = nil }
    }

    /// Results of a read that started for `account` in `gen` still belong to what's open.
    private func isCurrent(_ gen: Int, _ account: NockCore.Account) -> Bool {
        gen == generation && self.account == account
    }

    private func loadOnce() async {
        guard let account else { return }
        let gen = generation
        do {
            async let plain = client.notes(firstName: account.simpleFirstName, owner: account.address)
            async let mined = client.notes(firstName: account.coinbaseFirstName, owner: account.address)
            let (a, b) = try await (plain, mined)
            guard isCurrent(gen, account) else { return }
            var byID: [String: NockNote] = [:]
            for n in a.notes + b.notes { byID[n.id] = n }
            let tip = max(a.height, b.height)
            let current = byID.values.sorted { $0.originPage > $1.originPage }
            let openBefore = state.pending.filter { $0.status == .pending }.count
            await reconcileSends(notes: current, gen: gen, account: account)
            guard isCurrent(gen, account) else { return }
            notes = current
            tipHeight = tip
            state.tip = tip
            recomputeBalance()
            let arrived = addArrivals(current, tip: tip)
            let settled = state.pending.filter { $0.status == .pending }.count < openBefore
            backendReady = true
            balanceIsCached = false
            syncError = nil
            lastSyncedAt = Date()
            state.syncedAt = lastSyncedAt
            lastLoadAt = Date()
            persist()
            // The balance is up; then the history nockscan has that this device never saw.
            if inUse || historyRequested,
               forceScanNext || arrived || settled || scanAt.map({ Date().timeIntervalSince($0) > Self.scanEvery }) ?? true {
                forceScanNext = false
                await scanHistory(gen: gen, account: account)
                guard isCurrent(gen, account) else { return }
            }
            // The rows' real block times follow (one request per ~21 h of blocks).
            await fillBlockTimes(tip: tip, gen: gen, account: account)
        } catch {
            guard isCurrent(gen, account) else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if case NockClient.RPCError.transport = error, !backendReady, !retriedFirstLoad {
                // The first read of a session failing (network still waking up) retries once
                // shortly instead of showing an error until the next minute's poll.
                retriedFirstLoad = true
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, self.generation == gen else { return }
                    await self.load()
                }
                return
            }
            syncError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastLoadAt = Date()
        }
    }

    /// Settle sends that got mined, give up on ones the node dropped, and take back a "dropped"
    /// one that made it after all. Every await is followed by a fresh lookup by txid: a
    /// broadcast finishing meanwhile can add or remove entries.
    private func reconcileSends(notes: [NockNote], gen: Int, account: NockCore.Account) async {
        let present = Set(notes.map(\.id))
        let open = state.pending.filter { $0.status != .confirmed }.map(\.txId)
        for txId in open {
            guard let p = state.pending.first(where: { $0.txId == txId }) else { continue }
            // Notes leave the balance only once a block spends them.
            let inputsGone = !p.inputs.isEmpty && p.inputs.allSatisfy { !present.contains($0) }

            if p.status == .failed {
                guard inputsGone else { continue }
                // Given up on — but did it get mined (through another node)?
                guard case .some(.some(let d)) = await lookup(txId), !d.pending else { continue }
                guard isCurrent(gen, account) else { return }
                settle(txId, d)
                continue
            }

            if inputsGone {
                let found = await lookup(txId)
                guard isCurrent(gen, account) else { return }
                switch found {
                case .some(.some(let d)) where !d.pending:
                    settle(txId, d)
                case .some(.none):
                    // Its notes went into another tx, so this one can never be mined.
                    markFailed(txId)
                default:
                    break   // lookup failed, or the index hasn't caught up: ask again next time
                }
                continue
            }

            // Still unmined: is the node holding it? A failed query changes nothing.
            let known: Bool?
            do { known = try await client.accepted(txId: txId) } catch { known = nil }
            guard isCurrent(gen, account) else { return }
            guard let i = state.pending.firstIndex(where: { $0.txId == txId && $0.status == .pending }) else { continue }
            if known == true {
                state.pending[i].verified = true
            } else if known == false, Date().timeIntervalSince(state.pending[i].createdAt) > Self.dropAfter {
                markFailed(txId)
            }
        }
        // Keep finished sends a few hours: their change may still arrive, a "dropped" one may still land.
        state.pending.removeAll { $0.status != .pending && Date().timeIntervalSince($0.createdAt) > 6 * 3600 }
    }

    /// The tx as the explorer knows it: `.some(nil)` = not found, `nil` = the lookup failed.
    private func lookup(_ txId: String) async -> NockClient.TxDetails?? {
        do { return .some(try await client.txDetails(txId: txId)) } catch { return nil }
    }

    private func settle(_ txId: String, _ d: NockClient.TxDetails) {
        guard let i = state.pending.firstIndex(where: { $0.txId == txId }) else { return }
        state.pending[i].status = .confirmed
        state.pending[i].verified = true
        updateSendRow(txId) { row in
            row.status = .confirmed
            row.height = d.height
            if let t = d.time { row.time = t; row.timeExact = true }
            if let fee = d.fee { row.fee = fee }
        }
    }

    private func markFailed(_ txId: String) {
        guard let i = state.pending.firstIndex(where: { $0.txId == txId }) else { return }
        state.pending[i].status = .failed
        updateSendRow(txId) { $0.status = .failed }
    }

    /// A row per note seen for the first time (our own change excepted), timed from its height
    /// until `fillBlockTimes` puts the block's own time in. True when a row was added.
    @discardableResult
    private func addArrivals(_ notes: [NockNote], tip: UInt64) -> Bool {
        let ownChange = Set(state.pending.flatMap(\.changeNotes))
        let rows = Set(state.history.map(\.id))
        let now = Date()
        var added = false
        for n in notes {
            let firstSight = state.seen[n.id] == nil
            state.seen[n.id] = now
            guard firstSight, !ownChange.contains(n.id), !rows.contains("note:\(n.id)"),
                  !Self.scanCovers(n, in: state.history) else { continue }
            added = true
            state.history.append(NockTx(id: "note:\(n.id)", kind: n.isMiningReward ? .mined : .received,
                                        amount: n.assets, fee: nil, counterparty: nil, txId: nil,
                                        height: n.originPage, time: blockTimes[n.originPage] ?? estimatedTime(height: n.originPage, tip: tip),
                                        timeExact: blockTimes[n.originPage] != nil, status: .confirmed))
        }
        // A spent note never comes back (names are unique): forget it after a few days. A busy
        // address keeps its most recent rows only.
        state.seen = state.seen.filter { now.timeIntervalSince($0.value) < Self.seenRetention }
        capHistory()
        history = sortedHistory(state.history)
        return added
    }

    private func capHistory() {
        let sorted = sortedHistory(state.history)
        if sorted.count > Self.historyLimit { state.history = Array(sorted.prefix(Self.historyLimit)) }
    }

    // MARK: History from nockscan

    /// Reads the address's history from nockscan and folds it in. A full pass (first time, then
    /// daily) walks back to the history limit; otherwise it stops at the first page that reaches
    /// rows already here. A failed read changes nothing and is retried on the next load.
    private func scanHistory(gen: Int, account: NockCore.Account) async {
        let full = state.fullScanAt.map { Date().timeIntervalSince($0) > Self.fullScanEvery } ?? true
        let known = Set(state.history.map(\.id))
        var entries: [NockScan.Entry] = []
        var reachedEnd = false
        while entries.count < Self.historyLimit {
            guard let page = try? await scan.page(address: account.address, limit: full ? NockScan.pageSize : 25,
                                                  offset: entries.count) else { break }
            guard isCurrent(gen, account) else { return }
            entries += page.entries
            if !page.hasMore || entries.count >= Self.historyLimit { reachedEnd = true; break }
            if !full && page.entries.contains(where: { known.contains($0.txId) }) { break }
        }
        guard reachedEnd || !entries.isEmpty else { return }
        scanAt = Date()
        if full && reachedEnd { state.fullScanAt = scanAt }
        state.history = Self.merge(state.history, scan: entries)
        capHistory()
        history = sortedHistory(state.history)
        persist()
    }

    /// Folds nockscan's rows into the history. A row already here keeps what only this device
    /// knows (a send's recipient amount; a send still pending or failed is `reconcileSends`'
    /// business). Notes this device recorded become the transaction that brought them: one
    /// note of that amount at that height, or all of that kind there together — if they don't
    /// add up, this device's rows stay and nockscan's is left out rather than counted twice.
    /// Notes that arrived at the height of a send made elsewhere were its change, not income.
    nonisolated static func merge(_ history: [NockTx], scan entries: [NockScan.Entry]) -> [NockTx] {
        var rows = history
        var done = Set<String>()
        for e in entries where done.insert(e.txId).inserted {
            if let i = rows.firstIndex(where: { $0.id == e.txId }) {
                guard rows[i].status == .confirmed else { continue }
                rows[i].height = e.height
                rows[i].time = e.time
                rows[i].timeExact = true
                if rows[i].kind == .sent, rows[i].fee == nil { rows[i].fee = e.fee }
                continue
            }
            switch e.kind {
            case .sent:
                rows.append(NockTx(id: e.txId, kind: .sent, amount: e.amount >= e.fee ? e.amount - e.fee : e.amount,
                                   fee: e.fee, counterparty: e.counterparties.first, txId: e.txId, height: e.height,
                                   time: e.time, timeExact: true, status: .confirmed))
            case .received, .mined:
                let kind: NockTx.Kind = e.kind == .mined ? .mined : .received
                let notes = rows.indices.filter { rows[$0].id.hasPrefix("note:") && rows[$0].kind == kind && rows[$0].height == e.height }
                var drop: [Int] = []
                if let one = notes.first(where: { rows[$0].amount == e.amount }) {
                    drop = [one]
                } else if !notes.isEmpty {
                    guard notes.reduce(UInt64(0), { $0 + rows[$1].amount }) == e.amount else { continue }
                    drop = notes
                }
                for i in drop.sorted(by: >) { rows.remove(at: i) }
                // A mining reward's id ("coinbase-…") isn't a transaction anyone can look up.
                rows.append(NockTx(id: e.txId, kind: kind, amount: e.amount, fee: nil, counterparty: nil,
                                   txId: kind == .mined ? nil : e.txId, height: e.height,
                                   time: e.time, timeExact: true, status: .confirmed))
            }
        }
        let sendHeights = Set(entries.filter { $0.kind == .sent }.map(\.height))
        rows.removeAll { $0.id.hasPrefix("note:") && $0.kind == .received && $0.height.map(sendHeights.contains) == true }
        return rows
    }

    /// A note nockscan already accounted for: a row of its kind at its height, or a send there
    /// (the note is that send's change). If it was in fact a second payment in the same block,
    /// nockscan lists it under its own txid and the next read adds it.
    nonisolated static func scanCovers(_ n: NockNote, in history: [NockTx]) -> Bool {
        let kind: NockTx.Kind = n.isMiningReward ? .mined : .received
        return history.contains { row in
            !row.id.hasPrefix("note:") && row.status == .confirmed && row.height == n.originPage
                && (row.kind == kind || (row.kind == .sent && kind == .received))
        }
    }

    /// Real block times for rows still on an estimate: the last ~3.5 days of blocks in at most
    /// four requests. Older rows keep the estimate (shown as such).
    private func fillBlockTimes(tip: UInt64, gen: Int, account: NockCore.Account) async {
        let recent = state.history.compactMap { row -> UInt64? in
            guard !row.timeExact, let h = row.height, tip >= h, tip - h < 2_000 else { return nil }
            return h
        }
        guard let lowest = recent.min(), let times = try? await client.blockTimes(downTo: lowest) else { return }
        guard isCurrent(gen, account) else { return }
        blockTimes.merge(times) { a, _ in a }
        for i in state.history.indices where !state.history[i].timeExact {
            guard let h = state.history[i].height, let t = blockTimes[h] else { continue }
            state.history[i].time = t
            state.history[i].timeExact = true
        }
        history = sortedHistory(state.history)
        persist()
    }

    private func estimatedTime(height: UInt64, tip: UInt64) -> Date {
        Date().addingTimeInterval(-Double(tip > height ? tip - height : 0) * Self.blockSeconds)
    }

    private func updateSendRow(_ txId: String, _ change: (inout NockTx) -> Void) {
        guard let i = state.history.firstIndex(where: { $0.id == txId }) else { return }
        change(&state.history[i])
    }

    /// Inputs of unmined sends are spent as far as this wallet is concerned; their change is
    /// on its way back (counted in the total, spendable once mined).
    private var inFlightInputs: Set<String> {
        Set(state.pending.filter { $0.status == .pending }.flatMap(\.inputs))
    }

    private var liveNotes: [NockNote] {
        let held = inFlightInputs
        return notes.filter { !held.contains($0.id) }
    }

    private func recomputeBalance() {
        let live = liveNotes
        let change = state.pending.filter { $0.status == .pending }.reduce(UInt64(0)) { $0 + $1.returningNicks }
        let held = live.reduce(UInt64(0)) { $0 + $1.assets }
        let available = live.filter(\.spendable).reduce(UInt64(0)) { $0 + $1.assets }
        let locked = live.filter { !$0.spendable && $0.isMiningReward }.reduce(UInt64(0)) { $0 + $1.assets }
        balance = NockBalance(total: held + change, available: available, locked: locked)
        state.balance = balance
    }

    /// Blocks until the soonest locked mining reward unlocks (nil: none locked).
    var blocksUntilNextUnlock: UInt64? {
        guard let tip = tipHeight else { return nil }
        return liveNotes.filter { !$0.spendable && $0.isMiningReward && $0.unlockHeight > tip }
            .map { $0.unlockHeight - tip }.min()
    }

    func confirmations(_ tx: NockTx) -> Int? {
        guard tx.status == .confirmed, let h = tx.height, let tip = tipHeight, tip >= h else { return nil }
        return Int(tip - h) + 1
    }

    // MARK: Sending

    enum SendOutcome { case sent(String), failed(String), unverified(String) }

    /// Build + sign on-device, without broadcasting: the confirmation shows the real fee.
    /// `sweep` sends everything spendable (the fee comes out of it).
    func prepareSend(to recipient: String, amount: UInt64, sweep: Bool) async throws -> NockPreparedSend {
        let to = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = NockCore.addressProblem(to) {
            throw NockCore.Failure(code: problem, message: "")
        }
        guard let mnemonic = WalletStore.shared.mnemonic, let walletID, account != nil, let tip = tipHeight else {
            throw WalletError(Loc("钱包未就绪"))
        }
        guard !hasUnverifiedSend else {
            throw WalletError(Loc("上一笔转账是否发出尚未确认，请先查看交易记录，稍后再试"))
        }
        let spendable = liveNotes.filter(\.spendable)
        guard !spendable.isEmpty else { throw NockCore.Failure(code: "no_funds", message: "") }
        let gen = generation
        var params: [String: Any] = [
            "mnemonic": mnemonic, "account": 0, "notes": spendable.map(\.raw),
            "recipient": to, "sweep": sweep, "height": tip,
        ]
        if !sweep { params["amount"] = String(amount) }
        let r = try await NockCore.callDetached("buildSend", params)
        guard gen == generation else { throw WalletError(Loc("钱包或网络已切换，已取消本次转账")) }
        func nicks(_ k: String) -> UInt64 { UInt64(r[k] as? String ?? "") ?? 0 }
        let names = { (k: String) -> [String] in
            (r[k] as? [[String: Any]] ?? []).compactMap { o in
                guard let f = o["nameFirst"] as? String, let l = o["nameLast"] as? String else { return nil }
                return "\(f)/\(l)"
            }
        }
        let changeNotes = (r["outputs"] as? [[String: Any]] ?? []).compactMap { o -> String? in
            guard (o["mine"] as? Bool) == true, let f = o["nameFirst"] as? String, let l = o["nameLast"] as? String else { return nil }
            return "\(f)/\(l)"
        }
        guard let txId = r["txId"] as? String,
              let body = (r["body"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            throw WalletError(Loc("NOCK 钱包出错：%@", "build"))
        }
        return NockPreparedSend(txId: txId, recipient: to, amount: nicks("amount"), fee: nicks("fee"),
                                change: nicks("change"), returning: nicks("returning"), sweep: sweep, body: body, inputs: names("inputs"),
                                changeNotes: changeNotes, walletID: walletID, generation: gen)
    }

    /// Everything spendable minus the fee for sending it all, in nicks.
    func maxSendQuote(to recipient: String) async throws -> (amount: UInt64, fee: UInt64) {
        let p = try await prepareSend(to: Self.quoteRecipient(for: recipient, own: address), amount: 0, sweep: true)
        return (p.amount, p.fee)
    }

    /// A public test key's address (the official wallet's `clutch inmate …` vector): MAX's quote is
    /// built to it while the recipient isn't filled in yet. The quote is never broadcast.
    nonisolated static let quoteAddress = "3b3eG8WgWHfXTeAMJzNDWxM3b6WFadxQiiJRQrY6zPJ4J2F5QtHjZRQ"

    /// Where MAX's quote is built to. The recipient only shapes the output, so any valid address
    /// quotes the same fee, but not the wallet's own: sending everything to itself, the builder
    /// spends only some of the notes and the core refuses the sweep ("unbalanced transaction").
    nonisolated static func quoteRecipient(for recipient: String, own: String?) -> String {
        let to = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return NockCore.isValidAddress(to) && to != own ? to : quoteAddress
    }

    func broadcast(_ p: NockPreparedSend) async -> SendOutcome {
        guard p.generation == generation, p.walletID == walletID, WalletStore.shared.mnemonic != nil else {
            return .failed(Loc("钱包或网络已切换，已取消本次转账"))
        }
        guard Date().timeIntervalSince(p.createdAt) < Self.preparedLifetime else {
            return .failed(Loc("确认超时，请重新发送"))
        }
        guard await WalletStore.shared.authenticate(reason: Loc("确认转账")) else { return .failed(Loc("认证未通过")) }
        guard p.generation == generation else { return .failed(Loc("钱包或网络已切换，已取消本次转账")) }
        guard !hasUnverifiedSend else { return .failed(Loc("上一笔转账是否发出尚未确认，请先查看交易记录，稍后再试")) }

        // Hold the inputs BEFORE the request goes out: a refresh racing the broadcast must not
        // offer them to another send, and a lost response must not free them.
        record(p, verified: false)
        do {
            try await client.send(body: p.body)
            markVerified(p.txId)
            return .sent(p.txId)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // The node may have taken it even if the reply got lost (or it already had it).
            if (try? await client.accepted(txId: p.txId)) == true {
                markVerified(p.txId)
                return .sent(p.txId)
            }
            if Self.isAlreadyKnown(error) {
                markVerified(p.txId)
                return .sent(p.txId)
            }
            // Only the node's own refusal proves nothing went out. A gateway 5xx, a timeout or a
            // reply that didn't parse leaves it open: the tx may be in — never invite a resend.
            guard Self.isRefusal(error) else {
                return .unverified(Loc("网络异常，无法确认转账是否已发出（%@）。请先查看交易记录，切勿重复发送。", message))
            }
            forget(p.txId)
            return .failed(message)
        }
    }

    /// The node answered "no": its error in the reply, or a gRPC / HTTP status that is decided
    /// before the tx is accepted (bad request, rate limit, auth).
    nonisolated static func isRefusal(_ error: Error) -> Bool {
        switch error {
        case let f as NockCore.Failure: return f.code == "server"
        case NockClient.RPCError.status(let code, _): return [3, 7, 8, 9, 11, 12, 16].contains(code)
        case NockClient.RPCError.http(let code): return (400..<500).contains(code) && code != 408
        default: return false
        }
    }

    /// The node already has this tx (gRPC ALREADY_EXISTS).
    nonisolated static func isAlreadyKnown(_ error: Error) -> Bool {
        if case NockClient.RPCError.status(6, _) = error { return true }
        return false
    }

    private func record(_ p: NockPreparedSend, verified: Bool) {
        state.pending.removeAll { $0.txId == p.txId }
        state.pending.append(PendingSend(txId: p.txId, recipient: p.recipient, amount: p.amount, fee: p.fee,
                                         returningNicks: p.returning, inputs: p.inputs, changeNotes: p.changeNotes,
                                         createdAt: p.createdAt, verified: verified, status: .pending))
        state.history.removeAll { $0.id == p.txId }
        state.history.append(NockTx(id: p.txId, kind: .sent, amount: p.amount, fee: p.fee,
                                    counterparty: p.recipient, txId: p.txId, height: nil,
                                    time: p.createdAt, timeExact: true, status: .pending))
        history = sortedHistory(state.history)
        recomputeBalance()
        persist()
    }

    private func markVerified(_ txId: String) {
        if let i = state.pending.firstIndex(where: { $0.txId == txId }) { state.pending[i].verified = true }
        persist()
    }

    private func forget(_ txId: String) {
        state.pending.removeAll { $0.txId == txId }
        state.history.removeAll { $0.id == txId }
        history = sortedHistory(state.history)
        recomputeBalance()
        persist()
    }

    #if DEBUG
    /// Tests only: the derived account without going through the wallet.
    func _testAdopt(account: NockCore.Account, notes: [NockNote], tip: UInt64) {
        self.account = account
        self.notes = notes
        self.tipHeight = tip
        recomputeBalance()
    }
    #endif
}

/// NOCK → USD from CoinGecko (the price Iris shows), cached for a few minutes.
@MainActor
final class NockPriceManager: ObservableObject {
    static let shared = NockPriceManager()
    @Published private(set) var usd: Double?
    private var at: Date?
    private var inFlight = false
    private static let key = "nock.priceUSD"
    private static let atKey = "nock.priceAt"

    private init() {
        let v = UserDefaults.standard.double(forKey: Self.key)
        if v > 0 { usd = v }
        let t = UserDefaults.standard.double(forKey: Self.atKey)
        if t > 0 { at = Date(timeIntervalSince1970: t) }
    }

    func value(ofNicks nicks: UInt64) -> Double? {
        guard let usd else { return nil }
        return NSDecimalNumber(decimal: NockCore.nock(fromNicks: nicks)).doubleValue * usd
    }

    func refreshIfStale() async {
        if let at, Date().timeIntervalSince(at) < 300, usd != nil { return }
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        var req = URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=nockchain&vs_currencies=usd")!)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = (o["nockchain"] as? [String: Any])?["usd"] as? Double, p > 0 else { return }
        usd = p
        at = Date()
        UserDefaults.standard.set(p, forKey: Self.key)
        UserDefaults.standard.set(at!.timeIntervalSince1970, forKey: Self.atKey)
    }
}
