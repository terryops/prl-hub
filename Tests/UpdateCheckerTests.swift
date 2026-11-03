import Foundation
import Testing
@testable import Pearl

/// 钱包页的新版本提示: when the banner shows, and reading Apple's lookup answer.
struct UpdateCheckerTests {
    @Test func versionsCompareByNumber() {
        #expect(UpdateChecker.compare("2.1.10", "2.1.9") == 1)
        #expect(UpdateChecker.compare("2.1.6", "2.1.7") == -1)
        #expect(UpdateChecker.compare("2.2", "2.1.9") == 1)
        #expect(UpdateChecker.compare("2.1", "2.1.0") == 0)
        #expect(UpdateChecker.compare("17.0", "26.0.1") == -1)
    }

    private func notice(_ latest: String?, current: String = "2.1.6", dismissed: String? = nil,
                        minOS: String? = "17.0", os: [Int] = [26, 0, 0]) -> String? {
        UpdateChecker.notice(latest: latest, minOS: minOS, current: current, dismissed: dismissed, os: os)
    }

    @Test func showsOnlyANewerVersion() {
        #expect(notice("2.1.7") == "2.1.7")
        #expect(notice("2.1.6") == nil)              // up to date
        #expect(notice("2.1.5") == nil)              // TestFlight / debug runs ahead of the store
        #expect(notice(nil) == nil)                  // never checked
    }

    @Test func closingHidesThatVersionOnly() {
        #expect(notice("2.1.7", dismissed: "2.1.7") == nil)
        #expect(notice("2.1.8", dismissed: "2.1.7") == "2.1.8")
    }

    @Test func skipsAVersionThisOSCannotInstall() {
        #expect(notice("2.1.7", minOS: "27.0", os: [26, 4, 0]) == nil)
        #expect(notice("2.1.7", minOS: "26.4", os: [26, 4, 0]) == "2.1.7")
        #expect(notice("2.1.7", minOS: nil) == "2.1.7")
    }

    @Test func readsLookupForThisApp() {
        let body = #"{"resultCount":1,"results":[{"kind":"software","trackId":\#(ReviewPrompt.appStoreID),"version":"2.1.5","minimumOsVersion":"17.0"}]}"#
        let found = UpdateChecker.parse(Data(body.utf8))
        #expect(found?.version == "2.1.5")
        #expect(found?.minOS == "17.0")
        #expect(UpdateChecker.parse(Data(#"{"resultCount":0,"results":[]}"#.utf8)) == nil)
        #expect(UpdateChecker.parse(Data(#"{"results":[{"trackId":1,"version":"9.9"}]}"#.utf8)) == nil)
        #expect(UpdateChecker.parse(Data("not json".utf8)) == nil)
    }
}
