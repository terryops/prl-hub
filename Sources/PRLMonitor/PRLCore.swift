import Foundation

// ============================================================
// PRL (Pearl) 挖矿监控 — 核心数据模型与收益模型
// 从 prl-monitor-gui 的单文件 SwiftUI App 移植；业务逻辑跨平台，无需改动。
// ============================================================

// MARK: - 数据模型

struct GPU: Identifiable {
    let id = UUID()
    let name: String
    let pearl: Double
    let watts: Double
    let price: Double
    let rentDefault: Double   // 默认租金，内部按日存储 ¥/天；UI 以 ¥/小时(=÷24) 录入/展示
}

extension GPU: Decodable {
    enum CodingKeys: String, CodingKey { case name, pearl = "th", watts, price, rentDefault }
}

/// 显卡参考表（算力 / 功率 / 价格 / 租金），读打包进 App 的同目录 gpus.json。
/// 后台 /v1/gpus 和网页版用的也是这个文件，改数据只改它，App 随新版本更新。
struct GPUCatalog: Decodable {
    let gpus: [GPU]
    static let bundled: [GPU] = Bundle.main.url(forResource: "gpus", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(GPUCatalog.self, from: $0) }?.gpus ?? []
}

let GPUS: [GPU] = GPUCatalog.bundled
func gpu(_ name: String) -> GPU? { GPUS.first { $0.name == name } }

/// 链上恒等式的常数：算力 = 难度 × 2^48 ÷ 出块时间。
/// 不是标定值 —— Pearl 浏览器就是这么公布算力的，WhatToMine 的 nethash 也能由它复现
/// （2026-07-24 实测两边都落在 24.7~25.0 EH/s）。凡是"由难度得算力"或"由算力得日产"，
/// 都必须和出块时间成对使用同一个窗口，否则就会出现 18% 那种凭空的偏差。
let prlWorkPerDifficulty = 281_474_976_710_656.0   // 2^48

struct Config {
    var price: Double = 0.72            // ≈ BTC$66.7k × 1.078e-5（2026-06 实测，联网会刷新）
    var nethashEH: Double = 27.39       // 全网算力 ≈ nethash 27.39 EH/s（difficulty24=12.58M 推导）
    var perUnit: Double = 0.063         // 单位日产 = block_reward24×86400/block_time ÷ 全网
    var poolFee: Double = 0.03
    var elec: Double = 0.10
    var fx: Double = 7.2
    var diffGrowthMonthly: Double = 0   // 难度(全网算力)月增长 %，0=恒定
    var diffConst: Double = 2.177e12    // 难度→算力 常数 (nethash ÷ difficulty24)
    var syncWPerTH: Double = 1.8        // 矿池同步设备的能效假设：每 TH/s(=1 Pearl) 多少瓦（用于估电费）
    // 难度趋势快照（联网刷新，仅供查看，不参与算力推导；0=未知）
    var diffNow: Double = 0, diff24: Double = 0, diff3: Double = 0, diff7: Double = 0
}
extension Config {
    var hasDiffTrend: Bool { diff7 > 0 && diffNow > 0 }
    func diffChange(vs base: Double) -> Double { base > 0 && diffNow > 0 ? (diffNow / base - 1) * 100 : .nan }
}

struct Calc {
    let g: GPU
    let dailyPRL, grossRev, netRev, power, ownNet: Double
    let net30, net90: Double            // 难度衰减后的累计净利(USD)
}
func compute(_ g: GPU, _ c: Config) -> Calc {
    let prl = g.pearl * c.perUnit
    let gross = prl * c.price
    let net = gross * (1 - c.poolFee)
    let pw = g.watts / 1000.0 * 24.0 * c.elec
    let own = net - pw
    let r = dailyDecay(c.diffGrowthMonthly)
    return Calc(g: g, dailyPRL: prl, grossRev: gross, netRev: net,
                power: pw, ownNet: own,
                net30: cumNet(net, pw, 30, r), net90: cumNet(net, pw, 90, r))
}

// MARK: - 难度感知的出币 / 收益模型

