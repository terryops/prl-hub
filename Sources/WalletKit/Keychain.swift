import Foundation
import Security

/// Minimal Keychain wrapper.
///
/// Two storage classes, selected per item via `synchronizable`:
///   • `false` (default) — the wallet's at-rest seed (BIP39 mnemonic). Stored
///     `WhenUnlockedThisDeviceOnly` so it is non-exportable and excluded from
///     iCloud/backups. The seed NEVER leaves the device.
///   • `true` — non-seed secrets the user opted to sync (the SafeTrade exchange
///     API key/secret). Stored as an iCloud-Keychain item (`kSecAttrSynchronizable`,
///     `AfterFirstUnlock`), which is end-to-end encrypted by Apple — unlike the
///     plaintext `NSUbiquitousKeyValueStore` these used to live in.
enum Keychain {
    static let service = "com.pearl.native.wallet"

    #if DEBUG
    /// Screenshot-only: SHOT_MEMORY_KEYCHAIN=1 keeps every item in process memory, so a
    /// local capture run of an ad-hoc-signed Mac build never reads — or prompts for — the
    /// real wallet seed / SafeTrade keys in this Mac's keychain (the seed lives in the
    /// legacy file keychain, which any same-service lookup would hit). Never in Release.
    private static let memoryOnly = ProcessInfo.processInfo.environment["SHOT_MEMORY_KEYCHAIN"] == "1"
    private static var memory: [String: String] = [:]
    private static func memoryKey(_ account: String, _ synchronizable: Bool) -> String {
        "\(synchronizable ? "sync" : "local")|\(account)"
    }
    #endif

    private static func baseQuery(account: String, synchronizable: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Must match at lookup/delete time too: a query defaults to matching
            // ONLY non-synchronizable items, so we always pin this explicitly.
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
        // iCloud-synchronizable items live in the DATA-PROTECTION keychain. On macOS
        // that is NOT the default (the legacy file keychain is), so without this flag
        // the add and the lookup hit different keychains and the value reads back
        // empty — the "保存后仍未设置" bug. iOS already defaults to this keychain, so
        // setting it true there is a harmless no-op. Must be identical on set/get/delete.
        if synchronizable {
            query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue!
        }
        return query
    }

    @discardableResult
    static func set(_ value: String, account: String, synchronizable: Bool = false) -> Bool {
        #if DEBUG
        if memoryOnly { memory[memoryKey(account, synchronizable)] = value; return true }
        #endif
        guard let data = value.data(using: .utf8) else { return false }
        delete(account: account, synchronizable: synchronizable)
        var query = baseQuery(account: account, synchronizable: synchronizable)
        query[kSecValueData as String] = data
        // Synchronizable items cannot use a `…ThisDeviceOnly` accessibility class.
        query[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func get(account: String, synchronizable: Bool = false) -> String? {
        #if DEBUG
        if memoryOnly { return memory[memoryKey(account, synchronizable)] }
        #endif
        var query = baseQuery(account: account, synchronizable: synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    static func exists(account: String, synchronizable: Bool = false) -> Bool {
        get(account: account, synchronizable: synchronizable) != nil
    }

    @discardableResult
    static func delete(account: String, synchronizable: Bool = false) -> Bool {
        #if DEBUG
        if memoryOnly { return memory.removeValue(forKey: memoryKey(account, synchronizable)) != nil }
        #endif
        return SecItemDelete(baseQuery(account: account, synchronizable: synchronizable) as CFDictionary) == errSecSuccess
    }

    /// Remove an item in EVERY variant: synchronizable OR not, in the data-protection
    /// OR the legacy macOS keychain. A plain delete only matches one (sync, keychain)
    /// combination, so a "clear" could otherwise leave a stale copy that still reads
    /// back as set. Uses kSecAttrSynchronizableAny to match both sync states at once.
    static func deleteAll(account: String) {
        #if DEBUG
        if memoryOnly {
            memory[memoryKey(account, false)] = nil
            memory[memoryKey(account, true)] = nil
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
}
