import Foundation

/// Sign in once, on every device. A signed-in app keeps a ticket in the user's iCloud
/// Keychain (end-to-end encrypted, shared by their iPhone, iPad and Mac); a device that isn't
/// signed in trades it for a session of its own (POST /v1/auth/ticket).
///
/// Never a copy of the session itself: the server rotates refresh tokens and treats a reused
/// one as stolen, so two devices sharing one session would sign each other out.
struct DeviceTicket: Codable, Equatable {
    var user: String
    var email: String?
    var ticket: String
    /// The installation that issued it (its `account.device`): it can't trade its own ticket.
    var device: String
    var issued: Date
    var expires: Date

    static let account = "account.ticket"
    /// Issue a fresh ticket this often, well inside its 30-day life.
    static let refreshAfter: TimeInterval = 7 * 86400

    static func read() -> DeviceTicket? {
        Keychain.get(account: account, synchronizable: true).flatMap(decode)
    }

    static func decode(_ s: String) -> DeviceTicket? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(DeviceTicket.self, from: Data(s.utf8))
    }

    var encoded: String? {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return (try? e.encode(self)).map { String(decoding: $0, as: UTF8.self) }
    }

    @discardableResult
    func write() -> Bool {
        guard let encoded else { return false }
        return Keychain.set(encoded, account: Self.account, synchronizable: true)
    }

    static func delete() {
        Keychain.delete(account: account, synchronizable: true)
    }

    /// Whether a device signed in as `user` should issue a fresh ticket in place of `held`:
    /// there is none, it is (about to be) out of date, or it is this account's and due for
    /// renewal. Another account's live ticket is left alone — signing in by email is what
    /// replaces it (whoever did that last decides).
    static func needsIssue(_ held: DeviceTicket?, user: String, now: Date) -> Bool {
        guard let held else { return true }
        if held.expires <= now.addingTimeInterval(86400) { return true }
        return held.user == user && now.timeIntervalSince(held.issued) >= refreshAfter
    }

    /// The ticket a device that isn't signed in can use: one still in date, issued by another
    /// installation.
    static func usable(_ held: DeviceTicket?, device: String?, now: Date) -> DeviceTicket? {
        guard let held, held.expires > now, held.device != device else { return nil }
        return held
    }
}
