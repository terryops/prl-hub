import SwiftUI

/// Address book — list, add, edit, delete saved payees. Styled like the rest of
/// the app (section header + frosted card rows), not a bare system List.
struct ContactsView: View {
    @EnvironmentObject private var contacts: ContactsStore
    @State private var editing: ContactDraft?
    @State private var copiedID: UUID?   // row whose address was just copied (✓ flash)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Pearl.Space.lg) {
                PearlSectionHeader(Loc("地址簿"), systemImage: "person.2.fill",
                                   subtitle: contacts.contacts.isEmpty
                                       ? Loc("保存常用收款地址，转账时一键选择。")
                                       : Loc("%@ 位联系人 · 转账时一键选择", "\(contacts.contacts.count)"))
                if contacts.contacts.isEmpty {
                    PearlEmptyState(systemImage: "person.crop.circle.badge.plus",
                                    title: Loc("暂无联系人"),
                                    message: Loc("保存常用收款地址，转账时一键选择。")) {
                        Button { editing = ContactDraft() } label: {
                            Label(Loc("添加"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 0) {
                        ForEach(contacts.contacts) { c in
                            row(c)
                            if c.id != contacts.contacts.last?.id {
                                Divider().padding(.leading, 36 + Pearl.Space.sm * 2)
                            }
                        }
                    }
                    .pearlCard(padding: Pearl.Space.sm)
                }
            }
            .animation(.snappy, value: contacts.contacts)
            .padding(Pearl.Space.screen).frame(maxWidth: 860).frame(maxWidth: .infinity)
        }
        .navigationTitle(Loc("地址簿"))
        .toolbar { Button { editing = ContactDraft() } label: { Label(Loc("添加"), systemImage: "plus") } }
        .sheet(item: $editing) { ContactEditor(draft: $0) }
    }

    @ViewBuilder private func row(_ c: Contact) -> some View {
        HStack(spacing: Pearl.Space.sm) {
            PearlIconBadge(systemImage: "person.fill", size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(c.name).font(.body.weight(.medium)).lineLimit(1)
                    if !c.note.isEmpty {
                        Text(c.note).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                }
                Text(c.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Pearl.Space.sm)
            Button {
                copyToPasteboard(c.address)
                flashCopied(c.id)
            } label: {
                Image(systemName: copiedID == c.id ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copiedID == c.id ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Loc("复制地址"))
            Button { editing = ContactDraft(c) } label: {
                Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Loc("编辑联系人"))
        }
        .padding(Pearl.Space.sm)
        .contentShape(Rectangle())
        .onTapGesture { editing = ContactDraft(c) }
        .contextMenu {
            Button { copyToPasteboard(c.address) } label: { Label(Loc("复制地址"), systemImage: "doc.on.doc") }
            Button { editing = ContactDraft(c) } label: { Label(Loc("编辑联系人"), systemImage: "square.and.pencil") }
            Button(role: .destructive) { contacts.remove(c.id) } label: { Label(Loc("删除"), systemImage: "trash") }
        }
    }

    private func flashCopied(_ id: UUID) {
        withAnimation(.snappy) { copiedID = id }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if copiedID == id { withAnimation(.snappy) { copiedID = nil } }
        }
    }
}

/// Mutable working copy for the add/edit sheet (Identifiable for `.sheet(item:)`).
struct ContactDraft: Identifiable {
    let id = UUID()
    var contactID: UUID?
    var name = ""
    var address = ""
    var note = ""
    init(prefillAddress: String = "") { address = prefillAddress }
    init(_ c: Contact) { contactID = c.id; name = c.name; address = c.address; note = c.note }
}

struct ContactEditor: View {
    @EnvironmentObject private var contacts: ContactsStore
    @Environment(\.dismiss) private var dismiss
    @State var draft: ContactDraft

    private var addr: String { draft.address.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section(Loc("名称")) {
                    TextField(Loc("如：交易所 / 朋友"), text: $draft.name)
                        #if os(iOS)
                        .autocorrectionDisabled()
                        #endif
                }
                Section(Loc("地址")) {
                    TextField("prl1…", text: $draft.address)
                        .font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        #endif
                }
                Section(Loc("备注（可选）")) { TextField(Loc("备注"), text: $draft.note) }
                // Deleting lives here (not a swipe) since the list is custom cards.
                if let id = draft.contactID {
                    Section {
                        Button(role: .destructive) {
                            contacts.remove(id)
                            dismiss()
                        } label: {
                            HStack { Spacer(); Text(Loc("删除联系人")); Spacer() }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .pearlListBackground()
            .navigationTitle(draft.contactID == nil ? Loc("新增联系人") : Loc("编辑联系人"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Loc("取消")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Loc("保存")) {
                        if let id = draft.contactID {
                            contacts.update(Contact(id: id, name: draft.name, address: addr, note: draft.note))
                        } else {
                            contacts.add(name: draft.name, address: addr, note: draft.note)
                        }
                        dismiss()
                    }
                    .disabled(!PRLAddress.isValidAnyNetwork(addr))
                }
            }
            .frame(minWidth: 360, minHeight: 260)
        }
    }
}
