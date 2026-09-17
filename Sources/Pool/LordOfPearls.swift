import Foundation

// MARK: - lordofpearls.xyz — the Pearl explorer, as one source for chain + pools
//
// Two endpoints, two shapes:
//
//   • /api/public — JSON straight off the site's own Pearl full node: difficulty, network
//     hashrate, average block time, the last 30 blocks (→ the current subsidy) and a
//     whole-chain difficulty series. This is where 难度 / 全网算力 / 单位日产 come from.
//
//   • /pools — the per-pool comparison table: fee, payout scheme, miner count, blocks found
//     in the last 24h (counted on-chain by coinbase attribution, not taken on trust) and
//     each pool's live hashrate, polled from that pool's own API every ~10 min. It is
//     server-rendered HTML with no JSON twin — /pools.json 404s, and both `?format=json`
//     and `Accept: application/json` hand back the same page — so it is parsed.
//
// The table's columns are located by their HEADER TEXT, never by index: the site already
// carries a paid "Banner" column between the name and the numbers, and one more inserted
// anywhere would otherwise shift every value one cell to the left, silently.

struct LordOfPearlsClient {
    private static let api = "https://lordofpearls.xyz/api/public"
    private static let poolsPage = "https://lordofpearls.xyz/pools"

    private func get(_ s: String, timeout: TimeInterval = 20) async throws -> Data {
        guard let url = URL(string: s) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData   // refresh must fetch live numbers
        req.setValue(poolBrowserUA, forHTTPHeaderField: "User-Agent")
        let (d, r) = try await URLSession.shared.data(for: req)
        guard (r as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return d
    }

    /// Chain-wide stats from the site's node.
    func publicStats() async throws -> LOPPublic {
        try JSONDecoder().decode(LOPPublic.self, from: try await get(Self.api))
    }

    /// Every pool the site lists, in its own ranking order (by live hashrate).
    /// Throws when the page can no longer be parsed, so the caller falls back.
    func pools() async throws -> [LOPPool] {
        guard let html = String(data: try await get(Self.poolsPage), encoding: .utf8)
        else { throw URLError(.cannotDecodeContentData) }
        let rows = LOPPool.parse(html)
        guard !rows.isEmpty else { throw URLError(.cannotParseResponse) }
        return rows
    }
}

// MARK: - /api/public

/// Everything the site's dashboard renders, in one document. Only the fields the app uses
/// are declared: an undeclared key can't break the decode, and this payload also carries a
/// lot the app has no use for (peer geo-IP, holder distribution, visitor counts…).
struct LOPPublic: Decodable {
    struct Network: Decodable {
        let difficulty: Double?
        let networkhashps: Double?        // H/s, computed over the last 60 blocks
        let avg_block_time_s: Double?     // seconds, same 60-block window
    }
    struct Block: Decodable { let reward: Double? }   // PRL, already scaled
    struct Leaderboard: Decodable {
        let recent_blocks: [Block]?
        let total_blocks: Int?      // blocks the whole network found inside `window`
        let window: Double?         // length of that count, in `window_unit`
        let window_unit: String?    // "hours" today
    }
    /// One difficulty sample. The series spans the whole chain in ~200 points, so today's
    /// spacing is ≈19h — wide enough that a 24h window can hold a single point (see
    /// `averageDifficulty`, which interpolates the window edge rather than pretend).
    struct DiffPoint: Decodable { let t: Double?; let diff: Double? }
    struct Lifetime: Decodable { let hashrate_series: [DiffPoint]? }

    let ts: Double?                       // when the site built this snapshot (unix seconds)
    let network: Network?
    let leaderboard: Leaderboard?
    let lifetime: Lifetime?
}

extension LOPPublic {
    private func positive(_ v: Double?) -> Double? { (v ?? 0) > 0 ? v : nil }

    var difficulty: Double? { positive(network?.difficulty) }
    var networkHashrate: Double? { positive(network?.networkhashps) }
    var blockTimeSec: Double? { positive(network?.avg_block_time_s) }

