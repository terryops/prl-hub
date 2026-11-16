import Foundation
import os

/// Gate API v4 credentials.
///
/// Stored in the **iCloud Keychain** (synchronizable, end-to-end encrypted) with
/// device-local Keychain fallback on builds without the synchronizable entitlement,
/// matching `SafeTradeSecrets`. Never stored in UserDefaults or iCloud KVS.
enum GateSecrets {
    private static let aKey = "gate.apikey"
    private static let aSecret = "gate.apisecret"

    static var apiKey: String { cached(aKey) }
    static var apiSecret: String { cached(aSecret) }
    static var hasCredentials: Bool { !apiKey.isEmpty && !apiSecret.isEmpty }

    static var credentials: (key: String, secret: String)? {
        hasCredentials ? (apiKey, apiSecret) : nil
    }

    private static let cache = OSAllocatedUnfairLock<[String: CachedValue]>(initialState: [:])
    private struct CachedValue: Sendable { let value: String; let at: Date }
    private static let cacheLifetime: TimeInterval = 30

    private static func cached(_ account: String) -> String {
        let now = Date()
        if let hit = cache.withLock({ $0[account] }), now.timeIntervalSince(hit.at) < cacheLifetime {
            return hit.value
        }
        let value = getEither(account) ?? ""
        cache.withLock { $0[account] = CachedValue(value: value, at: now) }
        return value
    }

    static func invalidateCache() { cache.withLock { $0.removeAll() } }

    private static func getEither(_ account: String) -> String? {
        Keychain.get(account: account, synchronizable: true)
            ?? Keychain.get(account: account, synchronizable: false)
    }

    @discardableResult
    private static func setEither(_ value: String, account: String) -> Bool {
        if Keychain.set(value, account: account, synchronizable: true) {
            Keychain.delete(account: account, synchronizable: false)
            return true
        }
        return Keychain.set(value, account: account, synchronizable: false)
    }

    static var maskedKey: String {
        let k = apiKey
        guard !k.isEmpty else { return Loc("未设置") }
        guard k.count > 6 else { return "••••" }
        return k.prefix(4) + "••••" + k.suffix(2)
    }

    @discardableResult
    static func save(apiKey: String, apiSecret: String) -> Bool {
        defer { invalidateCache() }
        let okKey = setEither(apiKey, account: aKey)
        let okSecret = setEither(apiSecret, account: aSecret)
        return okKey && okSecret
    }

    static func clear() {
        defer { invalidateCache() }
        Keychain.deleteAll(account: aKey)
        Keychain.deleteAll(account: aSecret)
    }
}
