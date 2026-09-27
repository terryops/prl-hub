import Foundation
import Combine
import SwiftUI

/// On-chain income for one mining address, as the 链上到账 rows show it. A figure is nil until
/// it first loads; `failed` then says whether that's still "查询中" or a lookup that didn't
/// answer ("—"). A later failure keeps the last good figures rather than blanking them.
struct OnchainIncome: Equatable {
    var h24: Double?
    var d7: Double?
    var total: Double?
    var failed = false
}

@MainActor
final class PoolStore: ObservableObject {
    // Per-miner watches the user added.
    @Published var watches: [PoolWatch] = []
    @Published var watchData: [UUID: WatchData] = [:]
    /// On-chain actual income (Blockbook balance history), keyed by ADDRESS — two watches on
    /// one address are one lookup and show one set of figures.
    @Published var onchain: [String: OnchainIncome] = [:]
    /// Live fiat conversion for displaying PRL amounts.
    @Published var prlUsd: Double?   // 1 PRL = ? USD — mirrors the app-wide PRLPriceManager
    private var priceSub: AnyCancellable?
    @Published var usdCny: Double?   // 1 USD = ? CNY
    @Published var loading = false

    nonisolated static let watchesKey = "pool.watches"
    /// Stored watches this build can't read — a pool added in a newer version, say — kept
    /// VERBATIM and written back on every save. Dropping them would push the trimmed list to
    /// iCloud and delete those watches from the newer devices as well.
    private var foreignWatches: [Data] = []
    /// Pools that are gone for good: their stored watches are dropped, not carried forever.
    nonisolated private static let retiredPools: Set<String> = ["TW-Pool"]

    init() {
        loadWatches()
        // Same number as every other screen: follow the shared price as it updates.
        priceSub = PRLPriceManager.shared.$usd.sink { [weak self] in
            if let v = $0, self?.prlUsd != v { self?.prlUsd = v }
        }
        #if DEBUG
        seedScreenshotWatchIfNeeded()
        #endif
    }