    /// Seconds per block MEASURED over the site's 24h window (its on-chain block count for the
    /// last day). Prefer this to `avg_block_time_s`, which is a 60-block window: pairing a
    /// 60-block block time with a daily figure is exactly the mismatch that put the app's
    /// network hashrate 18% high — and the count checks out against the chain (238 blocks
    /// spanning 24.0h when verified against Blockbook on 2026-07-24).
    var blockTime24h: Double? {
        guard let n = leaderboard?.total_blocks, n > 0 else { return nil }
        let hours = (leaderboard?.window_unit ?? "hours").hasPrefix("hour") ? (leaderboard?.window ?? 24) : 24
        let secs = hours * 3600 / Double(n)
        return (30...3600).contains(secs) ? secs : nil
    }

    /// Current block subsidy, as the MEDIAN of the last 30 rewards — a mean would be pulled
    /// by a block that carried unusual fees, while the subsidy itself only steps at a halving.
    var rewardPerBlock: Double? {
        let r = (leaderboard?.recent_blocks ?? []).compactMap(\.reward).filter { $0 > 0 }.sorted()
        return r.isEmpty ? nil : r[r.count / 2]
    }

    /// Time-weighted average difficulty over the trailing `days` — the app's difficulty24 /
    /// difficulty3 / difficulty7 snapshots, which WhatToMine used to supply.
    ///
    /// The series is far too coarse to average by simply taking the points inside the window
    /// (24h can contain ONE), so the value at the window's leading edge is interpolated from
    /// the straddling pair and the live difficulty closes the trapezoid at `now`. Measured
    /// against WhatToMine on 2026-07-24 that lands within 0.2% on all three windows; naively
    /// averaging the interior points alone was 2.6% off at 24h.
    func averageDifficulty(days: Double) -> Double? {
        guard days > 0, let live = difficulty else { return nil }
        let now = ts ?? Date().timeIntervalSince1970
        let series = (lifetime?.hashrate_series ?? [])
            .compactMap { p -> (t: Double, d: Double)? in
                guard let t = p.t, let d = p.diff, t > 0, d > 0, t <= now else { return nil }
                return (t, d)
            }
            .sorted { $0.t < $1.t }
        guard !series.isEmpty else { return nil }

        let from = now - days * 86400
        var pts = series.filter { $0.t >= from }
        if let before = series.last(where: { $0.t < from }) {
            let next = pts.first ?? (t: now, d: live)
            let span = next.t - before.t
            let f = span > 0 ? (from - before.t) / span : 0
            pts.insert((t: from, d: before.d + (next.d - before.d) * f), at: 0)
        }
        pts.append((t: now, d: live))

        var weighted = 0.0, span = 0.0
        for (a, b) in zip(pts, pts.dropFirst()) where b.t > a.t {
            weighted += (a.d + b.d) / 2 * (b.t - a.t)
            span += b.t - a.t
        }
        return span > 0 ? weighted / span : live
    }
}

// MARK: - /pools

/// One row of the comparison table. Anything the page prints as "—" (its explicit "this pool
/// has not published that figure" marker — never a guess) arrives here as nil, so it renders
/// downstream as "—" instead of as a zero that would sort the pool last and read as fact.
struct LOPPool {
    let name: String        // the site's own label ("AlphaMine", "PearlFortune"…)
    let url: String
    var miners: Int?
    var blocks24h: Int?
    var feePercent: Double?
    var payout: String?     // PPLNS · PROP · SOLO — the scheme, as the site curates it
    var hashrate: Double?   // raw H/s

