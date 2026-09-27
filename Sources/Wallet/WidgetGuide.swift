import SwiftUI
import WidgetKit

// MARK: - 桌面小组件 hint (钱包 tab)

/// A one-line hint under 价格提醒 on the 钱包 tab: how to put Pearl Hub on the Home
/// Screen / desktop. Hidden once a Pearl Hub home widget is already placed. The small
/// size is free, medium and large are Pro; the paywall only opens from the guide's
/// explicit unlock button.
struct WidgetInlineLink: View {
    @ObservedObject private var pro = ProStore.shared
    @Environment(\.scenePhase) private var scenePhase
    // The last answer, so someone who has the widget doesn't see the hint flash in on
    // every launch before the check comes back.
    @AppStorage("widget.homePlaced") private var placed = false
    @State private var showingGuide = WidgetInlineLink.shotGuide

    var body: some View {
        // Always-present (zero-height) anchor: with the hint hidden the stack would
        // otherwise be empty, and an empty view never runs its .task — the check below.
        VStack(spacing: 0) {
            Color.clear.frame(height: 0)
            if !placed || showingGuide {
                Button { showingGuide = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.grid.2x2").foregroundStyle(Pearl.accent)
                        Text(Loc("桌面小组件")).foregroundStyle(Pearl.accent)
                        Text(verbatim: "·").foregroundStyle(.tertiary)
                        Text(Self.subtitle).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
            }
        }
        .sheet(isPresented: $showingGuide) { WidgetGuideSheet() }
        // Re-checked on coming back to the app — typically right after adding the widget.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            placed = await Self.homeWidgetPlaced()
        }
    }

    private static var subtitle: String {
        #if os(macOS)
        Loc("在桌面看余额和币价")
        #else
        Loc("在主屏幕看余额和币价")
        #endif
    }

    /// Whether a Pearl Hub home / desktop widget is already placed (false if unsure).
    private static func homeWidgetPlaced() async -> Bool {
        let home = WidgetBridge.homeKind
        return await withCheckedContinuation { c in
            WidgetCenter.shared.getCurrentConfigurations { result in
                let kinds = (try? result.get())?.map(\.kind) ?? []
                c.resume(returning: kinds.contains(home))
            }
        }
    }

    /// DEBUG-only: SHOT_WIDGET_GUIDE=1 opens the guide on launch (钱包 tab).
    private static var shotGuide: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SHOT_WIDGET_GUIDE"] == "1"
        #else
        return false
        #endif
    }
}

/// How to add the widget, per platform, and — without Pro — that medium / large need it.
struct WidgetGuideSheet: View {
    @ObservedObject private var pro = ProStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showingPaywall = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                    Text(Self.intro)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    proStatus
                    VStack(alignment: .leading, spacing: Pearl.Space.md) {
                        ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, text in
                            step(i + 1, text)
                        }
                    }
                    .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
                    Text(Loc("小组件会定时自动刷新；打开 App 时会立即更新。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Pearl.Space.screen)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(Loc("添加桌面小组件"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(Loc("完成")) { dismiss() } }
                    .noGlassBackground()
            }
            .sheet(isPresented: $showingPaywall) {
                ProUpsellSheet(headline: Loc("高级版功能：桌面小组件"), headlineIcon: "square.grid.2x2")
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 520)
        #endif
    }

    @ViewBuilder private var proStatus: some View {
        if pro.isPro {
            Label(Loc("高级版已解锁，所有尺寸都能用。"), systemImage: "checkmark.seal.fill")
                .font(.callout).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: Pearl.Space.sm) {
                HStack(spacing: 6) {
                    Text(Loc("中、大尺寸是高级版功能")).font(.subheadline.weight(.semibold))
                    PearlBadge(text: Loc("高级版"), systemImage: "sparkles")
                }
                Text(Loc("小尺寸（币价和余额）免费使用。中、大尺寸还能看矿池算力和最近交易，没有高级版时会显示锁定画面，点它即可解锁。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showingPaywall = true } label: { Text(Loc("解锁高级版")) }
                    .buttonStyle(.pearl(Pearl.brand))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: Pearl.Space.sm) {
            Text(verbatim: "\(n)")
                .font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Pearl.brand, in: Circle())
            Text(text).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static var intro: String {
        #if os(macOS)
        Loc("把 Pearl Hub 放到桌面，不用打开 App 也能看余额、币价和矿池算力。")
        #else
        Loc("把 Pearl Hub 放到主屏幕，不用打开 App 也能看余额、币价和矿池算力。")
        #endif
    }

    private static var steps: [String] {
        #if os(macOS)
        [Loc("在桌面空白处点右键，选「编辑小组件」。"),
         Loc("在小组件列表里搜索「Pearl Hub」。"),
         Loc("选一个尺寸，把它拖到桌面上。")]
        #else
        [Loc("回到主屏幕，长按空白处，直到图标开始晃动。"),
         Loc("点左上角的「编辑」（或「+」），再点「添加小组件」。"),
         Loc("搜索「Pearl Hub」，选择小、中或大尺寸。"),
         Loc("点「添加小组件」，再把它拖到想放的位置。")]
        #endif
    }
}
