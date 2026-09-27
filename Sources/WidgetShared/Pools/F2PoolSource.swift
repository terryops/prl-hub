import Foundation

// MARK: - F2Pool (鱼池) — the account's read-only page
//
// F2Pool has no public per-address API. Its v2 API doesn't list `pearl` as a currency at
// all (and the hashrate module is bitcoin/bitcoin-cash/litecoin only), and v1
// (`api.f2pool.com/pearl/{account}`) now demands an account-wide `F2P-API-SECRET` token
// that ALSO authorises withdrawals — not something to ship in a watch-only app.
//
// What is public is the account's *read-only page*: a revocable share link the user
// creates on f2pool. The tables on that page are fed by JSON `action=…` endpoints on the
// page's own URL, gated solely by the `X-Requested-With: XMLHttpRequest` header — without
// it the server answers 200 with the 280 KB HTML page instead of JSON.
//
// So a F2Pool watch stores that page URL rather than a PRL address. The 32-hex `key` is
// the identity: the server resolves the account from it and ignores a wrong `account`
// param. We still send `user_name`/`account` to mirror what the real page sends.

struct F2PoolRef: Equatable, Sendable {
    let key: String        // read-only key — the capability
    let account: String    // f2pool account name (display + mirrors the page's params)

    /// Canonical form, persisted in `PoolWatch.address`. Note the coin slug: F2Pool SHARES
    /// the coin-less `/mining-user/{key}`, but only `-prl` answers the AJAX endpoints
    /// (`-pearl` 404s), so the stored URL is always rewritten to the form the client calls.
    /// Built through URLComponents so a spaced/CJK account name is percent-encoded — the
    /// stored URL is re-parsed on every load, and a raw space would fail URLComponents and
    /// make the watch silently vanish.
    var pageURL: String {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "www.f2pool.com"
        c.path = "/mining-user-prl/\(key)"
        if !account.isEmpty { c.queryItems = [URLQueryItem(name: "user_name", value: account)] }
        return c.string ?? "https://www.f2pool.com/mining-user-prl/\(key)"
    }

