import Foundation
import os

/// SafeTrade API credentials (personal app).
///
/// Stored in the **iCloud Keychain** (synchronizable, end-to-end encrypted) —
/// NOT UserDefaults. This keeps the user's opt-in cross-device sync while
/// fixing the previous exposure where the secret sat in plaintext UserDefaults
/// (world-readable on a non-sandboxed Mac) and in plaintext `NSUbiquitousKeyValueStore`.
/// The wallet *seed* lives in its own device-only Keychain item; these are just
/// exchange API keys. Nothing is hardcoded, so this file holds no secret.
///
/// One pair for everything: SafeTrade binds every key to a Trusted IPs list whether
/// or not it may withdraw, so a second key wouldn't dodge the IP check (requests go
/// out over IPv4 instead — see SafeTradeIPv4).
enum SafeTradeSecrets {
    // Keychain accounts (synchronizable → iCloud Keychain).
    private static let aKey = "safetrade.apikey"
    private static let aSecret = "safetrade.apisecret"
    // Legacy UserDefaults / iCloud-KVS keys to migrate away from + scrub.
    private static let legacyKeyDefault = "safetrade.apikey"
    private static let legacySecretDefault = "safetrade.apisecret"
    private static let migratedDefault = "safetrade.legacyMigrated"

    static var apiKey: String { cached(aKey) }
    static var apiSecret: String { cached(aSecret) }
    static var hasCredentials: Bool { !apiKey.isEmpty && !apiSecret.isEmpty }

    /// The pair to sign with, nil until both are set.
    static var credentials: (key: String, secret: String)? {
        hasCredentials ? (apiKey, apiSecret) : nil
    }

    // MARK: read cache

    /// Every Keychain read is a SecItemCopyMatching, and the Trade tab and Settings ask
    /// on every render — so reads are memoized. iCloud-Keychain sync posts no change
    /// notification, hence a short lifetime instead of caching until the next write.
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

    /// Forget memoized reads — after a write, or when a screen wants keys that may
    /// have just synced in from another device.
    static func invalidateCache() { cache.withLock { $0.removeAll() } }

    /// Read preferring the iCloud-synchronizable item, falling back to a device-local
    /// one. A Developer ID macOS build (no iCloud-Keychain entitlement) can't use the
    /// synchronizable keychain, so its keys live device-local — this finds them either way.
    private static func getEither(_ account: String) -> String? {
        Keychain.get(account: account, synchronizable: true)
            ?? Keychain.get(account: account, synchronizable: false)
    }

    /// Write the iCloud-synchronizable item when the platform allows it (iOS, and
    /// macOS App Store builds); if that write fails — e.g. a Developer ID macOS build
    /// that can't reach the iCloud/data-protection keychain — fall back to a
    /// device-local item so the key still saves (just not synced across devices).
    @discardableResult
    private static func setEither(_ value: String, account: String) -> Bool {
        if Keychain.set(value, account: account, synchronizable: true) {
            Keychain.delete(account: account, synchronizable: false)   // drop any stale device-local copy
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

    /// Returns false if either item failed to write to the Keychain, so the UI can
    /// report the failure instead of falsely showing "已保存".
    @discardableResult
    static func save(apiKey: String, apiSecret: String) -> Bool {
        defer { invalidateCache() }
        let okKey = setEither(apiKey, account: aKey)
        let okSecret = setEither(apiSecret, account: aSecret)
        return okKey && okSecret
    }

    static func clear() {
        defer { invalidateCache() }
        // Remove every variant (sync/non-sync × data-protection/legacy keychain) so
        // nothing reads back as "已设置" afterwards.
        Keychain.deleteAll(account: aKey)
        Keychain.deleteAll(account: aSecret)
    }

    /// One-time migration: lift any credentials saved by an older build (plaintext
    /// UserDefaults, possibly mirrored to iCloud KVS) into the iCloud Keychain,
    /// then scrub every plaintext copy (local + cloud). Called on every launch, so
    /// once it has run clean it returns before touching the Keychain — unless a
    /// plaintext copy has somehow reappeared.
    static func migrateFromLegacyIfNeeded() {
        let d = UserDefaults.standard
        let hasLegacy = d.object(forKey: legacyKeyDefault) != nil || d.object(forKey: legacySecretDefault) != nil
        guard hasLegacy || !d.bool(forKey: migratedDefault) else { return }
        let legacyKey = (d.string(forKey: legacyKeyDefault) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let legacySecret = (d.string(forKey: legacySecretDefault) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Adopt legacy values only for slots the Keychain doesn't already have.
        let k = apiKey.isEmpty ? legacyKey : apiKey
        let s = apiSecret.isEmpty ? legacySecret : apiSecret
        if !k.isEmpty, !s.isEmpty, !hasCredentials { save(apiKey: k, apiSecret: s) }
        // Scrub plaintext copies wherever they were (no-op if already clean).
        if hasLegacy {
            d.removeObject(forKey: legacyKeyDefault)
            d.removeObject(forKey: legacySecretDefault)
        }
        CloudSync.scrub([legacyKeyDefault, legacySecretDefault])
        d.set(true, forKey: migratedDefault)
    }
}
