import Foundation

/// The key that lets Pearl Hub use its own Blockbook at node.pearlhub.net (the gateway
/// refuses requests without it, and the app then falls back to the official indexer).
/// Stored masked so it isn't a plain string in the binary. The public repo gets an empty
/// key (tools/publish-oss.sh) — builds from there use the official indexer only.
enum NodeAccess {
    static let header = "X-Pearl-Hub-Key"
    static let key: String = {
        let masked: [UInt8] = []  // oss: node key (private, not published)
        return String(decoding: masked.enumerated().map { $0.element ^ UInt8(truncatingIfNeeded: 0xA5 &+ $0.offset &* 7) }, as: UTF8.self)
    }()
    /// Whether this build may use node.pearlhub.net at all.
    static var enabled: Bool { key.count >= 32 }
}