    /// Parse a pasted read-only-page link. Deliberately forgiving about the SHAPE of the
    /// paste: what F2Pool's share button hands out is `/mining-user/{key}` (no coin slug),
    /// on a phone it usually arrives wrapped in chat text or missing its scheme, and it may
    /// carry a locale prefix. Only the key is non-negotiable — it is the whole capability,
    /// and a wrong one just 404s (→ "未在此矿池") rather than silently reporting someone else.
    init?(_ raw: String) {
        // Pick the link out of whatever was pasted ("我的只读页 https://… 请查收").
        guard let r = raw.range(of: #"(?i)(https?://)?[a-z0-9.-]*f2pool\.com(/\S*)?"#,
                                options: .regularExpression) else { return nil }
        var s = String(raw[r]).trimmingCharacters(in: CharacterSet(charactersIn: "。，、）)]》」』.,;"))
        // Without a scheme, URLComponents parses the host as a path and `host` comes back nil.
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let c = URLComponents(string: s), (c.host ?? "").hasSuffix("f2pool.com") else { return nil }
        // Take the first key-shaped segment AFTER the page slug — scanning forward (rather
        // than demanding slug+1) accepts `/mining-user/{key}`, `/mining-user-prl/{key}` and a
        // coin that sits in its own segment alike.
        let parts = c.path.split(separator: "/").map(String.init)
        guard let slug = parts.firstIndex(where: { $0.hasPrefix("mining-user") }),
              let k = parts[(slug + 1)...].first(where: { $0.count >= 16 && $0.allSatisfy(\.isHexDigit) })
        else { return nil }
        key = k.lowercased()
        account = c.queryItems?.first { $0.name == "user_name" }?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// One rig. F2Pool mixes JSON types across sibling fields (`hashrate` is a string,
/// `stalerate` a number — and `status` has been seen both ways), hence FlexDouble throughout:
/// a plain Int would throw typeMismatch on the first odd row and blank the whole card.
struct F2Worker: Decodable, Sendable {
    let name: String?
    let hashrate: FlexDouble?           // TH/s — pre-scaled to the currency's `scale: "T"`
    let hashrate_last_day: FlexDouble?  // TH/s
    let last_share: FlexDouble?         // unix seconds
    let status: FlexDouble?             // 0 online · 1 offline · 2 dead
}

/// ⚠️ Account-level hashrates are RAW H/s here, unlike the per-worker TH/s above —
/// verified live: summary.hash_rate "12509998964918.04" alongside worker "12.51".
struct F2Summary: Decodable, Sendable {
    let hash_rate: FlexDouble?          // raw H/s, 15-minute window
    let hash_rate_daily: FlexDouble?    // raw H/s, 24-hour window
}

struct F2OriginData: Decodable, Sendable {
    let summary: F2Summary?
    let workers: [F2Worker]?
    let worker_length_all: Int?
    let worker_length_online: Int?
}

struct F2WorkersResp: Decodable, Sendable {
    let status: String?
    let originData: F2OriginData?
}

private struct F2Payout: Decodable { let amount: FlexDouble? }
private struct F2PayoutsResp: Decodable { let data: [F2Payout]? }

/// The two figures the read-only page renders only as HTML.
struct F2Revenue: Sendable {
    let balance: Double     // settled, accumulating toward the 1.0 PRL payout threshold
    let estToday: Double    // this UTC day's PPS estimate — not in `balance` until 00:00 UTC
}

enum F2PoolSource: PoolMinerSource {
    /// Per-worker hashrates arrive in TH/s; ×1e12 recovers real H/s.
    static let hashScale = 1e12

    private static func base(_ ref: F2PoolRef) -> String { "https://www.f2pool.com/mining-user-prl/\(ref.key)" }

    /// The page's own AJAX transport. `X-Requested-With` is load-bearing, not politeness.
    private static func ajax(_ ref: F2PoolRef, _ items: [URLQueryItem], scope: PoolScope) async throws -> Data {
        guard var c = URLComponents(string: base(ref)) else { throw URLError(.badURL) }
        c.queryItems = [URLQueryItem(name: "user_name", value: ref.account)] + items
        guard let url = c.url else { throw URLError(.badURL) }
        return try await PoolHTTP.get(url, timeout: scope.timeout,
                                      accept: "application/json, text/javascript, */*; q=0.01",
                                      headers: ["X-Requested-With": "XMLHttpRequest"])
    }

    /// Workers + account hashrate summary. `currency` is required: omit it and the server
    /// falls back to rendering the HTML page.
    static func workers(_ ref: F2PoolRef, scope: PoolScope) async throws -> F2WorkersResp {
        try PoolHTTP.decode(F2WorkersResp.self, from: try await ajax(ref, [
            .init(name: "action", value: "get_pagination_workers"),
            .init(name: "account", value: ref.account),
            .init(name: "currency", value: "PRL")], scope: scope))
    }

    /// Lifetime paid = Σ of the payout table, which this action returns in full (unpaginated).
    static func totalPaid(_ ref: F2PoolRef) async throws -> Double {
        try paid(from: try await ajax(ref, [
            .init(name: "action", value: "load_payout_history_outcome"),
            .init(name: "account", value: ref.account),
            .init(name: "currency_code", value: "prl")], scope: .full))
    }

    static func paid(from data: Data) throws -> Double {
        (try PoolHTTP.decode(F2PayoutsResp.self, from: data).data ?? []).reduce(0) { $0 + ($1.amount?.value ?? 0) }
    }

    /// Balance and today's estimate are the figures with NO JSON action — both are
    /// server-rendered, so they come off the page itself. Never throws: a markup change or a
    /// failed fetch must degrade the card to 0, not break it.
    static func revenue(_ ref: F2PoolRef) async -> F2Revenue {
        guard var c = URLComponents(string: base(ref)) else { return F2Revenue(balance: 0, estToday: 0) }
        c.queryItems = [URLQueryItem(name: "user_name", value: ref.account)]
        guard let url = c.url, let d = try? await PoolHTTP.get(url, timeout: 25, accept: nil),
              let html = String(data: d, encoding: .utf8) else { return F2Revenue(balance: 0, estToday: 0) }
        return revenue(html: html)
    }

    /// A money amount as f2pool renders it, e.g. "1.15106604" or "1,234.5" — strip grouping
    /// separators before parsing, or a comma silently truncates the value.
    private static func amount(_ s: Substring) -> Double {
        Double(s.replacingOccurrences(of: ",", with: "")) ?? 0
    }

    /// Each figure has a stable, language-independent hook:
    ///   • balance      → `<span class="balance-num" data-balance=1.23…>` (attribute unquoted)
    ///   • today's est. → the `.num` cell right after the `revenue-est-today-tooltip` marker
    /// (Anchoring on the CSS class, not the label text, is what survives `?lang=`.)
    /// Note f2pool settles PPS once a day at 00:00 UTC — until then the day's earnings sit in
    /// `estToday` and `balance` reads 0.
    static func revenue(html: String) -> F2Revenue {
        var balance = 0.0
        if let m = html.range(of: "data-balance=\"?[0-9][0-9.,]*", options: .regularExpression),
           let num = html[m].split(separator: "=").last {
            balance = amount(num.drop { $0 == "\"" })
        }
        var est = 0.0
        if let anchor = html.range(of: "revenue-est-today-tooltip"),
           let cell = html.range(of: "class=\"num\"", range: anchor.upperBound..<html.endIndex),
           let num = html.range(of: "[0-9][0-9.,]*", options: .regularExpression,
                                range: cell.upperBound..<html.endIndex) {
            est = amount(html[num])
        }
        return F2Revenue(balance: balance, estToday: est)
    }

    /// Full: workers decide whether the key is live; revenue/paid are best-effort so a hiccup
    /// on either can't blank an otherwise healthy card. Live: workers only (the widget never
    /// shows money, and the revenue page alone is ~280 KB).
    static func miner(_ id: String, scope: PoolScope) async throws -> PoolMinerStats? {
        guard let ref = F2PoolRef(id) else { return nil }
        async let rev: F2Revenue? = scope == .full ? await revenue(ref) : nil
        async let pd: Double? = scope == .full ? (try? await totalPaid(ref)) : nil
        let w: F2WorkersResp
        do { w = try await workers(ref, scope: scope) }
        catch PoolHTTPError.status(404) { return nil }   // key revoked / mistyped → 未在此矿池
        return stats(w, revenue: await rev, paid: await pd ?? 0)
    }

    static func stats(_ w: F2WorkersResp, revenue r: F2Revenue?, paid: Double) -> PoolMinerStats? {
        guard let o = w.originData else { return nil }
        var s = PoolMinerStats()
        // Account-level figures are raw H/s; per-worker are TH/s (×hashScale → H/s).
        // F2Pool publishes NO instantaneous rate: its freshest figure is a 15-minute
        // average, and there is no 1h series either — hence only [15分, 24h]. Nothing
        // is passed off as 实时.
        s.windows = [.m15, .day]
        s.rates = [.m15: o.summary?.hash_rate?.value ?? 0,
                   .day: o.summary?.hash_rate_daily?.value ?? 0]
        s.paid = paid
        // F2Pool settles PPS once a day (00:00 UTC): until then the day's earnings sit in
        // the "today's estimate" tile and `balance` reads 0 — which would show a freshly
        // pointed rig as earning nothing. Fall back to the estimate, and RELABEL so the
        // figure is never passed off as a settled balance.
        let balance = r?.balance ?? 0, est = r?.estToday ?? 0
        if balance > 0 || est <= 0 {
            s.pending = balance
        } else {
            s.pending = est
            s.pendingKind = .todayEstimate
        }
        s.workers = (o.workers ?? []).map { w in
            WatchWorker(name: w.name ?? "—",
                        online: (w.status?.value ?? 1) == 0,   // 0 online · 1 offline · 2 dead
                        rates: [.m15: (w.hashrate?.value ?? 0) * hashScale,
                                .day: (w.hashrate_last_day?.value ?? 0) * hashScale])
        }
        .sorted(by: onlineFirst)
        return s
    }
}
