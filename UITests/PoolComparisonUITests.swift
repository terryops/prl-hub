import XCTest

/// Live integration check: a new phone session reads the shared server's dated
/// PPS observation, and comparing columns keeps the pool name in view.
@MainActor final class PoolComparisonUITests: XCTestCase {
    func testPhoneComparisonAndDatedFeeExplanation() {
        executionTimeAllowance = 60
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-app.language", "zh-Hans",
                               "-ui.appearance", "light", "-prlmonitor.introSeen", "YES"]
        app.launchEnvironment = ["SHOT_MEMORY_KEYCHAIN": "1", "SHOT_TAB": "2", "SHOT_SECTION": "矿池"]
        app.launch()
        let help = app.buttons["pool-real-fee-help"].firstMatch
        XCTAssertTrue(help.waitForExistence(timeout: 45), "The phone did not receive a server PPS measurement")
        let name = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Kryptex")).firstMatch
        XCTAssertTrue(name.exists)
        let originalX = name.frame.minX
        capture("phone-pool-comparison")
        help.tap()
        let explanation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "期间，实际结算收益相对理论收益的折损率")).firstMatch
        XCTAssertTrue(explanation.waitForExistence(timeout: 5))
        XCTAssertLessThan(explanation.label.count, 100)
        XCTAssertTrue(explanation.isHittable)
        capture("phone-real-fee-explanation")
        app.buttons["关闭"].firstMatch.tap()
        // SwiftUI exposes the inner horizontal scroller as a container rather
        // than an XCUI ScrollView; drag in its visible region.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.90, dy: 0.40))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.38, dy: 0.40))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(name.isHittable)
        XCTAssertEqual(name.frame.minX, originalX, accuracy: 1)
        capture("phone-pool-comparison-scrolled")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