    #if DEBUG
    /// App Store screenshot harness ONLY (never compiled into release builds):
    /// seed a single watch from the launch environment so the "我的监控" card renders
    /// real pool data without driving the add-sheet UI. No-op unless SHOT_WATCH_ADDR
    /// is set — and only the XCUITest sets it. Ephemeral: not persisted.
    private func seedScreenshotWatchIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["SHOT_WATCH_ADDR"], !raw.isEmpty else { return }
        let addr = Self.cleanAddr(raw).lowercased()
        guard PRLAddress.isValid(addr, network: .mainnet) else { return }
        let pool = PoolKind(rawValue: env["SHOT_WATCH_POOL"] ?? "AlphaPool") ?? .alphaPool
        watches = [PoolWatch(pool: pool, address: addr)]
    }
    #endif

    // MARK: watches persistence

    /// Normalise a pasted address: take the first whitespace-delimited token, so
    /// a value that got duplicated across a newline (e.g. "prl1…\nprl1…") — which
    /// `trimmingCharacters` can't fix because the break is in the middle — resolves
    /// to a single valid address instead of silently failing every lookup.
    nonisolated static func cleanAddr(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
            ?? s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct StoredWatches {
        var known: [PoolWatch] = []
        /// Elements this build can't decode, as their raw JSON.
        var foreign: [Data] = []
        var droppedRetired = false
    }

    /// Per-element lenient decode: one watch this build can't read costs that watch — and is
    /// kept aside verbatim — instead of failing (and wiping) the entire array.
    nonisolated static func decodeStoredWatches(_ data: Data) -> StoredWatches? {
        guard let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        var out = StoredWatches()
        for el in arr where JSONSerialization.isValidJSONObject(el) {
            guard let raw = try? JSONSerialization.data(withJSONObject: el) else { continue }
            if let w = try? JSONDecoder().decode(PoolWatch.self, from: raw) {
                out.known.append(w)
            } else if let pool = (el as? [String: Any])?["pool"] as? String, retiredPools.contains(pool) {
                out.droppedRetired = true
            } else {
                out.foreign.append(raw)
            }
        }
        return out
    }

    /// The watches this build can read, straight from storage (for the monitor's device sync
    /// and income, which don't own a PoolStore).
    nonisolated static func storedWatches() -> [PoolWatch] {
        UserDefaults.standard.data(forKey: watchesKey).flatMap(decodeStoredWatches)?.known ?? []
    }

    private func loadWatches() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.watchesKey), let stored = Self.decodeStoredWatches(data) {
            var foreign = stored.foreign
            // Auto-heal any corrupted (whitespace-containing) addresses on load, per the
            // pool's own rules — an F2Pool watch stores a read-only page URL, not an address.
            // One that can't be healed is set aside with the unreadable ones, not deleted.
            var cleaned: [PoolWatch] = []
            for var w in stored.known {
                if let a = normalizeWatchAddress(w.pool, w.address) {
                    w.address = a
                    cleaned.append(w)
                } else if let raw = try? JSONEncoder().encode(w) {
                    foreign.append(raw)
                }
            }
            watches = cleaned
            foreignWatches = foreign
            // Persist when something was healed OR a retired-pool watch was dropped.
            if cleaned != stored.known || stored.droppedRetired { saveWatches() }
        } else if let legacy = d.string(forKey: "pool.address"),
                  !legacy.trimmingCharacters(in: .whitespaces).isEmpty {
            // Migrate the old single-address setup → an AlphaPool watch.
            let a = Self.cleanAddr(legacy).lowercased()
            if PRLAddress.isValid(a, network: .mainnet) {
                watches = [PoolWatch(pool: .alphaPool, address: a)]
                saveWatches()
            }
        }
    }

    private func saveWatches() {
        guard var data = try? JSONEncoder().encode(watches) else { return }
        if !foreignWatches.isEmpty, var arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
            arr += foreignWatches.compactMap { try? JSONSerialization.jsonObject(with: $0) }
            if let merged = try? JSONSerialization.data(withJSONObject: arr) { data = merged }
        }
        UserDefaults.standard.set(data, forKey: Self.watchesKey)
        CloudSync.push(Self.watchesKey)   // mirror to iCloud (no-op if not provisioned)
    }

    /// Re-read watches after an incoming iCloud change.
    func reloadWatches() {
        loadWatches()
        Task { await refresh() }
    }

    func addWatch(pool: PoolKind, address: String, alias: String = "") {
        guard let a = normalizeWatchAddress(pool, address),
              !watches.contains(where: { $0.pool == pool && $0.address == a }) else { return }
        var w = PoolWatch(pool: pool, address: a)
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { w.alias = trimmed }
        watches.append(w); saveWatches()
        Task {
            async let income: Void = fetchOnchainIncome(force: false)
            adopt(await fetchWatchData(w), for: w)
            await income
        }
    }

    func removeWatch(_ id: UUID) {
        watches.removeAll { $0.id == id }
        watchData[id] = nil
        pruneOnchain()
        saveWatches()
    }

    /// Reorder a watch during a drag (drag-to-reorder “我的监控”). The move itself is live
    /// only — persisting on every hover would spam UserDefaults / iCloud — but the save is
    /// SCHEDULED here rather than left to the drop callback: when the system cancels a drag
    /// (released where no target accepts it, or over the window chrome) neither `performDrop`
    /// nor the scroll view's `onDrop` fires, and an order that was only ever committed from
    /// those callbacks would silently revert on the next launch. Debounced, so a drag that
    /// sweeps across ten cards still writes once, ~0.7s after the user settles.
    func moveWatch(from source: Int, to destination: Int) {
        guard watches.indices.contains(source),
              source != destination,
              (0...watches.count).contains(destination) else { return }
        watches.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
        orderCommit?.cancel()
        orderCommit = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.commitWatchOrder()
        }
    }

    /// Persist the current watch order (drop landed, or the debounce above fired).
    func commitWatchOrder() {
        orderCommit?.cancel()
        orderCommit = nil
        saveWatches()
    }

    private var orderCommit: Task<Void, Never>?

    /// Pause / resume a watch. Pausing drops its cached stats so the card can't keep showing
    /// numbers that are quietly going stale; resuming fetches it again immediately rather than
    /// leaving a spinner until the next 60s tick.
    func setEnabled(_ id: UUID, _ on: Bool) {
        guard let i = watches.firstIndex(where: { $0.id == id }), watches[i].isEnabled != on else { return }
        watches[i].enabled = on
        saveWatches()
        if on {
            let w = watches[i]
            Task {
                async let income: Void = fetchOnchainIncome(force: false)
                adopt(await fetchWatchData(w), for: w)
                await income
                pushWidgetSnapshot()
            }
        } else {
            watchData[id] = nil
            pruneOnchain()
            pushWidgetSnapshot()   // drop it from the widget now, not at the next refresh
        }
    }

    /// Set (or clear) a watch's display alias. Empty/whitespace clears it back to
    /// the pool's default label. Persisted + iCloud-synced like add/remove.
    func renameWatch(_ id: UUID, alias: String) {
        guard let i = watches.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        watches[i].alias = trimmed.isEmpty ? nil : trimmed
        saveWatches()
    }

    /// Edit an existing watch's pool / address / alias in place — for when a miner
    /// switches pools (the watch keeps its id, so its card position and ordering
    /// survive). No-op on an invalid address or if the new (pool, address) would
    /// duplicate a DIFFERENT watch. When the pool or address actually changes, the
    /// stale cached stats are cleared and a fresh fetch kicks off.
    func updateWatch(_ id: UUID, pool: PoolKind, address: String, alias: String = "") {
        guard let i = watches.firstIndex(where: { $0.id == id }) else { return }
        guard let a = normalizeWatchAddress(pool, address),
              !watches.contains(where: { $0.id != id && $0.pool == pool && $0.address == a }) else { return }
        let changed = watches[i].pool != pool || watches[i].address != a
        watches[i].pool = pool
        watches[i].address = a
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        watches[i].alias = trimmed.isEmpty ? nil : trimmed
        saveWatches()
        guard changed else { return }   // alias-only edit: keep the cached data
        watchData[id] = nil
        pruneOnchain()
        let w = watches[i]
        Task {
            async let income: Void = fetchOnchainIncome(force: false)
            adopt(await fetchWatchData(w), for: w)
            await income
        }
    }

    /// Adopt a fetch result only if the watch still points where the fetch went. A refresh
    /// that was already in flight when the user switched a watch from AlphaPool to Kryptex
    /// (same id) would otherwise land the OLD pool's numbers on the new card. nil = a
    /// cancelled fetch: the card keeps its current state.
    private func adopt(_ d: WatchData?, for w: PoolWatch) {
        guard let d, watches.contains(where: { $0.sameTarget(as: w) }) else { return }
        watchData[w.id] = d
    }

    // MARK: refresh

    private var refreshTask: Task<Void, Never>?

    /// Pull-to-refresh, the toolbar button, the 60s loop and an iCloud-triggered reload can all
    /// land at once; they share ONE refresh instead of racing (the first to finish used to
    /// clear `loading` under the others). `force` also bypasses the on-chain cache.
    func refresh(force: Bool = false) async {
        if let running = refreshTask { await running.value; return }
        let t = Task { await performRefresh(force: force) }
        refreshTask = t
        await withTaskCancellationHandler { await t.value } onCancel: { t.cancel() }
        refreshTask = nil
    }

    private func performRefresh(force: Bool) async {
        loading = true
        async let pu: Void = PRLPriceManager.shared.refreshIfStale()
        // The chain lookups run ALONGSIDE the pool fetches: one slow pool no longer holds up
        // 链上到账 for every card.
        async let income: Void = fetchOnchainIncome(force: force)

        let current = watches.filter(\.isEnabled)   // a paused watch costs no network
        await withTaskGroup(of: (PoolWatch, WatchData?).self) { group in
            for w in current { group.addTask { (w, await fetchWatchData(w)) } }
            // Skip a watch the user removed or re-pointed mid-refresh, and skip nil (a
            // cancelled fetch) so navigating away can't overwrite a card with 失败.
            for await (w, d) in group { adopt(d, for: w) }
        }

        await income
        await pu   // prlUsd follows PRLPriceManager via priceSub
        // The app-wide daily rate table — no separate exchange-rate request of our own.
        if let c = CurrencyManager.shared.rate("CNY") { usdCny = c }
        loading = false

        pushWidgetSnapshot()
    }

    /// Mirror ALL pool watches + fiat rates into the shared App Group so the
    /// home-screen Mining widget can show every miner (2+) and refresh itself.
    private func pushWidgetSnapshot() {
        WidgetBridge.updatePrice(prlUsd: prlUsd, usdCny: usdCny)
        let pools = watches.filter(\.isEnabled).map { w -> WidgetPool in
            // The SAME live total the widget computes on its own refresh (PoolMinerStats.liveRate).
            let s = watchData[w.id]?.stats
            return WidgetPool(label: w.displayName,
                              kind: w.pool.rawValue,
                              address: w.address,
                              hashrate: s?.liveRateText ?? "—",
                              hashrateRaw: s?.liveRate ?? 0,
                              online: s?.onlineCount ?? 0,
                              total: s?.workers.count ?? 0)
        }
        WidgetBridge.updatePools(pools)
    }

    // MARK: per-address on-chain income (see ChainIncome)

    /// The address a watch's payouts land on — nil for F2Pool, whose read-only page link
    /// never reveals the payout address.
    private static func chainAddress(_ w: PoolWatch) -> String? {
        guard w.pool.isAddressBased else { return nil }
        let a = cleanAddr(w.address).lowercased()
        return PRLAddress.isValid(a, network: .mainnet) ? a : nil
    }

    /// Every enabled watch's payout address — the user's own mining addresses, between which a
    /// transfer is not income.
    private var ownAddresses: [String] {
        Array(Set(watches.filter(\.isEnabled).compactMap(Self.chainAddress)))
    }

    private func fetchOnchainIncome(force: Bool) async {
        let own = ownAddresses
        guard !own.isEmpty else { return }
        async let recent = ChainIncome.shared.recent(own, force: force)
        async let life = ChainIncome.shared.lifetime(own, force: force)
        let (r, l) = await (recent, life)
        for a in own {
            var f = onchain[a] ?? OnchainIncome()
            if let x = r[a] { f.h24 = x.h24; f.d7 = x.d7 }
            if let t = l[a] { f.total = t }
            f.failed = r[a] == nil || l[a] == nil
            onchain[a] = f
        }
        pruneOnchain()
    }

    /// Drop figures for addresses no enabled watch points at any more.
    private func pruneOnchain() {
        let own = Set(ownAddresses)
        for a in onchain.keys where !own.contains(a) { onchain[a] = nil }
    }

    /// 24h hashrate of EVERY enabled watch paying into `address`. The 每 P·天 row divides the
    /// address's whole on-chain income by this: dividing it by one card's hashrate over-stated
    /// the yield whenever the address is mined on more than one pool.
    func addressHashrate24h(_ address: String) -> Double {
        watches.filter { $0.isEnabled && Self.chainAddress($0) == address }
            .reduce(0) { $0 + (watchData[$1.id]?.hr24hRaw ?? 0) }
    }

    func chainAddress(for w: PoolWatch) -> String? { Self.chainAddress(w) }
}
