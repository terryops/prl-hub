import Foundation
import Security

/// Minimal Keychain wrapper.
///
/// Two storage classes, selected per item via `synchronizable`:
///   • `false` (default) — the wallet's at-rest seed (BIP39 mnemonic). Stored
///     `WhenUnlockedThisDeviceOnly` in the data-protection keychain, so it is
///     non-exportable and excluded from iCloud/backups (Time Machine and Migration
///     Assistant included on macOS). The seed NEVER leaves the device.
///   • `true` — non-seed secrets the user opted to sync (the SafeTrade exchange
///     API key/secret). Stored as an iCloud-Keychain item (`kSecAttrSynchronizable`,
///     `WhenUnlocked`), which is end-to-end encrypted by Apple — unlike the
///     plaintext `NSUbiquitousKeyValueStore` these used to live in.
///
/// macOS has a second, legacy FILE keychain, where earlier builds kept the seed: an item
/// there ignores the ThisDeviceOnly class and follows the login keychain into backups.
/// `migrateLegacyItemsIfNeeded()` moves such items across; lookups still fall back to it
/// so a build that can't reach the data-protection keychain keeps working.
enum Keychain {
    static let service = "com.pearl.native.wallet"

    #if DEBUG
    /// Screenshot-only: SHOT_MEMORY_KEYCHAIN=1 keeps every item in process memory, so a
    /// local capture run of an ad-hoc-signed Mac build never reads — or prompts for — the
    /// real wallet seed / SafeTrade keys in this Mac's keychain (the seed lives in the
    /// legacy file keychain, which any same-service lookup would hit). Never in Release.
    private static let memoryOnly = ProcessInfo.processInfo.environment["SHOT_MEMORY_KEYCHAIN"] == "1"
    static var isMemoryOnly: Bool { memoryOnly }
    private static let memoryLock = NSLock()
    nonisolated(unsafe) private static var memory: [String: String] = [:]   // guarded by memoryLock
    private static func memoryKey(_ account: String, _ synchronizable: Bool) -> String {
        "\(synchronizable ? "sync" : "local")|\(account)"
    }
    private static func withMemory<T>(_ body: (inout [String: String]) -> T) -> T {
        memoryLock.lock(); defer { memoryLock.unlock() }
        return body(&memory)
    }
    #endif

    /// Where an item lives. Everything is written to the data-protection keychain; the
    /// legacy file keychain is only ever read from / cleaned up (macOS).
    private enum Store { case dataProtection, legacyFile }

