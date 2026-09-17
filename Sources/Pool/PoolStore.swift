import Foundation
import Combine
import SwiftUI

@MainActor
final class PoolStore: ObservableObject {
    // Per-miner watches the user added.
    @Published var watches: [PoolWatch] = []
    @Published var watchData: [UUID: WatchData] = [:]
    /// On-chain actual income (Blockbook balancehistory) per watch — 近24h / 近7天 / 累计.
    @Published var onchain24h: [UUID: Double] = [:]
    @Published var onchain7d: [UUID: Double] = [:]
    @Published var onchainTotal: [UUID: Double] = [:]
    /// Live fiat conversion for displaying PRL amounts.
    @Published var prlUsd: Double?   // 1 PRL = ? USD (SafeTrade PRL/USDT)
    @Published var usdCny: Double?   // 1 USD = ? CNY
    @Published var loading = false

    private static let watchesKey = "pool.watches"

    init() {
        loadWatches()
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

    /// Per-element lenient decode: a stored watch whose pool no longer exists
    /// (e.g. the removed TW-Pool) becomes nil instead of failing — and wiping —
    /// the entire watches array.
    private struct MaybeWatch: Decodable {
        let watch: PoolWatch?
        init(from decoder: Decoder) { watch = try? PoolWatch(from: decoder) }
    }

    private func loadWatches() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.watchesKey),
           let raw = try? JSONDecoder().decode([MaybeWatch].self, from: data) {
            let ws = raw.compactMap(\.watch)
            // Auto-heal any corrupted (whitespace-containing) addresses on load, per the
            // pool's own rules — an F2Pool watch stores a read-only page URL, not an address.
            let cleaned = ws.compactMap { w -> PoolWatch? in
                var w = w
                guard let a = normalizeWatchAddress(w.pool, w.address) else { return nil }
                w.address = a
                return w
            }
            watches = cleaned
            // Persist when something was healed OR a dead-pool watch was dropped.
            if cleaned != ws || ws.count != raw.count { saveWatches() }
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
        if let data = try? JSONEncoder().encode(watches) {
            UserDefaults.standard.set(data, forKey: Self.watchesKey)
        }
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
        Task { if let d = await fetchWatchData(w) { watchData[w.id] = d } }
    }

