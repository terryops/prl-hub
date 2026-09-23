import Foundation
import Combine
import LocalAuthentication

/// Drives the wallet's lifecycle and is the single source of truth for the
/// Wallet UI. Key management (BIP39 generate/validate via the Go framework,
/// Keychain-backed mnemonic, lock/unlock) is fully real today. On-chain data
/// (address derivation, balance, history, send) is gated behind `backendReady`
/// and lands with the in-process node + `.200` watch-only server in M3–M4.
@MainActor
final class WalletStore: ObservableObject {

    enum Phase: Equatable { case loading, noWallet, locked, unlocked }

    @Published private(set) var phase: Phase = .loading
    @Published var network: WalletNetwork = .mainnet
    @Published private(set) var mnemonic: String?      // in memory only while unlocked
    @Published private(set) var balance: WalletBalance = .zero
    @Published private(set) var sync = SyncProgress()
    @Published private(set) var txs: [WalletTx] = []
    /// Stranded-change recovery: funds on change addresses the xpub scan can't see,
    /// rediscovered from history and confirmed ours by trial-signing.
    @Published private(set) var recoverable: [RecoverableUTXOSet] = []
    @Published private(set) var recoveryScanning = false
    @Published private(set) var recoveryScanned = false
    @Published var lastError: String?
    /// Transient success/info toast shown by the wallet UI (auto-clears after a moment).
    @Published var toast: String?

    /// Real receive address (derived on-device by oyster) + account xpub + live chain data.
    @Published private(set) var address: String?
    /// Which external receive index `address` currently shows (0,1,2…). Tap the
    /// address chip to advance; funds on every index share the same xpub balance.
    /// Session-only: always resets to 0 (your main address) on launch, so the
    /// primary address is never "lost" behind a switch.
    @Published private(set) var receiveIndex: Int = 0
    @Published private(set) var xpub: String?
    @Published private(set) var backendReady = false
    /// True only after the tx history has been fetched at least once this session.
    /// Balance (`backendReady`) lands before history, so the tx list gates its
    /// "暂无交易记录" empty state on THIS — otherwise it flashes "暂无" before history loads.
    @Published private(set) var historyReady = false
    var backendStatus: String { Loc("正在从链上同步余额与记录…") }
    var frameworkOK: Bool { OysterBridge.isAvailable() }
    static let sendFeeReserve = Decimal(string: "0.001")!
    /// How far a MAX sweep may exceed the amount the user confirmed (0.01 PRL): the unused
    /// fee reserve fits comfortably, newly arrived funds or a different wallet do not.
    static let maxSweepSlackSat: Int64 = 1_000_000
    /// Fee rate (sat/kB) used for the ownership-oracle trial-sign. Deliberately the
    /// relay floor, not a realistic spend fee: the trial only needs to BUILD, so a low
    /// fee keeps small owned change from failing to cover it and being mis-tagged foreign.
    static let oracleFeePerKB: Int64 = 1_000
    /// Bump when the ownership-oracle logic changes so cached classifications (which may
    /// have wrongly tagged small owned change as foreign) are dropped and re-tested once.
    static let changeClassVersion = 2
    /// Total PRL currently rediscovered as recoverable stranded change.
    var recoverableTotal: Decimal { recoverable.reduce(0) { $0 + $1.valuePRL } }

    /// Any transaction still awaiting its first confirmation — an optimistic pending
    /// send not yet mined, or an incoming/mempool tx sitting at 0 confirmations.
    var hasUnconfirmedTx: Bool { txs.contains { $0.confirmations == 0 } }

    /// Adaptive auto-refresh cadence for the wallet dashboard: poll fast while a tx is
    /// still unconfirmed (so "待确认" flips to confirmed within roughly one block), then
    /// back off to a gentle keep-warm interval once everything has ≥1 confirmation.
    var pollInterval: Duration { hasUnconfirmedTx ? .seconds(15) : .seconds(60) }

    /// Every wallet on this device, in display order, and which one is open.
    @Published private(set) var wallets: [WalletRecord] = []
    @Published private(set) var activeWalletID: String?

    /// The wallet that predates multi-wallet support keeps its original Keychain
    /// account, data dir and change-cache keys, so upgrading moves nothing on disk.
    static let legacyWalletID = "primary"

    /// Persistent wallet db location (the gomobile side appends the network dir).
    ///
    /// MUST be unique per seed: oyster keeps the keys in this db and re-opens an
    /// existing one regardless of the mnemonic passed in, so a second seed pointed at
    /// the first wallet's dir derives the FIRST wallet's addresses/xpub and can't sign
    /// its own UTXOs (verified against the macOS slice).
    private func walletDataURL(for id: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(id == Self.legacyWalletID ? "PearlWallet" : "PearlWallet-\(id)", isDirectory: true)
    }
    private var walletDataDir: String {
        let base = walletDataURL(for: activeWalletID ?? Self.legacyWalletID)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.path
    }

    private static let walletAccountPrefix = "wallet."
    private func mnemonicAccount(for id: String) -> String {
        id == Self.legacyWalletID ? "primary.mnemonic" : "\(Self.walletAccountPrefix)\(id).mnemonic"
    }

    /// UserDefaults key prefix for the per-wallet change-chain caches (`<prefix><net>.owned` …).
    private func changeKeyPrefix(for id: String?) -> String {
        guard let id, id != Self.legacyWalletID else { return "change." }
        return "change.\(id)."
    }
    private var changeKeyPrefix: String { changeKeyPrefix(for: activeWalletID) }

    /// iCloud-synced name of the legacy wallet (kept for older builds / other devices).
    private let nameKey = "wallet.name"
    private let networkKey = "wallet.network"
    private let walletsKey = "wallet.list"     // local only: seeds never leave the device
    private let walletsBackupKey = "wallet.list.unreadable"   // raw copy of a list this build couldn't decode
    private let activeWalletKey = "wallet.active"
    private var chainLoadToken = UUID()

    /// Last on-chain snapshot from Blockbook (the source of truth), kept separate
    /// from the published `balance`/`txs` so optimistic sends can be overlaid on
    /// top deterministically (re-applying the overlay never double-counts).
    private var serverBalance: WalletBalance = .zero
    private var serverTxs: [WalletTx] = []
    /// Funds on internal-chain change addresses the xpub scan can't see. Folded into
    /// the published balance and offered to coin selection so change never strands.
    private var changeBalance: WalletBalance = .zero
    private var changeOwned: Set<String> = []     // change addresses confirmed ours (persisted, per network)
    private var changeForeign: Set<String> = []   // candidates confirmed NOT ours (cached to skip re-testing)
    private var lastChangeScanSig: String?         // signature of the latest tx set; re-discover when it changes
    private var changeClassLoadedFor: WalletNetwork?  // which network's cached classification is in memory
    /// Just-broadcast sends Blockbook hasn't indexed yet, keyed by txid. Overlaid
    /// on the snapshot so a send shows instantly, then dropped once the indexer
    /// reports the real tx. See `publishOverlay()` / `reconcileAfterSend()`.
    private var pendingSends: [String: WalletTx] = [:]
    /// Txids merged into `serverTxs` from the internal change chain (spends the xpub
    /// history can't see — see `refreshChangeChain`). When a fresh xpub history page
    /// replaces `serverTxs`, entries with these txids are carried over so the rows
    /// don't flicker out until the change-chain merge re-adds them.
    private var mergedChangeTxids: Set<String> = []
    /// Outpoints (`txid:vout`) of change UTXOs already committed to an in-flight recovery
    /// sweep Blockbook hasn't indexed yet. Kept OUT of `recoverable` (and coin selection)
    /// so a refresh/re-scan that races the indexer can't re-offer already-swept change as
    /// "recoverable" again — the bug where the recovery screen flipped back to un-recovered
    /// on refresh but showed recovered on relaunch. They stay counted in `changeBalance`
    /// (the funds are still ours, just moving) so the total doesn't dip meanwhile. Cleared
    /// once the sweep's txid lands in history.
    private var recoveringOutpoints: Set<String> = []
    private var recoveringTxid: String?
    /// Single-flight guards for `loadChain`: prevent two loads from interleaving their
    /// writes to serverBalance/serverTxs/changeBalance (a slow stale load could otherwise
    /// clobber a fresh one). A call arriving mid-load schedules one trailing reload.
    private var loadInFlight = false
    private var loadAgain = false

