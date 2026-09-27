import Foundation
import Combine
import CryptoKit
import LocalAuthentication

/// Drives the wallet's lifecycle and is the single source of truth for the Wallet UI:
/// the on-device wallets (seeds in the Keychain, BIP39 via the Go framework), lock /
/// unlock, and on-chain state from Blockbook — balance, history, sends signed on-device,
/// plus the internal-chain change the xpub scan can't see (`refreshChangeChain`).
@MainActor
final class WalletStore: ObservableObject {

    enum Phase: Equatable { case loading, noWallet, locked, unlocked }

    @Published private(set) var phase: Phase = .loading
    @Published var network: WalletNetwork = .mainnet
    @Published private(set) var mnemonic: String?      // in memory only while unlocked
    @Published private(set) var balance: WalletBalance = .zero
    @Published private(set) var txs: [WalletTx] = []
    /// Stranded-change recovery: funds on change addresses the xpub scan can't see,
    /// rediscovered from history and confirmed ours by trial-signing. Settable only
    /// because WalletStore+ChangeChain (another file) maintains them — views just read.
    @Published var recoverable: [RecoverableUTXOSet] = []
    @Published var recoveryScanning = false
    @Published var recoveryScanned = false
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
    /// The tx list gates its "暂无交易记录" empty state on THIS — otherwise it flashes
    /// "暂无" before history loads.
    @Published private(set) var historyReady = false
    /// Older history pages exist beyond what's loaded (交易记录「加载更多」).
    @Published private(set) var historyHasMore = false
    @Published private(set) var loadingMoreHistory = false
    /// Why the latest chain refresh failed (nil = it didn't), and when the snapshot last
    /// refreshed — so a dead backend shows as stale data instead of silently frozen numbers.
    /// (`lastSyncedAt` is read alongside `syncError`, so it needn't publish every load.)
    @Published private(set) var syncError: String?
    private(set) var lastSyncedAt: Date?
    var frameworkOK: Bool { OysterBridge.isAvailable() }
    nonisolated static let sendFeeReserve = Decimal(string: "0.001")!
    /// A fee above this many reserves is called out in the send confirmation.
    nonisolated static let highFeeReserveMultiple: Decimal = 5
    /// How far a MAX sweep may differ from the amount the user confirmed (0.01 PRL): the unused
    /// fee reserve fits comfortably, newly arrived funds or a different wallet do not.
    nonisolated static let maxSweepSlackSat: Int64 = 1_000_000
    /// Fee rate (sat/kB) used for the ownership-oracle trial-sign. Deliberately the
    /// relay floor, not a realistic spend fee: the trial only needs to BUILD, so a low
    /// fee keeps small owned change from failing to cover it and being mis-tagged foreign.
    nonisolated static let oracleFeePerKB: Int64 = 1_000
    /// A signed-but-unsent tx older than this is rebuilt rather than broadcast: its inputs
    /// may have moved since.
    nonisolated static let preparedSendLifetime: TimeInterval = 600
    /// Most unclassified change candidates trial-signed per load; the rest follow on the next.
    nonisolated static let changeScanBatch = 200
    /// Blocks re-scanned below the incremental-discovery watermark, in case of a reorg.
    nonisolated static let changeScanReorgMargin = 6
    /// Confirmations after which a fully spent change address stops being re-fetched.
    nonisolated static let changeRetireDepth = 6
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
    var walletDataDir: String {
        let base = walletDataURL(for: activeWalletID ?? Self.legacyWalletID)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        Self.protectWalletDir(base)
        return base.path
    }