    func removeWatch(_ id: UUID) {
        watches.removeAll { $0.id == id }
        watchData[id] = nil
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
                if let d = await fetchWatchData(w) { watchData[w.id] = d }
                await fetchOnchainIncome([w])
                pushWidgetSnapshot()
            }
        } else {
            watchData[id] = nil
            onchain24h[id] = nil; onchain7d[id] = nil; onchainTotal[id] = nil
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
    /// stale cached stats/on-chain figures are cleared and a fresh fetch kicks off.
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
        onchain24h[id] = nil; onchain7d[id] = nil; onchainTotal[id] = nil
        let w = watches[i]
        Task {
            if let d = await fetchWatchData(w) { watchData[w.id] = d }
            await fetchOnchainIncome([w])
        }
    }

    // MARK: refresh

    func refresh() async {
        loading = true
        async let pu = Self.fetchPrlUsd()
        async let uc = Self.fetchUsdCny()

        let current = watches.filter(\.isEnabled)   // a paused watch costs no network
        await withTaskGroup(of: (UUID, WatchData?).self) { group in
            for w in current { group.addTask { (w.id, await fetchWatchData(w)) } }
            // Skip a watch the user removed mid-refresh (dead UUID → orphan entry), and
            // skip nil (a cancelled fetch) so navigating away mid-refresh can't overwrite
            // a card with 失败 — the card keeps its current state until the next refresh.
            for await (id, d) in group {
                guard let d, watches.contains(where: { $0.id == id }) else { continue }
                watchData[id] = d
            }
        }
        await fetchOnchainIncome(current)

        if let u = await pu { prlUsd = u }
        if let c = await uc { usdCny = c }
        loading = false

        pushWidgetSnapshot()
    }

    /// Mirror ALL pool watches + fiat rates into the shared App Group so the
    /// home-screen Mining widget can show every miner (2+) and refresh itself.
    private func pushWidgetSnapshot() {
        WidgetBridge.updatePrice(prlUsd: prlUsd, usdCny: usdCny)
        let pools = watches.filter(\.isEnabled).map { w -> WidgetPool in
            let d = watchData[w.id]
            // REAL-TIME (瞬时) hashrate = Σ per-worker live rate; fall back to the 24h
            // estimate only for pools whose workers don't report a live value.
            let liveRaw = d?.workers.reduce(0) { $0 + $1.instant } ?? 0
            let raw = liveRaw > 0 ? liveRaw : (d?.hr24hRaw ?? 0)
            return WidgetPool(label: w.displayName,
                              kind: w.pool.rawValue,
                              address: w.address,
                              hashrate: raw > 0 ? formatHashrate(raw) : "—",
                              hashrateRaw: raw,
                              online: d?.workers.filter { $0.online }.count ?? 0,
                              total: d?.workers.count ?? 0)
        }
        WidgetBridge.updatePools(pools)
    }

    // MARK: fiat prices

    private static func fetchPrlUsd() async -> Double? {
        var req = URLRequest(url: URL(string: "https://safetrade.com/api/v2/peatio/public/markets/prlusdt/tickers")!)
        req.timeoutInterval = 15; req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let t = (obj["ticker"] as? [String: Any]) ?? obj
        if let s = t["last"] as? String, let v = Double(s) { return v }
        if let n = t["last"] as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func fetchUsdCny() async -> Double? {
        var req = URLRequest(url: URL(string: "https://open.er-api.com/v6/latest/USD")!)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = obj["rates"] as? [String: Any] else { return nil }
        return (rates["CNY"] as? NSNumber)?.doubleValue
    }

    // MARK: per-watch on-chain income (Blockbook balancehistory)

    /// Net PRL received by `addr` over `hours` (received − sent-to-self), i.e. the
    /// actual money that landed on this pool's收款地址.
    nonisolated private static func bbReceived(_ addr: String, hours: Double) async -> Double? {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - Int(hours * 3600)
        guard var comps = URLComponents(string: "https://blockbook.pearlresearch.ai/api/v2/balancehistory/\(addr)") else { return nil }
        comps.queryItems = [
            .init(name: "from", value: String(from)),
            .init(name: "to", value: String(now + 60)),
            .init(name: "groupBy", value: "86400"),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20; req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData   // refresh = re-query on-chain, not a cached body
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return nil }
        var sat = 0.0
        for b in arr {
            let rec = Double((b["received"] as? String) ?? "0") ?? 0
            let ss  = Double((b["sentToSelf"] as? String) ?? "0") ?? 0
            if rec - ss > 0 { sat += (rec - ss) }
        }
        return sat / 1e8
    }

    private func fetchOnchainIncome(_ ws: [PoolWatch]) async {
        await withTaskGroup(of: (UUID, Double?, Double?, Double?).self) { group in
            for w in ws {
                let a = Self.cleanAddr(w.address).lowercased()
                guard PRLAddress.isValid(a, network: .mainnet) else { continue }
                group.addTask {
                    async let h24  = Self.bbReceived(a, hours: 24)
                    async let d7   = Self.bbReceived(a, hours: 24 * 7)
                    async let life = Self.bbReceived(a, hours: 24 * 365 * 5)   // ≈ lifetime
                    return (w.id, await h24, await d7, await life)
                }
            }
            for await (id, r24, r7, rlife) in group {
                guard watches.contains(where: { $0.id == id }) else { continue }   // watch removed mid-refresh
                if let r24  { onchain24h[id] = r24 }
                if let r7   { onchain7d[id] = r7 }
                if let rlife { onchainTotal[id] = rlife }
            }
        }
    }
}
