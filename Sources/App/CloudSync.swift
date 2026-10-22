import Foundation

extension Notification.Name {
    static let cloudSyncDidUpdate = Notification.Name("cloudSyncDidUpdate")
    /// Persist pending edits before the active account's preferences are replaced.
    static let accountPreferencesWillChange = Notification.Name("accountPreferencesWillChange")
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
    static func canSync(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "pro.unlocked") ||
            (defaults.string(forKey: "account.current") != nil && defaults.bool(forKey: "pro.accountSync"))
    }
    /// Allow-list of UserDefaults keys mirrored to iCloud. Live market-derived
    /// numbers (PRL 币价 / 全网算力 / 单位日产 = prl.price/neth/pu/diffConst) are
    /// intentionally absent — each device refetches them, so syncing would only
    /// churn the cloud store on every refresh. They're still saved locally.
    static let syncedKeys = [
        // pool monitor (+ which monitors have a 掉线提醒, and after how many minutes)
        "pool.watches", "pool.alerts",
        // exchange / trade — NON-secret only. The API key/secret are stored in the
        // iCloud Keychain (E2E-encrypted), never in this plaintext KVS.
        "safetrade.period", "safetrade.withdrawAddresses",
        // wallet — non-secret meta only (the seed stays in the Keychain)
        "wallet.name", "wallet.network", "wallet.contacts",
        // app appearance / language / currency
        "ui.appearance", "app.language", "currency.secondary",
        // price alerts: alerts.sync is merged rule by rule in PriceAlertStore (see
        // PriceAlertSync.swift) rather than adopted whole. The APNs token and each
        // device's fired state stay local.
        "alerts.sync", "alerts.window",
        // PRL mining monitor — user config (NOT the live-fetched market numbers).
        // prl.fx is intentionally NOT synced: each device derives its own 1-USD→local
        // rate from ITS own secondary currency. prl.rentCcy tags the currency the
        // synced rents are denominated in so a receiving device converts correctly.
        "prl.devices", "prl.rents", "prl.rentCcy", "prl.rentFX", "prl.elec", "prl.fee", "prl.fxManual", "prl.budget", "prl.budgetEnabled",
        "prl.live", "prl.rentEnabled", "prl.rentCovers", "prl.auto", "prl.sort",
        // prl.diffGrowth is intentionally NOT synced: in live mode each device auto-derives
        // it from its own difficulty feed, so syncing clobbered another device's manual
        // what-if (same reason the live market numbers above aren't synced).
        "prl.selected", "prl.selfDilution", "prl.syncW",
    ]
    static func accountOwns(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: "account.current") != nil && WebLinkStore.watchedKeys.contains(key)
    }
    /// The default store is documented thread-safe; read it through a computed
    /// property rather than caching it in a (non-Sendable) global.
    private static var kvs: NSUbiquitousKeyValueStore { .default }
    private static let tombstoneSuffix = ".__deleted"
    /// Synced keys changed here while sync was off (no Pro). The cloud's copy of each is
    /// older than this device's, so when sync turns on they are uploaded, not pulled over.
    static let pendingKey = "cloud.pending"
    /// Whether this install has ever been in step with the cloud. One that has not (a new
    /// phone, a reinstall) holds defaults, not edits: its first sync adopts the cloud, as
    /// it always has, and nothing it saved before that is queued for upload.
    static let syncedKey = "cloud.synced"
    /// Each synced key's value when this install was last in step with the cloud — what a
    /// save made while sync is off is compared with, to tell an edit from a rewrite.
    static let baselineKey = "cloud.baseline"
    @MainActor private static var started = false

    @MainActor static func start() {
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
            noteSynced()
        }
        kvs.synchronize()
        // Upload only what the cloud has never seen. Pushing every local value that
        // merely DIFFERS (the old behaviour) let a device that was closed while
        // another one edited overwrite that newer edit with its stale copy on launch.
        seedMissing(syncedKeys)
        flushPending()
        // Initial pull so a device that already has iCloud data adopts it.
        pullToLocal(syncedKeys)
        noteSynced()
    }

    /// First run of a build that gates sync on Pro: an install that was here before synced
    /// freely until now, so what it changes from here on is queued (see `pendingKey`).
    /// Has to run before `ReviewPrompt.registerLaunch()` counts the launch being decided on.
    static func adoptDefault(in defaults: UserDefaults = .standard, launches: Int = ReviewPrompt.launchCount) {
        guard defaults.object(forKey: syncedKey) == nil else { return }
        defaults.set(launches > 0, forKey: syncedKey)
        if launches > 0 { recordBaseline(defaults) }
    }

    /// A pass that left this device and the cloud agreeing has just run.
    private static func noteSynced(defaults d: UserDefaults = .standard) {
        guard canSync(defaults: d) else { return }
        if !d.bool(forKey: syncedKey) { d.set(true, forKey: syncedKey) }
        recordBaseline(d)
    }

    private static func recordBaseline(_ d: UserDefaults) {
        let now = Dictionary(uniqueKeysWithValues: syncedKeys.compactMap { key in d.object(forKey: key).map { (key, $0) } })
        if !plistEqual(d.dictionary(forKey: baselineKey), now) { d.set(now, forKey: baselineKey) }
    }

    /// Re-pull the latest from iCloud. Call when the app returns to the
    /// foreground so a value saved on another device shows up here without a
    /// relaunch.
    @MainActor static func refresh() {
        guard started else { start(); return }
        kvs.synchronize()
        flushPending()
        pullToLocal(syncedKeys)
        noteSynced()
    }

    /// Upload what changed here while sync was off — ahead of the pull, which would
    /// otherwise replace those edits with the cloud's older copies the moment Pro unlocks.
    private static func flushPending(defaults d: UserDefaults = .standard) {
        guard canSync(defaults: d) else { return }
        let pending = d.stringArray(forKey: pendingKey) ?? []
        guard !pending.isEmpty else { return }
        let plan = flushPlan(pending: pending) { accountOwns($0, defaults: d) }
        plan.upload.forEach { upload($0) }
        if plan.keep.isEmpty { d.removeObject(forKey: pendingKey) } else { d.set(plan.keep, forKey: pendingKey) }
        if !plan.upload.isEmpty { kvs.synchronize() }
    }

    /// Which pending keys go up now. One the signed-in account owns stays out of iCloud
    /// while that account is open, so it waits; a key no longer synced is forgotten.
    static func flushPlan(pending: [String], accountOwns: (String) -> Bool) -> (upload: [String], keep: [String]) {
        let known = pending.filter(syncedKeys.contains)
        return (known.filter { !accountOwns($0) }, known.filter(accountOwns))
    }

    /// Whether a save made while sync is off is an edit to upload later: only on an install
    /// that has synced before, and only if the value differs from what it held when it last
    /// did — the mining prefs are rewritten, unchanged, on every price tick. (Not compared
    /// with the cloud's copy: another device may have moved that on since.)
    static func shouldQueue(hasSynced: Bool, baseline: [String: Any]?, key: String, local: Any?) -> Bool {
        guard hasSynced, let baseline else { return false }
        return !plistEqual(baseline[key], local)
    }

    private static func markPending(_ key: String, defaults d: UserDefaults = .standard) {
        guard shouldQueue(hasSynced: d.bool(forKey: syncedKey), baseline: d.dictionary(forKey: baselineKey),
                          key: key, local: d.object(forKey: key)) else { return }
        var pending = d.stringArray(forKey: pendingKey) ?? []
        guard !pending.contains(key) else { return }
        pending.append(key)
        d.set(pending, forKey: pendingKey)
    }

    /// Upload this device's value for each of `keys` that the cloud holds nothing
    /// for — neither a value nor a deletion tombstone. Self-heals a value saved
    /// before the iCloud entitlement was provisioned (so never uploaded) without
    /// ever overriding anything another device has written.
    static func seedMissing(_ keys: [String]) {
        guard canSync() else { return }
        let d = UserDefaults.standard
        var pushedAny = false
        for key in keys where syncedKeys.contains(key) && !accountOwns(key) {
            let value = d.object(forKey: key)
            guard shouldSeed(local: value, cloud: kvs.object(forKey: key),
                             tombstone: kvs.object(forKey: tombstoneKey(key))), let value else { continue }
            kvs.set(value, forKey: key)
            pushedAny = true
        }
        if pushedAny { kvs.synchronize() }
    }

    /// Seed only a non-empty local value into a cloud slot that is completely
    /// empty. A cloud value or tombstone always wins: it is at least as new as
    /// anything this device holds before its first pull.
    static func shouldSeed(local: Any?, cloud: Any?, tombstone: Any?) -> Bool {
        guard let local, cloud == nil, tombstone == nil else { return false }
        if let s = local as? String, s.isEmpty { return false }
        if let data = local as? Data, data.isEmpty { return false }
        return true
    }

    /// Push a locally-changed key up to iCloud. No-ops when the cloud copy already
    /// matches, so it's safe to call from a frequently-fired `didSet`/`savePrefs`.
    static func push(_ key: String) {
        // Manual mining inputs also belong to the account even though iCloud
        // deliberately excludes the live market values stored under those keys.
        WebLinkStore.keyChanged(key)
        guard syncedKeys.contains(key) else { return }
        guard canSync() else { markPending(key); return }
        guard !accountOwns(key) else { return }
        if upload(key) { kvs.synchronize() }
    }

    /// Put this device's value for `key` (or its absence) into the cloud store. Returns
    /// whether that changed anything.
    @discardableResult
    private static func upload(_ key: String) -> Bool {
        let d = UserDefaults.standard
        if let value = d.object(forKey: key) {
            if plistEqual(kvs.object(forKey: key), value) { return false }   // already current — avoid churn
            kvs.set(value, forKey: key)
            kvs.removeObject(forKey: tombstoneKey(key))
        } else {
            kvs.removeObject(forKey: key)
            kvs.set(Date().timeIntervalSince1970, forKey: tombstoneKey(key))
        }
        return true
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
        guard canSync() else { return }
        let d = UserDefaults.standard
        var changed = false
        for key in keys where syncedKeys.contains(key) && !accountOwns(key) {
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
