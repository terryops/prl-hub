import SwiftUI
import UserNotifications

/// 价格和到账提醒 — one page for both pushes, reached from the wallet page's bottom card,
/// 设置 → 通知设置 and the 交易 tab's card. 价格提醒: rules on the PRL price (tap one to edit /
/// delete it); 到账提醒: one address, pushed when it's paid (IncomeAlertCard). Both are checked
/// on the server (PriceAlertStore, IncomeAlertStore) and share this device's push
/// registration and 推送时段, which close the page.
struct AlertsView: View {
    @ObservedObject private var store = PriceAlertStore.shared
    @ObservedObject private var income = IncomeAlertStore.shared
    @ObservedObject private var price = PRLPriceManager.shared
    @ObservedObject private var pro = ProStore.shared
    @State private var editing: EditTarget?
    @State private var quote: AlertQuote?
    @State private var testing = false
    @State private var testMsg: String?

    enum EditTarget: Identifiable {
        case new
        case rule(PriceAlertRule)
        var id: String { if case .rule(let r) = self { return r.id }; return "new" }
    }

    /// Price the alerts trigger on (the worker's) — the app's own price until it loads.
    private var refPrice: Double? { quote?.usd ?? price.usd }
    private var priceActive: Bool { store.rules.contains(where: \.isOn) }
    /// Something on this page is meant to push.
    private var anyActive: Bool { priceActive || income.wire != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: Pearl.Space.lg) {
                if pro.isPro {
                    if store.authorization == .denied && store.pushHere && anyActive {
                        NotificationsDeniedCard(message: priceActive ? Loc("通知权限已关闭，价格提醒无法送达")
                                                                     : Loc("通知权限已关闭，到账提醒无法送达"))
                    }
                    priceCard
                    IncomeAlertCard()
                    footer
                    #if os(macOS)
                    PushHereCard(store: store)
                    #endif
                    PushWindowCard(store: store)
                } else {
                    // Its feature list says what both alerts do (到价 / 涨跌幅 / 到账).
                    ProPaywallCard(pro: pro)
                }
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background { PearlBackground() }
        .navigationTitle(Loc("价格和到账提醒"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(item: $editing) { target in
            AlertEditorSheet(existing: { if case .rule(let r) = target { return r }; return nil }(),
                             current: refPrice,
                             onSave: { rule in
                                 if case .rule(let old) = target { store.update(rule, from: old) } else { store.add(rule) }
                             },
                             onDelete: { rule in store.remove(rule) })
        }
        .task {
            async let q = AlertQuote.fetch()
            await store.refresh()
            await store.refreshAuthorization()
            // Alerts that came over iCloud from another device: ask for notifications here,
            // where it's clear what for, rather than on some later launch.
            await store.pageOpened()
            await price.refreshIfStale()
            await pro.loadProduct()
            quote = await q
        }
        .refreshable { quote = await AlertQuote.fetch() }
    }

    // MARK: 价格提醒

    private var priceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            AlertCardHeader(systemImage: "bell.badge.fill", title: Loc("价格提醒"),
                            subtitle: Loc("PRL 到价或大涨大跌时推送通知"),
                            info: Loc("价格提醒只需要本机的推送令牌和提醒条件，不涉及钱包地址或余额。"))

            quoteBlock.padding(.top, Pearl.Space.md)

            // Empty: the 添加提醒 button right below is the next step.
            if !store.rules.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(store.rules.enumerated()), id: \.element.id) { i, rule in
                        if i > 0 { Divider().padding(.leading, 34 + Pearl.Space.sm) }
                        ruleRow(rule)
                    }
                }
                .padding(.top, Pearl.Space.sm)
            }

            Button { editing = .new } label: {
                Label(Loc("添加提醒"), systemImage: "plus")
            }
            .buttonStyle(.pearl)
            .disabled(store.rules.count >= PriceAlertStore.maxRules)
            .padding(.top, Pearl.Space.md)
        }
        .pearlCard()
    }

    /// The price the rules are checked against, and how it moved — what a new rule is set from.
    private var quoteBlock: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(Loc("PRL 提醒参考价")).font(.caption).foregroundStyle(.secondary)
                    // The worker prices off SafeTrade (same as the wallet) and only falls
                    // back to the three-exchange median while its SafeTrade relay is down.
                    PearlInfoTip(quote?.source == "median"
                                 ? Loc("每分钟更新 · CoinEx、BigONE、WhatToMine 行情中位数")
                                 : Loc("每分钟更新 · SafeTrade 行情"),
                                 title: Loc("PRL 提醒参考价"))
                }
                Text(refPrice.map(PriceAlertFormat.usd) ?? "—")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            HStack(spacing: Pearl.Space.xs) {
                changeCell(Loc("5 分钟"), quote?.change5m)
                changeCell(Loc("1 小时"), quote?.change1h)
                changeCell(Loc("24 小时"), quote?.change24h)
            }
        }
    }

    private func changeCell(_ label: String, _ pct: Double?) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(pct.map { (($0 >= 0) ? "+" : "") + String(format: "%.2f%%", $0) } ?? "—")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
                .foregroundStyle(pct.map { $0 >= 0 ? Color.green : Color.red } ?? .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Pearl.Space.xs)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: Pearl.Radius.xs, style: .continuous))
    }

    private func ruleRow(_ rule: PriceAlertRule) -> some View {
        HStack(spacing: Pearl.Space.sm) {
            PearlIconBadge(systemImage: PriceAlertFormat.icon(rule), gradient: PriceAlertFormat.gradient(rule), size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(PriceAlertFormat.title(rule))
                    .font(.body.weight(.semibold)).monospacedDigit()
                if rule.deferred == true, store.pushHere, let w = store.window {
                    // Fired in quiet hours; the worker pushes it at the window start.
                    Label(Loc("免打扰时段内触发，将于 %@ 推送", PushWindow.timeText(w.start)), systemImage: "moon.zzz.fill")
                        .font(.caption).foregroundStyle(Pearl.accent)
                        .lineLimit(1).minimumScaleFactor(0.8)
                } else {
                    Text(PriceAlertFormat.subtitle(rule))
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Pearl.Space.xs)
            Toggle(Loc("启用"), isOn: Binding(get: { rule.isOn }, set: { store.setEnabled(rule, $0) }))
                .labelsHidden()
        }
        .padding(.vertical, Pearl.Space.sm)
        .opacity(rule.isOn ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { editing = .rule(rule) }
        .contextMenu {
            Button { editing = .rule(rule) } label: { Label(Loc("编辑"), systemImage: "pencil") }
            Button(role: .destructive) { store.remove(rule) } label: { Label(Loc("删除"), systemImage: "trash") }
        }
    }

    // MARK: under both cards

    /// The registration both cards ride on: synced or not, why not, and a test push.
    @ViewBuilder private var footer: some View {
        let canTest = anyActive && store.token != nil && store.pushHere
        if anyActive {
            VStack(spacing: 4) {
                HStack(spacing: Pearl.Space.sm) {
                    AlertSyncStatus(store: store, active: anyActive)
                    Spacer(minLength: 0)
                    if canTest {
                        if testing { ProgressView().controlSize(.small) }
                        Button {
                            Task { await sendTest() }
                        } label: {
                            Label(Loc("发送测试通知"), systemImage: "paperplane")
                        }
                        .font(.footnote.weight(.medium))
                        .disabled(testing)
                    }
                }
                if let testMsg {
                    Text(testMsg).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.horizontal, Pearl.Space.xs)
        }
        AlertSyncFailure(store: store)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Pearl.Space.xs)
    }

    private func sendTest() async {
        testing = true
        defer { testing = false }
        switch await store.sendTest() {
        case .sent: testMsg = Loc("已发送，几秒内应收到一条通知。")
        case .failed(let msg): testMsg = msg
        }
    }
}
