import XCTest

@MainActor final class SettingsNavigationUITests: XCTestCase {
    private func launch(pro: Bool, appearance: String = "light", language: String = "zh-Hans") -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-app.language", language,
                               "-ui.appearance", appearance, "-ui.palette", "mono", "-pro.unlocked", pro ? "YES" : "NO"]
        app.launchEnvironment = ["SHOT_MEMORY_KEYCHAIN": "1", "SHOT_TAB": "4"]
        if pro { app.launchEnvironment["SHOT_PRO"] = "1" }
        app.launch()
        for host in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            if host.alerts.firstMatch.waitForExistence(timeout: 1) {
                host.alerts.firstMatch.buttons.firstMatch.tap()
            }
        }
        XCTAssertTrue(app.buttons["settings-account"].waitForExistence(timeout: 10))
        return app
    }

    private func open(_ identifier: String, title: String, in app: XCUIApplication) {
        let entry = app.buttons[identifier].firstMatch
        // A partially visible row can report hittable while its center is covered
        // by the floating tab bar. Reveal the whole row before tapping it.
        if !entry.exists {
            for _ in 0..<3 { app.swipeDown() }
        }
        for _ in 0..<12 {
            if entry.exists && entry.isHittable && entry.frame.minY >= 125 && entry.frame.maxY < app.frame.maxY - 130 { break }
            let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            if entry.exists && entry.frame.minY < 125 {
                upper.press(forDuration: 0.05, thenDragTo: lower)
            } else {
                lower.press(forDuration: 0.05, thenDragTo: upper)
            }
        }
        XCTAssertTrue(entry.isHittable, "Settings entry is unreachable: \(identifier)")
        entry.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    private func back(in app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testGroupedSettingsDestinationsRemainReachable() {
        let app = launch(pro: true)
        capture("settings-directory-light-top")

        open("settings-account", title: "邮箱账号", in: app)
        XCTAssertTrue(app.buttons["用邮箱登录"].exists)
        back(in: app)

        open("settings-wallet", title: "钱包与安全", in: app)
        XCTAssertTrue(app.staticTexts["助记词加密存于钥匙串；查看助记词与转账需 Face ID / Touch ID 验证。"].exists)
        back(in: app)

        open("settings-pro", title: "Pro 会员", in: app)
        XCTAssertTrue(app.staticTexts["已开通"].exists)
        XCTAssertTrue(app.staticTexts["数据同步：登录同一邮箱，在网页、iPhone、iPad 和 Mac 间同步配置"].exists)
        capture("settings-pro-active")
        let account = app.buttons["pro-sync-account"]
        for _ in 0..<5 where !account.isHittable { app.swipeUp() }
        XCTAssertTrue(account.isHittable)
        XCTAssertTrue(app.staticTexts["用邮箱登录，同步矿机、挖矿配置、监控、公开地址、通讯录、提醒和偏好设置。助记词、私钥和钱包密码不会上传。"].exists)
        capture("settings-pro-sync-details")
        account.tap()
        XCTAssertTrue(app.navigationBars["邮箱账号"].waitForExistence(timeout: 5))
        back(in: app)
        back(in: app)

        for (id, title) in [("settings-price-alerts", "价格提醒"),
                            ("settings-offline-alerts", "掉线提醒"),
                            ("settings-live-activity", "锁屏盯盘")] {
            open(id, title: title, in: app)
            back(in: app)
        }

        open("settings-appearance", title: "主题与配色", in: app)
        XCTAssertTrue(app.buttons["现代银"].exists)
        XCTAssertTrue(app.switches["锁定竖屏"].exists)
        capture("settings-theme-colors")
        back(in: app)

        open("settings-app-icon", title: "应用图标", in: app)
        XCTAssertTrue(app.buttons["app-icon-pearl"].exists)
        XCTAssertTrue(app.buttons["app-icon-modern"].exists)
        XCTAssertTrue(app.buttons["app-icon-classic"].exists)
        capture("settings-app-icon")
        back(in: app)

        open("settings-language", title: "界面语言", in: app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "简体中文")).firstMatch.exists)
        back(in: app)
        open("settings-currency", title: "货币", in: app)
        XCTAssertTrue(app.buttons["立即刷新汇率"].exists)
        capture("settings-currency")
        back(in: app)

        open("settings-network", title: "Pearl 网络", in: app)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "blockbook.pearlresearch.ai")).firstMatch.exists)
        back(in: app)
        if app.buttons["settings-trade"].exists {
            open("settings-trade", title: "交易（SafeTrade）", in: app)
            XCTAssertTrue(app.buttons["如何获取 API 密钥"].exists)
            back(in: app)
        }
        capture("settings-directory-light-bottom")
        open("settings-about", title: "关于", in: app)
        XCTAssertTrue(app.buttons["开源许可"].exists)
    }

    func testSecurityOverviewNamesItsRepositories() {
        let app = launch(pro: false)
        open("settings-security", title: "安全性说明", in: app)
        XCTAssertTrue(app.staticTexts["自托管钱包"].exists)
        capture("settings-security-top")
        app.swipeUp()
        capture("settings-security-middle")
        let server = app.staticTexts["github.com/terryops/prl-hub-server"]
        for _ in 0..<12 where !(server.exists && server.isHittable) { app.swipeUp() }
        XCTAssertTrue(server.isHittable)
        XCTAssertTrue(app.staticTexts["github.com/terryops/prl-hub"].exists)
        XCTAssertTrue(app.staticTexts["github.com/terryops/prl-hub-web"].exists)
        capture("settings-security-repositories")
    }

    func testMembershipExplainsSyncBeforePurchase() {
        let app = launch(pro: false)
        open("settings-pro", title: "Pro 会员", in: app)
        XCTAssertTrue(app.staticTexts["数据同步：登录同一邮箱，在网页、iPhone、iPad 和 Mac 间同步配置"].exists)
        app.swipeUp()
        XCTAssertTrue(app.buttons["恢复购买"].exists)
        XCTAssertTrue(app.buttons["已有高级版？登录账号"].exists)
        capture("settings-pro-purchase")
        // The account sheet has its own way out (a Mac's can't be swiped away).
        app.buttons["已有高级版？登录账号"].tap()
        XCTAssertTrue(app.navigationBars["邮箱账号"].waitForExistence(timeout: 5))
        capture("settings-pro-account-sheet")
        let close = app.navigationBars["邮箱账号"].buttons["关闭"]
        XCTAssertTrue(close.exists)
        close.tap()
        XCTAssertTrue(app.navigationBars["Pro 会员"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["邮箱账号"].exists)
    }

    func testDirectoryInEnglishAndDarkAppearance() {
        let app = launch(pro: true, appearance: "dark", language: "en")
        capture("settings-directory-dark-english-top")
        open("settings-appearance", title: "Theme & Colors", in: app)
        XCTAssertTrue(app.buttons["Modern Silver"].exists)
        capture("settings-theme-dark-english")
        back(in: app)
        app.swipeUp()
        capture("settings-directory-dark-english-bottom")
    }
}
