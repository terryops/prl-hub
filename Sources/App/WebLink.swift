import SwiftUI
import Combine
import AuthenticationServices

// Email sessions and the last server-verified account Pro verdict stay together
// in the device-only Keychain. Wallet keys are never part of the account.
private struct AccountSession: Codable, Equatable {
    var userId: String; var deviceId: String; var accessToken: String; var refreshToken: String; var expiresAt: Date
    var pro: Bool?
    init(_ body: [String: Any]) throws {
        guard let user = body["user_id"] as? String, user.hasPrefix("u_"), let device = body["device_id"] as? String,
              let access = body["access_token"] as? String, let refresh = body["refresh_token"] as? String,
              access.count == 43, refresh.count == 43 else { throw URLError(.badServerResponse) }
        userId = user; deviceId = device; accessToken = access; refreshToken = refresh
        expiresAt = Date().addingTimeInterval((body["expires_in"] as? Double) ?? 900)
    }
}

@MainActor
final class WebLinkStore: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = WebLinkStore()

    enum State: Equatable { case idle, syncing, synced(Date), failed(String) }

    @Published private(set) var email: String?
    @Published private(set) var signingIn = false
    private var credentials: AccountSession?
    private var browserSession: ASWebAuthenticationSession?
    private var refreshTask: Task<AccountSession, Error>?
    private var generation = 0
    @Published private(set) var state: State = .idle
    /// Pro from a verified account purchase, shared by Web and native apps.
    @Published private(set) var accountPro: Bool?

    var isLinked: Bool { credentials != nil }

    /// Derive the shared preference keys from their wire mapping so a mining
    /// field cannot be uploaded yet left outside account/iCloud isolation.
    nonisolated static let watchedKeys: Set<String> = Set([PoolStore.watchesKey, OfflineAlertStore.key,
                                                       PriceAlertStore.syncKey, PriceAlertStore.windowKey])
        .union(WebSharedMerge.nativeKeys)
    private static let account = "account.session"
    private var baseKey: String { "account.base." + (credentials?.userId ?? "guest") }
    /// The server's cap on the configuration before encryption at rest.
    private static let maxConfig = 65536
    /// Quiet time after a change before syncing: an edit is rarely alone.
    private static let settle: UInt64 = 3_000_000_000
    /// A foreground sync is skipped this soon after the last one.
    private static let fresh: TimeInterval = 60
    /// Syncs that changed something, inside `burstWindow`, after which automatic syncing
    /// stops until the app is next opened: two sides that never agree must not loop.
    private static let burst = 8
    private static let burstWindow: TimeInterval = 120
    /// A purchase the worker didn't take is offered again after this long.
    private static let offerEvery: TimeInterval = 3600

    private var base = WebLinkBase()
    /// What this device held at the end of the last sync that reached the account.
    private var synced: LocalState?
    private var pending: Task<Void, Never>?
    private var running = false
    private var again = false
    private var busy: [Date] = []
    /// The purchase last handed to the worker, and when: a refusal isn't asked again at once.
    private var offered: (jws: String, at: Date)?
    private var cloudSub: AnyCancellable?
    private var jwsSub: AnyCancellable?
    private var proNeedsRefresh = true

    override init() {
        super.init()
        credentials = Keychain.get(account: Self.account).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(AccountSession.self, from: $0) }
        Keychain.delete(account: "weblink.code")
        let d = UserDefaults.standard
        d.removeObject(forKey: "weblink.base")
        AccountPreferences.adopt(credentials?.userId, defaults: d) {
            NotificationCenter.default.post(name: .accountPreferencesWillChange, object: nil)
        }
        if let uid = credentials?.userId {
            email = d.string(forKey: "account.email." + uid)
            if let data = d.data(forKey: baseKey), let b = try? JSONDecoder().decode(WebLinkBase.self, from: data) { base = b }
        }
        accountPro = credentials?.pro
        ProStore.shared.useAccount(credentials?.userId, verifiedPro: credentials?.pro == true)
        cloudSub = NotificationCenter.default.publisher(for: .cloudSyncDidUpdate).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.localChanged() }
        // The signed purchase can arrive after the link (StoreKit answers late, or the
        // purchase is made later): hand it over then.
        jwsSub = ProStore.shared.$jws.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.proNeedsRefresh = true; self?.localChanged() }
    }

    // MARK: linking

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
    func login(importLocal: Bool) async {
        guard !signingIn else { return }
        signingIn = true; defer { signingIn = false; browserSession = nil }
        let at = generation, verifier = AccountPKCE.random(), nonce = AccountPKCE.random()
        let device = Keychain.get(account: "account.device") ?? UUID().uuidString
        guard Keychain.set(device, account: "account.device") else { state = .failed(Loc("无法安全保存登录信息")); return }
        #if os(iOS)
        let platform = "ios", name = UIDevice.current.name
        #else
        let platform = "macos", name = Host.current().localizedName ?? "Mac"
        #endif
        var url = URLComponents(string: "https://pearlhub.net/")!
        url.queryItems = [URLQueryItem(name: "account", value: "connect"), URLQueryItem(name: "redirect_uri", value: "prlhub://account"), URLQueryItem(name: "code_challenge", value: AccountPKCE.challenge(verifier)), URLQueryItem(name: "state", value: nonce), URLQueryItem(name: "device_id", value: device), URLQueryItem(name: "platform", value: platform), URLQueryItem(name: "device_name", value: name), URLQueryItem(name: "reauth", value: "1")]
        do {
            let callback: URL = try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: "prlhub") { url, error in
                    if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? URLError(.cancelled)) }
                }
                session.presentationContextProvider = self; browserSession = session
                if !session.start() { continuation.resume(throwing: URLError(.cannotConnectToHost)) }
            }
            guard at == generation, let code = AccountPKCE.code(callback, state: nonce) else { throw Failure.refused }
            let body = try await raw("auth/exchange", method: "POST", body: ["code": code, "code_verifier": verifier, "redirect_uri": "prlhub://account"])
            var next = try AccountSession(body)
            let info = try await raw("account", token: next.accessToken, user: next.userId)
            guard at == generation else { return }
            // The server's verdict came with the login: an account that has Pro must not
            // look as if it lost it until the first sync answers.
            next.pro = info["pro"] as? Bool
            let old = credentials?.userId
            let d = UserDefaults.standard
            if old != next.userId {
                NotificationCenter.default.post(name: .accountPreferencesWillChange, object: nil)
                snapshot(old)
                if d.dictionary(forKey: "account.prefs." + next.userId) == nil {
                    let imported = importLocal || info["pro"] as? Bool != true ? d.dictionary(forKey: "account.prefs." + (old ?? "guest")) ?? [:] : [:]
                    d.set(imported, forKey: "account.prefs." + next.userId)
                }
                d.set(next.userId, forKey: "account.pendingPrefs")
            }
            guard saveSession(next) else { d.removeObject(forKey: "account.pendingPrefs"); throw Failure.refused }
            if old != next.userId {
                AccountPreferences.restore(next.userId)
                base = WebLinkBase()
                if let data = d.data(forKey: "account.base." + next.userId), let b = try? JSONDecoder().decode(WebLinkBase.self, from: data) { base = b }
            }
            credentials = next; generation += 1; email = info["email"] as? String
            UserDefaults.standard.set(next.userId, forKey: "account.current")
            d.removeObject(forKey: "account.pendingPrefs")
            UserDefaults.standard.set(email, forKey: "account.email." + next.userId)
            accountPro = next.pro; offered = nil; proNeedsRefresh = true; synced = nil
            ProStore.shared.useAccount(next.userId, verifiedPro: next.pro == true)
            NotificationCenter.default.post(name: .cloudSyncDidUpdate, object: nil)
            await sync()
        } catch { if at == generation { state = .failed(Loc("邮箱登录未完成，请重试")) } }
    }
    private func snapshot(_ uid: String?) {
        AccountPreferences.snapshot(uid)
    }
    private func saveSession(_ session: AccountSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session), let text = String(data: data, encoding: .utf8) else { return false }
        return Keychain.set(text, account: Self.account)
    }
    func logout() async {
        do { if isLinked { _ = try await call(credentials!.userId, "auth/logout", method: "POST", body: [:]) }; clearSession() }
        catch { if isLinked { state = .failed(Loc("退出未完成，请检查网络后重试")) } }
    }
    private func clearSession() {
        NotificationCenter.default.post(name: .accountPreferencesWillChange, object: nil)
        snapshot(credentials?.userId); generation += 1; pending?.cancel(); refreshTask?.cancel(); refreshTask = nil
        Keychain.delete(account: Self.account); credentials = nil; email = nil; accountPro = nil; offered = nil; base = WebLinkBase(); synced = nil; state = .idle
        ProStore.shared.useAccount(nil)
        UserDefaults.standard.removeObject(forKey: "account.current")
        AccountPreferences.restore(nil)
        NotificationCenter.default.post(name: .cloudSyncDidUpdate, object: nil)
    }

    // MARK: when to sync

    /// CloudSync.push calls this for every key it mirrors, from wherever that was saved.
    nonisolated static func keyChanged(_ key: String) {
        guard watchedKeys.contains(key) else { return }
        Task { @MainActor in shared.localChanged() }
    }

    /// The wallet list isn't an account preference (it stays with the device whoever signs
    /// in), so WalletStore reports its changes here: the web shows the wallets read-only.
    nonisolated static func walletsChanged() {
        Task { @MainActor in shared.localChanged() }
    }

    /// Something the web also holds changed here (or arrived over iCloud).
    func localChanged() {
        guard isLinked else { return }
        let now = Date()
        busy.removeAll { now.timeIntervalSince($0) > Self.burstWindow }
        guard busy.count < Self.burst else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.settle)
            guard !Task.isCancelled, let self else { return }
            // CloudSync reports every save, and the mining prefs are saved on each price
            // tick: one that left everything the account holds as it was needs no request.
            guard self.proNeedsRefresh || self.accountPro != true || self.synced != LocalState.read() else { return }
            await self.sync(full: false)
        }
    }

    /// The app came to the front: pick up what changed on the web meanwhile.
    func foreground() {
        guard isLinked else { return }
        busy.removeAll()
        if case .synced(let at) = state, Date().timeIntervalSince(at) < Self.fresh { return }
        Task { await sync() }
    }

    // MARK: sync

    private enum Failure: Error { case network, server, refused, tooLarge, conflict, requiresPro }

    func sync(full: Bool = true) async {
        guard let code = credentials?.userId else { return }
        if running { again = true; return }
        running = true
        defer {
            running = false
            if again { again = false; localChanged() }
        }
        state = .syncing
        do {
            try await syncPro(code, full: full)
            guard credentials?.userId == code else { return }
            guard accountPro == true else { state = .idle; return }
            try await syncConfig(code)
            if credentials?.userId == code { state = .synced(Date()) }
        } catch {
            guard credentials?.userId == code else { return }
            switch error as? Failure {
            case .requiresPro:
                if var current = credentials {
                    current.pro = false
                    if saveSession(current) { credentials = current }
                }
                accountPro = false; ProStore.shared.updateAccount(code, verifiedPro: false)
                state = .idle
            case .tooLarge: state = .failed(Loc("配置太大，无法同步到网页版"))
            case .refused: state = .failed(Loc("登录已过期，请重新登录"))
            case .server, .conflict: state = .failed(Loc("网页版暂时无法同步，稍后会再试"))
            case .network: state = .failed(Loc("无法连接网页版，请检查网络"))
            // A configuration this build can't merge is not the network's fault.
            case nil: state = .failed(error is URLError ? Loc("无法连接网页版，请检查网络") : Loc("网页版暂时无法同步，稍后会再试"))
            }
        }
    }

    /// App Store and PRL purchases provide the same account Pro entitlement.
    private func syncPro(_ code: String, full: Bool) async throws {
        let at = generation
        let jws = ProStore.shared.jws
        let canOffer = jws != nil && (offered.map { $0.jws != jws || Date().timeIntervalSince($0.at) > Self.offerEvery } ?? true)
        guard full || accountPro == nil || canOffer || proNeedsRefresh else { return }
        let me = try await call(code, "me")
        guard at == generation, credentials?.userId == code else { return }
        var pro = me["pro"] as? Bool ?? false
        if canOffer, let jws {
            offered = (jws, Date())
            // An unavailable route or a receipt already linked to another account leaves
            // the account entitlement unchanged. Offer Apple purchases even when
            // PRL already provides Pro so the independent sources stay linked.
            if let o = try? await call(code, "account/entitlements/apple", method: "POST", body: ["jws": jws]) {
                pro = o["pro"] as? Bool ?? pro
            }
        }
        guard at == generation, var current = credentials, current.userId == code else { return }
        current.pro = pro
        guard saveSession(current) else { clearSession(); throw Failure.refused }
        credentials = current; accountPro = pro
        ProStore.shared.updateAccount(code, verifiedPro: pro)
        proNeedsRefresh = ProStore.shared.jws != jws
    }

    private func syncConfig(_ code: String) async throws {
        for _ in 0..<3 {
            let server = try await call(code, "account/config")
            guard credentials?.userId == code else { return }
            let rev = (server["rev"] as? NSNumber)?.intValue ?? 0
            var remote: [String: Any]?
            guard (server["schema_version"] as? Int) == 1 else { throw Failure.refused }
            if let data = server["data"] as? [String: Any] { remote = data }
            let stored = Stored.read()
            let sharedLocal = WebSharedMerge.read(UserDefaults.standard)
            var outcome = WebLinkMerge.merge(local: stored.local, base: base, remote: remote,
                                             timeZone: TimeZone.current.identifier, lang: PriceAlertStore.pushLanguage,
                                             now: Int64((Date().timeIntervalSince1970 * 1000).rounded()))
            let shared = try WebSharedMerge.merge(local: sharedLocal, remote: outcome.config,
                                                 base: base.shared, now: Int64((Date().timeIntervalSince1970 * 1000).rounded()))
            outcome.config = shared.config; outcome.base.shared = shared.base
            outcome.upload = outcome.upload || shared.upload
            _ = try WebSharedMerge.apply(shared.native, to: UserDefaults.standard, dryRun: true)
            if outcome.upload {
                let config = AccountConfig.clean(outcome.config)
                guard try JSONSerialization.data(withJSONObject: config).count <= Self.maxConfig else { throw Failure.tooLarge }
                do {
                    _ = try await call(code, "account/config", method: "PUT", body: ["schema_version": 1, "rev": rev, "data": config])
                } catch Failure.conflict {
                    continue     // a browser saved meanwhile: merge with what it saved
                }
                guard credentials?.userId == code else { return }
            }
            // A native edit during the upload must be merged again, never overwritten.
            guard Stored.read() == stored,
                  WebSharedMerge.encoded(WebSharedMerge.read(UserDefaults.standard)) == WebSharedMerge.encoded(sharedLocal) else { continue }
            let sharedChanged = try WebSharedMerge.apply(shared.native, to: UserDefaults.standard)
            let changedHere = stored.apply(outcome) || !sharedChanged.isEmpty
            if !sharedChanged.isEmpty {
                sharedChanged.forEach(CloudSync.push)
                NotificationCenter.default.post(name: .cloudSyncDidUpdate, object: nil)
            }
            if changedHere || outcome.upload { busy.append(Date()) }
            // Only now is this what both sides hold. Had the upload failed, the next sync
            // would start from the old agreement and reach the same result.
            base = outcome.base
            if let data = try? JSONEncoder().encode(base) { UserDefaults.standard.set(data, forKey: baseKey) }
            synced = LocalState.read()
            return
        }
        throw Failure.conflict
    }

    private func refreshed(force: Bool = false) async throws -> AccountSession {
        guard let current = credentials else { throw Failure.refused }
        if !force && current.expiresAt.timeIntervalSinceNow > 30 { return current }
        if let task = refreshTask { return try await task.value }
        let at = generation
        let task = Task { @MainActor in
            let body = try await raw("auth/refresh", method: "POST", body: ["refresh_token": current.refreshToken])
            var next = try AccountSession(body)
            guard at == generation, next.userId == current.userId else { throw Failure.refused }
            next.pro = credentials?.pro
            guard saveSession(next) else { throw Failure.refused }
            credentials = next; return next
        }
        refreshTask = task
        defer { refreshTask = nil }
        do { return try await task.value } catch { if case Failure.refused = error, at == generation { clearSession() }; throw error }
    }
    /// Notification routes also use the account session, so revoked devices cannot reconnect through legacy token APIs.
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        guard isLinked else { return try await URLSession.shared.data(for: request) }
        let id = credentials!.userId, at = generation
        var session = try await refreshed(), req = request
        req.httpShouldHandleCookies = false
        req.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization"); req.setValue(id, forHTTPHeaderField: "X-Account-ID")
        var result = try await URLSession.shared.data(for: req)
        if (result.1 as? HTTPURLResponse)?.statusCode == 401 {
            session = try await refreshed(force: true)
            req.setValue("Bearer " + session.accessToken, forHTTPHeaderField: "Authorization")
            result = try await URLSession.shared.data(for: req)
        }
        guard at == generation, credentials?.userId == id else { throw Failure.refused }
        return result
    }
    private func call(_ code: String, _ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        guard credentials?.userId == code else { throw Failure.refused }
        var req = URLRequest(url: PriceAlertStore.endpoint.appendingPathComponent(path)); req.httpMethod = method; req.timeoutInterval = 20; req.cachePolicy = .reloadIgnoringLocalCacheData
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await self.data(for: req)
        return try parse(data, response)
    }
    private func raw(_ path: String, method: String = "GET", body: [String: Any]? = nil, token: String? = nil, user: String? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: PriceAlertStore.endpoint.appendingPathComponent(path)); req.httpMethod = method; req.timeoutInterval = 20; req.httpShouldHandleCookies = false; req.cachePolicy = .reloadIgnoringLocalCacheData
        if let token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }; if let user { req.setValue(user, forHTTPHeaderField: "X-Account-ID") }
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        return try parse(data, response)
    }
    private func parse(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        if (response as? HTTPURLResponse)?.statusCode == 403,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           body["error"] as? String == "sync_requires_pro" { throw Failure.requiresPro }
        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        case 409: throw Failure.conflict
        case 400, 401, 403, 404: throw Failure.refused
        default: throw Failure.server
        }
    }

}