    /// The wallet db holds oyster's key material for a seed that is itself device-only
    /// (ThisDeviceOnly), so a backed-up copy could never be used on a restored device —
    /// it could only leak. Keep it out of iCloud/iTunes/Time Machine backups, and on iOS
    /// unreadable while the device is locked unless a signing call already has it open.
    private static func protectWalletDir(_ dir: URL) {
        var url = dir
        if (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        #if os(iOS)
        let fm = FileManager.default
        let protection = FileProtectionType.completeUnlessOpen
        let paths = [dir.path] + ((try? fm.subpathsOfDirectory(atPath: dir.path)) ?? []).map { dir.appendingPathComponent($0).path }
        for p in paths where (try? fm.attributesOfItem(atPath: p)[.protectionKey] as? FileProtectionType) != protection {
            try? fm.setAttributes([.protectionKey: protection], ofItemAtPath: p)
        }
        #endif
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
    var changeKeyPrefix: String { changeKeyPrefix(for: activeWalletID) }

    /// iCloud-synced name of the legacy wallet (kept for older builds / other devices).
    private let nameKey = "wallet.name"
    private let networkKey = "wallet.network"
    private let walletsKey = "wallet.list"     // local only: seeds never leave the device
    private let walletsBackupKey = "wallet.list.unreadable"   // raw copy of a list this build couldn't decode
    private let activeWalletKey = "wallet.active"
    /// Set by a manual lock, cleared by an authenticated unlock: a locked wallet stays
    /// locked across relaunches instead of auto-opening on the next launch.
    private let lockedKey = "wallet.locked"

    // Chain state below without `private` is shared with the WalletStore+Send and
    // WalletStore+ChangeChain extensions (Swift has no type-private across files).
    // Views never touch it; they read the @Published state above.
    var chainLoadToken = UUID()

    /// Last on-chain snapshot from Blockbook (the source of truth), kept separate
    /// from the published `balance`/`txs` so optimistic sends can be overlaid on
    /// top deterministically (re-applying the overlay never double-counts).
    private var serverBalance: WalletBalance = .zero
    var serverTxs: [WalletTx] = []
    /// History pages beyond the first (「加载更多」). Refreshed only when reloaded, so their
    /// confirmation counts are recomputed from the current tip on publish.
    private var olderTxs: [WalletTx] = []
    private var historyPagesLoaded = 1
    /// Every address Blockbook lists under the xpub (both chains) — "ours" when mapping the
    /// per-address change-chain histories, so a sweep back to the main address isn't shown
    /// as money sent to someone else.
    var xpubAddresses: Set<String> = []
    /// Funds on internal-chain change addresses the xpub scan can't see. Folded into
    /// the published balance and offered to coin selection so change never strands.
    var changeBalance: WalletBalance = .zero
    /// Persisted stranded-change classification for the open wallet + network.
    var change = ChangeChainCache()
    var lastChangeScanSig: String?         // confirmed-send set at the last complete discovery
    var changeClassLoadedFor: WalletNetwork?  // which network's cached classification is in memory
    /// The recovery screen asked for a full re-discovery; consumed by the next load.
    var changeScanForced = false
    /// Just-broadcast sends Blockbook hasn't indexed yet, keyed by txid. Overlaid
    /// on the snapshot so a send shows instantly, then dropped once the indexer
    /// reports the real tx. See `publishOverlay()` / `reconcileAfterSend()`.
    var pendingSends: [String: WalletTx] = [:]
    /// Inputs (outpoint → sat) of sends Blockbook hasn't indexed yet, keyed by txid. Kept
    /// out of coin selection so a second send in the indexing window can't pick an
    /// already-spent outpoint, and out of `available` so MAX matches what can be spent.
    var sendLocks: [String: [String: Int64]] = [:]
    /// Broadcasts whose outcome is unknown (the request failed, the network may still have
    /// the tx). While any is open, new sends are refused rather than risk paying twice.
    var unverifiedSends: Set<String> = []
    /// Txids merged into `serverTxs` from the internal change chain (spends the xpub
    /// history can't see — see `refreshChangeChain`). When a fresh xpub history page
    /// replaces `serverTxs`, entries with these txids are carried over so the rows
    /// don't flicker out until the change-chain merge re-adds them.
    var mergedChangeTxids: Set<String> = []
    /// Outpoints (`txid:vout`) of change UTXOs already committed to an in-flight recovery
    /// sweep Blockbook hasn't indexed yet. Kept OUT of `recoverable` (and coin selection)
    /// so a refresh/re-scan that races the indexer can't re-offer already-swept change as
    /// "recoverable" again — the bug where the recovery screen flipped back to un-recovered
    /// on refresh but showed recovered on relaunch. They stay counted in `changeBalance`
    /// (the funds are still ours, just moving) so the total doesn't dip meanwhile. Cleared
    /// once the sweep's txid lands in history.
    var recoveringOutpoints: Set<String> = []
    var recoveringTxid: String?
    /// Single-flight chain load: every caller awaits the same task, and a call arriving
    /// mid-load schedules one trailing pass, so no caller returns with data older than its
    /// call and two loads never interleave their state writes. `loadGeneration` changes
    /// with the wallet/network, retiring (and cancelling) the old wallet's task.
    private var loadTask: Task<Void, Never>?
    private var loadAgain = false
    private var loadGeneration = 0
    private var lastChainLoadAt: Date?

    /// One store per process: every window (macOS ⌘N, iPad scenes) must share the wallet
    /// list, or each window's `saveWallets()` overwrites the others' changes.
    static let shared = WalletStore()

    init() { loadMeta() }

    // MARK: lifecycle

    func bootstrap() {
        Keychain.migrateLegacyItemsIfNeeded()
        loadMeta()
        loadWallets()
        guard let id = activeWalletID else {
            #if DEBUG
            // Screenshot-only: SHOT_MNEMONIC imports a throwaway test wallet on launch, so a
            // Mac capture run (no XCUITest to drive the import sheet) lands on a real 钱包 tab.
            if let m = ProcessInfo.processInfo.environment["SHOT_MNEMONIC"],
               commitWallet(name: "Pearl Wallet", mnemonic: m) { return }
            #endif
            phase = .noWallet
            return
        }
        // Locked by hand last session: stay locked until the owner authenticates.
        if manuallyLocked { phase = .locked; return }
        if let m = Keychain.get(account: mnemonicAccount(for: id)) {
            open(mnemonic: m)
        } else {
            // The seed is listed in the Keychain but couldn't be read (macOS access prompt
            // denied, keychain locked). Don't fall through to onboarding — let them retry.
            lastError = Loc("无法读取钥匙串中的助记词，请重试解锁")
            phase = .locked
        }
    }

    private var manuallyLocked: Bool {
        get {
            #if DEBUG
            if Keychain.isMemoryOnly { return false }   // screenshot runs share the real defaults
            #endif
            return UserDefaults.standard.bool(forKey: lockedKey)
        }
        set {
            #if DEBUG
            if Keychain.isMemoryOnly { return }
            #endif
            UserDefaults.standard.set(newValue, forKey: lockedKey)
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
    /// can't be read. While locked it only changes which wallet the unlock screen opens —
    /// switching must not be a way around the lock.
    @discardableResult
    func switchWallet(to id: String) -> Bool {
        guard id != activeWalletID, wallets.contains(where: { $0.id == id }) else { return id == activeWalletID }
        guard phase != .locked else {
            activeWalletID = id
            saveWallets()
            lastError = nil
            return true
        }
        guard let m = Keychain.get(account: mnemonicAccount(for: id)) else {
            lastError = Loc("无法读取该钱包的助记词（钥匙串拒绝了访问），请重试")
            return false
        }
        select(walletID: id)
        open(mnemonic: m)
        return true
    }

    /// Make `id` the active wallet with a clean chain state (the old one's optimistic state
    /// is parked). The caller opens it with `open(mnemonic:)`.
    private func select(walletID id: String) {
        invalidateChainLoads()
        parkOverlay()
        clearChainState()
        activeWalletID = id
        saveWallets()
        WidgetBridge.clearWallet()   // don't keep showing the previous wallet until the new one publishes
    }

    /// Unlock the active wallet with its (already read or just typed) seed and start syncing.
    private func open(mnemonic m: String) {
        invalidateChainLoads()
        restoreOverlay()
        mnemonic = m
        phase = .unlocked
        manuallyLocked = false
        lastError = nil
        if let id = activeWalletID { noteFingerprint(of: m, for: id) }
        Task { await loadChain() }
    }

    // MARK: per-wallet optimistic state

    /// Optimistic sends and in-flight recovery guards of a wallet/network the user moved
    /// away from before Blockbook indexed them. Restored on the way back so a quick A→B→A
    /// can't re-show pre-send balances or re-offer already-swept change.
    struct ParkedOverlay {
        var pendingSends: [String: WalletTx] = [:]
        var sendLocks: [String: [String: Int64]] = [:]
        var unverifiedSends: Set<String> = []
        var recoveringOutpoints: Set<String> = []
        var recoveringTxid: String?
        var isEmpty: Bool {
            pendingSends.isEmpty && sendLocks.isEmpty && unverifiedSends.isEmpty
                && recoveringOutpoints.isEmpty && recoveringTxid == nil
        }
    }
    var parkedOverlays: [String: ParkedOverlay] = [:]
    func overlayKey(_ id: String?, _ net: WalletNetwork) -> String { "\(id ?? "")|\(net.rawValue)" }

    private func parkOverlay() {
        // Locked: lock() already parked this wallet's state and cleared it, so the empty
        // state seen now must not overwrite (erase) that parked copy.
        guard mnemonic != nil else { return }
        let parked = ParkedOverlay(pendingSends: pendingSends, sendLocks: sendLocks,
                                   unverifiedSends: unverifiedSends,
                                   recoveringOutpoints: recoveringOutpoints, recoveringTxid: recoveringTxid)
        parkedOverlays[overlayKey(activeWalletID, network)] = parked.isEmpty ? nil : parked
    }

    private func restoreOverlay() {
        guard let p = parkedOverlays.removeValue(forKey: overlayKey(activeWalletID, network)) else { return }
        pendingSends = p.pendingSends
        sendLocks = p.sendLocks
        unverifiedSends = p.unverifiedSends
        recoveringOutpoints = p.recoveringOutpoints
        recoveringTxid = p.recoveringTxid
    }

    /// Generate a brand-new mnemonic (not yet persisted — caller confirms backup first).
    func newMnemonic() -> String? { OysterBridge.generateMnemonic() }

    /// Validate a user-entered recovery phrase.
    func isValidMnemonic(_ m: String) -> Bool { OysterBridge.validate(m) }

    /// The one spelling of a recovery phrase: lower-case words joined by single spaces.
    /// BIP39 derives from the exact string, so stray tabs/newlines/double spaces must never
    /// reach the Keychain.
    nonisolated static func normalizedPhrase(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// Keyed SHA-256 of a seed, stored in the (non-secret) wallet list so an import can
    /// recognise a seed that's already here without reading every seed from the Keychain.
    /// The key is a random per-device salt, so the list alone can't be tested against
    /// guessed phrases elsewhere.
    static func fingerprint(of phrase: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(normalizedPhrase(phrase).utf8),
                                                  using: SymmetricKey(data: fingerprintSalt))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
    private static var fingerprintSalt: Data {
        let d = UserDefaults.standard
        if let s = d.data(forKey: "wallet.fingerprintSalt"), s.count == 32 { return s }
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        d.set(Data(bytes), forKey: "wallet.fingerprintSalt")
        return Data(bytes)
    }

    /// Record the seed fingerprint for a wallet whose seed was just read legitimately
    /// (records from before fingerprints existed get one lazily).
    private func noteFingerprint(of phrase: String, for id: String) {
        guard let i = wallets.firstIndex(where: { $0.id == id }) else { return }
        let fp = Self.fingerprint(of: phrase)
        guard wallets[i].fingerprint != fp else { return }
        wallets[i].fingerprint = fp
        saveWallets()
    }

    /// The wallet already holding `phrase`, if any. Matches fingerprints; only records that
    /// predate them fall back to reading their seed (once — the fingerprint is kept after).
    private func existingWallet(for phrase: String) -> WalletRecord? {
        let fp = Self.fingerprint(of: phrase)
        if let hit = wallets.first(where: { $0.fingerprint == fp }) { return hit }
        for w in wallets where w.fingerprint == nil {
            guard let m = Keychain.get(account: mnemonicAccount(for: w.id)) else { continue }
            noteFingerprint(of: m, for: w.id)
            if Self.normalizedPhrase(m) == phrase { return w }
        }
        return nil
    }

    /// Add a freshly created or imported wallet to this device and open it. Importing
    /// a seed that is already here just switches to that wallet instead of duplicating it.
    func commitWallet(name: String, mnemonic: String) -> Bool {
        let phrase = Self.normalizedPhrase(mnemonic)
        guard OysterBridge.validate(phrase) else {
            lastError = Loc("助记词无效（BIP39 校验失败）")
            return false
        }
        if let existing = existingWallet(for: phrase) {
            // Typing the seed proves ownership, so this also opens a locked wallet. Open it
            // with the STORED seed when readable: that's the exact string its keys came from.
            let seed = Keychain.get(account: mnemonicAccount(for: existing.id)) ?? phrase
            if existing.id != activeWalletID {
                select(walletID: existing.id)
                open(mnemonic: seed)
            } else if self.mnemonic == nil {
                open(mnemonic: seed)
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
        wallets.append(WalletRecord(id: id, name: trimmed.isEmpty ? suggestedWalletName() : trimmed,
                                    fingerprint: Self.fingerprint(of: phrase)))
        select(walletID: id)
        open(mnemonic: phrase)
        return true
    }

    /// Re-open the wallet after a lock. Requires device auth — the lock would otherwise
    /// be decorative.
    func unlock() async {
        guard let id = activeWalletID else { phase = .noWallet; return }
        lastError = nil
        // With no device passcode there is nothing to authenticate against: the lock is
        // then only a privacy screen, and failing closed would shut the owner out of
        // their own wallet for good. Sends stay gated by authenticate() regardless.
        if Self.deviceHasPasscode {
            guard await authenticate(reason: Loc("解锁钱包")) else {
                if lastError == nil { lastError = Loc("认证未通过") }
                return
            }
        }
        guard phase == .locked, id == activeWalletID else { return }
        guard let m = Keychain.get(account: mnemonicAccount(for: id)) else {
            lastError = Loc("无法读取钥匙串中的助记词，请重试解锁")
            return
        }
        open(mnemonic: m)
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
    /// sensitive actions: unlocking, revealing the seed and authorising a send.
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

    /// False only when the device has no passcode at all (biometry lockout etc. still
    /// count as "has one" — deviceOwnerAuthentication falls back to the passcode).
    private static var deviceHasPasscode: Bool {
        var err: NSError?
        if LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) { return true }
        return err?.code != LAError.Code.passcodeNotSet.rawValue
    }

    // MARK: chain loading

    /// Derive the real receive address (on-device) and pull balance + history
    /// from Blockbook. Safe to call repeatedly (idempotent). Single-flighted: returns once
    /// a load that started after this call has finished. `forceChangeScan` re-runs the
    /// full stranded-change discovery (the recovery screen).
    func loadChain(forceChangeScan: Bool = false) async {
        if forceChangeScan { changeScanForced = true }
        if let running = loadTask {
            loadAgain = true
            await running.value
            return
        }
        let generation = loadGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.loadAgain = false
                await self.loadChainOnce()
            } while self.loadAgain && generation == self.loadGeneration && !Task.isCancelled
            // Same main-actor turn as the loop's exit check, so a caller can't slip in
            // between and wait on a task that will never loop again.
            if generation == self.loadGeneration { self.loadTask = nil }
        }
        loadTask = task
        await task.value
    }

    /// Screen-appearance refresh: joins a load already in flight, and skips one that
    /// finished moments ago (the dashboard, 收款 and 记录 each ask on appear).
    func refreshIfStale(maxAge: TimeInterval = 5) async {
        if let running = loadTask { await running.value; return }
        if let t = lastChainLoadAt, Date().timeIntervalSince(t) < maxAge { return }
        await loadChain()
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
        // Balance + history in ONE response (they can't disagree about a just-indexed send),
        // alongside the confirmed UTXOs that define what is actually spendable.
        let knownChange = change.owned
        async let accountRequest = bb.account(xpub: xp, knownChange: knownChange)
        async let utxoRequest = bb.utxos(xpub: xp)
        let account: BlockbookClient.XpubAccount
        do {
            account = try await accountRequest
        } catch {
            guard isCurrentChainLoad(token, mnemonic: mnemonic, network: expectedNetwork) else { return }
            // Backend unreachable: keep the last good figures and say so. The change-chain
            // refresh would only stall behind the same dead backend, so skip it too.
            syncError = Loc("无法连接区块浏览器")
            lastChainLoadAt = Date()
            return
        }
        let utxos = try? await utxoRequest
        guard isCurrentChainLoad(token, mnemonic: mnemonic, network: expectedNetwork) else { return }
        let total = account.confirmed + account.unconfirmed
        // Available = what coin selection can actually spend: the confirmed UTXOs. The old
        // `confirmed + min(0, unconfirmed)` overstated it whenever an unconfirmed receipt
        // offset an unconfirmed spend (whose inputs then counted as spendable again).
        let spendable = utxos.map { list in RawTx.prl(fromSat: list.reduce(Int64(0)) { $0 + (Int64($1.value) ?? 0) }) }
            ?? max(0, account.confirmed + min(0, account.unconfirmed))
        serverBalance = WalletBalance(total: total, available: max(0, min(spendable, total)))
        xpubAddresses = account.addresses
        if historyPagesLoaded <= 1, historyHasMore != account.hasMorePages { historyHasMore = account.hasMorePages }
        // Carry over internal-chain spends merged by refreshChangeChain — the xpub
        // page can't contain them, and dropping them here would flicker the rows
        // out until the (slow) change-chain merge below re-adds them.
        let pageIDs = Set(account.txs.map(\.txid))
        let carried = serverTxs.filter { mergedChangeTxids.contains($0.txid) && !pageIDs.contains($0.txid) }
        serverTxs = carried.isEmpty ? account.txs : (account.txs + carried).sorted { $0.time > $1.time }
        settleIndexed(pageIDs)
        if !backendReady { backendReady = true }
        if !historyReady { historyReady = true }
        lastSyncedAt = Date()
        if syncError != nil { syncError = nil }
        // Publish the moment the snapshot lands — the change-chain scan below is slower.
        publishOverlay()
        // Bring internal-chain change (which the xpub scan misses) into balance + spending.
        await refreshChangeChain(xpub: xp, dir: dir, net: net, token: token, force: changeScanForced)
        guard isCurrentChainLoad(token, mnemonic: mnemonic, network: expectedNetwork) else { return }
        await resolveStalePendingSends(bb: bb, token: token)
        lastChainLoadAt = Date()
        publishOverlay()
    }

    /// Append the next history page (交易记录「加载更多」).
    func loadMoreHistory() async {
        guard historyHasMore, !loadingMoreHistory, mnemonic != nil, let xp = xpub else { return }
        let token = chainLoadToken
        let net = network
        let page = historyPagesLoaded + 1
        loadingMoreHistory = true
        defer { loadingMoreHistory = false }
        guard let more = try? await BlockbookClient(network: net)
                .account(xpub: xp, page: page, knownChange: change.owned.union(xpubAddresses)),
              chainLoadToken == token, network == net else { return }
        let known = Set(serverTxs.map(\.txid)).union(olderTxs.map(\.txid))
        olderTxs += more.txs.filter { !known.contains($0.txid) }
        historyPagesLoaded = page
        historyHasMore = more.hasMorePages
        publishOverlay()
    }

    /// The indexer now reports these txids → stop overlaying our optimistic copies and
    /// release the outpoints they spend (Blockbook's own UTXO set has caught up).
    func settleIndexed(_ txids: Set<String>) {
        for id in txids where pendingSends[id] != nil || sendLocks[id] != nil || unverifiedSends.contains(id) {
            pendingSends[id] = nil
            sendLocks[id] = nil
            unverifiedSends.remove(id)
        }
        // The recovery sweep is indexed too → stop guarding its swept change outpoints.
        if let tid = recoveringTxid, txids.contains(tid) {
            recoveringOutpoints = []; recoveringTxid = nil
        }
    }

    /// Highest block implied by the fresh first page (a tx's height + its confirmations).
    private var tipHeight: Int? {
        serverTxs.compactMap { tx in tx.height.map { $0 + tx.confirmations - 1 } }.max()
    }

    /// Rows fetched a while ago (older pages, archived change-chain spends) with their
    /// confirmation counts brought up to the current tip.
    private func withLiveConfirmations(_ rows: [WalletTx]) -> [WalletTx] {
        guard let tip = tipHeight else { return rows }
        return rows.map { tx in
            guard let h = tx.height else { return tx }
            var t = tx
            t.confirmations = max(tx.confirmations, tip - h + 1)
            return t
        }
    }

    /// Recompute the published `balance` / `txs` from the on-chain snapshot plus any
    /// still-unindexed optimistic sends. Idempotent: an overlay is only applied for
    /// a pending tx the snapshot doesn't yet contain, so re-publishing (or a second
    /// send) never double-counts a spend.
    func publishOverlay() {
        var known = Set(serverTxs.map { $0.txid })
        var extras: [WalletTx] = []
        for tx in olderTxs + change.archive where known.insert(tx.txid).inserted { extras.append(tx) }
        let overlay = pendingSends.values.filter { !known.contains($0.txid) }
        let nextTxs = (extras.isEmpty && overlay.isEmpty) ? serverTxs
            : (serverTxs + withLiveConfirmations(extras) + overlay).sorted { $0.time > $1.time }
        // Assigning an equal value still fires objectWillChange and re-renders every
        // wallet screen, and the chain poll republishes unchanged data every 15–60 s.
        if nextTxs != txs { txs = nextTxs }
        // Base = external (xpub) snapshot + internal-chain change the xpub scan misses.
        let base = WalletBalance(total: serverBalance.total + changeBalance.total,
                                 available: serverBalance.available + changeBalance.available)
        let outflow = overlay.reduce(Decimal(0)) { $0 + $1.amount + $1.fee }
        // Until the indexer catches up, the inputs of a pending send still look spendable;
        // what isn't spendable is exactly those inputs (the change only returns once mined).
        let lockedInputs = overlay.reduce(Decimal(0)) { sum, tx in
            sum + (sendLocks[tx.txid].map { RawTx.prl(fromSat: $0.values.reduce(0, +)) } ?? tx.amount + tx.fee)
        }
        let nextBalance = overlay.isEmpty ? base
            : WalletBalance(total: max(0, base.total - outflow),
                            available: max(0, base.available - lockedInputs))
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
                                      languageCode: LocBundleHolder.shared.languageCode)
            WidgetBridge.updatePrice(prlUsd: PRLPriceManager.shared.usd)
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

    func lock() {
        invalidateChainLoads()
        parkOverlay()
        mnemonic = nil
        lastError = nil   // a stale send/switch error must not show up on the unlock screen
        clearChainState()
        phase = .locked
        manuallyLocked = true
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
        // Behind any FFI call already queued for this wallet's db, so none of them can
        // re-create it after the delete.
        let dbDir = walletDataURL(for: id)
        Task { await WalletDBQueue.shared.run { try? FileManager.default.removeItem(at: dbDir) } }
        ChangeChainCache.remove(prefix: changeKeyPrefix(for: id))
        for n in WalletNetwork.allCases { parkedOverlays[overlayKey(id, n)] = nil }
        if id == Self.legacyWalletID { UserDefaults.standard.removeObject(forKey: nameKey) }
        wallets.removeAll { $0.id == id }
        lastError = nil
        guard wasActive else { saveWallets(); return true }

        guard !wallets.isEmpty else {
            activeWalletID = nil
            saveWallets()
            manuallyLocked = false
            SafeTradeSecrets.clear()   // last wallet gone → also de-provision the exchange API keys
            phase = .noWallet
            return true
        }
        // Open the first remaining wallet whose seed reads; if none can be read right now
        // (locked keychain, denied prompt), keep them all and wait on the unlock screen.
        for w in wallets {
            if let m = Keychain.get(account: mnemonicAccount(for: w.id)) {
                activeWalletID = w.id
                saveWallets()
                open(mnemonic: m)
                return true
            }
        }
        activeWalletID = wallets.first?.id
        saveWallets()
        lastError = Loc("无法读取钥匙串中的助记词，请重试解锁")
        phase = .locked
        return true
    }

    /// Forget the open wallet's derived keys and chain data (lock, wallet/network switch, removal).
    private func clearChainState() {
        address = nil
        xpub = nil
        receiveIndex = 0
        balance = .zero
        txs = []
        backendReady = false; historyReady = false
        historyHasMore = false; historyPagesLoaded = 1; olderTxs = []
        lastSyncedAt = nil; syncError = nil; lastChainLoadAt = nil
        serverBalance = .zero; serverTxs = []; xpubAddresses = []
        pendingSends.removeAll(); sendLocks.removeAll(); unverifiedSends.removeAll()
        clearChangeChainState()
    }

    private func clearChangeChainState() {
        changeBalance = .zero
        recoverable = []
        change = ChangeChainCache()
        mergedChangeTxids = []
        changeClassLoadedFor = nil
        lastChangeScanSig = nil
        changeScanForced = false
        recoveryScanned = false
        recoveringOutpoints = []
        recoveringTxid = nil
    }

    /// Retire every in-flight load of the wallet/network being left: its token no longer
    /// matches (no stale writes), its task is cancelled (its requests stop), and the next
    /// `loadChain()` starts fresh instead of queueing behind it.
    private func invalidateChainLoads() {
        chainLoadToken = UUID()
        loadGeneration += 1
        loadTask?.cancel()
        loadTask = nil
        loadAgain = false
    }

    func isCurrentChainLoad(_ token: UUID, mnemonic: String, network: WalletNetwork) -> Bool {
        chainLoadToken == token && self.mnemonic == mnemonic && self.network == network && phase == .unlocked
    }
}