    /// One store per process: every window (macOS ⌘N, iPad scenes) must share the wallet
    /// list, or each window's `saveWallets()` overwrites the others' changes.
    static let shared = WalletStore()

    init() { loadMeta() }

    // MARK: lifecycle

    func bootstrap() {
        loadMeta()
        loadWallets()
        // Personal-use: auto-unlock on launch (no biometric). Only sending asks for auth.
        if let id = activeWalletID, let m = Keychain.get(account: mnemonicAccount(for: id)) {
            mnemonic = m
            phase = .unlocked
            Task { await loadChain() }
        } else if activeWalletID != nil {
            // The seed is listed in the Keychain but couldn't be read (macOS access prompt
            // denied, keychain locked). Don't fall through to onboarding — let them retry.
            lastError = Loc("无法读取钥匙串中的助记词，请重试解锁")
            phase = .locked
        } else {
            #if DEBUG
            // Screenshot-only: SHOT_MNEMONIC imports a throwaway test wallet on launch, so a
            // Mac capture run (no XCUITest to drive the import sheet) lands on a real 钱包 tab.
            if let m = ProcessInfo.processInfo.environment["SHOT_MNEMONIC"],
               commitWallet(name: "Pearl Wallet", mnemonic: m) { return }
            #endif
            phase = .noWallet
        }
    }

    private func loadMeta() {
        let d = UserDefaults.standard
        if let net = d.string(forKey: networkKey), let v = WalletNetwork(rawValue: net) { network = v }
    }
    private func saveNetwork() {
        UserDefaults.standard.set(network.rawValue, forKey: networkKey)
        CloudSync.push(networkKey)
    }

    /// Rebuild the wallet list: the persisted index, plus any seed still in the Keychain
    /// without an entry (upgrade from the single-wallet build, or an app reinstall that
    /// wiped UserDefaults but not the Keychain), minus entries whose seed is gone.
    ///
    /// Presence is checked from Keychain ATTRIBUTES only — reading every seed would raise one
    /// macOS access prompt per wallet, and a denied prompt must never count as "seed gone".
    /// If the Keychain can't be listed at all, the persisted list is used untouched.
    private func loadWallets() {
        let d = UserDefaults.standard
        let raw = d.data(forKey: walletsKey)
        let decoded = raw.flatMap { try? JSONDecoder().decode([WalletRecord].self, from: $0) }
        // A list that exists but can't be decoded (e.g. written by a newer build) is copied
        // aside before this launch rebuilds a working list from the Keychain — any later save
        // (an address cache, a rename) would otherwise overwrite the only copy of the names.
        if let raw, decoded == nil, d.data(forKey: walletsBackupKey) == nil {
            d.set(raw, forKey: walletsBackupKey)
        }
        let persisted = decoded ?? []
        let storedActive = d.string(forKey: activeWalletKey)
        guard let accounts = Keychain.accounts(prefix: "") else {
            wallets = persisted
            activeWalletID = persisted.contains { $0.id == storedActive } ? storedActive : persisted.first?.id
            return
        }
        let present = Set(accounts)
        var list = persisted.filter { present.contains(mnemonicAccount(for: $0.id)) }
        var known = Set(list.map(\.id))
        if !known.contains(Self.legacyWalletID), present.contains(mnemonicAccount(for: Self.legacyWalletID)) {
            let legacyName = d.string(forKey: nameKey).flatMap { $0.isEmpty ? nil : $0 } ?? "Pearl Wallet"
            list.insert(WalletRecord(id: Self.legacyWalletID, name: legacyName), at: 0)
            known.insert(Self.legacyWalletID)
        }
        for account in accounts.sorted() where account.hasPrefix(Self.walletAccountPrefix) && account.hasSuffix(".mnemonic") {
            let id = String(account.dropFirst(Self.walletAccountPrefix.count).dropLast(".mnemonic".count))
            guard !id.isEmpty, !known.contains(id) else { continue }
            list.append(WalletRecord(id: id, name: suggestedWalletName(in: list)))
            known.insert(id)
        }
        wallets = list
        activeWalletID = list.contains { $0.id == storedActive } ? storedActive : list.first?.id
        if list != persisted || activeWalletID != storedActive { saveWallets() }
    }

    private func saveWallets() {
        #if DEBUG
        // Screenshot runs keep seeds in memory but share the real UserDefaults: writing
        // here would prune the real wallet list down to the throwaway test wallet.
        if Keychain.isMemoryOnly { return }
        #endif
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(wallets) { d.set(data, forKey: walletsKey) }
        d.set(activeWalletID, forKey: activeWalletKey)
    }

    /// The open wallet's entry in `wallets`.
    var activeRecord: WalletRecord? { wallets.first { $0.id == activeWalletID } }
    /// Display name of the open wallet (derived — `wallets` is the single source).
    var walletName: String { activeRecord?.name ?? "Pearl Wallet" }

    /// "Pearl Wallet", then "Pearl Wallet 2", "Pearl Wallet 3"… — the first name no wallet uses.
    func suggestedWalletName() -> String { suggestedWalletName(in: wallets) }
    private func suggestedWalletName(in list: [WalletRecord]) -> String {
        let used = Set(list.map(\.name))
        if !used.contains("Pearl Wallet") { return "Pearl Wallet" }
        var n = 2
        while used.contains("Pearl Wallet \(n)") { n += 1 }
        return "Pearl Wallet \(n)"
    }

    /// Adopt wallet name / network pushed in from another device via iCloud
    /// (CloudSync has already written them into UserDefaults). The synced name only
    /// ever belonged to the legacy single wallet, so it never renames the others.
    func adoptSyncedMeta() {
        let d = UserDefaults.standard
        if let n = d.string(forKey: nameKey), !n.isEmpty,
           let i = wallets.firstIndex(where: { $0.id == Self.legacyWalletID }), wallets[i].name != n {
            wallets[i].name = n
            saveWallets()
        }
        if let net = d.string(forKey: networkKey), let v = WalletNetwork(rawValue: net), v != network {
            changeNetwork(v)   // re-derive address + re-sync for the new network
        }
    }