/// Everything on this device that the account also holds, to tell a save that changed
/// some of it from one that didn't.
private struct LocalState: Equatable {
    var stored: Stored
    var shared: Data

    static func read() -> LocalState {
        LocalState(stored: Stored.read(), shared: WebSharedMerge.encoded(WebSharedMerge.read(UserDefaults.standard)))
    }
}

/// The app's side of the configuration, as stored: what the merge reads, plus the entries
/// this build can't read, which are written back exactly as they were.
private struct Stored: Equatable {
    var local: WebLinkLocal
    var foreignWatches: [Data] = []
    var foreignMinutes: [String: Int] = [:]

    static func read() -> Stored {
        let d = UserDefaults.standard
        let watches = d.data(forKey: PoolStore.watchesKey).flatMap(PoolStore.decodeStoredWatches)
        let minutes = OfflineAlertStore.split(d.data(forKey: OfflineAlertStore.key))
        let rules = d.data(forKey: PriceAlertStore.syncKey)
        // No stored copy = no alerts yet; one this build can't read = hands off.
        let alerts = rules == nil ? CloudAlerts() : CloudAlerts.decode(rules)
        let window = d.data(forKey: PriceAlertStore.windowKey).flatMap { try? JSONDecoder().decode(PushWindow.self, from: $0) }
        return Stored(local: WebLinkLocal(watches: watches?.known ?? [], minutes: minutes.known, alerts: alerts, window: window),
                      foreignWatches: watches?.foreign ?? [], foreignMinutes: minutes.foreign)
    }

