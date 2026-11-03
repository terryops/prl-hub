import SwiftUI
import Combine

// ============================================================
// 到账提醒 (remote push)
// ------------------------------------------------------------
// One PRL address (Pro). The worker (repo alerts/, src/income-watch.js)
// reads every new block and pushes when a transaction pays the address,
// from its first confirmation. Sends from the address, and the change
// they return to it, are not income.
//
// Switching it on is what sends the address to the worker; nothing is
// sent while it is off. The address follows the user over iCloud
// (`income.alert`). Getting it to the worker is PriceAlertStore's job,
// in the same device record as the price alerts and 掉线提醒.
// ============================================================

/// The address as the worker gets it, with the name the push leads with.
struct IncomeAlertWire: Codable, Equatable {
    var addr: String
    /// The wallet's or monitor's name for this address, "" if it has none.
    var label: String = ""

    var payload: [String: Any] { label.isEmpty ? ["addr": addr] : ["addr": addr, "label": label] }
}

/// What a registration says about 到账提醒: nothing (the worker keeps what it has), off, or this address.
enum IncomeAlertField: Equatable {
    case unsaid, off, on(IncomeAlertWire)
}

/// What is kept (and synced over iCloud): the address, its name, and whether the alert is on.
/// Switched off, the address stays here so it can be switched back on; only an alert that is
/// on is sent to the worker.
struct IncomeAlertSetting: Codable, Equatable {
    var addr: String
    var label: String = ""
    var on: Bool = true
}

@MainActor
final class IncomeAlertStore: ObservableObject {
    static let shared = IncomeAlertStore()

    /// iCloud-synced (CloudSync): the IncomeAlertSetting, as JSON.
    nonisolated static let key = "income.alert"

    /// The address chosen, if any, and whether its alert is on.
    @Published private(set) var setting: IncomeAlertSetting?

    /// What the worker should watch: the address, while its alert is on.
    var wire: IncomeAlertWire? {
        guard let s = setting, s.on else { return nil }
        return IncomeAlertWire(addr: s.addr, label: s.label)
    }

    private var cloudSub: AnyCancellable?

    init() {
        setting = Self.load(.standard)
        cloudSub = NotificationCenter.default.publisher(for: .cloudSyncDidUpdate).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.cloudDidUpdate() }
    }

    /// A mainnet PRL address as typed or pasted (spaces, a `pearl:` link, upper case), or nil.
    nonisolated static func normalize(_ raw: String) -> String? {
        var a = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if a.hasPrefix("pearl:") { a = String(a.dropFirst(6)) }
        if let q = a.firstIndex(of: "?") { a = String(a[..<q]) }
        return PRLAddress.isValid(a, network: .mainnet) ? a : nil
    }

    /// Watch `address` (replacing whatever was watched), switched on unless `on` says otherwise
    /// — another address picked for an alert that is off stays off, so nothing goes to the
    /// server. false if it is not a mainnet address.
    @discardableResult
    func set(address raw: String, label: String = "", on: Bool = true) -> Bool {
        guard let addr = Self.normalize(raw) else { return false }
        var name = label.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        // The worker keeps 40 UTF-16 units (as the web counts): drop whole characters until it fits.
        while name.utf16.count > 40 { name.removeLast() }
        update(IncomeAlertSetting(addr: addr, label: name, on: on), prompt: on)
        return true
    }

    /// Switch the alert for the chosen address on or off.
    func setOn(_ on: Bool) {
        guard var s = setting, s.on != on else { return }
        s.on = on
        update(s, prompt: on)
    }

    private func update(_ next: IncomeAlertSetting, prompt: Bool) {
        guard next != setting else { return }
        let sent = wire
        setting = next
        Self.store(next, defaults: .standard)
        CloudSync.push(Self.key)
        // Switching it on is the moment to ask for notifications: it is clear what for.
        if wire != sent { PriceAlertStore.shared.contentChanged(prompt: prompt) }
    }

    /// Switched on, off or to another address on another device.
    private func cloudDidUpdate() {
        let s = Self.load(.standard)
        guard s != setting else { return }
        let sent = wire
        setting = s
        if wire != sent { PriceAlertStore.shared.contentChanged(prompt: false) }
    }

    nonisolated static func load(_ d: UserDefaults) -> IncomeAlertSetting? {
        guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(IncomeAlertSetting.self, from: data),
              normalize(s.addr) == s.addr else { return nil }
        return s
    }

    nonisolated static func store(_ s: IncomeAlertSetting?, defaults d: UserDefaults) {
        if let s, let data = try? JSONEncoder().encode(s) { d.set(data, forKey: key) } else { d.removeObject(forKey: key) }
    }
}