    /// Rename a wallet (display only — the seed and on-chain data are untouched).
    func renameWallet(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = wallets.firstIndex(where: { $0.id == id }) else { return }
        wallets[i].name = trimmed
        if id == Self.legacyWalletID {
            UserDefaults.standard.set(trimmed, forKey: nameKey)
            CloudSync.push(nameKey)
        }
        saveWallets()
        if id == activeWalletID { publishOverlay() }   // widget shows the new name
    }

    /// Open another wallet on this device: set the current wallet's chain state aside,
    /// then load the chosen seed and re-sync. Returns false (nothing changes) if the seed
    /// can't be read.
    @discardableResult
    func switchWallet(to id: String) -> Bool {
        guard id != activeWalletID, wallets.contains(where: { $0.id == id }) else { return id == activeWalletID }
        guard let m = Keychain.get(account: mnemonicAccount(for: id)) else {
            lastError = Loc("无法读取该钱包的助记词（钥匙串拒绝了访问），请重试")
            return false
        }
        invalidateChainLoads()
        parkOverlay()
        clearChainState()
        activeWalletID = id
        saveWallets()
        restoreOverlay()
        WidgetBridge.clearWallet()   // don't keep showing the previous wallet until the new one publishes
        mnemonic = m
        phase = .unlocked
        lastError = nil
        Task { await loadChain() }
        return true
    }

    // MARK: per-wallet optimistic state

    /// Optimistic sends and in-flight recovery guards of a wallet/network the user moved
    /// away from before Blockbook indexed them. Restored on the way back so a quick A→B→A
    /// can't re-show pre-send balances or re-offer already-swept change.
    private struct ParkedOverlay {
        var pendingSends: [String: WalletTx]
        var recoveringOutpoints: Set<String>
        var recoveringTxid: String?
    }
    private var parkedOverlays: [String: ParkedOverlay] = [:]
    private func overlayKey(_ id: String?, _ net: WalletNetwork) -> String { "\(id ?? "")|\(net.rawValue)" }

    private func parkOverlay() {
        // Locked: lock() already parked this wallet's state and cleared it, so the empty
        // state seen now must not overwrite (erase) that parked copy.
        guard mnemonic != nil else { return }
        let key = overlayKey(activeWalletID, network)
        if pendingSends.isEmpty && recoveringOutpoints.isEmpty && recoveringTxid == nil {
            parkedOverlays[key] = nil
        } else {
            parkedOverlays[key] = ParkedOverlay(pendingSends: pendingSends,
                                                recoveringOutpoints: recoveringOutpoints,
                                                recoveringTxid: recoveringTxid)
        }
    }

    private func restoreOverlay() {
        guard let p = parkedOverlays.removeValue(forKey: overlayKey(activeWalletID, network)) else { return }
        pendingSends = p.pendingSends
        recoveringOutpoints = p.recoveringOutpoints
        recoveringTxid = p.recoveringTxid
    }

    /// Generate a brand-new mnemonic (not yet persisted — caller confirms backup first).
    func newMnemonic() -> String? { OysterBridge.generateMnemonic() }

    /// Validate a user-entered recovery phrase.
    func isValidMnemonic(_ m: String) -> Bool { OysterBridge.validate(m) }

    /// Add a freshly created or imported wallet to this device and open it. Importing
    /// a seed that is already here just switches to that wallet instead of duplicating it.
    func commitWallet(name: String, mnemonic: String) -> Bool {
        let phrase = mnemonic.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .lowercased()
        guard OysterBridge.validate(phrase) else {
            lastError = Loc("助记词无效（BIP39 校验失败）")
            return false
        }
        if let existing = wallets.first(where: { Keychain.get(account: mnemonicAccount(for: $0.id)) == phrase }) {
            // The phrase just matched this wallet's stored seed, so opening it can't hit a
            // read failure — but only report success once it is actually open.
            if existing.id == activeWalletID {
                if self.mnemonic == nil {
                    invalidateChainLoads()
                    self.mnemonic = phrase
                    Task { await loadChain() }
                }
                phase = .unlocked
            } else if !switchWallet(to: existing.id) {
                return false
            }
            lastError = nil
            flashToast(Loc("该钱包已在本机，已切换到「%@」", existing.name))
            return true
        }
        let id = UUID().uuidString.lowercased()
        // A fresh id can't collide, but never let a new seed open a leftover db (see walletDataURL).
        try? FileManager.default.removeItem(at: walletDataURL(for: id))
        guard Keychain.set(phrase, account: mnemonicAccount(for: id)) else {
            lastError = Loc("无法写入钥匙串（Keychain）")
            return false
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        invalidateChainLoads()
        parkOverlay()
        clearChainState()
        wallets.append(WalletRecord(id: id, name: trimmed.isEmpty ? suggestedWalletName() : trimmed))
        activeWalletID = id
        saveWallets()
        WidgetBridge.clearWallet()
        self.mnemonic = phrase
        phase = .unlocked
        lastError = nil
        Task { await loadChain() }
        return true
    }

    /// Re-open the wallet after a manual lock (no biometric — personal use).
    func unlock() async {
        guard let id = activeWalletID else { phase = .noWallet; return }
        guard let m = Keychain.get(account: mnemonicAccount(for: id)) else {
            lastError = Loc("无法读取钥匙串中的助记词，请重试解锁")
            return
        }
        invalidateChainLoads()
        mnemonic = m
        restoreOverlay()
        phase = .unlocked
        lastError = nil
        await loadChain()
    }

    /// Switch network live: persist, reset chain state, re-derive + re-sync.
    func changeNetwork(_ net: WalletNetwork) {
        guard net != network else { return }
        invalidateChainLoads()
        parkOverlay()
        network = net
        saveNetwork()
        clearChainState()
        // Locked: leave the parked state where it is — unlock() restores the network then
        // current. Pulling it into memory now would let a second locked switch clear it.
        if mnemonic != nil { restoreOverlay() }
        if mnemonic != nil { Task { await loadChain() } }
    }

    /// Device auth (Face ID / Touch ID / passcode / login password). Gates the
    /// two sensitive actions: revealing the seed and authorising a send.
    /// Fails CLOSED — if the device has no lock configured at all (so no auth can
    /// be evaluated), the action is denied rather than silently allowed.
    func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            lastError = Loc("请先为本设备设置锁屏密码或生物识别，再进行此操作。")
            return false
        }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// Derive the real receive address (on-device) and pull balance + history
    /// from Blockbook. Safe to call repeatedly (idempotent). Single-flighted so
    /// concurrent/re-entrant callers can't interleave two loads' state writes.
    func loadChain() async {
        if loadInFlight { loadAgain = true; return }
        loadInFlight = true
        defer { loadInFlight = false }
        repeat {
            loadAgain = false
            await loadChainOnce()
        } while loadAgain
    }

