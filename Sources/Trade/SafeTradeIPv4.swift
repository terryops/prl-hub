import Foundation
import Network
import os

// SafeTrade over IPv4 only.
//
// SafeTrade binds every API key to a Trusted IPs list, and safetrade.com sits behind
// Cloudflare with both A and AAAA records. URLSession races IPv4 against IPv6 per
// connection (Happy Eyeballs), so one Wi-Fi alternated between an IPv4 address the
// user had whitelisted and a rotating IPv6 one — and every call on the IPv6 path came
// back `authz.*trusted*ip`. URLSession has no way to pin the address family, so the
// requests go out on an NWConnection with IPv4 required: on a given network the
// address SafeTrade sees is then its one public IPv4, which a whitelist can hold.
//
// A network with no IPv4 at all (IPv6-only / NAT64) can't take that path; the request
// then falls back to URLSession — but only if the IPv4 connection never came up, so a
// request is never sent twice.
//
// System proxies are still honoured (as URLSession does): with a proxy or VPN on, the
// address SafeTrade sees is the proxy's exit, whichever family it uses — bypassing it
// could leave the exchange unreachable where it's only reachable through the proxy.

enum SafeTradeIPv4 {
    static let host = "safetrade.com"
    /// Replies are small JSON documents; anything this big is not one of them.
    static let maxResponse = 8 << 20
    /// How long the IPv4 connection may take to come up before the request falls back.
    private static let connectTimeout = 8
    /// After an IPv4 attempt ran into `connectTimeout`, requests skip straight to
    /// URLSession for a while instead of each paying the wait again.
    private static let skipAfterTimeout: TimeInterval = 120
    private static let skipUntil = OSAllocatedUnfairLock(initialState: Date.distantPast)

