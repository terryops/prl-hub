import SwiftUI

/// Final check before a withdrawal, laid out like a receipt: the amount maths
/// (amount − fee = received) in one group, where it goes (network + address) in
/// another, then the warning and a pinned confirm button. The address is split
/// into 4-character groups — first and last in bold — so it can be checked
/// piece by piece against the receiving wallet.
struct WithdrawConfirmSheet: View {
    let amount: String
    let fee: String
    let received: String
    let unit: String
    let network: String?
    let address: String
    let addressName: String?
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                    section(Loc("金额")) {
                        row(Loc("提现数量"), amount)
                        Divider()
                        row(Loc("手续费"), "− " + fee)
                        Divider()
                        HStack(alignment: .firstTextBaseline) {
                            Text(Loc("实际到账")).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(verbatim: "\(received) \(unit)")
                                .font(.title3.weight(.bold)).monospacedDigit()
                        }
                        .padding(.vertical, 12)
                    }

                    section(Loc("收款信息")) {
                        if let network {
                            row(Loc("网络"), network)
                            Divider()
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(Loc("收款地址")).foregroundStyle(.secondary)
                                Spacer()
                                if let addressName {
                                    Text(addressName).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .font(.subheadline)
                            groupedAddress
                                .font(.body.monospaced())
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 12)
                    }

                    Label {
                        Text(Loc("链上转账无法撤回，请核对地址和网络。"))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(Pearl.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Pearl.Radius.xs, style: .continuous))
                }
                .padding(Pearl.Space.screen)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button { dismiss(); onConfirm() } label: { Text(Loc("确认提现")) }
                    .buttonStyle(.pearl(Pearl.brand))
                    .frame(maxWidth: 520)
                    .padding(.horizontal, Pearl.Space.screen)
                    .padding(.vertical, Pearl.Space.sm)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            .navigationTitle(Loc("确认提现"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Loc("取消")) { dismiss() } }
                    .noGlassBackground()
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 420, minHeight: 520)
        #endif
    }

    /// A titled group: small caption heading above a card of rows.
    private func section<Rows: View>(_ title: String, @ViewBuilder _ rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { rows() }
                .padding(.horizontal, Pearl.Space.md)
                .pearlCard(padding: 0, radius: Pearl.Radius.sm)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(verbatim: value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .padding(.vertical, 12)
    }

    /// The address in 4-character groups, first and last group bold, the rest
    /// secondary — e.g. **prl1** pqvw gxsx … 2qxl **z0q9m**.
    private var groupedAddress: Text {
        let chars = Array(address)
        let groups = stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }
        guard groups.count > 2 else { return Text(verbatim: address).bold() }
        var t = Text(verbatim: groups[0]).bold()
        for g in groups.dropFirst().dropLast() { t = t + Text(verbatim: " " + g).foregroundColor(.secondary) }
        return t + Text(verbatim: " " + groups[groups.count - 1]).bold()
    }
}