    private func loadChainOnce() async {
        guard let mnemonic else { return }
        let token = chainLoadToken
        let expectedNetwork = network
        let dir = walletDataDir
        let net = expectedNetwork.rawValue
        if changeClassLoadedFor != expectedNetwork {
            loadChangeClassification(for: expectedNetwork)
            changeClassLoadedFor = expectedNetwork
        }
        if address == nil || xpub == nil {
            let expectedReceiveIndex = receiveIndex
            // Blocking + disk I/O (creates the wallet db on first run) → off main.
            let derived = await WalletDBQueue.shared.run { () -> (String?, String?) in
                // ALWAYS derive by fixed index. The no-index FFI call is stateful: once
                // the wallet db has derived other keys (address cycling, sends pre-deriving
                // keys) it wanders off index 0 — sometimes onto the INTERNAL change chain,
                // whose receipts the external-only xpub scan can't see. Fixed-index
                // derivation is deterministic, so index 0 is always the original address.
                let a = OysterBridge.receiveAddress(mnemonic: mnemonic, dataDir: dir, network: net, at: expectedReceiveIndex)
                let x = OysterBridge.accountXpub(mnemonic: mnemonic, dataDir: dir, network: net)
                return (a, x)
            }
            guard isCurrentChainLoad(token, mnemonic: mnemonic, network: expectedNetwork) else { return }
            if receiveIndex == expectedReceiveIndex { address = derived.0 }
            if xpub == nil { xpub = derived.1 }
            if expectedReceiveIndex == 0, let a = derived.0 { cacheMainAddress(a, network: expectedNetwork) }
        }
        guard isCurrentChainLoad(token, mnemonic: mnemonic, network: expectedNetwork) else { return }
        guard let xp = xpub else { return }
        let bb = BlockbookClient(network: expectedNetwork)
        if let b = try? await bb.balance(xpub: xp) {
            guard isCurrentChainLoad(token, mnemonic: mnemonic, network: expectedNetwork) else { return }
            serverBalance = b; backendReady = true
            // Publish the real balance the INSTANT backendReady flips — otherwise the
            // hero shows "0 PRL" for the seconds the slow history + change-chain scan
            // below take before the next publishOverlay() runs.
            publishOverlay()
        }
        if let h = try? await bb.history(xpub: xp, knownChange: changeOwned) {
            guard isCurrentChainLoad(token, mnemonic: mnemonic, network: expectedNetwork) else { return }
            // Carry over internal-chain spends merged by refreshChangeChain — the xpub
            // page can't contain them, and dropping them here would flicker the rows
            // out until the (slow) change-chain merge below re-adds them.
            let carried = serverTxs.filter { tx in
                mergedChangeTxids.contains(tx.txid) && !h.contains(where: { $0.txid == tx.txid })
            }
            serverTxs = carried.isEmpty ? h : (h + carried).sorted { $0.time > $1.time }
            // The indexer now reports these txids → stop overlaying our optimistic copies.
            for tx in h where pendingSends[tx.txid] != nil { pendingSends.removeValue(forKey: tx.txid) }
            // The recovery sweep is indexed too → stop guarding its swept change outpoints.
            if let tid = recoveringTxid, h.contains(where: { $0.txid == tid }) {
                recoveringOutpoints = []; recoveringTxid = nil
            }
            historyReady = true
            // Publish the txs the INSTANT history lands — otherwise the list shows
            // "暂无交易记录" until the slow change-chain scan below republishes.
            publishOverlay()
        }
        // Bring internal-chain change (which the xpub scan misses) into balance + spending.
        await refreshChangeChain(xpub: xp, dir: dir, net: net, token: token, force: false)
        guard isCurrentChainLoad(token, mnemonic: mnemonic, network: expectedNetwork) else { return }
        publishOverlay()
    }

    /// Recompute the published `balance` / `txs` from the on-chain snapshot plus any
    /// still-unindexed optimistic sends. Idempotent: an overlay is only applied for
    /// a pending tx the snapshot doesn't yet contain, so re-publishing (or a second
    /// send) never double-counts a spend.
    private func publishOverlay() {
        let known = Set(serverTxs.map { $0.txid })
        let overlay = pendingSends.values.filter { !known.contains($0.txid) }
        let nextTxs = overlay.isEmpty ? serverTxs
                                      : (overlay + serverTxs).sorted { $0.time > $1.time }
        // Assigning an equal value still fires objectWillChange and re-renders every
        // wallet screen, and the chain poll republishes unchanged data every 15–60 s.
        if nextTxs != txs { txs = nextTxs }
        // Base = external (xpub) snapshot + internal-chain change the xpub scan misses.
        let base = WalletBalance(total: serverBalance.total + changeBalance.total,
                                 available: serverBalance.available + changeBalance.available)
        let outflow = overlay.reduce(Decimal(0)) { $0 + $1.amount + $1.fee }
        let nextBalance = outflow > 0
            ? WalletBalance(total: max(0, base.total - outflow),
                            available: max(0, base.available - outflow))
            : base
        if nextBalance != balance { balance = nextBalance }

        // Mirror the published wallet state into the shared App Group so the
        // home-screen Wallet widget has fresh inputs (xpub/network) + values to
        // show immediately. Only once the xpub is known — before that there's
        // nothing the widget could refresh itself with.
        if let xpub {
            let recent = txs.filter { $0.amount > 0 }.prefix(3).map {
                WidgetTx(received: $0.direction == .received,
                         amount: NSDecimalNumber(decimal: $0.amount).doubleValue,
                         time: $0.time)
            }
            WidgetBridge.updateWallet(name: walletName,
                                      balancePRL: NSDecimalNumber(decimal: balance.total).doubleValue,
                                      changePRL: NSDecimalNumber(decimal: changeBalance.total).doubleValue,
                                      xpub: xpub,
                                      network: network.rawValue,
                                      recentTx: Array(recent),
                                      labelBalance: Loc("余额"),
                                      labelRecentTx: Loc("最近交易"),
                                      labelNoTx: Loc("暂无交易记录"),
                                      languageCode: LocBundleHolder.shared.languageCode)
            WidgetBridge.updatePrice(prlUsd: PRLPriceManager.shared.usd, usdCny: nil)
        }
    }

    /// After a broadcast, pull fresh chain data a few times until Blockbook reports
    /// the new tx (which drops the optimistic overlay and makes the balance exact).
    private func reconcileAfterSend(txid: String) async {
        for _ in 0..<12 {
            try? await Task.sleep(for: .seconds(3))
            await loadChain()
            if pendingSends[txid] == nil { break }
        }
    }

    private func cacheMainAddress(_ a: String, network net: WalletNetwork) {
        guard let i = wallets.firstIndex(where: { $0.id == activeWalletID }),
              wallets[i].addresses[net.rawValue] != a else { return }
        wallets[i].addresses[net.rawValue] = a
        saveWallets()
    }

    /// Show the next external receive address (0→1→2…). Funds received on any
    /// index land in the same xpub-aggregated balance and remain spendable, so
    /// this only changes which fresh address you hand out. Choice persists.
    func nextReceiveAddress() {
        // Cycle 0…9. Sending pre-derives 100 keys, so every address we hand out
        // here stays spendable; wrapping keeps the set small and predictable.
        let next = receiveIndex >= 9 ? 0 : receiveIndex + 1
        Task { await setReceiveIndex(next) }
    }

