import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#endif

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
    @Environment(\.openURL) private var openURL

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
                    if store.authorization == .denied { deniedCard }
                    rulesCard
                } else {
                    ProPaywallCard(pro: pro)
                }
                Label(Loc("服务器只保存本机的推送令牌和提醒条件，不涉及钱包地址或余额。"), systemImage: "lock.shield")
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
                                 if case .rule = target { store.update(rule) } else { store.add(rule) }
                             },
                             onDelete: { rule in store.remove(rule) })
        }
        .task {
            async let q = AlertQuote.fetch()
            await store.refreshAuthorization()
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

    private var deniedCard: some View {
        HStack(alignment: .center, spacing: Pearl.Space.md) {
            PearlIconBadge(systemImage: "bell.slash.fill", gradient: Pearl.sunrise, size: 38)
            VStack(alignment: .leading, spacing: 6) {
                Text(Loc("通知权限已关闭，价格提醒无法送达"))
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Button(Loc("打开系统设置")) { openNotificationSettings() }
                    .font(.subheadline)
            }
            Spacer(minLength: 0)
        }
        .pearlCard(padding: Pearl.Space.md)
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(Loc("我的提醒")).font(.headline)
                Spacer()
                syncStatus
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

            if case .failed(let msg) = store.syncState {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.top, Pearl.Space.xs)
            }

            Button { editing = .new } label: {
                Label(Loc("添加提醒"), systemImage: "plus")
            }
            .buttonStyle(.pearl)
            .disabled(store.rules.count >= 20)
            .padding(.top, Pearl.Space.md)

            if !store.rules.isEmpty && store.token != nil {
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
                Text(PriceAlertFormat.subtitle(rule))
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Pearl.Space.xs)
            Toggle(Loc("启用"), isOn: Binding(get: { rule.enabled }, set: { store.setEnabled(rule, $0) }))
                .labelsHidden()
        }
        .padding(.vertical, Pearl.Space.sm)
        .opacity(rule.enabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { editing = .rule(rule) }
        .contextMenu {
            Button { editing = .rule(rule) } label: { Label(Loc("编辑"), systemImage: "pencil") }
            Button(role: .destructive) { store.remove(rule) } label: { Label(Loc("删除"), systemImage: "trash") }
        }
    }

    @ViewBuilder private var syncStatus: some View {
        switch store.syncState {
        case .syncing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(Loc("同步中"))
            }
            .font(.caption).foregroundStyle(.secondary)
        case .synced where !store.rules.isEmpty:
            Label(Loc("已同步"), systemImage: "checkmark.icloud")
                .font(.caption).foregroundStyle(.secondary)
        case .idle where !store.rules.isEmpty && store.token == nil && store.authorization == .authorized:
            Text(Loc("正在向系统申请推送令牌…")).font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
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

    private func openNotificationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") { openURL(url) }
        #endif
    }
}

// MARK: - Paywall

/// Pearl Hub Pro — a one-time US$2.99 in-app purchase that unlocks price alerts.
struct ProPaywallCard: View {
    @ObservedObject var pro: ProStore

