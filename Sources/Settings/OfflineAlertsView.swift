import SwiftUI
import UserNotifications

/// 掉线提醒 — reached from 设置 → 通知 and from the pointer card on 我的监控. One row per
/// running pool monitor with how long a worker may be offline before the push; the
/// checking itself happens on the server — see OfflineAlertStore.
struct OfflineAlertsView: View {
    @ObservedObject private var store = OfflineAlertStore.shared
    @ObservedObject private var push = PriceAlertStore.shared
    @ObservedObject private var pro = ProStore.shared

    var body: some View {
        ScrollView {
            VStack(spacing: Pearl.Space.lg) {
                introCard
                if pro.isPro {
                    if push.authorization == .denied && push.pushHere {
                        NotificationsDeniedCard(message: Loc("通知权限已关闭，掉线提醒无法送达"))
                    }
                    monitorsCard
                    #if os(macOS)
                    PushHereCard(store: push)
                    #endif
                    PushWindowCard(store: push)
                    if push.window != nil {
                        note(Loc("推送时段之外掉线的矿机，到时段开始时如果还没恢复，会在那时通知你。"), systemImage: "moon.zzz")
                    }
                } else {
                    ProPaywallCard(pro: pro)
                }
                note(Loc("为监控开启掉线提醒后，服务器会保存它的矿池和收款地址（F2Pool 为只读页链接），只用来查询矿机状态；不涉及助记词、私钥或余额。"),
                     systemImage: "lock.shield")
            }
            .padding(Pearl.Space.screen)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background { PearlBackground() }
        .navigationTitle(Loc("掉线提醒"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            await push.refreshAuthorization()
            // Alerts that came over iCloud from another device: ask for notifications here,
            // where it's clear what for — then read back what the worker makes of the monitors.
            await push.pageOpened()
            await push.refresh()
            await pro.loadProduct()
        }
    }

    private func note(_ text: String, systemImage: String) -> some View {
        PearlInfoRow(text, systemImage: systemImage)
            .padding(.horizontal, Pearl.Space.xs)
    }

    // MARK: cards

    private var introCard: some View {
        HStack(alignment: .center, spacing: Pearl.Space.md) {
            PearlIconBadge(systemImage: "wifi.exclamationmark", size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(Loc("矿机掉线，第一时间知道")).font(.headline)
                Text(Loc("矿机离线达到你设定的时长就推送通知，恢复上线后再通知一次，不用打开 App。服务器每 3 分钟向矿池查询一次。"))
                    .pearlExplanation()
            }
            Spacer(minLength: 0)
        }
        .pearlCard(padding: Pearl.Space.md)
    }

    private var monitorsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(Loc("我的监控")).font(.headline)
                Spacer()
                AlertSyncStatus(store: push, active: store.activeCount > 0)
            }
            .padding(.bottom, Pearl.Space.sm)

            // Only the monitors that are running: a paused one is not watched, so an alert
            // for it has nothing to say until it is resumed (its choice is kept meanwhile).
            let running = store.watches.filter(\.isEnabled)
            if running.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: store.watches.isEmpty ? "square.stack.3d.up" : "pause.circle")
                        .font(.title2).foregroundStyle(Pearl.accent.opacity(0.7))
                    Text(store.watches.isEmpty
                         ? Loc("还没有监控。先到「我的监控」添加矿池和收款地址。")
                         : Loc("监控都已暂停。恢复监控后，可以在这里开启掉线提醒。"))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Pearl.Space.md)
            } else {
                ForEach(Array(running.enumerated()), id: \.element.id) { i, w in
                    if i > 0 { Divider().padding(.leading, 34 + Pearl.Space.sm) }
                    row(w)
                }
            }

            AlertSyncFailure(store: push)
            if !store.canAddMore {
                Text(Loc("最多可为 %d 个监控开启掉线提醒。", OfflineAlertStore.maxWatches))
                    .pearlExplanation(.footnote)
                    .padding(.top, Pearl.Space.xs)
            }
        }
        .pearlCard()
    }

    private func row(_ w: PoolWatch) -> some View {
        let m = store.threshold(for: w.id)
        return HStack(spacing: Pearl.Space.sm) {
            PoolIcon(pool: w.pool, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(w.displayName).font(.body.weight(.semibold)).lineLimit(1)
                subtitle(w, minutes: m)
            }
            Spacer(minLength: Pearl.Space.xs)
            OfflineAlertPicker(watch: w, store: store) {
                Text(m.map { Loc("%d 分钟", $0) } ?? Loc("不提醒"))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }
        }
        .padding(.vertical, Pearl.Space.sm)
    }

    @ViewBuilder private func subtitle(_ w: PoolWatch, minutes m: Int?) -> some View {
        if m != nil, store.missing.contains(w.id) {
            Label(Loc("矿池查不到这个地址，无法提醒"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).lineLimit(1).minimumScaleFactor(0.8)
        } else if m != nil, store.stale.contains(w.id) {
            Label(Loc("矿池暂时查询不到，恢复后继续监控"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).lineLimit(1).minimumScaleFactor(0.8)
        } else {
            Text(m.map { Loc("矿机离线满 %d 分钟时通知", $0) } ?? (w.hasAlias ? w.pool.label : shortAddress(w)))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    /// The pool label already is the title of an un-aliased monitor, so its second line
    /// tells same-pool monitors apart by address instead.
    private func shortAddress(_ w: PoolWatch) -> String {
        guard w.pool.isAddressBased, w.address.count > 16 else { return w.pool.label }
        return w.address.prefix(8) + "…" + w.address.suffix(6)
    }
}

/// The 不提醒 / 10 / 15 / 30 / 60 分钟 choice for one monitor, as a menu. Shared by the
/// 掉线提醒 page (a labelled button) and the monitor card (the chip beside its name).
struct OfflineAlertPicker<MenuLabel: View>: View {
    let watch: PoolWatch
    @ObservedObject var store: OfflineAlertStore
    @ViewBuilder var label: () -> MenuLabel

    var body: some View {
        Menu {
            // The heading says what is being chosen: the card's bell (and a bare "10 分钟")
            // don't. Checkable items rather than an inline Picker, because a menu drops
            // the heading of a section that holds nothing but a picker.
            Section {
                item(nil, Loc("不提醒"))
                // At the cap, a monitor without an alert can't get one; the others still can change.
                if store.threshold(for: watch.id) != nil || store.canAddMore {
                    ForEach(OfflineAlertStore.choices, id: \.self) { m in
                        item(m, Loc("离线 %d 分钟后", m))
                    }
                }
            } header: {
                Text(Loc("掉线提醒：离线多久后通知"))
            }
        } label: {
            label()
        }
    }

    /// One choice, ticked while it is the monitor's. (Tapping the ticked one changes nothing.)
    private func item(_ minutes: Int?, _ title: String) -> some View {
        Toggle(title, isOn: Binding(get: { store.threshold(for: watch.id) == minutes },
                                    set: { if $0 { store.set(watch.id, minutes: minutes) } }))
    }
}

// MARK: - 我的监控 pointer

/// The card on 我的监控 that says 掉线提醒 exists and opens it. Shown by PoolView until it
/// is opened or closed once, or an alert is on.
struct OfflineAlertHintCard: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void
    @ObservedObject private var pro = ProStore.shared

    var body: some View {
        HStack(spacing: Pearl.Space.sm) {
            Button(action: onOpen) {
                HStack(spacing: Pearl.Space.md) {
                    PearlIconBadge(systemImage: "bell.badge.fill", size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(Loc("新功能：掉线提醒")).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            if !pro.isPro { PearlBadge(text: Loc("高级版"), systemImage: "sparkles").fixedSize() }
                        }
                        Text(Loc("矿机离线 10 分钟以上就推送通知。点这里为你的监控开启。"))
                            .pearlExplanation()
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Loc("关闭"))
        }
        .pearlCard(padding: Pearl.Space.md)
    }
}
