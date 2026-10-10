import SwiftUI
import UserNotifications

/// 价格提醒 — reached from 设置 → 通知 and from the 交易 tab's promo card. Card layout
/// in the app's Pearl style: the price the alerts watch, then either the Pro paywall
/// or the rule list (tap a rule to edit / delete it). The checking itself happens
/// on the server — see PriceAlertStore.
struct PriceAlertsView: View {
    @ObservedObject private var store = PriceAlertStore.shared
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

    var body: some View {
        ScrollView {
            VStack(spacing: Pearl.Space.lg) {
                priceCard
                if pro.isPro {
                    if store.authorization == .denied && store.pushHere {
                        NotificationsDeniedCard(message: Loc("通知权限已关闭，价格提醒无法送达"))
                    }
                    rulesCard
                    #if os(macOS)
                    PushHereCard(store: store)
                    #endif
                    PushWindowCard(store: store)
                } else {
                    ProPaywallCard(pro: pro)
                }
                Label(Loc("价格提醒只需要本机的推送令牌和提醒条件，不涉及钱包地址或余额。"), systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Pearl.Space.xs)
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background { PearlBackground() }
        .navigationTitle(Loc("价格提醒"))
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

    // MARK: price

    private var priceCard: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.md) {
            HStack(alignment: .center, spacing: Pearl.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Loc("PRL 提醒参考价")).font(.caption).foregroundStyle(.secondary)
                    Text(refPrice.map(PriceAlertFormat.usd) ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                PearlIconBadge(systemImage: "bell.badge.fill", size: 44)
            }
            HStack(spacing: Pearl.Space.xs) {
                changeCell(Loc("5 分钟"), quote?.change5m)
                changeCell(Loc("1 小时"), quote?.change1h)
                changeCell(Loc("24 小时"), quote?.change24h)
            }
            // The worker prices off SafeTrade (same as the wallet) and only falls
            // back to the three-exchange median while its SafeTrade relay is down.
            Text(quote?.source == "median" ? Loc("每分钟更新 · CoinEx、BigONE、WhatToMine 行情中位数")
                                           : Loc("每分钟更新 · SafeTrade 行情"))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .pearlCard()
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

    // MARK: rules

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(Loc("我的提醒")).font(.headline)
                Spacer()
                AlertSyncStatus(store: store, active: !store.rules.isEmpty)
            }
            .padding(.bottom, Pearl.Space.sm)

            if store.rules.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell.and.waves.left.and.right")
                        .font(.title2).foregroundStyle(Pearl.accent.opacity(0.7))
                    Text(Loc("还没有提醒。添加后，即使没有打开 App 也会收到通知。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Pearl.Space.md)
            } else {
                ForEach(Array(store.rules.enumerated()), id: \.element.id) { i, rule in
                    if i > 0 { Divider().padding(.leading, 34 + Pearl.Space.sm) }
                    ruleRow(rule)
                }
            }

            AlertSyncFailure(store: store)

            Button { editing = .new } label: {
                Label(Loc("添加提醒"), systemImage: "plus")
            }
            .buttonStyle(.pearl)
            .disabled(store.rules.count >= PriceAlertStore.maxRules)
            .padding(.top, Pearl.Space.md)

            if !store.rules.isEmpty && store.token != nil && store.pushHere {
                HStack(spacing: Pearl.Space.xs) {
                    Button {
                        Task { await sendTest() }
                    } label: {
                        Label(Loc("发送测试通知"), systemImage: "paperplane")
                    }
                    .font(.footnote.weight(.medium))
                    .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, Pearl.Space.sm)
                if let testMsg {
                    Text(testMsg).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                }
            }
        }
        .pearlCard()
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

    private func sendTest() async {
        testing = true
        defer { testing = false }
        switch await store.sendTest() {
        case .sent: testMsg = Loc("已发送，几秒内应收到一条通知。")
        case .failed(let msg): testMsg = msg
        }
    }
}
