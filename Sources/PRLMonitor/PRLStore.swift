import Foundation
import Combine
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// ============================================================
// 联网（async/await，跨平台；替换原版阻塞式 URLSession+DispatchSemaphore）
// ============================================================

func httpGET(_ s: String, timeout: TimeInterval = 8) async -> Data? {
    guard let url = URL(string: s) else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    req.setValue("prl-monitor/1.0", forHTTPHeaderField: "User-Agent")
    do {
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode == 200 { return data }
        return nil
    } catch {
        return nil
    }
}

func num(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s.replacingOccurrences(of: ",", with: "")) }
    return nil
}

func fetchBTC() async -> Double? {
    guard let d = await httpGET("https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd"),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let b = o["bitcoin"] as? [String: Any] else { return nil }
    return num(b["usd"])
}

/// Live PRL price (USD) straight from SafeTrade's PRL/USDT ticker — the real
/// market price, preferred over the WhatToMine exchange_rate×BTC derivation.
func fetchPRLUsdSafeTrade() async -> Double? {
    guard let url = URL(string: "https://safetrade.com/api/v2/peatio/public/markets/prlusdt/tickers") else { return nil }
    var req = URLRequest(url: url); req.timeoutInterval = 10
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    guard let (data, resp) = try? await URLSession.shared.data(for: req),
          (resp as? HTTPURLResponse)?.statusCode == 200,
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let t = (obj["ticker"] as? [String: Any]) ?? obj
    if let s = t["last"] as? String, let v = Double(s), v > 0 { return v }
    if let n = t["last"] as? NSNumber, n.doubleValue > 0 { return n.doubleValue }
    return nil
}

/// WhatToMine 的 PRL 页。链上数据与币价的回落路径各自取用（两条路都失败才会取两次）。
private func fetchWhatToMineCoin() async -> [String: Any]? {
    guard let d = await httpGET("https://whattomine.com/coins/469.json"),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return o
}

private func ehOf(_ hs: Double) -> Double { hs / 1e18 }
private func saneEH(_ eh: Double) -> Bool { eh > 1e-6 && eh < 1e6 }

/// 链上数字（难度快照 / 全网算力 / 单位日产）——首选 lordofpearls.xyz 的自建 Pearl 全节点。
///
/// 关键是**不要直接用它的 `networkhashps` 字段**：那个数按最近 60 块算，而出块时间字段是另一个
/// 窗口，两者相乘/相除就会凭空多出 18%（2026-07-24 实测 29.5 vs 24.7 EH/s）。这里一律走链上
/// 恒等式，且出块时间统一取 24h 实测窗口：
///     全网算力 = 难度 × 2^48 ÷ 24h 出块时间
///     单位日产 = 单块奖励 × 86400 ÷ (难度 × 2^48)      —— 出块时间在此自动抵消，与窗口无关
/// 这么推出来的两个数与 WhatToMine 分别差 1% 和 0%（24.68 vs 24.96 EH/s、0.02391 一致），
/// 但难度与奖励取自链上原值、快一倍，也不依赖第三方站点继续维护这个币种。
/// difficulty24/3/7 由整链难度序列按时间加权算出（见 averageDifficulty），与 WhatToMine 的
/// 三个窗口实测相差均 <0.2%。返回已更新的字段名；空数组 = 这个源没用上，调用方回落。
private func applyLordOfPearls(_ c: inout Config) async -> [String] {
    guard let s = try? await LordOfPearlsClient().publicStats(),
          let diff = s.difficulty, diff > 0 else { return [] }
    // 24h 实测优先；它缺席才退回 60 块窗口（口径略短，但仍是链上实测）。
    guard let bt = s.blockTime24h ?? s.blockTimeSec, bt > 0 else { return [] }
    let nh = diff * prlWorkPerDifficulty / bt
    guard saneEH(ehOf(nh)) else { return [] }

    var got = [Loc("全网算力")]
    c.diffNow = diff
    if let v = s.averageDifficulty(days: 1) { c.diff24 = v }
    if let v = s.averageDifficulty(days: 3) { c.diff3  = v }
    if let v = s.averageDifficulty(days: 7) { c.diff7  = v }
    c.nethashEH = ehOf(nh)
    c.diffConst = nh / diff        // = 2^48 ÷ 出块时间，供 WhatToMine 回落时做量级校验
    if let reward = s.rewardPerBlock, reward > 0 {
        let pu = reward * 86400.0 / (diff * prlWorkPerDifficulty) * 1e12   // PRL / (TH/s) / 天
        if pu > 1e-6 && pu < 100 { c.perUnit = pu; got.append(Loc("出币")) }
    }
    return got
}

