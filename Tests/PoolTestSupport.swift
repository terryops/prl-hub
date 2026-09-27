import Foundation
@testable import Pearl

/// Recorded pool responses under Tests/Fixtures (real payloads captured 2026-09-27, trimmed of
/// history rows the app never reads; F2Pool is synthetic — it has no public page to record).
enum Fixture {
    private final class Token {}

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: Token.self)
        guard let url = bundle.url(forResource: name, withExtension: nil)
                ?? bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name]) }
        return try Data(contentsOf: url)
    }

    static func string(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }
}

/// |a − b| within a relative tolerance — the reference values were summed in another language,
/// so the last bit of a float sum may differ.
func close(_ a: Double, _ b: Double, _ rel: Double = 1e-9) -> Bool {
    abs(a - b) <= max(abs(a), abs(b)) * rel + 1e-12
}

/// Canned HTTP responses for URLSession.shared, keyed by host + path. Unregistered URLs pass
/// through untouched, so the host app's own traffic is unaffected.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { let status: Int; let body: Data }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var hitCount: [String: Int] = [:]

    private static func key(_ url: URL?) -> String { (url?.host ?? "") + (url?.path ?? "") }

    /// Queue replies for `host+path`; the last one repeats once the queue drains.
    static func stub(_ hostPath: String, _ replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        queue[hostPath] = replies
        hitCount[hostPath] = 0
    }

    static func hits(_ hostPath: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return hitCount[hostPath] ?? 0
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queue = [:]; hitCount = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return queue[key(request.url)] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let k = Self.key(request.url)
        Self.lock.lock()
        var replies = Self.queue[k] ?? []
        let reply = replies.count > 1 ? replies.removeFirst() : replies.first
        Self.queue[k] = replies
        Self.hitCount[k, default: 0] += 1
        Self.lock.unlock()
        guard let reply, let url = request.url,
              let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: nil)
        else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
