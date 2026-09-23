import Foundation
import Combine

/// A saved (preset) withdrawal destination for a non-PRL coin — PRL payees live
/// in the wallet's own address book (ContactsStore). Public data only.
struct WithdrawAddress: Identifiable, Codable, Hashable {
    var id = UUID()
    var currency: String          // "usdt"
    var blockchainKey: String     // chain it was saved for, e.g. "bsc-tokens"
    var address: String
    var name: String
}

/// Preset withdrawal addresses, persisted to UserDefaults and mirrored via iCloud
/// like the wallet contacts (`safetrade.withdrawAddresses`).
@MainActor
final class WithdrawAddressBook: ObservableObject {
    static let shared = WithdrawAddressBook()
    static let key = "safetrade.withdrawAddresses"
    @Published private(set) var items: [WithdrawAddress] = []

    private var syncObserver: AnyCancellable?

    private init() {
        load()
        syncObserver = NotificationCenter.default.publisher(for: .cloudSyncDidUpdate)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.load() }
    }

    func items(for currency: String) -> [WithdrawAddress] { items.filter { $0.currency == currency } }

    func contains(currency: String, blockchainKey: String, address: String) -> Bool {
        items.contains { $0.currency == currency && $0.blockchainKey == blockchainKey && $0.address == address }
    }

    func add(currency: String, blockchainKey: String, address: String, name: String) {
        guard !contains(currency: currency, blockchainKey: blockchainKey, address: address) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        items.append(WithdrawAddress(currency: currency, blockchainKey: blockchainKey,
                                     address: address, name: n.isEmpty ? shortAddr(address) : n))
        save()
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let list = try? JSONDecoder().decode([WithdrawAddress].self, from: data) else { items = []; return }
        items = list
    }

    private func save() {
        items.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: Self.key) }
        CloudSync.push(Self.key)
    }
}
