import Foundation
import Combine

/// A saved payee (address book entry). Addresses are public, non-sensitive.
struct Contact: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    var note: String = ""
}

/// Address book — persisted to UserDefaults and mirrored via iCloud (same as
/// pool watches; never holds any secret).
@MainActor
final class ContactsStore: ObservableObject {
    @Published private(set) var contacts: [Contact] = []
    static let key = "wallet.contacts"

    init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let cs = try? JSONDecoder().decode([Contact].self, from: data) else {
            contacts = []
            return
        }
        contacts = cs.compactMap { c in
            let a = c.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard PRLAddress.isValidAnyNetwork(a) else { return nil }
            return Contact(id: c.id, name: c.name, address: a, note: c.note)
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
    private func save() {
        contacts.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(contacts) { UserDefaults.standard.set(data, forKey: Self.key) }
        CloudSync.push(Self.key)   // mirror to iCloud (no-op without entitlement)
    }
    /// Re-read after an incoming iCloud change.
    func reload() { load() }

    @discardableResult
    func add(name: String, address: String, note: String = "") -> Bool {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard PRLAddress.isValidAnyNetwork(a), !contacts.contains(where: { $0.address.lowercased() == a }) else { return false }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        contacts.append(Contact(name: n.isEmpty ? shortAddr(a) : n, address: a, note: note))
        save()
        return true
    }
    func update(_ c: Contact) {
        guard let i = contacts.firstIndex(where: { $0.id == c.id }) else { return }
        let a = c.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard PRLAddress.isValidAnyNetwork(a),
              !contacts.contains(where: { $0.id != c.id && $0.address.lowercased() == a }) else { return }
        contacts[i] = Contact(id: c.id, name: c.name, address: a, note: c.note)
        save()
    }
    func remove(_ id: UUID) { contacts.removeAll { $0.id == id }; save() }

    /// Saved name for an address, if any. Addresses are stored lowercased, so the
    /// lookup must lowercase too (uppercase Bech32m is valid input).
    func name(for address: String) -> String? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return contacts.first { $0.address == a }?.name
    }
    func contains(_ address: String) -> Bool { name(for: address) != nil }
}

func shortAddr(_ a: String) -> String {
    a.count > 16 ? String(a.prefix(10)) + "…" + String(a.suffix(6)) : a
}
