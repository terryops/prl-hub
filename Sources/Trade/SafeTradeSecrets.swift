import Foundation

/// SafeTrade API credentials (personal app).
///
/// Stored in the **iCloud Keychain** (synchronizable, end-to-end encrypted) —
/// NOT UserDefaults. This keeps the user's opt-in cross-device sync while
/// fixing the previous exposure where the secret sat in plaintext UserDefaults
/// (world-readable on a non-sandboxed Mac) and in plaintext `NSUbiquitousKeyValueStore`.
/// The wallet *seed* lives in its own device-only Keychain item; these are just
/// exchange API keys. Nothing is hardcoded, so this file holds no secret.
enum SafeTradeSecrets {
    // Keychain accounts (synchronizable → iCloud Keychain).
    private static let aKey = "safetrade.apikey"
    private static let aSecret = "safetrade.apisecret"
    // Legacy UserDefaults / iCloud-KVS keys to migrate away from + scrub.
    private static let legacyKeyDefault = "safetrade.apikey"
    private static let legacySecretDefault = "safetrade.apisecret"

    static var apiKey: String { getEither(aKey) ?? "" }
    static var apiSecret: String { getEither(aSecret) ?? "" }
    static var hasCredentials: Bool { !apiKey.isEmpty && !apiSecret.isEmpty }

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
        let okKey = setEither(apiKey, account: aKey)
        let okSecret = setEither(apiSecret, account: aSecret)
        return okKey && okSecret
    }

    static func clear() {
        // Remove every variant (sync/non-sync × data-protection/legacy keychain) so
        // nothing reads back as "已设置" afterwards.
        Keychain.deleteAll(account: aKey)
        Keychain.deleteAll(account: aSecret)
    }

    /// One-time migration: lift any credentials saved by an older build (plaintext
    /// UserDefaults, possibly mirrored to iCloud KVS) into the iCloud Keychain,
    /// then scrub every plaintext copy (local + cloud). Safe to call on every
    /// launch — it no-ops once the legacy copies are gone.
    static func migrateFromLegacyIfNeeded() {
        let d = UserDefaults.standard
        let legacyKey = (d.string(forKey: legacyKeyDefault) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let legacySecret = (d.string(forKey: legacySecretDefault) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Adopt legacy values only for slots the Keychain doesn't already have.
        let k = apiKey.isEmpty ? legacyKey : apiKey
        let s = apiSecret.isEmpty ? legacySecret : apiSecret
        if !k.isEmpty, !s.isEmpty, !hasCredentials { save(apiKey: k, apiSecret: s) }
        // Scrub plaintext copies wherever they were (no-op if already clean).
        if d.object(forKey: legacyKeyDefault) != nil || d.object(forKey: legacySecretDefault) != nil {
            d.removeObject(forKey: legacyKeyDefault)
            d.removeObject(forKey: legacySecretDefault)
        }
        CloudSync.scrub([legacyKeyDefault, legacySecretDefault])
    }
}
