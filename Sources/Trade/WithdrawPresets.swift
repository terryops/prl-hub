import SwiftUI

/// List of saved USDT withdrawal addresses, for deleting ones no longer wanted.
struct PresetAddressesView: View {
    let currency: String
    @ObservedObject var store: WithdrawStore
    @ObservedObject private var book = WithdrawAddressBook.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(book.items(for: currency)) { p in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name)
                            Text(store.network(forKey: p.blockchainKey)?.name ?? p.blockchainKey)
                                .font(.caption).foregroundStyle(.secondary)
                            Text(p.address).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        #if os(macOS)
                        Button(role: .destructive) { book.remove(p.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                        #endif
                    }
                }
                .onDelete { idx in
                    let list = book.items(for: currency)
                    idx.map { list[$0].id }.forEach(book.remove)
                }
            }
            .overlay {
                if book.items(for: currency).isEmpty {
                    Text(Loc("还没有常用地址")).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(Loc("常用地址"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(Loc("完成")) { dismiss() } }
                    .noGlassBackground()
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
        #endif
    }
}
