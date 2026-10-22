import SwiftUI

/// Final check before a withdrawal, laid out like a receipt: the amount maths
/// (amount − fee = received) in one group, where it goes (network + address) in
/// another, then the warning and a pinned confirm button. The address is split
/// into 4-character groups (`PearlReceiptAddress`) so it can be checked piece by
/// piece against the receiving wallet.
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
    /// The button stays tappable while the sheet animates away; one tap is one withdrawal.
    @State private var confirmed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                    PearlReceiptSection(Loc("金额")) {
                        PearlReceiptRow(Loc("提现数量"), amount)
                        Divider()
                        PearlReceiptRow(Loc("手续费"), "− " + fee)
                        Divider()
                        PearlReceiptRow(Loc("实际到账"), "\(received) \(unit)", total: true)
                    }

                    PearlReceiptSection(Loc("收款信息")) {
                        if let network {
                            PearlReceiptRow(Loc("网络"), network)
                            Divider()
                        }
                        PearlReceiptAddress(label: Loc("收款地址"), address: address, name: addressName)
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
                Button {
                    guard !confirmed else { return }
                    confirmed = true
                    dismiss(); onConfirm()
                } label: { Text(Loc("确认提现")) }
                    .buttonStyle(.pearl)
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
}
