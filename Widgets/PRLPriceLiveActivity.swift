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
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PriceActivityAttributes.self) { context in
            Group {
                if context.attributes.resolvedStyle == .island {
                    LockScreenStrip(state: context.state, label24h: context.attributes.label24h)
                } else {
                    LockScreenPriceView(attributes: context.attributes, state: context.state, stale: context.isStale)
                }
            }
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
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
                        .foregroundStyle(Color.pearlGold)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        ChangePill(label: context.attributes.label1h, pct: s.change1h)
                        ChangePill(label: context.attributes.label24h, pct: s.change24h)
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
            .keylineTint(Color.pearlIndigo)
        }
    }
}

private struct LockScreenPriceView: View {
    let attributes: PriceActivityAttributes
    let state: PriceActivityAttributes.ContentState
    let stale: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            PearlGlyph(size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(attributes.title).font(.caption).foregroundStyle(.white.opacity(0.7))
                Text(verbatim: usdString(state.usd))
                    .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                ChangePill(label: attributes.label1h, pct: state.change1h)
                ChangePill(label: attributes.label24h, pct: state.change24h)
                Text(Date(timeIntervalSince1970: state.at), style: .time)
                    .font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(16)
        .opacity(stale ? 0.6 : 1)
    }
}

/// 灵动岛为主: the Lock Screen part shrinks to one quiet line.
private struct LockScreenStrip: View {
    let state: PriceActivityAttributes.ContentState
    let label24h: String
    var body: some View {
        HStack(spacing: 8) {
            PearlGlyph(size: 18)
            Text(verbatim: "PRL").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.8))
            Text(verbatim: usdString(state.usd))
                .font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(.white)
            Spacer(minLength: 4)
            ChangePill(label: label24h, pct: state.change24h)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

/// "1h +2.35%" — label dimmed, figure in green/red.
private struct ChangePill: View {
    let label: String
    let pct: Double?
    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.white.opacity(0.6))
            Text(verbatim: pct.map { String(format: "%+.2f%%", $0) } ?? "—")
                .foregroundStyle(changeColor(pct)).monospacedDigit()
        }
        .font(.caption.weight(.semibold))
    }
}

/// The app's pearl symbol in the brand gradient.
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