func dailyDecay(_ monthlyPct: Double) -> Double {
    let gm = monthlyPct / 100.0
    if gm <= -0.99 { return 1 }
    return pow(1.0 + gm, -1.0 / 30.0)
}
func cumNet(_ net0: Double, _ power: Double, _ days: Int, _ r: Double) -> Double {
    guard days > 0 else { return 0 }
    let n = Double(days)
    let revSum = abs(r - 1) < 1e-12 ? net0 * n : net0 * (1 - pow(r, n)) / (1 - r)
    return revSum - power * n
}
struct Projection { let net30, net90: Double }
func project(netRev0: Double, power: Double, monthlyPct: Double) -> Projection {
    let r = dailyDecay(monthlyPct)
    return Projection(net30: cumNet(netRev0, power, 30, r),
                      net90: cumNet(netRev0, power, 90, r))
}

struct Device: Identifiable, Codable {
    var id = UUID()
    var name: String
    var gpu: String
    var count: Int
    var rented: Bool = false        // false=自有(付电费+计硬件成本)，true=租用(按小时付租·全包价)
    var hoursPerDay: Double = 24     // 每天实际可用(挖矿)小时
    /// Synced from a pool: this rig's 24h hashrate in Pearl units (1 Pearl = 1 TH/s).
    /// When non-nil the device is "matched to" real pool data instead of a GPU model.
    var customPearl: Double? = nil
    /// Per-device rent override, stored as daily-equivalent ¥/天 (UI edits it as ¥/小时);
    /// nil = use the chip's default rent.
    /// Lets each rented rig use a different price (different rental providers).
    var rentDaily: Double? = nil
    var rentCurrency: String? = nil
    var rentFX: Double? = nil
    /// Stable pool-sync identity. Lets a later sync refresh hashrate while keeping
    /// user-edited name/GPU/rent/hour fields on the same worker/address.
    var sourceKey: String? = nil
    var synced: Bool { customPearl != nil }
}
extension Device {   // 容错解码：旧存档缺字段时回退默认值
    enum CodingKeys: String, CodingKey { case id, name, gpu, count, rented, hoursPerDay, customPearl, rentDaily, rentCurrency, rentFX, sourceKey }
    init(from dec: Decoder) throws {
        let c = try dec.container(keyedBy: CodingKeys.self)
        id          = (try? c.decode(UUID.self,   forKey: .id))          ?? UUID()
        name        = (try? c.decode(String.self, forKey: .name))        ?? "设备"
        gpu         = (try? c.decode(String.self, forKey: .gpu))         ?? "RTX 4090"
        count       = (try? c.decode(Int.self,    forKey: .count))       ?? 1
        rented      = (try? c.decode(Bool.self,   forKey: .rented))      ?? false
        hoursPerDay = (try? c.decode(Double.self, forKey: .hoursPerDay)) ?? 24
        customPearl = try? c.decode(Double.self, forKey: .customPearl)
        rentDaily   = try? c.decode(Double.self, forKey: .rentDaily)
        rentCurrency = try? c.decode(String.self, forKey: .rentCurrency)
        rentFX = try? c.decode(Double.self, forKey: .rentFX)
        sourceKey   = try? c.decode(String.self, forKey: .sourceKey)
    }
}
struct Fleet {
    var cards = 0, ownCards = 0, rentedCards = 0
    var pearl = 0.0, prlDay = 0.0, revDay = 0.0, powerDay = 0.0, rentDay = 0.0, netDay = 0.0, watts = 0.0
    var cost = 0.0   // 自有卡硬件成本(USD)；租用卡不计
}

enum SortKey: String, CaseIterable, Identifiable {
    case ownNet = "按自有净利", rentNet = "按租用净利", beRent = "按平衡租金"
    case pearl = "按算力", effic = "按能效 P/W"
    var id: String { rawValue }
    var accountValue: String {
        switch self {
        case .ownNet: return "ownNet"
        case .rentNet: return "rentNet"
        case .beRent: return "breakEvenRent"
        case .pearl: return "hash"
        case .effic: return "efficiency"
        }
    }
    init?(accountValue: String) {
        guard let value = Self.allCases.first(where: { $0.accountValue == accountValue }) else { return nil }
        self = value
    }
}

// MARK: - 格式化助手

func f(_ x: Double, _ d: Int = 2) -> String { x.isFinite ? String(format: "%.\(d)f", x) : "—" }
func pctSigned(_ x: Double, _ d: Int = 0) -> String { x.isFinite ? ((x >= 0 ? "+" : "") + f(x, d) + "%") : "—" }
private let hmsFormatter: DateFormatter = { let df = DateFormatter(); df.dateFormat = "HH:mm:ss"; return df }()
func nowHMS() -> String { hmsFormatter.string(from: Date()) }