/// 链上数字的回落源：WhatToMine。字段口径与上面一致，逻辑保持原样。
private func applyWhatToMine(_ c: inout Config, _ o: [String: Any]) -> [String] {
    var got: [String] = []
    let btSec = num(o["block_time"])
    let diff  = num(o["difficulty24"]) ?? num(o["difficulty"])
    let nhRaw = num(o["nethash"])

    if let v = num(o["difficulty"]),   v > 0 { c.diffNow = v }
    if let v = num(o["difficulty24"]), v > 0 { c.diff24  = v }
    if let v = num(o["difficulty3"]),  v > 0 { c.diff3   = v }
    if let v = num(o["difficulty7"]),  v > 0 { c.diff7   = v }

    var nethashHs: Double? = nil
    if let nh = nhRaw, nh > 0, saneEH(ehOf(nh)) {
        if let df = diff, df > 0, c.diffConst > 0 {
            let expected = c.diffConst * df
            let ratio = max(nh, expected) / min(nh, expected)
            if ratio > 3 { nethashHs = expected; got.append(Loc("难度校正算力⚠")) }
            else { nethashHs = nh; c.diffConst = nh / df; got.append(Loc("全网算力")) }
        } else {
            nethashHs = nh
            if let df = diff, df > 0 { c.diffConst = nh / df }
            got.append(Loc("全网算力"))
        }
    } else if let df = diff, df > 0, c.diffConst > 0 {
        nethashHs = c.diffConst * df
        got.append(Loc("难度推导算力"))
    }
    if let hs = nethashHs, saneEH(ehOf(hs)) { c.nethashEH = ehOf(hs) }

    if let br = num(o["block_reward24"]) ?? num(o["block_reward"]), let bt = btSec, bt > 0, c.nethashEH > 0 {
        let pu = (br * 86400.0 / bt) / (c.nethashEH * 1e6)
        if pu > 1e-6 && pu < 100 { c.perUnit = pu; got.append(Loc("出币")) }
    }
    return got
}

/// 联网刷新行情；返回更新后的 Config + 成功标志 + 状态文案。
func fetchLive(_ input: Config) async -> (Config, Bool, String) {
    var c = input
    var got = await applyLordOfPearls(&c)
    // 链上源不可达 → WhatToMine。
    if got.isEmpty, let o = await fetchWhatToMineCoin() { got = applyWhatToMine(&c, o) }
    // 预估「难度月增长 %」：把"近7天难度趋势"(当前 vs 近7天均值，与设置页显示同口径)
    // 线性折算到 30 天。联网时自动锁定填入；手动模式下用户仍可拖动覆盖。0 = 难度恒定。
    if c.diffNow > 0, c.diff7 > 0 {
        let monthly = (c.diffNow / c.diff7 - 1) * (30.0 / 7.0) * 100
        c.diffGrowthMonthly = min(200, max(-20, monthly))
    }
    // Price: the app-wide PRL price (SafeTrade, WhatToMine×BTC fallback), so the
    // monitor shows the same number as the wallet, Trade tab and widgets.
    // Count it as fetched only if it is actually fresh — offline, the manager still
    // holds its disk-cached price, which must not read as a successful refresh.
    await PRLPriceManager.shared.refreshIfStale()
    if let p = await PRLPriceManager.shared.usd, let at = await PRLPriceManager.shared.lastUpdated,
       Date().timeIntervalSince(at) < 180 {
        c.price = p; got.append(Loc("币价"))
    }
    // 成功时不再回传啰嗦的「已更新 全网算力/出币/币价」——头部只用绿点表示联网即可。
    return got.isEmpty ? (c, false, Loc("行情数据源无响应")) : (c, true, "")
}

// MARK: - Store

@MainActor
final class PRLStore: ObservableObject {
    @Published var cfg = Config() { didSet { savePrefs() } }
    @Published var devices: [Device] = [] { didSet { saveDevices() } }
    @Published var rentByGPU: [String: Double] = [:] { didSet { saveRents() } }
    @Published var powerBudgetW: Double = 3000 { didSet { savePrefs() } }
    @Published var live = true { didSet { savePrefs() } }
    @Published var status = Loc("未刷新")
    @Published var lastUpdate = "—"
    @Published var loading = false
    /// True only after a successful live fetch THIS session. Until then the
    /// online-sourced numbers (币价/全网算力/单位日产 + everything derived) are shown
    /// blank rather than as stale defaults. (Manual mode counts as ready.)
    @Published var liveReady = false
    @Published var autoRefresh = false
    @Published var sortKey: SortKey = .ownNet { didSet { savePrefs() } }
    @Published var selected: String? = "RTX 5070" { didSet { savePrefs() } }
    @Published var rentEnabled = true { didSet { savePrefs() } }
    @Published var rentCoversPower = true { didSet { savePrefs() } }
    @Published var selfDilution = false { didSet { savePrefs() } }
    /// false = the local-currency rate (cfg.fx) auto-follows the live secondary
    /// currency rate (daily-updated); true = user pinned a custom rate via slider.
    @Published var fxManual = false { didSet { savePrefs() } }
    private var timer: Timer?
    /// Suppresses savePrefs() during init() — otherwise the first loaded field
    /// triggers a save that overwrites the not-yet-loaded fields with defaults.
    private var initializing = true
    /// True only while adopting an incoming iCloud change, so reloadDevices()'s
    /// assignment doesn't bounce the same data straight back up to the cloud.
    private var applyingRemote = false
    /// ISO code the stored rents are denominated in (the user's secondary currency
    /// at entry time). Synced alongside the rents so another device converts them
    /// correctly even when ITS own resolved secondary currency differs.
    private var rentCurrency = ""