    /// Switch the displayed receive address to a specific external index.
    /// In-memory only (not persisted) — relaunch always returns to index 0.
    func setReceiveIndex(_ i: Int) async {
        guard let mnemonic else { return }
        let token = chainLoadToken
        let expectedNetwork = network
        let idx = max(0, i)
        let dir = walletDataDir
        let net = expectedNetwork.rawValue
        // Fixed-index derivation only — see loadChainOnce for why the no-index FFI
        // call must never be used here.
        let a = await WalletDBQueue.shared.run {
            OysterBridge.receiveAddress(mnemonic: mnemonic, dataDir: dir, network: net, at: idx)
        }
        guard isCurrentChainLoad(token, mnemonic: mnemonic, network: expectedNetwork) else { return }
        guard let a else { return }
        address = a
        receiveIndex = idx
    }

    /// Show a transient toast (auto-clears). Used e.g. after a successful send.
    func flashToast(_ message: String) {
        toast = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            if toast == message { toast = nil }
        }
    }

    /// Build + sign (on-device) + broadcast a payment. Returns (success, txid-or-error).
    /// `isMax` carries the caller's EXPLICIT "send everything" intent (the MAX button);
    /// only then do we sweep to a single output. It is never inferred from the live
    /// balance — see the isSweep note below.
    func send(to recipient: String, amountPRL: Decimal, isMax: Bool = false) async -> (ok: Bool, message: String) {
        // Spending requires device auth (Touch ID / password).
        guard await authenticate(reason: Loc("确认转账")) else { return (false, Loc("认证未通过")) }
        let recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard PRLAddress.isValid(recipient, network: network) else { return (false, Loc("收款地址格式不正确")) }
        guard let mnemonic, let xp = xpub else { return (false, Loc("钱包未就绪")) }
        // Everything this send uses is captured now; if the wallet, network or lock state
        // changes during the network round-trips below, the send is abandoned.
        let session = chainLoadToken
        let changeSets = recoverable
        guard amountPRL + Self.sendFeeReserve <= balance.available else {
            return (false, Loc("余额不足：请预留至少 %@ PRL 作为手续费", "\(Self.sendFeeReserve)"))
        }
        let dir = walletDataDir
        let net = network.rawValue
        let bb = BlockbookClient(network: network)
        guard let amountSat = Self.satoshis(from: amountPRL) else {
            return (false, Loc("金额无效：最多支持 %@ 位小数", "\(BlockbookClient.decimals)"))
        }
        do {
            let utxos = try await bb.utxos(xpub: xp)
            var utxoObjs: [[String: Any]] = []
            for u in utxos {
                guard let value = Int64(u.value) else {
                    // A malformed UTXO value must NOT be silently zeroed — that would
                    // under-fund the tx and could sweep real value into the miner fee.
                    return (false, Loc("链上数据异常（UTXO 金额无法解析），已取消转账以保护资金"))
                }
                utxoObjs.append(["txid": u.txid, "vout": u.vout, "value": value, "address": u.address ?? ""])
            }
            // Also offer internal-chain change UTXOs (invisible to the xpub scan) to coin
            // selection, with their address injected — oyster signs them like any other.
            for s in changeSets {
                for u in s.utxos {
                    guard let value = Int64(u.value) else { continue }
                    utxoObjs.append(["txid": u.txid, "vout": u.vout, "value": value, "address": s.address])
                }
            }
            guard !utxoObjs.isEmpty else { return (false, Loc("没有可用的 UTXO（余额不足或未确认）")) }
            let fee = (try? await bb.estimateFeePerKB()) ?? 50_000
            guard chainLoadToken == session else { return (false, Loc("钱包或网络已切换，已取消本次转账")) }
            let utxosJSON = String(data: try JSONSerialization.data(withJSONObject: utxoObjs), encoding: .utf8) ?? "[]"
            // Full-balance ("MAX") send → true single-output sweep. Otherwise the fixed
            // `sendFeeReserve` (which far exceeds the real fee) would come back as a change
            // output on the internal change chain and re-strand. Same converging fold as
            // recoverChange. Partial sends keep the plain build — their change is expected,
            // and now visible + spendable via refreshChangeChain.
            //
            // CRITICAL: the sweep decision is the caller's EXPLICIT intent, never a re-read
            // of `balance.available`. That @Published value can be lowered by a concurrent
            // loadChain()/publishOverlay() during the awaits above (the xpub scan briefly
            // drops the prior tx's stranded change before refreshChangeChain restores it),
            // which would silently promote a partial send into a sweep that pays the WHOLE
            // balance to the recipient. amountSat (the user's typed amount) is what a
            // non-sweep send pays; a sweep ignores it and sends the full input set.
            let isSweep = isMax
            let hex: String
            if isSweep {
                let totalInputSat = utxoObjs.reduce(Int64(0)) { $0 + (($1["value"] as? Int64) ?? 0) }
                let startSat = totalInputSat - Self.estimateFeeSat(inputs: utxoObjs.count, outputs: 2, feePerKB: fee)
                guard startSat > 0 else { return (false, Loc("余额不足：请预留至少 %@ PRL 作为手续费", "\(Self.sendFeeReserve)")) }
                // The user confirmed `amountPRL`. The sweep pays out everything the inputs
                // hold, which is only ever the fee reserve more than that — unless funds
                // arrived (or the wallet changed) since MAX was tapped. Refuse rather than
                // send a larger amount than the confirmation showed.
                guard startSat <= amountSat + Self.maxSweepSlackSat else {
                    return (false, Loc("余额已变化，请重新点 MAX 后再发送"))
                }
                hex = try await sweepConverge(mnemonic: mnemonic, dir: dir, net: net, to: recipient,
                                              amountSat: startSat, totalSat: totalInputSat,
                                              feePerKB: fee, utxosJSON: utxosJSON)
            } else {
                hex = try await WalletDBQueue.shared.run {
                    try OysterBridge.buildSignedTx(mnemonic: mnemonic, dataDir: dir, network: net,
                                                   to: recipient, amountSat: amountSat, feeSatPerKB: fee, utxosJSON: utxosJSON)
                }
            }
            let txid = try await bb.broadcast(hex)
            // Switched wallets while this one was signing/broadcasting: the send still went
            // out from the original wallet, so don't overlay it onto the one now open.
            guard chainLoadToken == session else { return (true, txid) }
            // Reflect the send IMMEDIATELY. Blockbook can take several refreshes to
            // index the mempool tx, so instead of blocking on a poll we overlay an
            // optimistic 待确认 row and drop the spent amount from the balance now.
            // `reconcileAfterSend` then swaps in the real indexed tx + exact balance.
            let pending = WalletTx(txid: txid, direction: .sent, amount: amountPRL,
                                   fee: Self.sendFeeReserve, confirmations: 0,
                                   time: Date(), address: recipient)
            pendingSends[txid] = pending
            publishOverlay()
            Task { await reconcileAfterSend(txid: txid) }
            return (true, txid)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: stranded-change recovery

    /// Force a fresh internal-chain discovery (the explicit recovery screen). `loadChain`
    /// already keeps `recoverable`/`changeBalance` current; this just re-runs it on demand.
    func scanRecoverableChange() async {
        guard let xp = xpub else { return }
        if changeClassLoadedFor != network { loadChangeClassification(for: network); changeClassLoadedFor = network }
        recoveryScanning = true
        defer { recoveryScanning = false }
        await refreshChangeChain(xpub: xp, dir: walletDataDir, net: network.rawValue, token: chainLoadToken, force: true)
    }

    /// Track the wallet's internal-chain change addresses (which the xpub scan can't
    /// see), fold their balance into `changeBalance` and their UTXOs into `recoverable`
    /// for both display and coin selection — so change stops stranding. The expensive
    /// discovery (history + trial-signing to confirm ownership) only runs when the tx
    /// set changed or `force`; the cheap per-address UTXO refresh runs every time.
    private func refreshChangeChain(xpub xp: String, dir: String, net: String, token: UUID, force: Bool) async {
        guard let mnemonic else { return }
        let bb = BlockbookClient(network: network)
        // A send funded ENTIRELY by internal-chain change touches no xpub-derived
        // address, so the xpub history can never report it: its optimistic 待确认
        // row never reconciled (stuck "Unconfirmed" forever, even once mined) and
        // its outflow stayed deducted on top of the already-shrunk changeBalance.
        // Each owned change address's OWN history is the only place those spends
        // exist — fold the txs the xpub scan missed into the snapshot (so they
        // reconcile, show live confirmations, and survive relaunch), and surface
        // their outputs as change candidates (their change is invisible to
        // changeCandidates' xpub scan for the same reason).
        var changeChainOuts = Set<String>()
        for addr in changeOwned {
            guard let r = try? await bb.history(address: addr, mine: changeOwned) else { continue }
            guard isCurrentChainLoad(token, mnemonic: mnemonic, network: network) else { return }
            changeChainOuts.formUnion(r.outAddrs)
            // Xpub-history copies stay authoritative (token-aware classification);
            // previously-merged copies are REPLACED so confirmations stay live.
            // NOTE: a merged tx's "sent" amount counts its own not-yet-classified
            // change as paid out; once the oracle below tags that change ours, the
            // next load remaps with the bigger `mine` set and the amount corrects.
            let xpubTxids = Set(serverTxs.map { $0.txid }).subtracting(mergedChangeTxids)
            let fresh = r.txs.filter { !xpubTxids.contains($0.txid) }
            guard !fresh.isEmpty else { continue }
            mergedChangeTxids.formUnion(fresh.map { $0.txid })
            let freshIds = Set(fresh.map { $0.txid })
            serverTxs = (serverTxs.filter { !freshIds.contains($0.txid) } + fresh)
                .sorted { $0.time > $1.time }
            // The indexer reports these txids → same reconciliation as the xpub history.
            for tx in fresh where pendingSends[tx.txid] != nil { pendingSends.removeValue(forKey: tx.txid) }
            if let tid = recoveringTxid, fresh.contains(where: { $0.txid == tid }) {
                recoveringOutpoints = []; recoveringTxid = nil
            }
        }
        // NOTE: do NOT publishOverlay() here. Dropping the optimistic pending row above
        // while `changeBalance` still holds its stale pre-send value would briefly
        // republish the balance at the FULL pre-send amount (base = serverBalance +
        // stale change, with the overlay now gone) — a visible spike back to "as if the
        // send never happened", and an overstated `available` the send guard could act
        // on. changeBalance is recomputed from live UTXOs below, and the publishOverlay()
        // at the end of this function publishes the correct, deducted figure.
        let scanSig = Self.changeScanSignature(serverTxs)
        if force || scanSig != lastChangeScanSig,
           let candidates = try? await bb.changeCandidates(xpub: xp, extra: changeChainOuts) {
            lastChangeScanSig = scanSig
            for addr in candidates.prefix(200) where !changeOwned.contains(addr) && !changeForeign.contains(addr) {
                guard let utxos = try? await bb.utxos(address: addr), !utxos.isEmpty else { continue }
                let valueSat = utxos.compactMap { Int64($0.value) }.reduce(0, +)
                guard valueSat > 0 else { continue }
                let json = Self.encodeUTXOs(utxos, address: addr)
                // Ownership oracle: oyster signs only its own keys, so a successful build
                // proves the address is ours (a foreign recipient throws). Never broadcast.
                //
                // Trial-sign as a single-output sweep at the relay-floor fee, reserving a
                // 2-output fee so the build always has headroom. The old test (½-value
                // output at 50k sat/kB) FAILED for small owned change — the fee exceeded
                // the value — and mis-cached it as foreign, hiding those funds permanently.
                let trialFee = Self.estimateFeeSat(inputs: utxos.count, outputs: 2, feePerKB: Self.oracleFeePerKB)
                let trialAmount = max(Int64(1), valueSat - trialFee)
                let owned = await WalletDBQueue.shared.run { () -> Bool in
                    (try? OysterBridge.buildSignedTx(mnemonic: mnemonic, dataDir: dir, network: net,
                        to: addr, amountSat: trialAmount, feeSatPerKB: Self.oracleFeePerKB, utxosJSON: json)) != nil
                }
                guard isCurrentChainLoad(token, mnemonic: mnemonic, network: network) else { return }
                if owned { changeOwned.insert(addr) } else { changeForeign.insert(addr) }
            }
            // A wallet/network switch mid-scan cleared these sets; don't write them under the new wallet's keys.
            guard isCurrentChainLoad(token, mnemonic: mnemonic, network: network) else { return }
            persistChangeClassification()
        }
        var sets: [RecoverableUTXOSet] = []   // offered to recover + coin selection (excludes in-flight-swept)
        var allChangeSat: Int64 = 0           // EVERY owned change UTXO → the balance TOTAL (stable mid-sweep)
        var spendableChangeSat: Int64 = 0     // excludes in-flight-swept → the balance AVAILABLE (matches selection)
        for addr in changeOwned {
            guard let utxos = try? await bb.utxos(address: addr), !utxos.isEmpty else { continue }
            allChangeSat += utxos.compactMap { Int64($0.value) }.reduce(0, +)
            // Hide outpoints already committed to an in-flight recovery so a refresh can't re-offer them.
            let spendable = recoveringOutpoints.isEmpty ? utxos
                : utxos.filter { !recoveringOutpoints.contains(Self.outpoint($0.txid, $0.vout)) }
            let valueSat = spendable.compactMap { Int64($0.value) }.reduce(0, +)
            guard !spendable.isEmpty, valueSat > 0 else { continue }
            spendableChangeSat += valueSat
            sets.append(RecoverableUTXOSet(address: addr, utxos: spendable, valueSat: valueSat))
        }
        guard isCurrentChainLoad(token, mnemonic: mnemonic, network: network) else { return }
        // total counts in-flight-swept change so the displayed total holds steady mid-sweep;
        // available excludes it, because coin selection can't spend an outpoint already
        // committed to a recovery sweep — otherwise a send could be offered phantom funds.
        changeBalance = WalletBalance(total: Decimal(allChangeSat) / pow(Decimal(10), BlockbookClient.decimals),
                                      available: Decimal(spendableChangeSat) / pow(Decimal(10), BlockbookClient.decimals))
        // Cache the scanned change balance so the next launch can fold it into the very
        // first publish — without this the hero briefly shows only the xpub (external)
        // balance, then "jumps up" seconds later when this slow scan completes.
        UserDefaults.standard.set(["\(changeBalance.total)", "\(changeBalance.available)"],
                                  forKey: "\(changeKeyPrefix)\(net).balance")
        recoverable = sets.sorted { $0.valueSat > $1.valueSat }
        recoveryScanned = true
        publishOverlay()
    }

    private func persistChangeClassification() {
        let d = UserDefaults.standard
        d.set(Array(changeOwned), forKey: "\(changeKeyPrefix)\(network.rawValue).owned")
        d.set(Array(changeForeign), forKey: "\(changeKeyPrefix)\(network.rawValue).foreign")
    }
    private func loadChangeClassification(for net: WalletNetwork) {
        let d = UserDefaults.standard
        // Drop a stale-versioned cache (the prior oracle could mis-tag small owned change
        // as foreign): start empty so every candidate is re-tested once with the new oracle.
        if d.integer(forKey: "\(changeKeyPrefix)\(net.rawValue).ver") != Self.changeClassVersion {
            changeOwned = []; changeForeign = []
            d.removeObject(forKey: "\(changeKeyPrefix)\(net.rawValue).balance")
            d.set(Self.changeClassVersion, forKey: "\(changeKeyPrefix)\(net.rawValue).ver")
        } else {
            changeOwned = Set((d.array(forKey: "\(changeKeyPrefix)\(net.rawValue).owned") as? [String]) ?? [])
            changeForeign = Set((d.array(forKey: "\(changeKeyPrefix)\(net.rawValue).foreign") as? [String]) ?? [])
            // Seed the change balance from the last scan so the first publish already
            // includes it (no 48→52 jump at launch); refreshChangeChain re-verifies and
            // overwrites it with live data shortly after.
            if let cached = d.array(forKey: "\(changeKeyPrefix)\(net.rawValue).balance") as? [String], cached.count == 2,
               let total = Decimal(string: cached[0]), let available = Decimal(string: cached[1]) {
                changeBalance = WalletBalance(total: total, available: available)
            }
        }
        lastChangeScanSig = nil
    }

    /// Signature of the latest tx set, used to decide when to re-run change discovery.
    /// Count + newest txid, so a NEW tx (which can create fresh stranded change) is
    /// detected even when the history page is capped (count alone pins at pageSize).
    private static func changeScanSignature(_ txs: [WalletTx]) -> String {
        "\(txs.count):\(txs.first?.txid ?? "")"
    }

    /// Sweep every rediscovered stranded-change UTXO to `destination` in one tx,
    /// folding any residual change back in so nothing re-strands. Requires device auth.
    func recoverChange(to destination: String) async -> (ok: Bool, message: String) {
        guard await authenticate(reason: Loc("确认找回搁浅的找零")) else { return (false, Loc("认证未通过")) }
        let destination = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard PRLAddress.isValid(destination, network: network) else { return (false, Loc("收款地址格式不正确")) }
        guard let mnemonic else { return (false, Loc("钱包未就绪")) }
        let session = chainLoadToken
        let sets = recoverable
        let total = sets.reduce(Int64(0)) { $0 + $1.valueSat }
        guard !sets.isEmpty, total > 0 else { return (false, Loc("没有可找回的找零")) }
        let dir = walletDataDir
        let net = network.rawValue
        let bb = BlockbookClient(network: network)
        let feePerKB = (try? await bb.estimateFeePerKB()) ?? 50_000
        guard chainLoadToken == session else { return (false, Loc("钱包或网络已切换，已取消本次找回")) }
        let utxosJSON = Self.encodeUTXOs(sets)
        let inputCount = sets.reduce(0) { $0 + $1.utxos.count }
        do {
            // Over-reserve (2 outputs' worth of fee) so the first build succeeds with a
            // change output, then fold that change back in until the sweep collapses to a
            // single output — no residual re-stranding.
            let startSat = total - Self.estimateFeeSat(inputs: inputCount, outputs: 2, feePerKB: feePerKB)
            guard startSat > 0 else { return (false, Loc("找零金额过小，不足以支付手续费")) }
            let hex = try await sweepConverge(mnemonic: mnemonic, dir: dir, net: net, to: destination,
                                              amountSat: startSat, totalSat: total,
                                              feePerKB: feePerKB, utxosJSON: utxosJSON)
            let txid = try await bb.broadcast(hex)
            guard chainLoadToken == session else { return (true, txid) }
            // Guard the just-swept outpoints so a refresh/re-scan before Blockbook indexes the
            // spend can't re-discover them and flip the screen back to "un-recovered". They stay
            // in `changeBalance`, so the total holds steady until the funds land on the destination.
            recoveringOutpoints = Set(sets.flatMap { s in s.utxos.map { Self.outpoint($0.txid, $0.vout) } })
            recoveringTxid = txid
            recoverable = []
            recoveryScanned = false
            // Refresh a few times so the recovered funds show up once Blockbook indexes them.
            Task { [weak self] in
                for _ in 0..<8 {
                    try? await Task.sleep(for: .seconds(3))
                    await self?.loadChain()
                }
            }
            return (true, txid)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Converging single-output sweep: starting from `amountSat`, rebuild the tx while
    /// folding any residual change back into the payment until it collapses to one
    /// output — so a full-balance send/recovery leaves nothing on the internal change
    /// chain. Shared by `send()` (MAX) and `recoverChange()`.
    private func sweepConverge(mnemonic: String, dir: String, net: String, to destination: String,
                               amountSat: Int64, totalSat: Int64, feePerKB: Int64,
                               utxosJSON: String) async throws -> String {
        var amountSat = amountSat
        var hex = ""
        for _ in 0..<5 {
            hex = try await WalletDBQueue.shared.run {
                try OysterBridge.buildSignedTx(mnemonic: mnemonic, dataDir: dir, network: net,
                                               to: destination, amountSat: amountSat, feeSatPerKB: feePerKB, utxosJSON: utxosJSON)
            }
            let outs = Self.txOutputValues(hex)
            guard outs.count > 1 else { break }                  // single output → clean sweep
            let change = outs.reduce(Int64(0), +) - amountSat     // payment is exactly amountSat
            guard change > 0, amountSat + change < totalSat else { break }
            amountSat += change
        }
        return hex
    }

    func lock() {
        invalidateChainLoads()
        parkOverlay()
        mnemonic = nil
        lastError = nil   // a stale send/switch error must not show up on the unlock screen
        clearChainState()
        phase = .locked
    }

    /// Remove the open wallet from this device (the seed is unrecoverable without backup).
    @discardableResult
    func reset() -> Bool {
        guard let id = activeWalletID else { return false }
        return removeWallet(id: id)
    }

    /// Remove one wallet from this device: its seed, wallet db and cached change data.
    /// Opens the next remaining wallet whose seed can be read; removing the last one
    /// returns to onboarding. Returns false — and changes nothing — if the seed couldn't
    /// be deleted from the Keychain (it would otherwise reappear on the next launch).
    @discardableResult
    func removeWallet(id: String) -> Bool {
        guard wallets.contains(where: { $0.id == id }) else { return false }
        guard Keychain.delete(account: mnemonicAccount(for: id)) else {
            lastError = Loc("无法从钥匙串删除助记词，钱包未移除")
            return false
        }
        let wasActive = id == activeWalletID
        if wasActive {
            invalidateChainLoads()
            clearChainState()
            mnemonic = nil
            WidgetBridge.clearWallet()
        }
        try? FileManager.default.removeItem(at: walletDataURL(for: id))
        let d = UserDefaults.standard
        for n in WalletNetwork.allCases {
            for field in ["owned", "foreign", "balance", "ver"] {
                d.removeObject(forKey: "\(changeKeyPrefix(for: id))\(n.rawValue).\(field)")
            }
            parkedOverlays[overlayKey(id, n)] = nil
        }
        if id == Self.legacyWalletID { d.removeObject(forKey: nameKey) }
        wallets.removeAll { $0.id == id }
        lastError = nil
        guard wasActive else { saveWallets(); return true }

        guard !wallets.isEmpty else {
            activeWalletID = nil
            saveWallets()
            SafeTradeSecrets.clear()   // last wallet gone → also de-provision the exchange API keys
            sync = SyncProgress()
            phase = .noWallet
            return true
        }
        // Open the first remaining wallet whose seed reads; if none can be read right now
        // (locked keychain, denied prompt), keep them all and wait on the unlock screen.
        for w in wallets {
            if let m = Keychain.get(account: mnemonicAccount(for: w.id)) {
                activeWalletID = w.id
                saveWallets()
                restoreOverlay()
                mnemonic = m
                phase = .unlocked
                Task { await loadChain() }
                return true
            }
        }
        activeWalletID = wallets.first?.id
        saveWallets()
        lastError = Loc("无法读取钥匙串中的助记词，请重试解锁")
        phase = .locked
        return true
    }

    private static func satoshis(from amountPRL: Decimal) -> Int64? {
        guard amountPRL > 0 else { return nil }
        let sat = pow(Decimal(10), BlockbookClient.decimals)
        let scaled = amountPRL * sat
        var input = scaled
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 0, .plain)
        guard rounded == scaled else { return nil }
        let number = NSDecimalNumber(decimal: scaled)
        guard number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending else { return nil }
        return number.int64Value
    }

    // MARK: recovery helpers

    /// Stable key for a UTXO outpoint (`txid:vout`).
    private static func outpoint(_ txid: String, _ vout: Int) -> String { "\(txid):\(vout)" }

    private static func encodeUTXOs(_ utxos: [BlockbookClient.UTXO], address: String) -> String {
        encodeUTXOs(utxos.map { (txid: $0.txid, vout: $0.vout, value: $0.value, address: address) })
    }
    private static func encodeUTXOs(_ sets: [RecoverableUTXOSet]) -> String {
        encodeUTXOs(sets.flatMap { s in s.utxos.map { (txid: $0.txid, vout: $0.vout, value: $0.value, address: s.address) } })
    }
    private static func encodeUTXOs(_ items: [(txid: String, vout: Int, value: String, address: String)]) -> String {
        var objs: [[String: Any]] = []
        for it in items {
            guard let v = Int64(it.value) else { continue }
            objs.append(["txid": it.txid, "vout": it.vout, "value": v, "address": it.address])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: objs),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    /// Rough taproot key-spend vsize → fee (sat); slightly over-estimates so any
    /// leftover stays sub-dust and is absorbed into the fee rather than re-stranded.
    private static func estimateFeeSat(inputs: Int, outputs: Int, feePerKB: Int64) -> Int64 {
        let vbytes = 11 + inputs * 58 + outputs * 43
        let fee = Double(vbytes) * Double(feePerKB) / 1000.0
        // Clamp before the Int64 conversion: a garbage feePerKB from the backend would
        // otherwise trap on overflow. Callers reserve this against the inputs, so an
        // absurd value just yields a large (finite) reservation that fails safely upstream.
        guard fee.isFinite, fee < Double(Int64.max - 1) else { return Int64.max - 1 }
        return Int64(fee) + 1
    }

    /// Output values (sat) of a raw signed tx — just enough parsing to detect and
    /// measure a change output while converging the sweep.
    static func txOutputValues(_ hex: String) -> [Int64] {
        let b = hexBytes(hex)
        guard b.count > 6 else { return [] }
        var i = 4
        if i + 1 < b.count, b[i] == 0, b[i + 1] == 1 { i += 2 }   // segwit marker + flag
        func varint() -> Int {
            guard i < b.count else { return 0 }
            let n = b[i]; i += 1
            if n < 0xfd { return Int(n) }
            if n == 0xfd { let v = Int(b[i]) | Int(b[i + 1]) << 8; i += 2; return v }
            if n == 0xfe { var v = 0; for k in 0..<4 { v |= Int(b[i + k]) << (8 * k) }; i += 4; return v }
            var v = 0; for k in 0..<8 { v |= Int(b[i + k]) << (8 * k) }; i += 8; return v
        }
        let nin = varint()
        for _ in 0..<nin { i += 36; let sl = varint(); i += sl + 4 }
        let nout = varint()
        var vals: [Int64] = []
        for _ in 0..<nout {
            guard i + 8 <= b.count else { break }
            var v: Int64 = 0; for k in 0..<8 { v |= Int64(b[i + k]) << (8 * k) }; i += 8
            let sl = varint(); i += sl
            vals.append(v)
        }
        return vals
    }
    private static func hexBytes(_ hex: String) -> [UInt8] {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return [] }
        var out = [UInt8](); out.reserveCapacity(chars.count / 2)
        var k = 0
        while k < chars.count {
            guard let hi = chars[k].hexDigitValue, let lo = chars[k + 1].hexDigitValue else { return [] }
            out.append(UInt8(hi << 4 | lo)); k += 2
        }
        return out
    }

    /// Forget the open wallet's derived keys and chain data (lock, wallet/network switch, removal).
    private func clearChainState() {
        address = nil
        xpub = nil
        receiveIndex = 0
        balance = .zero
        txs = []
        backendReady = false; historyReady = false
        serverBalance = .zero; serverTxs = []; pendingSends.removeAll()
        clearChangeChainState()
    }

    private func clearChangeChainState() {
        changeBalance = .zero
        recoverable = []
        changeOwned = []
        changeForeign = []
        mergedChangeTxids = []
        changeClassLoadedFor = nil
        lastChangeScanSig = nil
        recoveryScanned = false
        recoveringOutpoints = []
        recoveringTxid = nil
    }

    private func invalidateChainLoads() {
        chainLoadToken = UUID()
    }

    private func isCurrentChainLoad(_ token: UUID, mnemonic: String, network: WalletNetwork) -> Bool {
        chainLoadToken == token && self.mnemonic == mnemonic && self.network == network && phase == .unlocked
    }
}

/// A set of stranded-change UTXOs sitting on one address the xpub scan can't see,
/// confirmed spendable by us (oyster could sign a trial tx for it).
struct RecoverableUTXOSet: Identifiable {
    let address: String
    let utxos: [BlockbookClient.UTXO]
    let valueSat: Int64
    var id: String { address }
    var valuePRL: Decimal { Decimal(valueSat) / pow(Decimal(10), BlockbookClient.decimals) }
}
