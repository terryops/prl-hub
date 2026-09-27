import Foundation
import Testing
@testable import Pearl

/// The HTTP/1.1 the IPv4 SafeTrade path speaks — offline, byte-level.
struct SafeTradeHTTPTests {
    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    @Test func contentLength() throws {
        let raw = bytes("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"a\":\"b\"}xx")
        let r = try #require(try SafeTradeHTTP.parse(raw, atEOF: false))
        #expect(r.status == 200)
        #expect(r.body == bytes("{\"a\":\"b\"}xx"))
        #expect(r.header("content-type") == "application/json")   // case-insensitive
        // Short body: wait for more, or fail once the server has closed.
        let short = bytes("HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n{}")
        #expect(try SafeTradeHTTP.parse(short, atEOF: false) == nil)
        #expect(throws: SafeTradeHTTP.Malformed.self) { try SafeTradeHTTP.parse(short, atEOF: true) }
        // Bytes past Content-Length are not body.
        let extra = try #require(try SafeTradeHTTP.parse(bytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}junk"), atEOF: true))
        #expect(extra.body == bytes("{}"))
    }

    @Test func chunked() throws {
        let raw = bytes("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n"
                        + "4;ext=1\r\n{\"a\"\r\n5\r\n:\"bc\"\r\n1\r\n}\r\n0\r\n\r\n")
        let r = try #require(try SafeTradeHTTP.parse(raw, atEOF: false))
        #expect(r.body == bytes("{\"a\":\"bc\"}"))
        // Trailer fields after the last chunk.
        let trailer = bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\nX-T: 1\r\n\r\n")
        #expect(try SafeTradeHTTP.parse(trailer, atEOF: false)?.body == bytes("{}"))
        // Uppercase hex sizes.
        let big = String(repeating: "x", count: 26)
        let hex = bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1A\r\n\(big)\r\n0\r\n\r\n")
        #expect(try SafeTradeHTTP.parse(hex, atEOF: false)?.body == bytes(big))
    }

    @Test func chunkedIncomplete() throws {
        let partial = bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\n{\"a\"\r\n")
        #expect(try SafeTradeHTTP.parse(partial, atEOF: false) == nil)
        #expect(throws: SafeTradeHTTP.Malformed.self) { try SafeTradeHTTP.parse(partial, atEOF: true) }
        // Last chunk seen but not its closing blank line yet.
        #expect(try SafeTradeHTTP.dechunk(bytes("2\r\n{}\r\n0\r\n")) == nil)
    }

    @Test func noLengthReadsToEOF() throws {
        let raw = bytes("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nip=203.0.113.9\n")
        #expect(try SafeTradeHTTP.parse(raw, atEOF: false) == nil)
        #expect(try SafeTradeHTTP.parse(raw, atEOF: true)?.body == bytes("ip=203.0.113.9\n"))
    }

    @Test func headersAndStatus() throws {
        let raw = bytes("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 401 Unauthorized\r\nX-A: 1\r\nx-a: 2\r\nContent-Length: 0\r\n\r\n")
        let r = try #require(try SafeTradeHTTP.parse(raw, atEOF: true))
        #expect(r.status == 401)                 // the interim 100 is skipped
        #expect(r.header("X-A") == "1, 2")       // repeated fields are joined
        #expect(r.body.isEmpty)
        #expect(try SafeTradeHTTP.parse(bytes("HTTP/1.1 204 No Content\r\n\r\n"), atEOF: false)?.body == Data())
    }

    @Test func malformed() throws {
        for bad in ["garbage\r\n\r\n", "HTTP/1.1 abc OK\r\n\r\n", "HTTP/1.1 200 OK\r\nno colon here\r\n\r\n",
                    "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n",
                    "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 2\r\n\r\n{}",
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n{}\r\n0\r\n\r\n",
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}XX0\r\n\r\n"] {
            #expect(throws: SafeTradeHTTP.Malformed.self, "\(bad)") { try SafeTradeHTTP.parse(bytes(bad), atEOF: true) }
        }
        // No header terminator yet: more bytes needed, unless the server already closed.
        #expect(try SafeTradeHTTP.parse(bytes("HTTP/1.1 200 OK\r\nContent-"), atEOF: false) == nil)
    }

    @Test func request() throws {
        var req = URLRequest(url: URL(string: "https://safetrade.com/api/v2/trade/market/orders?market=prlusdt&limit=20")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("k", forHTTPHeaderField: "X-Auth-Apikey")
        req.setValue("evil\r\nX-Injected: 1", forHTTPHeaderField: "X-Bad")
        req.httpBody = Data("a=1".utf8)
        let data = try #require(SafeTradeHTTP.request(for: req, host: "safetrade.com", userAgent: "Pearl/1"))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("POST /api/v2/trade/market/orders?market=prlusdt&limit=20 HTTP/1.1\r\nHost: safetrade.com\r\n"))
        #expect(text.contains("\r\nConnection: close\r\n"))
        #expect(text.contains("\r\nAccept-Encoding: identity\r\n"))
        #expect(text.contains("\r\nX-Auth-Apikey: k\r\n"))
        #expect(text.contains("\r\nContent-Length: 3\r\n\r\na=1"))
        #expect(!text.contains("X-Injected"))    // a header value with a line break is dropped
        // A body-less GET carries no Content-Length.
        let get = URLRequest(url: URL(string: "https://safetrade.com/cdn-cgi/trace")!)
        let getText = String(decoding: try #require(SafeTradeHTTP.request(for: get, host: "safetrade.com", userAgent: "u")), as: UTF8.self)
        #expect(getText.hasPrefix("GET /cdn-cgi/trace HTTP/1.1\r\n"))
        #expect(!getText.contains("Content-Length"))
        #expect(getText.hasSuffix("\r\n\r\n"))
    }
}
