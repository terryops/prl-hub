import Foundation
import SwiftUI

// MARK: - New-version notice
//
// Asks Apple's public lookup for this platform's latest App Store version, at most every
// 6 hours (launch + coming back to the app). While that version is newer than the running
// one — and this device's OS can install it — the wallet page shows a banner that opens the
// App Store. Closing it hides that version for good; the next release shows it again.
//
// iOS and Mac ship different versions at different times, so each asks for its own:
// the Mac app is the record's `desktopSoftware` entity. TestFlight and debug builds run
// ahead of the store, so they simply never see it.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// The newer App Store version to tell the user about; nil when up to date, unknown,
    /// not installable on this OS, or dismissed.
    @Published private(set) var available: String?

    private static let latestKey = "update.latest"        // last version the store reported
    private static let minOSKey = "update.minOS"          // and the OS it needs
    private static let checkedKey = "update.checkedAt"    // unix seconds
    private static let dismissedKey = "update.dismissed"  // the version the user closed
    private static let interval: TimeInterval = 6 * 3600

    private var checking = false

    init() { recompute() }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var storeURL: URL {
        #if os(macOS)
        URL(string: "macappstore://apps.apple.com/app/id\(ReviewPrompt.appStoreID)")!
        #else
        URL(string: "itms-apps://apps.apple.com/app/id\(ReviewPrompt.appStoreID)")!
        #endif
    }

    func checkIfDue() async {
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        guard !checking, Self.isDue(lastChecked: d.double(forKey: Self.checkedKey), now: now) else { return }
        checking = true
        defer { checking = false }
        // A failed lookup leaves the stamp alone, so the next foreground tries again.
        guard let found = await Self.fetch() else { return }
        d.set(now, forKey: Self.checkedKey)
        d.set(found.version, forKey: Self.latestKey)
        d.set(found.minOS, forKey: Self.minOSKey)
        recompute()
    }

    /// Six hours since the last answer. A stamp from the future means the clock was set back:
    /// check now rather than wait for the clock to catch up with it.
    static func isDue(lastChecked: TimeInterval, now: TimeInterval) -> Bool {
        lastChecked > now || now - lastChecked >= interval
    }

    func dismiss() {
        guard let v = available else { return }
        UserDefaults.standard.set(v, forKey: Self.dismissedKey)
        available = nil
    }

    private func recompute() {
        let d = UserDefaults.standard
        let os = ProcessInfo.processInfo.operatingSystemVersion
        available = Self.notice(latest: d.string(forKey: Self.latestKey),
                                minOS: d.string(forKey: Self.minOSKey),
                                current: Self.currentVersion,
                                dismissed: d.string(forKey: Self.dismissedKey),
                                os: [os.majorVersion, os.minorVersion, os.patchVersion])
    }

    /// The version to show, or nil. Pure, for the tests.
    nonisolated static func notice(latest: String?, minOS: String?, current: String,
                                   dismissed: String?, os: [Int]) -> String? {
        guard let latest, compare(latest, current) > 0, latest != dismissed else { return nil }
        if let minOS, compare(minOS, os.map(String.init).joined(separator: ".")) > 0 { return nil }
        return latest
    }

    /// Dotted-number comparison: "2.1.10" > "2.1.9", "2.1" == "2.1.0". -1 / 0 / 1.
    nonisolated static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r ? 1 : -1 }
        }
        return 0
    }

    /// This platform's latest App Store version and minimum OS, or nil on any failure.
    /// The US storefront answers for all: a version goes out everywhere at once.
    nonisolated private static func fetch() async -> (version: String, minOS: String?)? {
        #if os(macOS)
        let entity = "&entity=desktopSoftware"
        #else
        let entity = ""
        #endif
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(ReviewPrompt.appStoreID)&country=us\(entity)")
        else { return nil }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    nonisolated static func parse(_ data: Data) -> (version: String, minOS: String?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let app = results.first(where: { ($0["trackId"] as? Int).map(String.init) == ReviewPrompt.appStoreID }),
              let version = app["version"] as? String, compare(version, "0") > 0
        else { return nil }
        return (version, app["minimumOsVersion"] as? String)
    }
}
