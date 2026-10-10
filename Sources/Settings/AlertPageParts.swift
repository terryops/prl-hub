import SwiftUI
#if os(iOS)
import UIKit
#endif

// MARK: - Pieces the 价格提醒 and 掉线提醒 pages share
//
// Both pages sit on the same device registration (PriceAlertStore): whether
// notifications are allowed, and how the last sync with the worker went.

/// "Notifications are off, so these alerts can't arrive", with a way to the system's
/// settings for this app.
struct NotificationsDeniedCard: View {
    let message: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .center, spacing: Pearl.Space.md) {
            PearlIconBadge(systemImage: "bell.slash.fill", gradient: Pearl.sunrise, size: 38)
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Button(Loc("打开系统设置")) { openNotificationSettings() }
                    .font(.subheadline)
            }
            Spacer(minLength: 0)
        }
        .pearlCard(padding: Pearl.Space.md)
    }

    private func openNotificationSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") { openURL(url) }
        #endif
    }
}

/// The registration's state, for a card's header: syncing, synced, or still waiting
/// for the system's push token. `active`: this page has alerts that are meant to be live.
struct AlertSyncStatus: View {
    @ObservedObject var store: PriceAlertStore
    let active: Bool

    var body: some View {
        // Nothing to show while this device doesn't take pushes.
        if store.pushHere { status }
    }

    @ViewBuilder private var status: some View {
        switch store.syncState {
        case .syncing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(Loc("同步中"))
            }
            .font(.caption).foregroundStyle(.secondary)
        case .synced where active:
            Label(Loc("已同步"), systemImage: "checkmark.icloud")
                .font(.caption).foregroundStyle(.secondary)
        case .idle where active && store.token == nil && store.authorization == .authorized:
            Text(Loc("正在向系统申请推送令牌…")).font(.caption).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

/// Why the last sync (or the system's push registration) failed, under a card's list.
struct AlertSyncFailure: View {
    @ObservedObject var store: PriceAlertStore

    var body: some View {
        if case .failed(let msg) = store.syncState {
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
                .padding(.top, Pearl.Space.xs)
        }
    }
}