    /// Write what the web changed, the way an incoming iCloud change is written: into
    /// UserDefaults, up to iCloud, and announced, so the stores that own this data reload
    /// and run their own merges. Returns whether anything changed.
    @MainActor
    func apply(_ outcome: WebLinkOutcome) -> Bool {
        let d = UserDefaults.standard
        var changed: [String] = []
        if outcome.local.watches != local.watches, var data = try? JSONEncoder().encode(outcome.local.watches) {
            if !foreignWatches.isEmpty, var arr = (try? JSONSerialization.jsonObject(with: data)) as? [Any] {
                arr += foreignWatches.compactMap { try? JSONSerialization.jsonObject(with: $0) }
                if let merged = try? JSONSerialization.data(withJSONObject: arr) { data = merged }
            }
            d.set(data, forKey: PoolStore.watchesKey)
            changed.append(PoolStore.watchesKey)
        }
        if outcome.local.minutes != local.minutes {
            var raw = foreignMinutes
            for (id, m) in outcome.local.minutes { raw[id.uuidString] = m }
            if raw.isEmpty { d.removeObject(forKey: OfflineAlertStore.key) }
            else if let data = try? JSONEncoder().encode(raw) { d.set(data, forKey: OfflineAlertStore.key) }
            changed.append(OfflineAlertStore.key)
        }
        if let alerts = outcome.alerts, alerts != local.alerts, let data = alerts.encoded() {
            d.set(data, forKey: PriceAlertStore.syncKey)
            changed.append(PriceAlertStore.syncKey)
        }
        if outcome.local.window != local.window {
            if let w = outcome.local.window, let data = try? JSONEncoder().encode(w) { d.set(data, forKey: PriceAlertStore.windowKey) }
            else { d.removeObject(forKey: PriceAlertStore.windowKey) }
            changed.append(PriceAlertStore.windowKey)
        }
        guard !changed.isEmpty else { return false }
        changed.forEach(CloudSync.push)
        NotificationCenter.default.post(name: .cloudSyncDidUpdate, object: nil)
        return true
    }
}