    // MARK: 币价历史（行情趋势图）
    /// Daily PRL/USDT candles for the 行情 price-trend chart. Reuses SafeTrade's
    /// PUBLIC k-line endpoint, so no API keys are required.
    @Published var priceHistory: [STCandle] = []
    private let stClient = SafeTradeClient()
    private var lastPriceFetch: Date?
    private var priceSub: AnyCancellable?

    init() {
        devices = PRLStore.loadDevices()
        rentByGPU = PRLStore.loadRents()
        loadPrefsFromDefaults()
        initializing = false
        // Don't lose a still-pending coalesced save if the app is backgrounded right
        // after a slider drag.
        #if os(iOS)
        let resign = UIApplication.willResignActiveNotification
        #else
        let resign = NSApplication.willResignActiveNotification
        #endif
        resignSub = NotificationCenter.default.publisher(for: resign).sink { [weak self] _ in
            guard let self, let work = self.prefsSave else { return }
            work.cancel(); self.writePrefs()
        }
        syncFx()   // align cfg.fx with the live secondary rate when in auto mode
        // Live mode shows the app-wide price the moment anything refreshes it (the
        // Trade tab every 5 s), not just on this screen's own 60 s fetch. Manual
        // mode keeps the user's slider value.
        priceSub = PRLPriceManager.shared.$usd.dropFirst().sink { [weak self] v in
            guard let self, self.live, let v, v != self.cfg.price else { return }
            self.cfg.price = v
        }
    }

    /// Read all persisted prefs (cfg fields + toggles) from UserDefaults into the
    /// published state. Used at launch and when adopting an incoming iCloud change.
    private func loadPrefsFromDefaults() {
        let d = UserDefaults.standard
        if d.object(forKey: "prl.price") != nil { cfg.price = d.double(forKey: "prl.price") }
        if d.object(forKey: "prl.neth") != nil { cfg.nethashEH = d.double(forKey: "prl.neth") }
        if d.object(forKey: "prl.pu") != nil { cfg.perUnit = d.double(forKey: "prl.pu") }
        if d.object(forKey: "prl.elec") != nil { cfg.elec = d.double(forKey: "prl.elec") }
        if d.object(forKey: "prl.fee") != nil { cfg.poolFee = d.double(forKey: "prl.fee") }
        if d.object(forKey: "prl.fx") != nil { cfg.fx = d.double(forKey: "prl.fx") }
        if d.object(forKey: "prl.diffGrowth") != nil { cfg.diffGrowthMonthly = d.double(forKey: "prl.diffGrowth") }
        if d.object(forKey: "prl.diffConst") != nil { cfg.diffConst = d.double(forKey: "prl.diffConst") }
        if d.object(forKey: "prl.syncW") != nil { cfg.syncWPerTH = d.double(forKey: "prl.syncW") }
        if d.object(forKey: "prl.selfDilution") != nil { selfDilution = d.bool(forKey: "prl.selfDilution") }
        if d.object(forKey: "prl.budget") != nil { powerBudgetW = d.double(forKey: "prl.budget") }
        if d.object(forKey: "prl.live") != nil { live = d.bool(forKey: "prl.live") }
        if d.object(forKey: "prl.rentEnabled") != nil { rentEnabled = d.bool(forKey: "prl.rentEnabled") }
        if d.object(forKey: "prl.rentCovers") != nil { rentCoversPower = d.bool(forKey: "prl.rentCovers") }
        if d.object(forKey: "prl.fxManual") != nil { fxManual = d.bool(forKey: "prl.fxManual") }
        if let rc = d.string(forKey: "prl.rentCcy"), !rc.isEmpty { rentCurrency = rc }
        if let sv = d.string(forKey: "prl.sort"), let sk = SortKey(rawValue: sv) { sortKey = sk }
        if let s = d.string(forKey: "prl.selected"), !s.isEmpty { selected = s }
        if d.object(forKey: "prl.auto") != nil { setAuto(d.bool(forKey: "prl.auto")) }
    }

    /// Adopt PRL config (cfg fields + rents + toggles) pushed in from another
    /// device. CloudSync has already written the fresh values into UserDefaults;
    /// we read them into the published state without bouncing them back up.
    func reloadPrefs() {
        applyingRemote = true
        rentByGPU = PRLStore.loadRents()
        loadPrefsFromDefaults()
        applyingRemote = false
    }