    /// The pool's own domain — the stable key behind its app-side name and colour, since the
    /// site's labels drift from the app's ("AlphaMine" is the app's "AlphaPool").
    var host: String {
        let h = (URLComponents(string: url)?.host ?? "").lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

extension LOPPool {
    /// Parse the pool table out of the page. Returns [] when the markup no longer matches —
    /// the caller treats that as "source unavailable" and falls back.
    static func parse(_ html: String) -> [LOPPool] {
        guard let open = html.range(of: "<table[^>]*section-table[^>]*>", options: .regularExpression),
              let close = html.range(of: "</table>", range: open.upperBound..<html.endIndex)
        else { return [] }
        let table = html[open.upperBound..<close.lowerBound]

        let headers = LOPHTML.elements("th", in: table).map { LOPHTML.text($0).lowercased() }
        // Exact match first: a bare `contains` would resolve "payout" to whichever of
        // "payout" / "min payout" happens to come first.
        func column(_ name: String) -> Int? {
            headers.firstIndex(of: name) ?? headers.firstIndex { $0.contains(name) }
        }
        let cPool = column("pool") ?? 0
        let cMiners = column("miners"), cBlocks = column("blocks"), cFee = column("fee")
        let cPayout = column("payout"), cHash = column("hashrate")

        var out: [LOPPool] = []
        for row in LOPHTML.elements("tr", in: table) {
            let cells = LOPHTML.elements("td", in: row)
            guard cells.count > cPool else { continue }        // the header row carries no <td>
            func cell(_ i: Int?) -> String? {
                guard let i, i < cells.count else { return nil }
                return LOPHTML.text(cells[i])
            }
            let nameCell = cells[cPool]
            let name = LOPHTML.text(LOPHTML.elements("a", in: nameCell).first ?? nameCell)
            guard !name.isEmpty else { continue }
            out.append(LOPPool(name: name,
                               url: LOPHTML.attribute("href", in: nameCell) ?? "",
                               miners: count(cell(cMiners)),
                               blocks24h: count(cell(cBlocks)),
                               feePercent: percent(cell(cFee)),
                               payout: scheme(cell(cPayout)),
                               hashrate: hashrate(cell(cHash))))
        }
        return out
    }

    /// "31,703" → 31703; the page's "—" → nil.
    private static func count(_ s: String?) -> Int? {
        guard let s else { return nil }
        return Int(s.replacingOccurrences(of: ",", with: ""))
    }

    /// "4.4%" → 4.4
    private static func percent(_ s: String?) -> Double? {
        guard let s else { return nil }
        return Double(s.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }

    private static func scheme(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s != "—", s != "-" else { return nil }
        return s
    }

    /// "7.78 EH/s via PearlHash · 34s ago" → 7.78e18. The cell also carries the attribution
    /// and age line, so only the leading number+unit is read — and a cell whose first token
    /// isn't a number ("— 34s ago") means the pool publishes no feed at all, which is NOT
    /// the same statement as Akoya's honest "0 H/s".
    private static func hashrate(_ s: String?) -> Double? {
        let parts = (s ?? "").split(separator: " ")
        guard let head = parts.first,
              Double(head.replacingOccurrences(of: ",", with: "")) != nil else { return nil }
        return parseHashrate(parts.prefix(2).joined(separator: " "))
    }
}

// MARK: - The smallest HTML reader that can read that table

enum LOPHTML {
    /// Inner HTML of every `<tag …>…</tag>`, in document order. Deliberately naive: the
    /// tags it is asked for (tr / td / th / a) are never nested inside themselves here, so
    /// a depth-tracking parser would be dead weight.
    static func elements(_ tag: String, in s: Substring) -> [Substring] {
        var out: [Substring] = []
        var cursor = s.startIndex
        while let open = s.range(of: "<\(tag)", options: .caseInsensitive, range: cursor..<s.endIndex) {
            cursor = open.upperBound
            // "<td" must not also match "<table": the name has to end right here.
            guard open.upperBound < s.endIndex,
                  s[open.upperBound] == ">" || s[open.upperBound].isWhitespace else { continue }
            guard let gt = s.range(of: ">", range: open.upperBound..<s.endIndex),
                  let close = s.range(of: "</\(tag)>", options: .caseInsensitive,
                                      range: gt.upperBound..<s.endIndex) else { break }
            out.append(s[gt.upperBound..<close.lowerBound])
            cursor = close.upperBound
        }
        return out
    }

    /// Text of an HTML fragment. Tags collapse to a SPACE rather than to nothing: the
    /// hashrate cell is `<span>7.78 EH/s</span><svg…></svg><span>via PearlHash · 34s ago</span>`,
    /// and welding those together yields "EH/svia" — a unit that parses as nothing.
    static func text(_ frag: Substring) -> String {
        var out = ""
        var depth = 0
        for ch in frag {
            switch ch {
            case "<": depth += 1; out.append(" ")
            case ">": depth = max(0, depth - 1)
            default: if depth == 0 { out.append(ch) }
            }
        }
        return decode(out).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Value of `name="…"` inside a fragment; nil when absent.
    static func attribute(_ name: String, in frag: Substring) -> String? {
        guard let key = frag.range(of: "\(name)=\""),
              let end = frag.range(of: "\"", range: key.upperBound..<frag.endIndex) else { return nil }
        return decode(String(frag[key.upperBound..<end.lowerBound]))
    }

    private static let entities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
        "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&middot;": "·",
    ]

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return entities.reduce(s) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
}
