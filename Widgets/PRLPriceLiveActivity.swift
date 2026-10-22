#if os(iOS)
import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - 锁屏盯盘 (Live Activity)
//
// Lock Screen banner + Dynamic Island for PriceActivityAttributes. Content comes
// from the app (while it runs) or from the worker's pushes; see PriceActivity.swift.
// The user's style picks which of the two carries the price: `lock` keeps the
// island to a pearl, `island` shrinks the Lock Screen card to a one-line strip.

struct PriceLiveActivity: Widget {
    var body: some WidgetConfiguration { watchLayoutIfAvailable() }

    /// iOS 18+: the same activity plus its own Apple Watch Smart Stack layout (the
    /// `.small` family). Without it watchOS falls back to the Dynamic Island's compact
    /// pieces — a lone pearl, which showed as next to nothing on the watch.
    /// (Opaque results may differ per `if #available` branch, SE-0360.)
    private func watchLayoutIfAvailable() -> some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return priceActivityConfiguration(watchAware: true).supplementalActivityFamilies([.small])
        } else {
            return priceActivityConfiguration(watchAware: false)
        }
    }
}

@MainActor
private func priceActivityConfiguration(watchAware: Bool) -> some WidgetConfiguration {
    return ActivityConfiguration(for: PriceActivityAttributes.self) { context in
        let appearance = WidgetAppearance.load()
        if watchAware, #available(iOS 18.0, *) {
            FamilyAwarePriceView(appearance: appearance, attributes: context.attributes, state: context.state, stale: context.isStale)
        } else {
            WidgetPresentation(appearance: appearance) {
                PhoneLockScreenView(attributes: context.attributes, state: context.state, stale: context.isStale)
            }
            .activityBackgroundTint(appearance.activityBackground)
            .activitySystemActionForegroundColor(appearance.isModern ? .primary : .white)
        }
    } dynamicIsland: { context in
        let appearance = WidgetAppearance.load()
        let islandColors = WidgetColors(appearance, scheme: .dark)
        let s = context.state
        let pearlOnly = context.attributes.resolvedStyle == .lock
        return DynamicIsland {
            DynamicIslandExpandedRegion(.leading) {
                HStack(spacing: 6) {
                    PearlGlyph(size: 18)
                    Text(verbatim: "PRL").font(.headline)
                }
                .padding(.leading, 4)
            }
            DynamicIslandExpandedRegion(.trailing) {
                Text(verbatim: usdString(s.usd))
                    .font(.title2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(islandColors.price)
                    .padding(.trailing, 4)
            }
            DynamicIslandExpandedRegion(.bottom) {
                HStack {
                    ChangePill(label: context.attributes.label1h, pct: s.change1h).environment(\.widgetColors, islandColors)
                    ChangePill(label: context.attributes.label24h, pct: s.change24h).environment(\.widgetColors, islandColors)
                    Spacer()
                    Text(Date(timeIntervalSince1970: s.at), style: .time)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
        } compactLeading: {
            PearlGlyph(size: 16)
        } compactTrailing: {
            if !pearlOnly {
                Text(verbatim: usdString(s.usd))
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(changeColor(s.change24h))
            }
        } minimal: {
            PearlGlyph(size: 16)
        }
        .keylineTint(islandColors.accent)
    }
}

/// The phone's Lock Screen presentation, per the user's style.
private struct PhoneLockScreenView: View {
    let attributes: PriceActivityAttributes
    let state: PriceActivityAttributes.ContentState
    let stale: Bool
    var body: some View {
        if attributes.resolvedStyle == .island {
            LockScreenStrip(state: state, label24h: attributes.label24h)
        } else {
            LockScreenPriceView(attributes: attributes, state: state, stale: stale)
        }
    }
}

/// Picks the Apple Watch layout when the system asks for the `.small` family.
/// The watch always gets the price, whatever the phone's style.
@available(iOS 18.0, *)
private struct FamilyAwarePriceView: View {
    @Environment(\.activityFamily) private var family
    let appearance: WidgetAppearance
    let attributes: PriceActivityAttributes
    let state: PriceActivityAttributes.ContentState
    let stale: Bool
    var body: some View {
        if family == .small {
            WatchPriceView(appearance: appearance, attributes: attributes, state: state, stale: stale)
        } else {
            WidgetPresentation(appearance: appearance) {
                PhoneLockScreenView(attributes: attributes, state: state, stale: stale)
            }
            .activityBackgroundTint(appearance.activityBackground)
            .activitySystemActionForegroundColor(appearance.isModern ? .primary : .white)
        }
    }
}

/// The Smart Stack uses its own dark surface, even when the phone is in light mode.
/// Keep the price prominent in an 80-point card and dim decorative colour for Always On.
private struct WatchPriceView: View {
    @Environment(\.isLuminanceReduced) private var reducedLuminance
    let appearance: WidgetAppearance
    let attributes: PriceActivityAttributes
    let state: PriceActivityAttributes.ContentState
    let stale: Bool

    private var colors: WidgetColors { WidgetColors(appearance, scheme: .dark) }
    private var background: Color {
        if reducedLuminance { return .black }
        return appearance.isModern
            ? Color(red: 27 / 255, green: 29 / 255, blue: 33 / 255)
            : Color(red: 23 / 255, green: 38 / 255, blue: 61 / 255)
    }
    private var changeColor: Color {
        guard let pct = state.change24h, pct != 0 else { return colors.secondary }
        return pct > 0 ? colors.positive : colors.negative
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                PearlGlyph(size: 18)
                    .opacity(reducedLuminance ? 0.6 : 1)
                    .accessibilityHidden(true)
                Text(verbatim: "PRL")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.secondary)
                Spacer(minLength: 4)
                if stale {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 10)).foregroundStyle(colors.muted)
                }
                Text(Date(timeIntervalSince1970: state.at), style: .time)
                    .font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(colors.muted)
            }
            .lineLimit(1).minimumScaleFactor(0.75)
            Text(verbatim: usdString(state.usd))
                .font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(colors.primary.opacity(stale ? 0.65 : 1))
                .minimumScaleFactor(0.6).lineLimit(1)
            HStack(spacing: 4) {
                Text(attributes.label24h)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(colors.secondary)
                Spacer(minLength: 4)
                if let pct = state.change24h {
                    Image(systemName: pct > 0 ? "arrow.up.right" : pct < 0 ? "arrow.down.right" : "minus")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
                Text(verbatim: state.change24h.map { String(format: "%+.2f%%", $0) } ?? "—")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(changeColor.opacity(reducedLuminance ? 0.8 : 1))
            .lineLimit(1).minimumScaleFactor(0.75)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .environment(\.colorScheme, .dark)
        .activityBackgroundTint(background)
        .activitySystemActionForegroundColor(.white)
    }
}