    static func loadDevices() -> [Device] {
        if let data = UserDefaults.standard.data(forKey: "prl.devices"),
           let ds = try? JSONDecoder().decode([Device].self, from: data) { return ds }
        return []   // 新用户从空设备清单开始（不预置任何示例设备）
    }
    static func loadRents() -> [String: Double] {
        if let data = UserDefaults.standard.data(forKey: "prl.rents"),
           let m = try? JSONDecoder().decode([String: Double].self, from: data), !m.isEmpty { return m }
        var def: [String: Double] = [:]
        for g in GPUS { def[g.name] = g.rentDefault }
        return def
    }
    func saveDevices() {
        guard !initializing && !applyingRemote else { return }   // skip during load / remote-adopt
        if let d = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(d, forKey: "prl.devices") }
        CloudSync.push("prl.devices")   // mirror 设备资料 to iCloud (no-op if not provisioned)
    }

    /// Re-read 设备资料 after an incoming iCloud change from another device.
    /// CloudSync has already written the fresh value into UserDefaults; we only
    /// adopt it into the published `devices` (without pushing it back up).
    func reloadDevices() {
        applyingRemote = true
        devices = PRLStore.loadDevices()
        applyingRemote = false
    }
    func saveRents() {
        guard !initializing && !applyingRemote else { return }
        if let d = try? JSONEncoder().encode(rentByGPU) { UserDefaults.standard.set(d, forKey: "prl.rents") }
        // Stamp the currency the rents are entered in so a device whose own secondary
        // currency differs still converts these numbers correctly.
        rentCurrency = localCode
        UserDefaults.standard.set(rentCurrency, forKey: "prl.rentCcy")
        CloudSync.push("prl.rents")
        CloudSync.push("prl.rentCcy")
    }
    func savePrefs() {
        // Skip during init AND while adopting an incoming iCloud change: every
        // assignment in loadPrefsFromDefaults() fires a didSet → savePrefs(),
        // which would write the still-stale in-memory values back over the
        // freshly-pulled defaults before they're read — silently discarding the
        // synced config (and later pushing the stale values back to iCloud,
        // reverting the other device too).
        guard !initializing && !applyingRemote else { return }
        // Coalesced: a slider drag changes cfg on every tick, and writing ~18 defaults
        // plus an iCloud synchronize() per tick made the sliders lag. The write runs
        // once the values stop moving and always stores the CURRENT state.
        prefsSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writePrefs() }
        prefsSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    private var prefsSave: DispatchWorkItem?
    private var resignSub: AnyCancellable?

    private func writePrefs() {
        prefsSave = nil
        let d = UserDefaults.standard
        d.set(cfg.price, forKey: "prl.price"); d.set(cfg.nethashEH, forKey: "prl.neth"); d.set(cfg.perUnit, forKey: "prl.pu")
        d.set(cfg.elec, forKey: "prl.elec"); d.set(cfg.poolFee, forKey: "prl.fee"); d.set(cfg.fx, forKey: "prl.fx")
        d.set(cfg.diffGrowthMonthly, forKey: "prl.diffGrowth"); d.set(cfg.diffConst, forKey: "prl.diffConst")
        d.set(cfg.syncWPerTH, forKey: "prl.syncW")
        d.set(selfDilution, forKey: "prl.selfDilution")
        d.set(powerBudgetW, forKey: "prl.budget")
        d.set(live, forKey: "prl.live"); d.set(rentEnabled, forKey: "prl.rentEnabled")
        d.set(rentCoversPower, forKey: "prl.rentCovers"); d.set(autoRefresh, forKey: "prl.auto")
        d.set(fxManual, forKey: "prl.fxManual")
        d.set(sortKey.rawValue, forKey: "prl.sort"); d.set(selected ?? "", forKey: "prl.selected")
        // Mirror user config to iCloud — but NOT the live market numbers
        // (price/neth/pu/diffConst), which each device refetches. push() no-ops
        // when a value is unchanged, so this is cheap even on every refresh.
        for key in ["prl.elec", "prl.fee", "prl.fx", "prl.diffGrowth", "prl.syncW",
                    "prl.selfDilution", "prl.budget", "prl.live", "prl.rentEnabled",
                    "prl.rentCovers", "prl.fxManual", "prl.auto", "prl.sort", "prl.selected"] {
            CloudSync.push(key)
        }
    }

    // MARK: - 本地货币（= 全局副货币；无副货币时回退 USD）
    // cfg.fx 的语义 = 1 USD → 本地货币。挖矿盈亏里的「本地货币」金额、租金录入都以此为基准。

    /// The display currency for the mining monitor — the user's global secondary
    /// currency, or nil (→ USD) when they chose "none".
    var localCurrency: FiatCurrency? { CurrencyManager.shared.secondary }
    var localSymbol: String { localCurrency?.symbol ?? "$" }
    var localCode: String { localCurrency?.code ?? "USD" }
    var localName: String { localCurrency?.localizedName ?? Loc("美元") }
    /// Live 1 USD → local rate (falls back to the stored fx, or 1 when no secondary).
    var liveFx: Double {
        guard let c = localCurrency else { return 1 }
        return CurrencyManager.shared.rate(c.code) ?? cfg.fx
    }
    /// In auto mode, pull cfg.fx to the live secondary rate (or 1 when no secondary).
    /// No-op while the user has pinned a manual rate. Call on appear / after a rate
    /// refresh / when the secondary currency changes.
    func syncFx() {
        guard !fxManual else { return }
        let target = (localCurrency == nil) ? 1 : liveFx
        if abs(cfg.fx - target) > 1e-9 { cfg.fx = target }
    }
    /// Replace the ¥ placeholder symbol in a localized string with the active
    /// local-currency symbol (used for copy that bakes in a currency symbol).
    func sym(_ s: String) -> String {
        localSymbol == "¥" ? s : s.replacingOccurrences(of: "¥", with: localSymbol)
    }

    /// 1 USD → the currency the rents are stored in. Falls back to the device's own
    /// fx when untagged (legacy / never-edited), so behavior is unchanged for the
    /// single-device case but a cross-region second device converts via the rent's
    /// OWN currency rather than its own (possibly different) secondary rate.
    private var rentFxRate: Double {
        let ccy = rentCurrency.isEmpty ? localCode : rentCurrency
        if ccy == "USD" { return 1 }
        return CurrencyManager.shared.rate(ccy) ?? cfg.fx
    }

    func rent(for name: String) -> Double { rentByGPU[name] ?? gpu(name)?.rentDefault ?? 0 }
    func setRent(_ name: String, _ v: Double) { rentByGPU[name] = max(0, v) }
    // 云设备租金按「每小时」录入/展示（云算力通常按时计费）；内部仍以「日」为单位
    // 参与收益计算（日 = 时×24，可用h 会再按比例缩放），故无需迁移已存数据。
    func rentHour(for name: String) -> Double { rent(for: name) / 24 }
    func setRentHour(_ name: String, _ hourly: Double) { setRent(name, max(0, hourly) * 24) }
    func rentNetUSD(_ k: Calc) -> Double {
        let r = rent(for: k.g.name) / rentFxRate
        return k.netRev - r - (rentCoversPower ? 0 : k.power)
    }
    func beRentDayUSD(_ k: Calc) -> Double { k.netRev - (rentCoversPower ? 0 : k.power) }
    func ownNetUSD(_ g: GPU, perUnit pu: Double) -> Double {
        g.pearl * pu * cfg.price * (1 - cfg.poolFee) - g.watts / 1000.0 * 24.0 * cfg.elec
    }

    func calcs() -> [Calc] {
        var cs = GPUS.map { compute($0, cfg) }
        switch sortKey {
        case .ownNet:  cs.sort { $0.ownNet > $1.ownNet }
        case .rentNet: cs.sort { rentNetUSD($0) > rentNetUSD($1) }
        case .beRent:  cs.sort { beRentDayUSD($0) > beRentDayUSD($1) }
        case .pearl:   cs.sort { $0.g.pearl > $1.g.pearl }
        case .effic:   cs.sort { ($0.g.pearl / $0.g.watts) > ($1.g.pearl / $1.g.watts) }
        }
        return cs
    }

    // Economics inputs. A synced (pool) device keeps its real 24h hashrate for
    // revenue, but its watts/rent/hardware-cost come from the assigned chip,
    // scaled by a card-equivalent count = real hashrate ÷ that chip's hashrate.
    func devPearl(_ dv: Device) -> Double { dv.customPearl ?? (gpu(dv.gpu)?.pearl ?? 0) }
    /// Card-equivalent count for cost scaling (synced rig ÷ chosen chip).
    func devCards(_ dv: Device) -> Double {
        if dv.synced, let g = gpu(dv.gpu), g.pearl > 0 { return (dv.customPearl ?? 0) / g.pearl }
        return Double(dv.count)
    }
    func devWatts(_ dv: Device) -> Double {
        if dv.synced {
            // Power = the chip's rated draw × card-equivalent count, floored at one card.
            // A single mining GPU pulls ~its full TDP regardless of how little hashrate
            // the pool credits it (a 0.32× 4090 still draws ~450W, not 142W) — hence the
            // max(1.0, …) floor. But a multi-card rig / whole-address aggregate
            // (devCards ≫ 1, e.g. 2000 TH/s ≈ 8× a 4090) draws ALL its cards' power, so
            // we must still scale up: dropping devCards entirely under-counts power ~Nx,
            // inflating net profit and letting the cabinet power-budget bar read "safe"
            // while the real rig is far over. Rent / hardware-cost also scale by devCards.
            if let g = gpu(dv.gpu) { return max(1.0, devCards(dv)) * g.watts }
            return (dv.customPearl ?? 0) * cfg.syncWPerTH              // no chip → efficiency estimate
        }
        return gpu(dv.gpu)?.watts ?? 0
    }
    func devPrice(_ dv: Device) -> Double {
        if dv.synced { return gpu(dv.gpu).map { devCards(dv) * $0.price } ?? 0 }
        return gpu(dv.gpu)?.price ?? 0
    }
    /// Daily rent (¥) for the whole device-unit. A per-device override wins;
    /// otherwise fall back to the chip's rent (× card-equivalent for synced rigs).
    func devRent(_ dv: Device) -> Double {
        if let r = dv.rentDaily { return r }
        return dv.synced ? devCards(dv) * rent(for: dv.gpu) : rent(for: dv.gpu)
    }

    struct DevEcon { var prl = 0.0, rev = 0.0, power = 0.0, rent = 0.0, net = 0.0 }
    func deviceEcon(_ dv: Device, perUnit pu: Double) -> DevEcon {
        let duty = max(0, min(24, dv.hoursPerDay)) / 24.0
        let prl   = devPearl(dv) * pu * duty
        let rev   = prl * cfg.price * (1 - cfg.poolFee)
        let power = devWatts(dv) / 1000.0 * 24.0 * cfg.elec * duty
        if dv.rented {
            // 租用云设备：日租为全包价，不另计电费/功率。
            let r = devRent(dv) / rentFxRate * duty
            return DevEcon(prl: prl, rev: rev, power: 0, rent: r, net: rev - r)
        }
        return DevEcon(prl: prl, rev: rev, power: power, rent: 0, net: rev - power)
    }
    func fleet() -> Fleet {
        var fl = Fleet()
        for dv in devices { fl.pearl += devPearl(dv) * Double(dv.count) }
        let pu = effPerUnit(myHashPearl: fl.pearl)
        for dv in devices {
            let n = Double(dv.count); let e = deviceEcon(dv, perUnit: pu)
            fl.cards += dv.count
            fl.prlDay += e.prl * n; fl.revDay += e.rev * n
            fl.powerDay += e.power * n; fl.rentDay += e.rent * n; fl.netDay += e.net * n
            if dv.rented { fl.rentedCards += dv.count }
            else { fl.ownCards += dv.count; fl.cost += devPrice(dv) * n; fl.watts += devWatts(dv) * n }
        }
        return fl
    }

    // MARK: sync devices from the pool watch cards

    @Published var syncing = false
    /// One-shot guard so the “要不要同步” prompt is offered at most once per launch.
    var didOfferSync = false
    /// How many pool watches the user set up in 我的监控 — the source for syncing.
    var poolWatchCount: Int {
        (UserDefaults.standard.data(forKey: "pool.watches")
            .flatMap { try? JSONDecoder().decode([PoolWatch].self, from: $0) } ?? []).count
    }
    /// True once at least one device came from a pool sync (so we don't re-ask).
    var hasSyncedDevices: Bool { devices.contains { $0.synced } }
    /// Pull every pool watch's miners (workers) and turn them into synced devices,
    /// keyed by their 24h hashrate (1 Pearl = 1 TH/s). Replaces previously-synced
    /// devices; manual GPU devices are kept.
    func syncFromPools() {
        guard !syncing else { return }
        syncing = true
        Task { [weak self] in
            guard let self else { return }
            let watches = UserDefaults.standard.data(forKey: "pool.watches")
                .flatMap { try? JSONDecoder().decode([PoolWatch].self, from: $0) } ?? []
            let previousSynced = self.devices.filter(\.synced)
            var previousByKey: [String: Device] = [:]
            for dev in previousSynced {
                if let key = dev.sourceKey, previousByKey[key] == nil {
                    previousByKey[key] = dev
                }
            }
            var previousByName: [String: Device] = [:]
            for dev in previousSynced where previousByName[dev.name] == nil {
                previousByName[dev.name] = dev
            }
            var synced: [Device] = []
            var syncedKeys = Set<String>()
            for w in watches where w.isEnabled {   // paused watch → no devices, no fetch
                // The watch's normalized identifier — a PRL address for the address pools,
                // the read-only page URL for F2Pool. Only used to KEY the synced devices, so
                // an F2Pool watch syncs its rigs like any other (gating on PRLAddress.isValid
                // here silently dropped every F2Pool rig from the device list).
                guard let address = normalizeWatchAddress(w.pool, w.address)?.lowercased() else { continue }
                guard let d = await fetchWatchData(w), d.error == nil else {
                    // nil = cancelled, or a real error → keep the previously-synced devices
                    // for this watch rather than dropping them.
                    Self.preservePreviousSyncedDevices(pool: w.pool, address: address,
                                                       previousByKey: previousByKey,
                                                       previousByName: previousByName,
                                                       syncedKeys: &syncedKeys,
                                                       synced: &synced)
                    continue
                }
                let workers = d.workers.filter { $0.hashrate > 0 }
                if !workers.isEmpty {
                    for wk in workers {
                        let name = "\(w.pool.label)·\(wk.name)"
                        let key = Self.syncedDeviceKey(pool: w.pool, address: address, worker: wk.name)
                        // Same (pool, address, worker name) = one device. Skip a repeat so
                        // two identically-named workers can't both reuse the SAME previous
                        // device (→ duplicate Device.id → ForEach crash on the next refresh).
                        guard syncedKeys.insert(key).inserted else { continue }
                        synced.append(Self.mergedSyncedDevice(name: name, key: key, pearl: wk.hashrate / 1e12,
                                                              previousByKey: previousByKey,
                                                              previousByName: previousByName))
                    }
                } else if d.hr24hRaw > 0 {   // pool without per-worker hashrate → one device for the address
                    let name = "\(w.pool.label)·\(address.suffix(6))"
                    let key = Self.syncedDeviceKey(pool: w.pool, address: address, worker: nil)
                    guard syncedKeys.insert(key).inserted else { continue }
                    synced.append(Self.mergedSyncedDevice(name: name, key: key, pearl: d.hr24hRaw / 1e12,
                                                          previousByKey: previousByKey,
                                                          previousByName: previousByName))
                }
            }
            let manual = self.devices.filter { !$0.synced }
            // Safety net: guarantee no two devices share an id before publishing — a
            // name collision across different addresses can still make mergedSyncedDevice
            // reuse one previous device twice, and a duplicate id crashes ForEach($devices).
            self.devices = Self.withUniqueIDs(manual + synced)
            self.syncing = false
            self.refreshActualIncome()
        }
    }

    private static func syncedDeviceKey(pool: PoolKind, address: String, worker: String?) -> String {
        [pool.rawValue, address.lowercased(), worker ?? "_address"].joined(separator: "|")
    }

    private static func preservePreviousSyncedDevices(pool: PoolKind, address: String,
                                                      previousByKey: [String: Device],
                                                      previousByName: [String: Device],
                                                      syncedKeys: inout Set<String>,
                                                      synced: inout [Device]) {
        let prefix = [pool.rawValue, address.lowercased()].joined(separator: "|") + "|"
        for (key, device) in previousByKey where key.hasPrefix(prefix) && !syncedKeys.contains(key) {
            syncedKeys.insert(key)
            synced.append(device)
        }
        let legacyPrefix = pool.label + "·"
        for device in previousByName.values where device.sourceKey == nil && device.name.hasPrefix(legacyPrefix) {
            if !synced.contains(where: { $0.id == device.id || $0.name == device.name }) {
                synced.append(device)
            }
        }
    }

    private static func mergedSyncedDevice(name: String, key: String, pearl: Double,
                                           previousByKey: [String: Device],
                                           previousByName: [String: Device]) -> Device {
        if var existing = previousByKey[key] ?? previousByName[name] {
            existing.customPearl = pearl
            existing.sourceKey = key
            if existing.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.name = name
            }
            return existing
        }
        return Device(name: name, gpu: "RTX 4090", count: 1, customPearl: pearl, sourceKey: key)
    }

    /// Return `devs` with every id guaranteed unique — reassigns a fresh UUID to any
    /// device whose id already appeared. The device-list `ForEach($devices)` is keyed
    /// by Device.id, and a duplicate id is a hard SwiftUI crash; this is the last line
    /// of defense so a pool that reports colliding worker names can never take the app down.
    private static func withUniqueIDs(_ devs: [Device]) -> [Device] {
        var seen = Set<UUID>()
        return devs.map { d in
            var d = d
            while !seen.insert(d.id).inserted { d.id = UUID() }
            return d
        }
    }

    // MARK: actual pool income (on-chain "以矿池为准") for 24h / 7d

    struct ActualIncome: Identifiable { let pool: String; let addr: String; let prl24h: Double; let prl7d: Double; var id: String { pool + addr } }
    @Published var actualIncome: [ActualIncome] = []

    typealias BBBucket = (t: Int, recv: Double, sent: Double)   // sat; recv & sent are net of self-change

    /// balancehistory at 1s granularity (≈ per-tx) — gives received + sent per timestamp,
    /// which lets us match (and exclude) transfers between the user's own addresses.
    nonisolated static func bbBuckets(_ addr: String, hours: Double) async -> [BBBucket] {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - Int(hours * 3600)
        guard let d = await httpGET("https://blockbook.pearlresearch.ai/api/v2/balancehistory/\(addr)?from=\(from)&to=\(now + 60)&groupBy=1", timeout: 25),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return [] }
        return arr.map {
            // Blockbook reports GROSS legs: a send-with-change tx has sent = all inputs and
            // received = the change paid back to self (received == sentToSelf for a pure send).
            // Net BOTH legs by sentToSelf so a sibling's net send (= what actually left the
            // address, ± fee) cancels this address's net receive — otherwise inter-address
            // transfers leak through the matcher and inflate the "actual income" totals.
            let recv   = Double(($0["received"]   as? String) ?? "0") ?? 0
            let sent   = Double(($0["sent"]       as? String) ?? "0") ?? 0
            let toSelf = Double(($0["sentToSelf"] as? String) ?? "0") ?? 0
            return (t: ($0["time"] as? Int) ?? 0,
                    recv: max(0, recv - toSelf),
                    sent: max(0, sent - toSelf))
        }
    }

    /// External income (PRL): received minus any chunk that matches another own-address's
    /// send at the same timestamp (i.e. an inter-address transfer — not real income).
    nonisolated private static func externalReceived(_ buckets: [BBBucket], others: [[BBBucket]]) -> Double {
        var ext = 0.0
        for bk in buckets where bk.recv > 0 {
            let isTransfer = others.contains { ob in
                ob.contains { $0.t == bk.t && $0.sent > 0 && abs($0.sent - bk.recv) <= max(2_000_000, bk.recv * 0.02) }
            }
            if !isTransfer { ext += bk.recv }
        }
        return ext / 1e8
    }

    func refreshActualIncome() {
        Task { [weak self] in
            guard let self else { return }
            let watches = UserDefaults.standard.data(forKey: "pool.watches")
                .flatMap { try? JSONDecoder().decode([PoolWatch].self, from: $0) } ?? []
            var seen = Set<String>(); var items: [(pool: String, addr: String)] = []
            for w in watches where w.isEnabled {
                let a = PoolStore.cleanAddr(w.address).lowercased()
                guard PRLAddress.isValid(a, network: .mainnet), !seen.contains(a) else { continue }
                seen.insert(a); items.append((w.pool.label, a))
            }
            func external(_ hours: Double) async -> [String: Double] {
                var b: [String: [BBBucket]] = [:]
                for it in items { b[it.addr] = await Self.bbBuckets(it.addr, hours: hours) }
                var out: [String: Double] = [:]
                for it in items {
                    let others = items.filter { $0.addr != it.addr }.map { b[$0.addr] ?? [] }
                    out[it.addr] = Self.externalReceived(b[it.addr] ?? [], others: others)
                }
                return out
            }
            let d24 = await external(24), d7 = await external(24 * 7)
            self.actualIncome = items.map {
                ActualIncome(pool: $0.pool, addr: $0.addr, prl24h: d24[$0.addr] ?? 0, prl7d: d7[$0.addr] ?? 0)
            }
        }
    }
    func effPerUnit(myHashPearl: Double) -> Double {
        guard selfDilution, myHashPearl > 0, cfg.nethashEH > 0 else { return cfg.perUnit }
        let netPearl = cfg.nethashEH * 1e6
        return cfg.perUnit * netPearl / (netPearl + myHashPearl)
    }

    /// Pull daily PRL/USDT candles for the price-trend chart. Public k-line, no
    /// keys needed. Daily candles barely move intraday, so skip refetching within
    /// 5 min unless forced (the 60s auto-timer would otherwise hammer it).
    func loadPriceHistory(force: Bool = false) {
        if !force, !priceHistory.isEmpty, let t = lastPriceFetch, Date().timeIntervalSince(t) < 300 { return }
        let market = SafeTradeMarket.normalized(UserDefaults.standard.string(forKey: "safetrade.market"))
        Task { [weak self] in
            guard let self else { return }
            if let cs = try? await self.stClient.kline(market: market, period: 1440, limit: 90), !cs.isEmpty {
                self.priceHistory = cs
                self.lastPriceFetch = Date()
            }
        }
    }

    func refresh() {
        refreshActualIncome()   // pool actual income is independent of the WhatToMine fetch
        loadPriceHistory()      // price-trend candles (SafeTrade public k-line)
        guard live else { status = Loc("本地参数(手动)"); lastUpdate = nowHMS(); return }
        loading = true; status = Loc("联网中…")
        let snap = cfg
        Task { [weak self] in
            let (c, ok, msg) = await fetchLive(snap)
            guard let self else { return }
            if ok {
                self.cfg.price = c.price; self.cfg.nethashEH = c.nethashEH; self.cfg.perUnit = c.perUnit; self.cfg.diffConst = c.diffConst
                self.cfg.diffNow = c.diffNow; self.cfg.diff24 = c.diff24; self.cfg.diff3 = c.diff3; self.cfg.diff7 = c.diff7
                self.cfg.diffGrowthMonthly = c.diffGrowthMonthly   // 难度月增长：按近7天趋势自动估算
                self.liveReady = true
            }
            self.status = ok ? msg : Loc("失败 · 沿用本地")
            self.lastUpdate = nowHMS(); self.loading = false
        }
    }
    func setAuto(_ on: Bool) {
        // Idempotent: only rebuild the timer / persist when the state actually
        // changes. reloadPrefs() re-applies prefs on EVERY incoming iCloud change
        // (including unrelated keys), and an unconditional rebuild here would
        // perpetually reset the 60s auto-refresh countdown.
        guard on != autoRefresh || (on == (timer == nil)) else { return }
        autoRefresh = on
        timer?.invalidate(); timer = nil
        if on {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
        savePrefs()
    }
}