    private static func baseQuery(account: String?, synchronizable: Bool, store: Store = .dataProtection) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Must match at lookup/delete time too: a query defaults to matching
            // ONLY non-synchronizable items, so we always pin this explicitly.
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        // On macOS the legacy file keychain is the DEFAULT, so without this flag an add and
        // a lookup could hit different keychains (the "保存后仍未设置" bug), and a
        // ThisDeviceOnly class would be silently ignored. iOS only has the data-protection
        // keychain, so the flag is a harmless no-op there.
        if store == .dataProtection {
            query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue!
        }
        return query
    }

    /// Synchronizable items cannot use a `…ThisDeviceOnly` accessibility class.
    private static func accessibility(synchronizable: Bool) -> CFString {
        synchronizable ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    /// Lookups that may also need the legacy file keychain (local items on macOS).
    private static func stores(synchronizable: Bool) -> [Store] {
        #if os(macOS)
        return synchronizable ? [.dataProtection] : [.dataProtection, .legacyFile]
        #else
        return [.dataProtection]
        #endif
    }

    @discardableResult
    static func set(_ value: String, account: String, synchronizable: Bool = false) -> Bool {
        #if DEBUG
        if memoryOnly { withMemory { $0[memoryKey(account, synchronizable)] = value }; return true }
        #endif
        guard let data = value.data(using: .utf8) else { return false }
        var add = baseQuery(account: account, synchronizable: synchronizable)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessibility(synchronizable: synchronizable)
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            // Update in place rather than delete-then-add: a failed add after a delete would
            // lose the only copy.
            let attrs: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: accessibility(synchronizable: synchronizable)]
            status = SecItemUpdate(baseQuery(account: account, synchronizable: synchronizable) as CFDictionary,
                                   attrs as CFDictionary)
        }
        #if os(macOS)
        if status == errSecSuccess, !synchronizable {
            // The fresh copy supersedes any legacy file-keychain one.
            SecItemDelete(baseQuery(account: account, synchronizable: false, store: .legacyFile) as CFDictionary)
        } else if status == errSecMissingEntitlement, !synchronizable {
            // A build without a keychain entitlement (ad-hoc local run) can't reach the
            // data-protection keychain at all — keep working the old way.
            return setLegacy(data, account: account)
        }
        #endif
        return status == errSecSuccess
    }

    static func get(account: String, synchronizable: Bool = false) -> String? {
        #if DEBUG
        if memoryOnly { return withMemory { $0[memoryKey(account, synchronizable)] } }
        #endif
        for store in stores(synchronizable: synchronizable) {
            if let s = read(account: account, synchronizable: synchronizable, store: store) { return s }
        }
        return nil
    }

    private static func read(account: String, synchronizable: Bool, store: Store) -> String? {
        var query = baseQuery(account: account, synchronizable: synchronizable, store: store)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Account names of every NON-synchronizable item under our service whose account
    /// starts with `prefix`. Attributes only — never reads the secret data, so it can't
    /// trigger a macOS keychain access prompt. Lets the wallet list be rebuilt from seeds
    /// that outlived the app's UserDefaults (the iOS keychain survives an uninstall).
    ///
    /// Returns nil when the keychain couldn't be queried (locked, interaction not
    /// allowed, no entitlement…), which callers must NOT read as "no items".
    static func accounts(prefix: String) -> [String]? {
        #if DEBUG
        if memoryOnly {
            return withMemory { memory in
                memory.keys.compactMap { k in
                    k.hasPrefix("local|") ? String(k.dropFirst("local|".count)) : nil
                }.filter { $0.hasPrefix(prefix) }
            }
        }
        #endif
        var all = Set<String>()
        for store in stores(synchronizable: false) {
            guard let names = accountNames(store: store) else { return nil }
            all.formUnion(names)
        }
        return all.filter { $0.hasPrefix(prefix) }.sorted()
    }

    private static func accountNames(store: Store) -> [String]? {
        var query = baseQuery(account: nil, synchronizable: false, store: store)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &items) {
        case errSecSuccess:
            let rows = items as? [[String: Any]] ?? []
            return rows.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            return nil
        }
    }

    @discardableResult
    static func delete(account: String, synchronizable: Bool = false) -> Bool {
        #if DEBUG
        if memoryOnly { return withMemory { $0.removeValue(forKey: memoryKey(account, synchronizable)) != nil } }
        #endif
        // Already absent counts as deleted: the caller's goal (no such item) holds. Every
        // store must be clear, or the value would read back on the next launch.
        return stores(synchronizable: synchronizable).allSatisfy { store in
            let status = SecItemDelete(baseQuery(account: account, synchronizable: synchronizable, store: store) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
                || (store == .dataProtection && status == errSecMissingEntitlement)
        }
    }

    /// Remove an item in EVERY variant: synchronizable OR not, in the data-protection
    /// OR the legacy macOS keychain. A plain delete only matches one (sync, keychain)
    /// combination, so a "clear" could otherwise leave a stale copy that still reads
    /// back as set. Uses kSecAttrSynchronizableAny to match both sync states at once.
    static func deleteAll(account: String) {
        #if DEBUG
        if memoryOnly {
            withMemory { $0[memoryKey(account, false)] = nil; $0[memoryKey(account, true)] = nil }
            return
        }
        #endif
        for useDataProtection in [false, true] {
            var q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            ]
            if useDataProtection { q[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue! }
            SecItemDelete(q as CFDictionary)
        }
    }

    // MARK: migration

    /// One-time upgrades of items earlier builds wrote. Safe to call on every launch.
    ///   • macOS: move local items (the seeds) out of the legacy file keychain into the
    ///     data-protection keychain. Each seed is written, read back and compared before
    ///     the legacy copy is removed; any failure leaves the legacy copy untouched.
    ///   • Synced items (SafeTrade keys) move from `AfterFirstUnlock` to `WhenUnlocked`.
    static func migrateLegacyItemsIfNeeded() {
        #if DEBUG
        if memoryOnly { return }
        #endif
        #if os(macOS)
        migrateLegacyFileItems()
        #endif
        upgradeSyncedAccessibility()
    }

    #if os(macOS)
    private static func migrateLegacyFileItems() {
        guard let legacy = accountNames(store: .legacyFile), !legacy.isEmpty else { return }
        for account in legacy {
            // A denied access prompt / locked keychain: try again next launch.
            guard let value = read(account: account, synchronizable: false, store: .legacyFile) else { continue }
            if let existing = read(account: account, synchronizable: false, store: .dataProtection) {
                // Already copied by an earlier (interrupted) run. Only a byte-identical copy
                // lets the legacy one go; a mismatch keeps both (get() prefers the new one).
                if existing == value { deleteLegacy(account) }
                continue
            }
            guard let data = value.data(using: .utf8) else { continue }
            var add = baseQuery(account: account, synchronizable: false)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = accessibility(synchronizable: false)
            let status = SecItemAdd(add as CFDictionary, nil)
            // No entitlement (ad-hoc build) or any other failure: nothing to do this launch.
            guard status == errSecSuccess else { return }
            guard read(account: account, synchronizable: false, store: .dataProtection) == value else {
                // The copy didn't read back intact — drop it, keep the original.
                SecItemDelete(baseQuery(account: account, synchronizable: false) as CFDictionary)
                continue
            }
            deleteLegacy(account)
        }
    }

    private static func deleteLegacy(_ account: String) {
        SecItemDelete(baseQuery(account: account, synchronizable: false, store: .legacyFile) as CFDictionary)
    }

    private static func setLegacy(_ data: Data, account: String) -> Bool {
        let query = baseQuery(account: account, synchronizable: false, store: .legacyFile)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessibility(synchronizable: false)
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        return status == errSecSuccess
    }
    #endif

    private static let syncedAccessibilityKey = "keychain.syncedAccessibility.v2"

    /// Synced secrets were stored `AfterFirstUnlock`, readable whenever the device had been
    /// unlocked once since boot; nothing reads them in the background, so tighten them to
    /// `WhenUnlocked`. Runs until it has succeeded once.
    private static func upgradeSyncedAccessibility() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: syncedAccessibilityKey) else { return }
        let attrs = [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        let status = SecItemUpdate(baseQuery(account: nil, synchronizable: true) as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { d.set(true, forKey: syncedAccessibilityKey) }
    }
}
