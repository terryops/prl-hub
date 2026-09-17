import SwiftUI

// MARK: - 参数（Form；滑块行改为「标签+值在上、滑条在下」全宽布局，适配 iPhone 窄屏）

struct SettingsSection: View {
    @ObservedObject var store: PRLStore
    var body: some View {
        Form {
            Section(Loc("行情（联网时自动锁定；手动模式可拖动推演）")) {
                Toggle(Loc("联网取价（关闭 = 手动覆盖币价/算力/难度）"), isOn: liveBinding)
                slider(Loc("PRL 币价 $"), $store.cfg.price, 0...3, 0.01, 3, store.live)
                slider(Loc("全网算力 EH/s"), nethashBinding, 1...200, 0.1, 2, store.live)
                slider(Loc("单位日产 PRL/P"), perUnitPerPBinding, 5...250, 0.5, 2, store.live)
            }
            Section(Loc("成本 / 汇率 / 机柜")) {
                slider(Loc("电价 $/kWh"), $store.cfg.elec, 0...0.5, 0.005, 3, false)
                slider(Loc("矿池抽水"), $store.cfg.poolFee, 0...0.1, 0.005, 3, false)
                fxControl
                slider(Loc("机柜功耗预算 W"), $store.powerBudgetW, 500...30000, 100, 0, false)
                slider(Loc("矿池同步能效 W/(TH/s)"), $store.cfg.syncWPerTH, 0...5, 0.1, 1, false)
                Text(Loc("「矿池同步」的设备无法从链上得知功率，按此能效估电费（默认 1.8 ≈ RTX4090 级）。设 0 = 只看收入不扣电费。"))
                    .font(.callout).foregroundColor(.secondary)
            }
            Section(Loc("难度趋势 / 扩容推演")) {
                slider(Loc("难度月增长 %"), $store.cfg.diffGrowthMonthly, -20...200, 1, 0, store.live)
                if store.cfg.hasDiffTrend {
                    let c = store.cfg
                    Label(Loc("实时难度：当前 %@M · 近7天 %@ · 近3天 %@ · 近24h %@", f(c.diffNow/1e6,2), pctSigned(c.diffChange(vs: c.diff7)), pctSigned(c.diffChange(vs: c.diff3)), pctSigned(c.diffChange(vs: c.diff24))),
                          systemImage: "chart.line.uptrend.xyaxis")
                        .font(.callout).foregroundColor(.secondary)
                }
                Toggle(Loc("自身算力计入全网（扩容稀释每卡出币）"), isOn: $store.selfDilution)
                Text(Loc("难度月增长 = 预计全网算力每月涨幅；出币 ∝ 1/全网算力，按日衰减，用于回本天数与 30/90 天预测。0 = 难度恒定。"))
                    .font(.callout).foregroundColor(.secondary)
            }
            Section(Loc("租用")) {
                Toggle(Loc("在【显卡对比】显示租金 / 租净列"), isOn: $store.rentEnabled)
                Text(Loc("各显卡租金不同 → 在【显卡对比】选中某卡后于详情逐卡设置"))
                    .font(.callout).foregroundColor(.secondary)
            }
            Section {
                Text(Loc("电价、汇率、机柜预算、每卡租金、设备清单都会自动保存。"))
                    .font(.callout).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // 汇率 → 本地货币：跟随「设置 → 货币」里选的全局副货币。默认自动取实时汇率
    // （每日更新），也可手动钉死一个值。无副货币时挖矿金额直接按美元显示。
    @ViewBuilder var fxControl: some View {
        if let lc = store.localCurrency {
            Toggle(Loc("自动汇率（跟随副货币 · 每日更新）"), isOn: Binding(
                get: { !store.fxManual },
                set: { store.fxManual = !$0; store.syncFx() }))
            if store.fxManual {
                let live = max(0.0001, store.liveFx)
                slider(Loc("汇率 → %@", lc.localizedName), $store.cfg.fx,
                       (live * 0.5)...(live * 1.5), max(0.0001, live / 200), fxDigits(live), false)
            } else {
                LabeledContent(Loc("汇率 → %@", lc.localizedName),
                               value: "1 USD ≈ " + f(store.cfg.fx, fxDigits(store.cfg.fx)) + " " + lc.code)
            }
        } else {
            Label(Loc("未选副货币：挖矿金额按美元（USD）显示。可在「设置 → 货币」选择副货币后在此换算。"),
                  systemImage: "dollarsign.circle")
                .font(.callout).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Sensible decimal places for a USD→local rate (CNY 7.2→2, RUB 90→1, VND 25000→0).
    private func fxDigits(_ rate: Double) -> Int { rate >= 1000 ? 0 : (rate >= 20 ? 1 : 2) }

    var liveBinding: Binding<Bool> {
        Binding(get: { store.live }, set: { store.live = $0; if $0 { store.refresh() } })
    }
    // 全网算力与单位日产耦合：perUnit ∝ 1/nethash，拖动联动重算
    var nethashBinding: Binding<Double> {
        Binding(get: { store.cfg.nethashEH }, set: { nv in
            var c = store.cfg
            if c.nethashEH > 0 && nv > 0 { c.perUnit *= c.nethashEH / nv }
            c.nethashEH = nv; store.cfg = c
        })
    }
    // 单位日产以「每 P(=1000 TH)·天」展示/编辑，与仪表盘卡片同口径；模型内仍按每 TH 存储。
    var perUnitPerPBinding: Binding<Double> {
        Binding(get: { store.cfg.perUnit * 1000 }, set: { store.cfg.perUnit = $0 / 1000 })
    }

    @ViewBuilder func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                             _ step: Double, _ digits: Int, _ disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.body)
                Spacer()
                Text(f(value.wrappedValue, digits)).monospacedDigit()
                    .foregroundColor(disabled ? .secondary : .primary)
            }
            Slider(value: value, in: range, step: step).disabled(disabled)
        }
        .padding(.vertical, 2)
    }
}
