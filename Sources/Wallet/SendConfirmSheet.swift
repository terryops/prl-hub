import SwiftUI

/// Last look at an on-chain send, laid out like a receipt: the amount up top, then
/// where it goes (the full address in 4-character groups, to check piece by piece)
/// and what it costs (amount + network fee = total). The tx is already built and
/// signed, so the fee is the real one; an unusually high fee gets its own warning.
/// Confirming hands back to the send form, which asks for Face ID and broadcasts.
struct SendConfirmSheet: View {
    let send: PreparedSend
    /// The recipient's name in the address book, if it's saved there.
    let contactName: String?
    let network: WalletNetwork
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// The button stays tappable while the sheet animates away; one tap is one send.
    @State private var confirmed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                    hero
                    if send.feeIsHigh { highFeeWarning }

                    PearlReceiptSection(Loc("收款信息")) {
                        PearlReceiptAddress(label: Loc("收款地址"), address: send.recipient)
                        if network == .testnet {
                            Divider()
                            PearlReceiptRow(Loc("网络"), network.label)
                        }
                    }

                    PearlReceiptSection(Loc("金额")) {
                        PearlReceiptRow(Loc("发送"), Self.prl(send.amount))
                        Divider()
                        if let fee = send.fee {
                            PearlReceiptRow(Loc("网络手续费"), Self.prl(fee), tint: send.feeIsHigh ? .orange : nil)
                            Divider()
                            PearlReceiptRow(Loc("合计"), Self.prl(send.amount + fee), total: true)
                        } else {
                            PearlReceiptRow(Loc("网络手续费"), Loc("从余额扣除"))
                        }
                    }

                    PearlInfoRow(Loc("在本机签名，上链后不可撤销"), systemImage: "lock.shield")
                }
                .padding(Pearl.Space.screen)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .pearlScreenBackground()
            .safeAreaInset(edge: .bottom) {
                Button {
                    guard !confirmed else { return }
                    confirmed = true
                    onConfirm()
                } label: {
                    HStack(spacing: Pearl.Space.xs) {
                        Text(Loc("确认发送 %@ PRL", Self.number(send.amount)))
                        Image(systemName: "paperplane.fill")
                    }
                }
                .buttonStyle(.pearl)
                .frame(maxWidth: 520)
                .padding(.horizontal, Pearl.Space.screen)
                .padding(.vertical, Pearl.Space.sm)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .navigationTitle(Loc("确认转账"))
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
        .frame(minWidth: 460, minHeight: 700)
        #endif
    }

    /// The amount, big, and who it goes to when the address is a saved contact.
    private var hero: some View {
        VStack(spacing: Pearl.Space.xs) {
            PearlIconBadge(systemImage: "paperplane.fill", size: 52)
                .padding(.bottom, Pearl.Space.xxs)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: Self.number(send.amount))
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                Text(verbatim: "PRL")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            if let contactName {
                Label(Loc("发送至 %@", contactName), systemImage: "person.crop.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Pearl.Space.xs)
    }

    private var highFeeWarning: some View {
        Label {
            Text(Loc("本笔手续费明显高于平常，请确认。"))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.orange)
        .padding(Pearl.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Pearl.Radius.xs, style: .continuous))
    }

    /// Grouped like the balance (1,234.5), up to the chain's 8 decimals.
    private static func number(_ d: Decimal) -> String {
        d.formatted(.number.precision(.fractionLength(0...8)).locale(LocBundleHolder.shared.locale))
    }

    private static func prl(_ d: Decimal) -> String { "\(number(d)) PRL" }
}
