import Foundation

extension Notification.Name {
    static let cloudSyncDidUpdate = Notification.Name("cloudSyncDidUpdate")
}

/// Mirrors an allow-list of UserDefaults keys to iCloud key-value storage
/// (NSUbiquitousKeyValueStore) so config follows the user across their devices.
///
/// Values may be any property-list type (String / Data / Number / Bool / Array /
/// Dictionary) — so numeric + boolean preferences (electricity cost, fees, mode
/// toggles…) sync just like the JSON blobs do.
///
/// The wallet SEED is NEVER synced (it lives in the device-only Keychain). The
/// SafeTrade API key/secret are NOT synced here either — they live in the iCloud
/// Keychain (end-to-end encrypted), NOT this plaintext key-value store. Only
/// non-secret config travels through here.
/// Gracefully no-ops if the iCloud (KVS) entitlement isn't provisioned.
enum CloudSync {
    /// Allow-list of UserDefaults keys mirrored to iCloud. Live market-derived
    /// numbers (PRL 币价 / 全网算力 / 单位日产 = prl.price/neth/pu/diffConst) are
    /// intentionally absent — each device refetches them, so syncing would only
    /// churn the cloud store on every refresh. They're still saved locally.
    static let syncedKeys = [
        // pool monitor
        "pool.watches",
        // exchange / trade — NON-secret only. The API key/secret are stored in the
        // iCloud Keychain (E2E-encrypted), never in this plaintext KVS.
        "safetrade.market", "safetrade.period", "safetrade.withdrawAddresses",
        // wallet — non-secret meta only (the seed stays in the Keychain)
        "wallet.name", "wallet.network", "wallet.contacts",
        // app appearance / language / currency
        "ui.appearance", "app.language", "currency.secondary",
        // PRL mining monitor — user config (NOT the live-fetched market numbers).
        // prl.fx is intentionally NOT synced: each device derives its own 1-USD→local
        // rate from ITS own secondary currency. prl.rentCcy tags the currency the
        // synced rents are denominated in so a receiving device converts correctly.
        "prl.devices", "prl.rents", "prl.rentCcy", "prl.elec", "prl.fee", "prl.fxManual", "prl.budget",
        "prl.live", "prl.rentEnabled", "prl.rentCovers", "prl.auto", "prl.sort",
        // prl.diffGrowth is intentionally NOT synced: in live mode each device auto-derives
        // it from its own difficulty feed, so syncing clobbered another device's manual
        // what-if (same reason the live market numbers above aren't synced).
        "prl.selected", "prl.selfDilution", "prl.syncW",
    ]
    private static let kvs = NSUbiquitousKeyValueStore.default
    private static let tombstoneSuffix = ".__deleted"
    private static var started = false

    static func start(preferLocalKeys: [String] = []) {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvs, queue: .main
        ) { note in
            // Ignore AccountChange (iCloud sign-out / Apple-ID switch): the KVS is
            // replaced with a DIFFERENT account's data, so adopting it would overwrite
            // this device's local config (wallet name/network, address book, devices)
            // with another identity's values. Only adopt real server/initial syncs.
            if let reason = (note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? NSNumber)?.intValue,
               reason == NSUbiquitousKeyValueStoreAccountChange {
                return
            }
            pullToLocal(changedKeys(note))
        }
        kvs.synchronize()
        // Some locally-entered values (notably SafeTrade keys) may predate iCloud
        // provisioning. Push those before the initial pull so stale cloud values or
        // tombstones cannot erase the only current local copy on first launch.
        ensurePushed(preferLocalKeys)
        // Initial pull so a device that already has iCloud data adopts it.
        pullToLocal(syncedKeys)
    }

    /// Re-pull the latest from iCloud. Call when the app returns to the
    /// foreground so a value saved on another device shows up here without a
    /// relaunch.
    static func refresh() {
        guard started else { start(); return }
        kvs.synchronize()
        pullToLocal(syncedKeys)
    }

    /// Upload this device's locally-stored values for `keys` to iCloud, but only
    /// when a non-empty value exists (never wipes the cloud copy). Self-heals a
    /// value saved before the iCloud entitlement was provisioned and so never
    /// actually got uploaded — e.g. SafeTrade API keys saved long ago.
    static func ensurePushed(_ keys: [String]) {
        let d = UserDefaults.standard
        var pushedAny = false
        for key in keys where syncedKeys.contains(key) {
            guard let value = d.object(forKey: key) else { continue }
            if let s = value as? String, s.isEmpty { continue }
            if let data = value as? Data, data.isEmpty { continue }
            if plistEqual(kvs.object(forKey: key), value) { continue }
            kvs.set(value, forKey: key)
            kvs.removeObject(forKey: tombstoneKey(key))
            pushedAny = true
        }
        if pushedAny { kvs.synchronize() }
    }

    /// Push a locally-changed key up to iCloud. No-ops when the cloud copy already
    /// matches, so it's safe to call from a frequently-fired `didSet`/`savePrefs`.
    static func push(_ key: String) {
        guard syncedKeys.contains(key) else { return }
        let d = UserDefaults.standard
        if let value = d.object(forKey: key) {
            if plistEqual(kvs.object(forKey: key), value) { return }   // already current — avoid churn
            kvs.set(value, forKey: key)
            kvs.removeObject(forKey: tombstoneKey(key))
        } else {
            kvs.removeObject(forKey: key)
            kvs.set(Date().timeIntervalSince1970, forKey: tombstoneKey(key))
        }
        kvs.synchronize()
    }

    /// Hard-remove `keys` (and their tombstones) from the iCloud KVS — used to
    /// scrub secrets an older build left there in plaintext. Removes the raw
    /// object WITHOUT writing a tombstone, so a not-yet-updated device keeps its
    /// own local copy rather than having it deleted out from under it.
    static func scrub(_ keys: [String]) {
        var removedAny = false
        for key in keys {
            if kvs.object(forKey: key) != nil { kvs.removeObject(forKey: key); removedAny = true }
            if kvs.object(forKey: tombstoneKey(key)) != nil { kvs.removeObject(forKey: tombstoneKey(key)); removedAny = true }
        }
        if removedAny { kvs.synchronize() }
    }

    private static func changedKeys(_ note: Notification) -> [String] {
        guard let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else { return syncedKeys }
        let normalized = keys.compactMap { key -> String? in
            key.hasSuffix(tombstoneSuffix) ? String(key.dropLast(tombstoneSuffix.count)) : key
        }
        return Array(Set(normalized))
    }

    private static func pullToLocal(_ keys: [String]) {
        let d = UserDefaults.standard
        var changed = false
        for key in keys where syncedKeys.contains(key) {
            if let value = kvs.object(forKey: key) {
                if !plistEqual(d.object(forKey: key), value) {
                    d.set(value, forKey: key)
                    changed = true
                }
            } else if kvs.object(forKey: tombstoneKey(key)) != nil, d.object(forKey: key) != nil {
                d.removeObject(forKey: key)
                changed = true
            }
        }
        if changed { NotificationCenter.default.post(name: .cloudSyncDidUpdate, object: nil) }
    }

    /// Plist-value equality (String / Data / NSNumber-backed Double·Bool·Int /
    /// Array / Dictionary all bridge to NSObject and implement `isEqual`).
    private static func plistEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return (x as AnyObject).isEqual(y)
        default: return false
        }
    }

    private static func tombstoneKey(_ key: String) -> String { key + tombstoneSuffix }
}
