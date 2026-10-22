import SwiftUI

// The parts of a confirm-before-it-leaves screen (转账确认, 确认提现): titled groups of
// label/value rows, the address laid out for checking, the bold bottom line.

/// A titled group: small caption heading above a card of rows.
struct PearlReceiptSection<Rows: View>: View {
    let title: String
    let rows: Rows

    init(_ title: String, @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { rows }
                .padding(.horizontal, Pearl.Space.md)
                .pearlCard(padding: 0, radius: Pearl.Radius.sm)
        }
    }
}

/// One line of a receipt. `total` is the bottom line (what's spent / what arrives),
/// set larger and bold; `tint` colours a value that needs a second look.
struct PearlReceiptRow: View {
    let label: String
    let value: String
    var tint: Color? = nil
    var total = false

    init(_ label: String, _ value: String, tint: Color? = nil, total: Bool = false) {
        self.label = label; self.value = value; self.tint = tint; self.total = total
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(total ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(total ? .primary : .secondary)
            Spacer(minLength: Pearl.Space.sm)
            Text(verbatim: value)
                .font(total ? .title3.weight(.bold) : .subheadline)
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(total ? 1 : nil)
                .minimumScaleFactor(total ? 0.7 : 1)
        }
        .padding(.vertical, 12)
    }
}

/// The full address in 4-character groups, to check piece by piece against the
/// receiving wallet, with the saved name (if any) beside the label. Copying goes
/// through the context menu so it yields the address itself: selecting the text would
/// copy the spaces too, which no wallet accepts.
struct PearlReceiptAddress: View {
    let label: String
    let address: String
    var name: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Pearl.Space.xs) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                if let name {
                    Text(name).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.subheadline)
            Text(groupedAddress: address)
                .font(.body.monospaced())
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            Button { copyToPasteboard(address) } label: {
                Label(Loc("复制地址"), systemImage: "doc.on.doc")
            }
        }
    }
}

extension Text {
    /// An address in 4-character groups, first and last group bold, the rest
    /// secondary — e.g. **prl1** pqvw gxsx … 2qxl **z0q9**. Lines break only at the
    /// spaces, so the system never hyphenates it (a "-" that isn't in the address).
    init(groupedAddress address: String) {
        let chars = Array(address)
        let groups = stride(from: 0, to: chars.count, by: 4).map { String(chars[$0..<min($0 + 4, chars.count)]) }
        guard groups.count > 2 else { self = Text(verbatim: address).bold(); return }
        var t = Text(verbatim: groups[0]).bold()
        for g in groups.dropFirst().dropLast() { t = t + Text(verbatim: " " + g).foregroundColor(.secondary) }
        self = t + Text(verbatim: " " + groups[groups.count - 1]).bold()
    }
}