    var body: some View {
        VStack(spacing: Pearl.Space.lg) {
            VStack(spacing: Pearl.Space.xs) {
                PearlIconBadge(systemImage: "sparkles", size: 52)
                Text(Loc("Pearl Hub 高级版")).font(.title3.weight(.bold))
                Text(Loc("价格一到，第一时间通知你"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                feature("scope", Loc("到价提醒：涨破或跌破你设定的价格"))
                feature("waveform.path.ecg", Loc("涨跌幅提醒：5 分钟、1 小时或 24 小时"))
                feature("bell.badge", Loc("没打开 App 也能收到通知"))
                feature("laptopcomputer.and.iphone", Loc("一次购买，iPhone、iPad 和 Mac 通用"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: Pearl.Space.sm) {
                Button {
                    Task { await pro.purchase() }
                } label: {
                    HStack(spacing: Pearl.Space.xs) {
                        if pro.busy { ProgressView().controlSize(.small).tint(.white) }
                        Text(pro.product.map { Loc("以 %@ 解锁", $0.displayPrice) } ?? Loc("解锁高级版"))
                    }
                }
                .buttonStyle(.pearl)
                .disabled(pro.busy)

                HStack(spacing: 6) {
                    Button(Loc("恢复购买")) { Task { await pro.restore() } }
                        .disabled(pro.busy)
                    Text("·").foregroundStyle(.tertiary)
                    Text(Loc("一次性购买，不是订阅。")).foregroundStyle(.secondary)
                }
                .font(.footnote)

                if let msg = pro.message {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .pearlAccentCard()
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Pearl.Space.sm) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Pearl.accent)
                .frame(width: 24)          // one column for every icon, whatever its glyph width
            Text(text).font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - One-time upsell sheet

/// The paywall as a sheet — shown once, on the 2nd visit to 交易 (UpsellPrompt).
/// Closes itself when the purchase goes through; TradeView then opens 价格提醒.
struct ProUpsellSheet: View {
    @ObservedObject private var pro = ProStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 620   // measured; the sheet hugs its content

    var body: some View {
        ScrollView {
            VStack(spacing: Pearl.Space.md) {
                PearlBadge(text: Loc("新功能：价格提醒"), systemImage: "bell.badge")
                ProPaywallCard(pro: pro)
                Button(Loc("暂不")) { dismiss() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { contentHeight = g.size.height }
                    .onChange(of: g.size.height) { _, h in contentHeight = h }
            })
        }
        .background { PearlBackground() }
        .task { await pro.loadProduct() }
        .onChange(of: pro.isPro) { _, unlocked in if unlocked { dismiss() } }
        #if os(iOS)
        .presentationDetents([.height(contentHeight + Pearl.Space.lg)])
        .presentationDragIndicator(.visible)
        // Opaque: a partial-height sheet otherwise gets the system's see-through glass.
        .presentationBackground {
            ZStack { Color(uiColor: .systemBackground); PearlBackground() }
        }
        #else
        .frame(width: 460, height: 660)
        #endif
    }
}

// MARK: - 交易 tab promo

/// Card under the Trade chart that advertises / opens 价格提醒.
struct PriceAlertPromoCard: View {
    @ObservedObject private var store = PriceAlertStore.shared
    @ObservedObject private var pro = ProStore.shared

    private var subtitle: String {
        let on = store.rules.filter(\.enabled).count
        if !pro.isPro { return Loc("涨破、跌破或急涨急跌时推送通知") }
        return on > 0 ? Loc("%d 条提醒生效中", on) : Loc("添加到价或涨跌幅提醒")
    }

    var body: some View {
        NavigationLink {
            PriceAlertsView()
        } label: {
            HStack(spacing: Pearl.Space.md) {
                PearlIconBadge(systemImage: "bell.badge.fill", size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(Loc("价格提醒")).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if !pro.isPro { PearlBadge(text: Loc("高级版"), systemImage: "sparkles") }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pearlCard(padding: Pearl.Space.md)
    }
}

// MARK: - Add / edit sheet

private struct AlertEditorSheet: View {
    let existing: PriceAlertRule?
    let current: Double?
    let onSave: (PriceAlertRule) -> Void
    let onDelete: (PriceAlertRule) -> Void

    private enum Mode: Hashable { case price, move }
    @State private var mode: Mode
    @State private var priceText: String
    @State private var pctText: String
    @State private var window: Int
    @Environment(\.dismiss) private var dismiss

    init(existing: PriceAlertRule?, current: Double?,
         onSave: @escaping (PriceAlertRule) -> Void, onDelete: @escaping (PriceAlertRule) -> Void) {
        self.existing = existing; self.current = current; self.onSave = onSave; self.onDelete = onDelete
        let isMove = existing?.kind == .move
        _mode = State(initialValue: isMove ? .move : .price)
        _priceText = State(initialValue: existing.flatMap { $0.kind == .move ? nil : String(format: "%.2f", $0.value) } ?? "")
        _pctText = State(initialValue: existing.flatMap { $0.kind == .move ? String(format: "%g", $0.value) : nil } ?? "10")
        _window = State(initialValue: isMove ? (existing?.window ?? 86400) : 86400)
    }

    private static func number(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// Keep only digits and one decimal separator, with at most 2 decimals.
    static func limitDecimals(_ s: String) -> String {
        var out = "", sep = false, frac = 0
        for ch in s {
            if ch.isASCII && ch.isNumber {
                if sep { guard frac < 2 else { continue }; frac += 1 }
                out.append(ch)
            } else if (ch == "." || ch == ",") && !sep {
                sep = true
                out.append(ch)
            }
        }
        return out
    }

    /// The price rule to save, or nil while the input is invalid. The direction
    /// follows the current price: a target above it alerts on the way up.
    private var priceRule: PriceAlertRule? {
        guard let raw = Self.number(priceText) else { return nil }
        let t = PriceAlertFormat.cents(raw)
        guard t >= 0.01, t < 1_000_000 else { return nil }
        if let current, t == PriceAlertFormat.cents(current) { return nil }   // already there
        let up = current.map { t > $0 } ?? true
        return PriceAlertRule(kind: up ? .above : .below, value: t)
    }

    private var moveRule: PriceAlertRule? {
        guard let raw = Self.number(pctText) else { return nil }
        let p = PriceAlertFormat.cents(raw)
        guard p >= 0.5, p <= 1000 else { return nil }
        return PriceAlertRule(kind: .move, value: p, window: window)
    }

    /// The rule to save — an edit keeps the original id and on/off state.
    private var rule: PriceAlertRule? {
        guard var r = mode == .price ? priceRule : moveRule else { return nil }
        if let existing { r.id = existing.id; r.enabled = existing.enabled }
        return r
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(Loc("类型"), selection: $mode) {
                        Text(Loc("到价提醒")).tag(Mode.price)
                        Text(Loc("涨跌幅提醒")).tag(Mode.move)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if mode == .price {
                    Section {
                        LabeledContent(Loc("目标价格")) {
                            HStack(spacing: 2) {
                                Spacer(minLength: 0)
                                // "$" hugs the number: the field sizes to its text.
                                Text("$").foregroundStyle(.secondary)
                                TextField("0.00", text: $priceText)
                                    .fixedSize()
                                    .accessibilityLabel(Loc("目标价格（USD）"))
                                    #if os(iOS)
                                    .keyboardType(.decimalPad)
                                    #endif
                            }
                        }
                        if let current {
                            LabeledContent(Loc("当前价格"), value: PriceAlertFormat.usd(current))
                        }
                    } footer: {
                        if let r = priceRule {
                            Text(r.kind == .above
                                 ? Loc("价格涨到 %@ 时通知你", PriceAlertFormat.usd(r.value))
                                 : Loc("价格跌到 %@ 时通知你", PriceAlertFormat.usd(r.value)))
                        } else {
                            Text(Loc("输入一个与当前价格不同的目标价。"))
                        }
                    }
                } else {
                    Section {
                        Picker(Loc("时间范围"), selection: $window) {
                            Text(Loc("5 分钟")).tag(300)
                            Text(Loc("1 小时")).tag(3600)
                            Text(Loc("24 小时")).tag(86400)
                        }
                        LabeledContent(Loc("涨跌幅")) {
                            HStack(spacing: 4) {
                                TextField(Loc("涨跌幅（%）"), text: $pctText)
                                    .multilineTextAlignment(.trailing)
                                    #if os(iOS)
                                    .keyboardType(.decimalPad)
                                    #endif
                                Text("%").foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text(moveRule == nil
                             ? Loc("请输入 0.5 到 1000 之间的百分比。")
                             : Loc("涨或跌超过这个幅度都会通知你。"))
                    }
                }

                if let existing {
                    Section {
                        Button(role: .destructive) {
                            onDelete(existing); dismiss()
                        } label: {
                            Text(Loc("删除提醒")).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: priceText) { _, v in
                let l = Self.limitDecimals(v)
                if l != v { priceText = l }
            }
            .onChange(of: pctText) { _, v in
                let l = Self.limitDecimals(v)
                if l != v { pctText = l }
            }
            .navigationTitle(existing == nil ? Loc("添加提醒") : Loc("编辑提醒"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? Loc("添加") : Loc("保存")) {
                        if let rule { onSave(rule); dismiss() }
                    }
                    .disabled(rule == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}

// MARK: - Formatting

enum PriceAlertFormat {
    /// "$0.88", "$0.90", "$12.35" — always 2 decimals, like the wallet's price chip;
    /// mirrors the worker's fmtUSD so the list and the notification agree.
    static func usd(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }

    /// Round to the 2 decimals the alert inputs allow.
    static func cents(_ v: Double) -> Double { (v * 100).rounded() / 100 }

    static func pct(_ v: Double) -> String {
        String(format: "%g%%", v)
    }

    static func title(_ r: PriceAlertRule) -> String {
        switch r.kind {
        case .above: return Loc("涨到 %@", usd(r.value))
        case .below: return Loc("跌到 %@", usd(r.value))
        case .move:  return Loc("涨跌超过 %@", pct(r.value))
        }
    }

    static func subtitle(_ r: PriceAlertRule) -> String {
        let what: String
        switch r.kind {
        case .above, .below: what = Loc("到价提醒")
        case .move:
            switch r.window {
            case 300:  what = Loc("5 分钟内")
            case 3600: what = Loc("1 小时内")
            default:   what = Loc("24 小时内")
            }
        }
        guard let t = r.lastFired else { return what }
        return what + " · " + Loc("上次提醒：%@", RelTime(t))
    }

    static func icon(_ r: PriceAlertRule) -> String {
        switch r.kind {
        case .above: return "arrow.up.right"
        case .below: return "arrow.down.right"
        case .move:  return "waveform.path.ecg"
        }
    }

    static func gradient(_ r: PriceAlertRule) -> LinearGradient {
        switch r.kind {
        case .above: return Pearl.positive
        case .below: return Pearl.negative
        case .move:  return Pearl.brand
        }
    }
}
