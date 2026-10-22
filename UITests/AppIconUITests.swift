import XCTest

/// Exercises the setting and the system's icon-change confirmation.
@MainActor final class AppIconUITests: XCTestCase {
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func dismissIconAlert(in app: XCUIApplication, required: Bool = false, snapshot: String? = nil) {
        let deadline = Date().addingTimeInterval(required ? 10 : 2)
        repeat {
            for host in [app, springboard] {
                let alert = host.alerts.firstMatch
                if alert.exists {
                    if let snapshot { capture(snapshot) }
                    alert.buttons.firstMatch.tap()
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        XCTAssertFalse(required, "iOS did not confirm the alternate icon change")
    }

    private func reveal(_ button: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if button.exists && button.isHittable && button.frame.maxY < app.frame.maxY - 130 { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(button.isHittable, "Icon setting is not reachable")
    }

    private func select(_ name: String, in app: XCUIApplication) {
        let button = app.buttons["app-icon-" + name]
        reveal(button, in: app)
        let changed = !button.isSelected
        button.tap()
        dismissIconAlert(in: app, required: changed, snapshot: changed && name == "pearl" ? "pearl-system-confirmation" : nil)
        XCTAssertTrue(button.isSelected)
    }

    private func openIconSettings(in app: XCUIApplication) {
        let entry = app.buttons["settings-app-icon"]
        reveal(entry, in: app)
        entry.tap()
        XCTAssertTrue(app.buttons["app-icon-pearl"].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String) {
        // System confirmations and Home Screen transitions animate after the tap completes.
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPearlIconCanBeSelectedAndSurvivesRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-ui.appearance", "light"]
        app.launchEnvironment = ["SHOT_MEMORY_KEYCHAIN": "1", "SHOT_TAB": "4"]
        app.launch()
        dismissIconAlert(in: app)
        openIconSettings(in: app)
        reveal(app.buttons["app-icon-pearl"], in: app)
        let original = ["modern", "pearl", "classic"].first { app.buttons["app-icon-" + $0].isSelected }
        select("modern", in: app)
        select("pearl", in: app)
        capture("pearl-icon-picker")
        XCUIDevice.shared.press(.home)
        capture("pearl-home-screen")
        app.activate()
        app.navigationBars.buttons.firstMatch.tap()
        for _ in 0..<6 { app.swipeDown() }
        capture("pearl-settings-logo")

        app.terminate()
        app.launch()
        openIconSettings(in: app)
        let pearl = app.buttons["app-icon-pearl"]
        reveal(pearl, in: app)
        XCTAssertTrue(pearl.isSelected, "Pearl choice was lost at relaunch")
        select("classic", in: app)
        select("modern", in: app)
        select("pearl", in: app)
        if ProcessInfo.processInfo.environment["RESTORE_APP_ICON"] == "1", let original {
            select(original, in: app)
            // Publish the device's original appearance again after the temporary light preview.
            app.terminate()
            app.launchArguments = []
            app.launch()
            dismissIconAlert(in: app)
            app.terminate()
        }
    }
}
