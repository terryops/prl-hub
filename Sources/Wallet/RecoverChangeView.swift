import SwiftUI

/// Recovers "stranded change": funds the wallet sent to its own change addresses
/// that the xpub balance scan doesn't cover, so they vanish from the in-app balance.
/// Rediscovers them on-chain, proves ownership by trial-signing, and sweeps them
/// back to a destination you choose (your own address by default).
struct RecoverChangeView: View {
    @ObservedObject var store: WalletStore
    @State private var toMyWallet = true
    @State private var customDestination = ""
    @State private var working = false
    @State private var result: String?
    @State private var done = false

    private func amount(_ d: Decimal) -> String { d.formatted(.number.precision(.fractionLength(0...8))) }
    private func short(_ a: String) -> String { a.count > 18 ? "\(a.prefix(11))…\(a.suffix(6))" : a }
    private var destination: String {
        toMyWallet ? (store.address ?? "") : customDestination.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var destValid: Bool { PRLAddress.isValid(destination, network: store.network) }

    var body: some View {
        Form {
            Section {
                Text(Loc("转账产生的“找零”会退回到钱包自动生成的找零地址。这些余额已计入你的总额、也能正常花费；如需把它们归集到一个地址，可在这里一键扫回。"))
                    .font(.callout).foregroundStyle(.secondary)
            }

            if done {
                // Recovery succeeded: `recoverable` is now empty and `recoveryScanned` was
                // reset, which would otherwise flip the view to "没有发现搁浅的找零 🎉" and hide
                // the broadcast txid. Pin the success + txid here instead.
                Section {
                    if let result {
                        Text(result).font(.callout).foregroundStyle(.green).textSelection(.enabled)
                    } else {
                        Label(Loc("找回成功 ✓"), systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                    Text(Loc("交易已广播，待网络确认后即并入「钱包」余额与最近交易。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if store.recoveryScanning {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(Loc("正在扫描搁浅的找零…"))
                    }
                }
            } else if store.recoverable.isEmpty {
                Section {
                    Label(Loc("没有发现搁浅的找零 🎉"), systemImage: "checkmark.seal")
                }
                Section {
                    Button(Loc("重新扫描")) { Task { await store.scanRecoverableChange() } }
                }
            } else {
                Section(Loc("可找回 %@ PRL", amount(store.recoverableTotal))) {
                    ForEach(store.recoverable) { s in
                        HStack {
                            Text(short(s.address)).font(.footnote.monospaced())
                            Spacer()
                            Text(amount(s.valuePRL) + " PRL").foregroundStyle(.secondary)
                        }
                    }
                }

                Section(Loc("找回到")) {
                    Toggle(Loc("我的主地址"), isOn: $toMyWallet)
                    if toMyWallet {
                        if let a = store.address {
                            Text(short(a)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    } else {
                        TextField("\(store.network.addressPrefix)…", text: $customDestination)
                            .font(.body.monospaced())
                            #if os(iOS)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            #endif
                        if !customDestination.isEmpty && !destValid {
                            Text(Loc("地址格式不正确（需为 %@ 开头的 Taproot 地址）", store.network.addressPrefix))
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    Button {
                        Task {
                            working = true; result = nil
                            let r = await store.recoverChange(to: destination)
                            working = false
                            done = r.ok
                            result = r.ok ? Loc("已找回，交易已广播 ✓\n%@", r.message) : r.message
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if working { ProgressView().controlSize(.small) }
                            Text(working ? Loc("签名并广播…") : Loc("找回 %@ PRL", amount(store.recoverableTotal)))
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(working || done || !destValid)
                    .listRowBackground(Color.clear)
                } footer: {
                    Text(Loc("交易在本机签名（私钥不离开设备），合并到一笔扫回，剩余不再搁浅。"))
                }

                if let result {
                    Section {
                        Text(result)
                            .font(.callout)
                            .foregroundStyle(done ? .green : .red)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        // Same chrome as the main settings Form — without .grouped, macOS renders
        // a bare left-aligned text stack instead of inset card sections.
        .formStyle(.grouped)
        .pearlListBackground()
        .navigationTitle(Loc("找回搁浅的找零"))
        .task { if !done && !store.recoveryScanned { await store.scanRecoverableChange() } }
    }
}