    /// `request` over IPv4, falling back to `fallback` when no IPv4 connection can be
    /// made. Errors are URLErrors, with the same meaning as URLSession's: failures
    /// before the request left the device (`.cannotConnectToHost`, …) vs. after it
    /// (`.timedOut`, `.networkConnectionLost`, `.badServerResponse`).
    static func data(for request: URLRequest, fallback: URLSession) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", url.host == host,
              skipUntil.withLock({ $0 }) < Date(),
              let payload = SafeTradeHTTP.request(for: request, host: host, userAgent: userAgent)
        else { return try await viaSession(request, fallback) }
        let exchange = Exchange(payload: payload, timeout: request.timeoutInterval)
        let started = Date()
        let outcome = await withTaskCancellationHandler { await exchange.run() } onCancel: { exchange.cancel() }
        switch outcome {
        case .unavailable:
            // A quick refusal (no IPv4 route) costs nothing; a connect that hung does.
            if Date().timeIntervalSince(started) >= Double(connectTimeout) - 1 {
                skipUntil.withLock { $0 = Date().addingTimeInterval(skipAfterTimeout) }
            }
            return try await viaSession(request, fallback)
        case .failed(let e):
            throw e
        case .response(let r):
            guard let http = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1",
                                             headerFields: r.headers)
            else { throw URLError(.badServerResponse) }
            return (r.body, http)
        }
    }

    private static func viaSession(_ request: URLRequest, _ session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// The same shape URLSession sends ("Pearl/127 CFNetwork/… Darwin/…").
    static let userAgent: String = {
        let info = Bundle.main.infoDictionary
        let app = (info?["CFBundleName"] as? String) ?? "Pearl"
        let build = (info?["CFBundleVersion"] as? String) ?? "1"
        let cfNetwork = (Bundle(identifier: "com.apple.CFNetwork")?.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
        var u = utsname()
        uname(&u)
        let darwin = withUnsafeBytes(of: &u.release) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(app)/\(build) CFNetwork/\(cfNetwork) Darwin/\(darwin)"
    }()

    private enum Outcome: Sendable {
        /// The IPv4 connection never came up; nothing was sent.
        case unavailable
        case response(SafeTradeHTTP.Response)
        /// Failed while or after sending — the request may have reached SafeTrade.
        case failed(URLError)
    }

    /// One request/response on its own connection (`Connection: close`). All state is
    /// touched only on `queue`, which is also where the connection delivers callbacks.
    private final class Exchange: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.prl.wizard.safetrade.ipv4")
        private let connection: NWConnection
        private let payload: Data
        private let timeout: TimeInterval
        private var buffer = Data()
        private var sent = false
        private var finished = false
        private var continuation: CheckedContinuation<Outcome, Never>?

        init(payload: Data, timeout: TimeInterval) {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = SafeTradeIPv4.connectTimeout
            let params = NWParameters(tls: tls, tcp: tcp)
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            // The TLS server name comes from the host endpoint (SNI = safetrade.com).
            connection = NWConnection(host: NWEndpoint.Host(SafeTradeIPv4.host), port: 443, using: params)
            self.payload = payload
            self.timeout = timeout > 0 ? timeout : 20
        }

        func run() async -> Outcome {
            await withCheckedContinuation { c in
                queue.async { [self] in
                    // Cancelled before it started.
                    guard !finished else { c.resume(returning: .failed(URLError(.cancelled))); return }
                    continuation = c
                    connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                    connection.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.timeUp() }
                }
            }
        }

        func cancel() {
            queue.async { [self] in
                if continuation == nil { finished = true } else { finish(.failed(URLError(.cancelled))) }
            }
        }

        private func handle(_ state: NWConnection.State) {
            switch state {
            case .ready:
                guard !sent else { return }
                send()
            case .waiting, .failed:
                // Before `.ready`: no IPv4 route, refused, TLS failure — nothing sent, so
                // URLSession may take it. After sending: the reply was cut off.
                finish(sent ? .failed(URLError(.networkConnectionLost)) : .unavailable)
            default:
                break
            }
        }

        private func send() {
            sent = true   // from here on the request may reach SafeTrade: it is never re-sent
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil { self.finish(.failed(URLError(.networkConnectionLost))) } else { self.receive() }
            })
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, isComplete, error in
                guard let self, !self.finished else { return }
                if let data { self.buffer.append(data) }
                guard self.buffer.count <= SafeTradeIPv4.maxResponse else {
                    self.finish(.failed(URLError(.dataLengthExceedsMaximum)))
                    return
                }
                do {
                    // A complete message ends the exchange even if the socket stays open.
                    if let r = try SafeTradeHTTP.parse(self.buffer, atEOF: isComplete) {
                        self.finish(.response(r))
                        return
                    }
                } catch {
                    self.finish(.failed(URLError(.badServerResponse)))
                    return
                }
                if isComplete || error != nil {
                    self.finish(.failed(URLError(.networkConnectionLost)))
                } else {
                    self.receive()
                }
            }
        }

        private func timeUp() {
            finish(sent ? .failed(URLError(.timedOut)) : .unavailable)
        }

        private func finish(_ outcome: Outcome) {
            guard !finished else { return }
            finished = true
            continuation?.resume(returning: outcome)
            continuation = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }
}

/// The HTTP/1.1 the IPv4 path speaks: build a request, read a response. Pure (no
/// networking) so it can be unit-tested.
enum SafeTradeHTTP {
    struct Response: Equatable, Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    struct Malformed: Error {}

    private static let crlf = Data("\r\n".utf8)
    private static let blankLine = Data("\r\n\r\n".utf8)

