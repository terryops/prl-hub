import SwiftUI

// ============================================================
// PRL Monitor 根视图。
// 原版用 TabView 装 4 个子页；在本 App 里 PRL Monitor 本身已是一个顶层 Tab，
// 再嵌 TabView 在 iPhone 上会出现双层 tab bar，故改用顶部 segmented 切换 4 个分区。
// 布局自适应：iPhone 紧凑、iPad/Mac 宽屏（由 horizontalSizeClass 驱动）。
// ============================================================

struct PRLMonitorView: View {
    @StateObject private var store = PRLStore()
    @EnvironmentObject private var currency: CurrencyManager
    // DEBUG-only: a launch env var can pin the opening section, so a screenshot /
    // verification run lands on it without driving the pill strip (see RootView.SHOT_TAB).
    @State private var section: Section = {
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment["SHOT_SECTION"],
           let sec = Section(rawValue: s) { return sec }
        #endif
        return .dashboard
    }()
    // 参数（测算输入）不再占一个胶囊：改从导航栏右上角以 sheet 弹出。胶囊条因此
    // 从 5 → 4（长翻译不再挤），参数仍归挖矿 tab、与仪表盘相邻——调完一关即见卡片变化。
    @State private var showingParams = false
    // First-run hint: point newcomers at the add-pools → sync-devices flow.
    @AppStorage("prlmonitor.introSeen") private var introSeen = false

    enum Section: String, CaseIterable, Identifiable {
        case dashboard = "概览", pools = "矿池", devices = "我的设备", catalog = "显卡对比"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // A scrollable pill strip instead of a fixed 5-way segmented
                // control: equal-width segments cram long non-CJK labels
                // ("Perangkat" / "Parameter" / "Сравнение") edge-to-edge and
                // segmented text can't shrink. Pills size to their content and
                // scroll, so every language reads cleanly.
                SectionTabBar(section: $section)

                Divider()

                if !introSeen { introBanner }

                switch section {
                case .dashboard: DashboardSection(store: store)
                case .pools:     PoolsOverviewSection()
                case .devices:   DevicesSection(store: store)
                case .catalog:   CatalogSection(store: store)
                }
            }
            .navigationTitle(Loc("PRL 挖矿监控"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // 参数入口。用 slider.horizontal.3 而非齿轮：内容就是一组滑块，
                // 也避免与底部「设置」tab 的 gearshape 撞图标（两个齿轮会让人分不清）。
                ToolbarItem(placement: .primaryAction) {
                    Button { showingParams = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(Loc("参数"))
                }
            }
            .sheet(isPresented: $showingParams) {
                NavigationStack {
                    SettingsSection(store: store)
                        .navigationTitle(Loc("参数"))
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .pearlListBackground()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(Loc("完成")) { showingParams = false }
                            }
                        }
                }
            }
        }
        .onAppear { store.refresh(); store.syncFx() }
        // Keep the local-currency rate in step with the global secondary currency
        // and the daily rate refresh (no-op while the user pinned a manual rate).
        .onChange(of: currency.secondaryPref) { _, _ in store.syncFx() }
        .onChange(of: currency.lastUpdated) { _, _ in store.syncFx() }
        .onReceive(NotificationCenter.default.publisher(for: .cloudSyncDidUpdate)) { _ in
            store.reloadDevices()   // adopt 设备资料 synced from another device
            store.reloadPrefs()     // adopt synced config (电费 / 费率 / 模式 / 排序…)
            store.syncFx()
        }
    }

    /// Dismissible first-run tip: you add pools/addresses in 我的监控, then one-tap
    /// sync them into devices from 我的设备 → 从矿池同步.
    private var introBanner: some View {
        HStack(alignment: .top, spacing: Pearl.Space.sm) {
            Image(systemName: "lightbulb.fill").foregroundStyle(Pearl.gold)
            VStack(alignment: .leading, spacing: 4) {
                Text(Loc("新手提示")).font(.callout.weight(.semibold))
                Text(Loc("先到「我的监控」添加你的矿池和挖矿地址；再回到「我的设备」点『从矿池同步』，即可一键把矿机同步成设备。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Loc("Pearl Hub 本身不挖矿，仅读取矿池公开数据。"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { withAnimation(.snappy) { introSeen = true } } label: {
                Image(systemName: "xmark.circle.fill").font(.body).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Loc("知道了"))
        }
        .padding(Pearl.Space.md)
        .background(Pearl.gold.opacity(0.10), in: RoundedRectangle(cornerRadius: Pearl.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Pearl.Radius.md, style: .continuous).strokeBorder(Pearl.gold.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, Pearl.Space.md)
        .padding(.vertical, Pearl.Space.sm)
    }
}

// MARK: - 分区标签条（可横向滚动的胶囊；替换原 5 段等宽 segmented）

/// Horizontally-scrollable pill selector for the monitor's 5 sections. Pills
/// size to their content (so long translations breathe instead of being crammed
/// into equal segments), scroll when they overflow, and auto-center the
/// selected pill. CJK labels are short enough to all fit without scrolling.
private struct SectionTabBar: View {
    @Binding var section: PRLMonitorView.Section

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Pearl.Space.xs) {
                    ForEach(PRLMonitorView.Section.allCases) { s in
                        let on = section == s
                        Button {
                            withAnimation(.snappy) { section = s }
                        } label: {
                            Text(Loc(s.rawValue))
                                .font(.subheadline.weight(on ? .semibold : .regular))
                                .foregroundStyle(on ? Color.white : Color.primary)
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(on ? AnyShapeStyle(Pearl.accent)
                                                      : AnyShapeStyle(Color.primary.opacity(0.06)))
                                )
                        }
                        .buttonStyle(.plain)
                        .id(s)
                    }
                }
                .padding(.horizontal, Pearl.Space.md)
                .padding(.vertical, Pearl.Space.sm)
            }
            .onChange(of: section) { _, new in
                withAnimation(.snappy) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }
}

// MARK: - 通用组件

struct StatCard: View {
    let title: String, value: String, sub: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.xxs) {
            Text(title).font(.subheadline).foregroundColor(.secondary)
            Text(value).font(.system(.title2, design: .rounded).weight(.bold))
                .foregroundColor(color).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
            Text(sub).font(.caption).foregroundColor(.secondary)
        }
        .padding(Pearl.Space.md)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        // Clean, flat surface — the colored value carries the meaning, no shadow/dot/bar clutter.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Pearl.Radius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Pearl.Radius.sm, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

/// 自适应的 StatCard 网格：按可用宽度回流为 1–3 列（替换原版固定 3 列 GridRow）。
struct StatGrid<Content: View>: View {
    /// Min column width: lower it for cards nested inside a padded card (less width
    /// available) so they still reflow into 2 columns instead of a tall 1-column stack.
    var minimum: CGFloat = 165
    @ViewBuilder var content: Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: Pearl.Space.md)],
                  alignment: .leading, spacing: Pearl.Space.md) {
            content
        }
    }
}

#Preview {
    PRLMonitorView()
}
