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
/// Two pairs: the trading key (balances, orders — required) and an optional
/// withdraw-only key. SafeTrade only lets a key withdraw once it has a Trusted IPs
/// list, and that list then gates EVERY call the key makes — so a phone, whose IP
/// changes with the network (and flips between IPv4 and IPv6), kept getting
/// `authz.*trusted*ip` on the Trade tab. Keeping the IP-bound key for withdrawals
/// only leaves trading on a key without an IP list.
enum SafeTradeSecrets {
    /// Which stored pair a request signs with.
    enum Role: Sendable { case trading, withdraw }

    // Keychain accounts (synchronizable → iCloud Keychain).
    private static let aKey = "safetrade.apikey"
    private static let aSecret = "safetrade.apisecret"
    private static let aWithdrawKey = "safetrade.withdraw.apikey"
    private static let aWithdrawSecret = "safetrade.withdraw.apisecret"
    // Legacy UserDefaults / iCloud-KVS keys to migrate away from + scrub.
    private static let legacyKeyDefault = "safetrade.apikey"
    private static let legacySecretDefault = "safetrade.apisecret"
    private static let migratedDefault = "safetrade.legacyMigrated"

    static var apiKey: String { cached(aKey) }
    static var apiSecret: String { cached(aSecret) }
    static var hasCredentials: Bool { !apiKey.isEmpty && !apiSecret.isEmpty }

    static var withdrawKey: String { cached(aWithdrawKey) }
    static var withdrawSecret: String { cached(aWithdrawSecret) }
    static var hasWithdrawCredentials: Bool { !withdrawKey.isEmpty && !withdrawSecret.isEmpty }

    /// The pair to sign with: withdrawals prefer the withdraw-only key and fall back
    /// to the trading key (so a single key that may do both keeps working).
    static func credentials(for role: Role) -> (key: String, secret: String)? {
        if role == .withdraw, hasWithdrawCredentials { return (withdrawKey, withdrawSecret) }
        return hasCredentials ? (apiKey, apiSecret) : nil
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

    static var maskedKey: String { mask(apiKey) }
    static var maskedWithdrawKey: String { mask(withdrawKey) }

    private static func mask(_ k: String) -> String {
        guard !k.isEmpty else { return Loc("未设置") }
        guard k.count > 6 else { return "••••" }
        return k.prefix(4) + "••••" + k.suffix(2)
    }

    /// Returns false if either item failed to write to the Keychain, so the UI can
    /// report the failure instead of falsely showing "已保存".
    @discardableResult
    static func save(apiKey: String, apiSecret: String, role: Role = .trading) -> Bool {
        defer { invalidateCache() }
        let okKey = setEither(apiKey, account: role == .trading ? aKey : aWithdrawKey)
        let okSecret = setEither(apiSecret, account: role == .trading ? aSecret : aWithdrawSecret)
        return okKey && okSecret
    }

    /// Remove both pairs (the last wallet is gone → de-provision the exchange entirely).
    static func clear() {
        clear(role: .trading)
        clear(role: .withdraw)
    }

    static func clear(role: Role) {
        defer { invalidateCache() }
        // Remove every variant (sync/non-sync × data-protection/legacy keychain) so
        // nothing reads back as "已设置" afterwards.
        Keychain.deleteAll(account: role == .trading ? aKey : aWithdrawKey)
        Keychain.deleteAll(account: role == .trading ? aSecret : aWithdrawSecret)
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
