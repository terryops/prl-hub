import SwiftUI

/// Where in-app donations go. The wallet-page entry stays hidden until `address`
/// holds a valid mainnet address, so an unset address can never receive a send.
enum Donation {
    static let address = "prl1p8wznc8tkhlkjaq7v8ycugz93rgs8uezq6px7873934kh35nk9q2qlz0q9m"
    static let presets: [Decimal] = [10, 20, 50]
    /// Smallest custom amount accepted.
    static let minimum: Decimal = 1
    static var isConfigured: Bool { PRLAddress.isValid(address, network: .mainnet) }
}

/// One-time automatic donation ask: after the app has been opened 10 times over at least
/// 5 days (the same launch counters as `ReviewPrompt`). Shown once, ever.
enum DonationPrompt {
    static let minLaunches = 10
    static let minDaysInstalled: Double = 5
    private static let shownKey = "donate.prompted"

    static var isEligible: Bool {
        Donation.isConfigured
            && !UserDefaults.standard.bool(forKey: shownKey)
            && ReviewPrompt.launchCount >= minLaunches
            && ReviewPrompt.daysSinceFirstLaunch >= minDaysInstalled
    }

    static func markShown() { UserDefaults.standard.set(true, forKey: shownKey) }
}

/// "Support the developer": pick a preset amount (or type one), confirm, and it is
/// signed on-device and broadcast like any other send — same Face ID gate, same fee reserve.
struct DonateView: View {
    @ObservedObject var store: WalletStore
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""
    @State private var confirming: Decimal?
    @State private var sending = false
    @State private var error: String?
    /// The custom-amount field stays tucked away until asked for — presets are the default.
    @State private var showingCustom = false
    @FocusState private var customFocused: Bool

    private var customAmount: Decimal? { PRLAmount.parse(custom).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Pearl.Space.lg) {
                    VStack(spacing: Pearl.Space.sm) {
                        PearlIconBadge(systemImage: "heart.fill", gradient: Pearl.sunrise, size: 56)
                        Text(Loc("喜欢 Pearl Hub？请开发者喝杯咖啡"))
                            .font(.headline).multilineTextAlignment(.center)
                        PearlBadge(text: Loc("开源项目 · GPL-3.0"),
                                   systemImage: "chevron.left.forwardslash.chevron.right", tint: Pearl.accent)
                        Text(Loc("Pearl Hub 是免费的开源项目，全部代码公开在 GitHub，没有广告和追踪。你的捐赠会直接支持它持续更新。"))
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Link(destination: AppLinks.github) {
                            Label(Loc("在 GitHub 查看源码"), systemImage: "arrow.up.right.square")
                        }
                        .font(.callout.weight(.medium))
                    }

                    HStack(spacing: Pearl.Space.sm) {
                        ForEach(Donation.presets, id: \.self) { amount in
                            Button { confirming = amount } label: {
                                Text(verbatim: "\(Self.text(amount)) PRL")
                                    .font(.headline.monospacedDigit())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, Pearl.Space.xs)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(sending || !canAfford(amount))
                        }
                    }

                    if showingCustom {
                        HStack(spacing: Pearl.Space.sm) {
                            TextField(Loc("自定义金额（最少 %@ PRL）", Self.text(Donation.minimum)), text: $custom)
                                .textFieldStyle(.roundedBorder)
                                .font(.body.monospacedDigit())
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                                .focused($customFocused)
                                .onAppear { customFocused = true }
                                .onChange(of: custom) { _, _ in error = nil }
                            Button(Loc("捐赠")) {
                                if let a = customAmount { confirming = a }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(sending || !(customAmount.map(canAfford) ?? false))
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        if let a = customAmount, a < Donation.minimum {
                            Text(Loc("自定义金额最少 %@ PRL", Self.text(Donation.minimum)))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Button { withAnimation(.snappy) { showingCustom = true } } label: {
                            Text(Loc("自定义金额"))
                                .font(.footnote)
                                .underline()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(sending)
                    }

                    VStack(spacing: Pearl.Space.xxs) {
                        Text(Loc("可用余额 %@ PRL", store.balance.available.formatted(.number.precision(.fractionLength(0...8)))))
                        Text(Loc("开发者地址 %@", shortAddr(Donation.address)))
                            .font(.caption.monospaced())
                    }
                    .font(.caption).foregroundStyle(.secondary)

                    Text(Loc("捐赠会从当前钱包直接转到开发者地址，在本机签名并广播，手续费从余额扣除。"))
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if sending {
                        ProgressView(Loc("签名并广播…"))
                    }
                    if let error {
                        Label(error, systemImage: "xmark.octagon")
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .padding(Pearl.Space.screen)
                .frame(maxWidth: 460)
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: sending)
                .animation(.snappy, value: error)
            }
            .navigationTitle(Loc("支持开发者"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc("关闭")) { dismiss() }
                }
            }
            // .alert (not .confirmationDialog): centered on every platform — see SendView.
            .alert(Loc("确认捐赠"), isPresented: Binding(
                get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
                if let amount = confirming {
                    Button(Loc("确认捐赠 %@ PRL", Self.text(amount))) { donate(amount) }
                }
                Button(Loc("取消"), role: .cancel) { confirming = nil }
            } message: {
                Text(Loc("向开发者地址\n%@\n捐赠 %@ PRL。手续费从余额扣除，交易不可撤销。",
                         Donation.address, Self.text(confirming ?? 0)))
            }
        }
        #if os(iOS)
        .presentationDetents([.fraction(0.8), .large])
        #endif
    }

    private func canAfford(_ amount: Decimal) -> Bool {
        amount >= Donation.minimum && amount + WalletStore.sendFeeReserve <= store.balance.available
    }

    private func donate(_ amount: Decimal) {
        confirming = nil
        sending = true
        error = nil
        Task {
            let r = await store.send(to: Donation.address, amountPRL: amount)
            sending = false
            if r.ok {
                store.flashToast(Loc("感谢支持 ❤️"))
                dismiss()
                await store.loadChain()
            } else {
                error = r.message
            }
        }
    }

    private static func text(_ amount: Decimal) -> String { NSDecimalNumber(decimal: amount).stringValue }
}
