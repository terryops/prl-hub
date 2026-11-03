import SwiftUI

/// Top of the wallet page while the App Store has a newer version (see `UpdateChecker`):
/// tap anywhere on it for the App Store, × to stop showing this version.
struct UpdateBanner: View {
    let version: String
    var surface: Color? = nil
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: Pearl.Space.xs) {
            Button { openURL(UpdateChecker.storeURL) } label: {
                HStack(spacing: Pearl.Space.sm) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Pearl.accent)
                        .accessibilityHidden(true)
                    Text(Loc("有新版本 %@", version)).font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(Loc("更新"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Pearl.accent, in: Capsule())
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { withAnimation(.snappy) { UpdateChecker.shared.dismiss() } } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Loc("不再提示这个版本"))
        }
        .pearlCard(padding: Pearl.Space.md, radius: Pearl.Radius.md, frosted: true, surface: surface)
    }
}