    /// The request bytes: request line, headers, body. `Connection: close` (one request
    /// per connection) and `Accept-Encoding: identity` (no decompression to do).
    static func request(for req: URLRequest, host: String, userAgent: String) -> Data? {
        guard let url = req.url, let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var target = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
        if let q = comps.percentEncodedQuery, !q.isEmpty { target += "?" + q }
        let method = req.httpMethod ?? "GET"
        let body = req.httpBody ?? Data()
        var lines = ["\(method) \(target) HTTP/1.1", "Host: \(host)", "User-Agent: \(userAgent)",
                     "Accept-Encoding: identity", "Connection: close"]
        let own: Set<String> = ["host", "user-agent", "accept-encoding", "connection", "content-length"]
        for (name, value) in (req.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key })
        where !own.contains(name.lowercased()) && !(name + value).contains(where: \.isNewline) {
            lines.append("\(name): \(value)")
        }
        if !body.isEmpty || method != "GET" { lines.append("Content-Length: \(body.count)") }
        var data = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    /// A complete response from `raw`, nil while more bytes are needed. `atEOF`: the
    /// server closed the connection, so what's there is all there is — a body without
    /// a length runs to here, and a short one is an error.
    static func parse(_ raw: Data, atEOF: Bool) throws -> Response? {
        var start = raw.startIndex
        while true {
            guard let end = raw.range(of: blankLine, in: start..<raw.endIndex) else {
                if atEOF { throw Malformed() }
                return nil
            }
            let head = String(decoding: raw[start..<end.lowerBound], as: UTF8.self)
            let lines = head.components(separatedBy: "\r\n")
            let statusParts = lines[0].split(separator: " ", maxSplits: 2)
            guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."),
                  let status = Int(statusParts[1]), (100...599).contains(status) else { throw Malformed() }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { throw Malformed() }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { throw Malformed() }
                if let key = headers.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    headers[key] = headers[key]! + ", " + value
                } else {
                    headers[name] = value
                }
            }
            // An interim reply (100 Continue …): the real one follows.
            if status < 200 { start = end.upperBound; continue }

            let found = Response(status: status, headers: headers, body: Data())
            if status == 204 || status == 304 { return found }
            if let enc = found.header("Content-Encoding")?.lowercased(), enc != "identity" { throw Malformed() }
            let rest = Data(raw[end.upperBound...])
            if found.header("Transfer-Encoding")?.lowercased().contains("chunked") == true {
                guard let body = try dechunk(rest) else {
                    if atEOF { throw Malformed() }
                    return nil
                }
                return Response(status: status, headers: headers, body: body)
            }
            if let lengthText = found.header("Content-Length") {
                guard let length = Int(lengthText), length >= 0 else { throw Malformed() }
                if rest.count >= length { return Response(status: status, headers: headers, body: rest.prefix(length)) }
                if atEOF { throw Malformed() }
                return nil
            }
            return atEOF ? Response(status: status, headers: headers, body: rest) : nil
        }
    }

    /// The body of a chunked message, nil while the final chunk hasn't arrived.
    static func dechunk(_ data: Data) throws -> Data? {
        var out = Data()
        var i = data.startIndex
        while true {
            guard let lineEnd = data.range(of: crlf, in: i..<data.endIndex) else { return nil }
            let line = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self)
            // "1a;name=value" — chunk extensions are ignored.
            let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !sizeText.isEmpty, let size = Int(sizeText, radix: 16), size >= 0,
                  size <= SafeTradeIPv4.maxResponse else { throw Malformed() }
            let chunkStart = lineEnd.upperBound
            if size == 0 {
                // Optional trailer fields, then a blank line.
                let trailer = data[chunkStart...]
                if trailer.starts(with: crlf) || trailer.range(of: blankLine) != nil { return out }
                return nil
            }
            guard data.distance(from: chunkStart, to: data.endIndex) >= size + 2 else { return nil }
            let chunkEnd = data.index(chunkStart, offsetBy: size)
            guard data[chunkEnd..<data.index(chunkEnd, offsetBy: 2)].elementsEqual(crlf) else { throw Malformed() }
            out.append(data[chunkStart..<chunkEnd])
            i = data.index(chunkEnd, offsetBy: 2)
        }
    }
}
