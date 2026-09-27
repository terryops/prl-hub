import Foundation

// MARK: - The one request layer every pool client uses (app and widget alike)
//
// Nine pool clients used to carry nine copies of "build a URLRequest, check for 200, decode",
// each with its own error type, User-Agent and cache policy — which is how a 404 came to mean
// "not mining here" for one pool and a 5xx the same thing for another. Everything goes through
// here now: a non-200 is always a `PoolHTTPError.status(code)`, and each source decides what a
// 404 means for it.

/// Browser-like User-Agent for pool requests. The app runs on-device with the
/// user's own IP; a real-browser UA matches that and avoids non-browser soft-filters.
let poolBrowserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

/// A pool answered with a non-200. Carries the code so a 404 ("no such miner") can be told
/// apart from a 5xx ("try again"), which is the difference between 未在此矿池 and 查询失败.
enum PoolHTTPError: Error, Equatable { case status(Int) }

enum PoolHTTP {
    /// GET `url` → body. Throws `PoolHTTPError.status` on any non-200 and URLError on transport.
    ///
    /// `live`: per-miner numbers and an explicit refresh must hit the pool, never replay a cached
    /// body (the numbers would never move and refresh would look broken). Aggregate feeds that
    /// publish their own `Cache-Control` (lordofpearls: max-age 60/300) pass `false` so the
    /// shared URLCache honours it — the pool computes those every few minutes anyway.
    static func get(_ url: URL, timeout: TimeInterval = 20, live: Bool = true,
                    accept: String? = "application/json",
                    headers: [String: String] = [:]) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = live ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
        if let accept { req.setValue(accept, forHTTPHeaderField: "Accept") }
        req.setValue(poolBrowserUA, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (d, r) = try await URLSession.shared.data(for: req)
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw PoolHTTPError.status(code) }
        return d
    }

    static func get(_ s: String, timeout: TimeInterval = 20, live: Bool = true,
                    accept: String? = "application/json",
                    headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: s) else { throw URLError(.badURL) }
        return try await get(url, timeout: timeout, live: live, accept: accept, headers: headers)
    }

    /// Decode a pool payload. (A thin wrapper so every source reports a decode failure the
    /// same way — as an error, which `isTransient` then refuses to retry.)
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// Worth another try: the request never got an answer (timeout, dropped connection, DNS or
    /// connect failure) or the pool said it's busy (5xx / 429). A 4xx or an undecodable body is
    /// the pool's definitive answer — AlphaPool 400s an address it can't parse — and retrying
    /// it only burns the watch's deadline.
    static func isTransient(_ error: Error) -> Bool {
        if let e = error as? PoolHTTPError, case .status(let code) = e {
            return code == 429 || code >= 500 || code == 0
        }
        guard let u = error as? URLError else { return false }
        switch u.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed, .badServerResponse,
             .resourceUnavailable, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
            return true
        default:
            return false
        }
    }

    /// Run `op` up to `attempts` times — backing off 0.6s, 1.2s… between TRANSIENT failures
    /// only — all inside one overall `deadline`. A slow pool can therefore hold its own card for
    /// at most `deadline` seconds, never the whole refresh (20s × 5 × 3 tries used to add up to
    /// ~5 minutes). Cancellation propagates: the in-flight request is cancelled with the caller.
    static func retrying<T: Sendable>(attempts: Int = 3, deadline: TimeInterval,
                                      _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                var attempt = 1
                while true {
                    do { return try await op() }
                    catch {
                        guard attempt < attempts, isTransient(error), !Task.isCancelled else { throw error }
                        try await Task.sleep(for: .milliseconds(600 * attempt))
                        attempt += 1
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(deadline))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}
