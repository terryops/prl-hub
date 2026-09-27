import SwiftUI

// MARK: - Add / edit sheet

struct AlertEditorSheet: View {
    let existing: PriceAlertRule?
    let current: Double?
    let onSave: (PriceAlertRule) -> Void
    let onDelete: (PriceAlertRule) -> Void

    private enum Mode: Hashable { case price, move }
    @State private var mode: Mode
    @State private var priceText: String
    @State private var pctText: String
    @State private var window: Int
    @Environment(\.dismiss) private var dismiss

    init(existing: PriceAlertRule?, current: Double?,
         onSave: @escaping (PriceAlertRule) -> Void, onDelete: @escaping (PriceAlertRule) -> Void) {
        self.existing = existing; self.current = current; self.onSave = onSave; self.onDelete = onDelete
        let isMove = existing?.kind == .move
        _mode = State(initialValue: isMove ? .move : .price)
        _priceText = State(initialValue: existing.flatMap { $0.kind == .move ? nil : String(format: "%.2f", $0.value) } ?? "")
        _pctText = State(initialValue: existing.flatMap { $0.kind == .move ? String(format: "%g", $0.value) : nil } ?? "10")
        _window = State(initialValue: isMove ? (existing?.window ?? 86400) : 86400)
    }

    private static func number(_ s: String) -> Double? {
        Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    /// Keep only digits and one decimal separator, with at most 2 decimals.
    static func limitDecimals(_ s: String) -> String {
        var out = "", sep = false, frac = 0
        for ch in s {
            if ch.isASCII && ch.isNumber {
                if sep { guard frac < 2 else { continue }; frac += 1 }
                out.append(ch)
            } else if (ch == "." || ch == ",") && !sep {
                sep = true
                out.append(ch)
            }
        }
        return out
    }

    /// The price rule to save, or nil while the input is invalid. The direction
    /// follows the current price: a target above it alerts on the way up.
    private var priceRule: PriceAlertRule? {
        guard let raw = Self.number(priceText) else { return nil }
        let t = PriceAlertFormat.cents(raw)
        guard t >= 0.01, t < 1_000_000 else { return nil }
        if let current, t == PriceAlertFormat.cents(current) { return nil }   // already there
        let up = current.map { t > $0 } ?? true
        return PriceAlertRule(kind: up ? .above : .below, value: t)
    }

    private var moveRule: PriceAlertRule? {
        guard let raw = Self.number(pctText) else { return nil }
        let p = PriceAlertFormat.cents(raw)
        guard p >= 0.5, p <= 1000 else { return nil }
        return PriceAlertRule(kind: .move, value: p, window: window)
    }

    /// The rule to save — an edit keeps the original id (see applyingEdit).
    private var rule: PriceAlertRule? {
        guard let r = mode == .price ? priceRule : moveRule else { return nil }
        return existing.map { $0.applyingEdit(r) } ?? r
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(Loc("类型"), selection: $mode) {
                        Text(Loc("到价提醒")).tag(Mode.price)
                        Text(Loc("涨跌幅提醒")).tag(Mode.move)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if mode == .price {
                    Section {
                        LabeledContent(Loc("目标价格")) {
                            HStack(spacing: 2) {
                                Spacer(minLength: 0)
                                // "$" hugs the number: the field sizes to its text.
                                Text("$").foregroundStyle(.secondary)
                                TextField("0.00", text: $priceText)
                                    .fixedSize()
                                    .accessibilityLabel(Loc("目标价格（USD）"))
                                    #if os(iOS)
                                    .keyboardType(.decimalPad)
                                    #endif
                            }
                        }
                        if let current {
                            LabeledContent(Loc("当前价格"), value: PriceAlertFormat.usd(current))
                        }
                    } footer: {
                        if let r = priceRule {
                            Text(r.kind == .above
                                 ? Loc("价格涨到 %@ 时通知你", PriceAlertFormat.usd(r.value))
                                 : Loc("价格跌到 %@ 时通知你", PriceAlertFormat.usd(r.value)))
                        } else {
                            Text(Loc("输入一个与当前价格不同的目标价。"))
                        }
                    }
                } else {
                    Section {
                        Picker(Loc("时间范围"), selection: $window) {
                            Text(Loc("5 分钟")).tag(300)
                            Text(Loc("1 小时")).tag(3600)
                            Text(Loc("24 小时")).tag(86400)
                        }
                        LabeledContent(Loc("涨跌幅")) {
                            HStack(spacing: 4) {
                                TextField(Loc("涨跌幅（%）"), text: $pctText)
                                    .multilineTextAlignment(.trailing)
                                    #if os(iOS)
                                    .keyboardType(.decimalPad)
                                    #endif
                                Text("%").foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        Text(moveRule == nil
                             ? Loc("请输入 0.5 到 1000 之间的百分比。")
                             : Loc("涨或跌超过这个幅度都会通知你。"))
                    }
                }

                if let existing {
                    Section {
                        Button(role: .destructive) {
                            onDelete(existing); dismiss()
                        } label: {
                            Text(Loc("删除提醒")).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: priceText) { _, v in
                let l = Self.limitDecimals(v)
                if l != v { priceText = l }
            }
            .onChange(of: pctText) { _, v in
                let l = Self.limitDecimals(v)
                if l != v { pctText = l }
            }
            .navigationTitle(existing == nil ? Loc("添加提醒") : Loc("编辑提醒"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? Loc("添加") : Loc("保存")) {
                        if let rule { onSave(rule); dismiss() }
                    }
                    .disabled(rule == nil)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}