private struct LockScreenPriceView: View {
    @Environment(\.widgetColors) private var colors
    let attributes: PriceActivityAttributes
    let state: PriceActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            PearlGlyph(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.title).font(.caption).foregroundStyle(colors.secondary)
                Text(verbatim: usdString(state.usd))
                    .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(colors.primary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                ChangePill(label: attributes.label1h, pct: state.change1h)
                ChangePill(label: attributes.label24h, pct: state.change24h)
                Text(Date(timeIntervalSince1970: state.at), style: .time)
                    .font(.caption2).foregroundStyle(colors.muted)
            }
        }
        .padding(16)
        .opacity(stale ? 0.6 : 1)
    }
}

/// 灵动岛为主: the Lock Screen part shrinks to one quiet line.
private struct LockScreenStrip: View {
    @Environment(\.widgetColors) private var colors
    let state: PriceActivityAttributes.ContentState
    let label24h: String
    var body: some View {
        HStack(spacing: 8) {
            PearlGlyph(size: 18)
            Text(verbatim: "PRL").font(.subheadline.weight(.semibold)).foregroundStyle(colors.secondary)
            Text(verbatim: usdString(state.usd))
                .font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(colors.primary)
            Spacer(minLength: 4)
            ChangePill(label: label24h, pct: state.change24h)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// "1h +2.35%" — label dimmed, figure in green/red.
private struct ChangePill: View {
    @Environment(\.widgetColors) private var colors
    let label: String
    let pct: Double?
    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(colors.secondary)
            Text(verbatim: pct.map { String(format: "%+.2f%%", $0) } ?? "—")
                .foregroundStyle(pct.map { $0 == 0 ? colors.primary : $0 > 0 ? colors.positive : colors.negative } ?? colors.primary).monospacedDigit()
        }
        .font(.caption.weight(.semibold))
    }
}

/// Live Activities keep the original pearl symbol regardless of the app-icon choice.
private struct PearlGlyph: View {
    let size: CGFloat
    var body: some View {
        Image("pearl").resizable().scaledToFit()
            .foregroundStyle(pearlGradient)
            .frame(width: size, height: size)
    }
}

private func usdString(_ v: Double) -> String { String(format: "$%.2f", v) }

private func changeColor(_ pct: Double?) -> Color {
    guard let pct, pct != 0 else { return .white }
    return pct > 0 ? .green : .red
}
#endif
