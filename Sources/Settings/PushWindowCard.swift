import SwiftUI

// MARK: - 推送时段

/// 推送时段: all day (default) or a daily window of local time. Alerts that fire
/// outside it are queued by the worker and pushed when the window next opens.
struct PushWindowCard: View {
    @ObservedObject var store: PriceAlertStore

    private var custom: Binding<Bool> {
        Binding(get: { store.window != nil },
                set: { store.setWindow($0 ? (store.window ?? .default) : nil) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.md) {
            HStack(spacing: Pearl.Space.md) {
                PearlIconBadge(systemImage: "moon.zzz.fill", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Loc("推送时段")).font(.headline)
                    Text(summary)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Picker(Loc("推送时段"), selection: custom) {
                Text(Loc("全天")).tag(false)
                Text(Loc("自定义时段")).tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()

            if let w = store.window {
                HStack(spacing: Pearl.Space.sm) {
                    timePicker(Loc("从"), minutes: w.start) { store.setWindow(fixed(PushWindow(start: $0, end: w.end))) }
                    timePicker(Loc("到"), minutes: w.end) { store.setWindow(fixed(PushWindow(start: w.start, end: $0))) }
                }
            }
        }
        .pearlCard(padding: Pearl.Space.md)
    }

    private var summary: String {
        guard let w = store.window else { return Loc("任何时间触发都会立即推送。") }
        let start = PushWindow.timeText(w.start), end = PushWindow.timeText(w.end)
        return Loc("只在 %@–%@ 推送。其他时间触发的提醒，会在下一次 %@ 一到就推送给你。", start, end, start)
    }

    /// An empty window (start == end) would mean "never": push the end an hour on.
    private func fixed(_ w: PushWindow) -> PushWindow {
        w.start == w.end ? PushWindow(start: w.start, end: (w.end + 60) % 1440) : w
    }

    private func timePicker(_ label: String, minutes: Int, set: @escaping (Int) -> Void) -> some View {
        let binding = Binding<Date>(
            get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                set((c.hour ?? 0) * 60 + (c.minute ?? 0))
            })
        return HStack(spacing: Pearl.Space.xs) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            DatePicker(label, selection: binding, displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
