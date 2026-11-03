import XCTest

/// Captures the four App Store screenshots from the REAL running app (no mockups),
/// at full device resolution, on whatever simulator the test is run against:
///
///   wallet · mining overview · pool compare · pool monitor
///
///   TEST_RUNNER_SHOT_ADDR=prl1… TEST_RUNNER_SHOT_POOL="AlphaPool" \
///   xcodebuild test -scheme PRLHubScreenshots \
///     -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
///
/// Each capture is added as a `.keepAlways` XCTAttachment; the host extracts the
/// PNGs from the .xcresult and composites the caption bands.
///
/// The wallet uses a throwaway canonical BIP39 test mnemonic — it derives a real
/// on-device Taproot address and a real (empty) on-chain balance. Nothing is
/// funded; nothing sensitive is exposed. The "pool monitor" card is populated by
/// adding a watch for a REAL mining address supplied via SHOT_ADDR / SHOT_POOL —
/// without it, that one screen is skipped (the other three need no address).
final class ScreenshotUITests: XCTestCase {

    /// Canonical BIP39 test vector (valid checksum). Empty wallet — screenshots only.
    private let testMnemonic =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() {
        super.setUp()
        continueAfterFailure = true   // grab as many screens as possible even if one step drifts
    }

    func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    func testCaptureAppStoreScreenshots() {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // Seed the "我的监控" watch directly (DEBUG-only app seam) — far more reliable
        // than driving the add-sheet's .menu picker. Must be set before launch.
        if let addr = env["SHOT_ADDR"], !addr.isEmpty {
            app.launchEnvironment["SHOT_WATCH_ADDR"] = addr
            app.launchEnvironment["SHOT_WATCH_POOL"] = env["SHOT_POOL"] ?? "AlphaPool"
        }
        // Worker names on a real watch are the owner's machine hostnames — list them as
        // worker-01, worker-02 … instead (DEBUG seam in WatchData.workers).
        if env["SHOT_ANON_WORKERS"] == "1" {
            app.launchEnvironment["SHOT_ANON_WORKERS"] = "1"
        }
        // Populate the Trade tab with a believable demo account (DEBUG seam) so the
        // promo shot shows balances + open orders, not the "configure API key" warning.
        app.launchEnvironment["SHOT_TRADE_DEMO"] = "1"
        // Pro unlocked (DEBUG seam in ProStore): price alerts show their rule list instead
        // of the paywall, and the trade tab its depth chart.
        app.launchEnvironment["SHOT_PRO"] = "1"
        // 价格提醒 seeded around this reference price and opened on the 设置 tab (DEBUG seam
        // in PriceAlertStore; nothing is synced). Only shot when the runner passes a price.
        if let ref = env["SHOT_PRICE_ALERTS"], !ref.isEmpty {
            app.launchEnvironment["SHOT_PRICE_ALERTS"] = ref
        }
        app.launch()

        importWalletIfNeeded(app)

        // 1) Wallet dashboard — wait until it's up (its Receive action exists).
        let receive = app.buttons["Receive"]
        XCTAssertTrue(receive.waitForExistence(timeout: 30), "dashboard did not appear")
        // A fresh import shows "Syncing balance…" in the hero until the first chain scan
        // lands — wait it out so the first store screenshot shows a settled wallet.
        let syncing = app.staticTexts["Syncing balance\u{2026}"]
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: syncing)],
             timeout: 60)
        sleep(4)                       // balance hero + address capsule settle
        capture("01-wallet")

        // 2) Pools → Overview (live PRL price / hashrate / difficulty / chart).
        tapTab(app, "Pools")
        dismissIntroBanner(app)
        _ = app.buttons["Overview"].waitForExistence(timeout: 10)
        sleep(8)                       // network fetch for the overview cards + chart
        capture("02-mining")

        // 3) Pool compare — the address-free pool comparison table + hashrate-share donut.
        tapPill(app, "Pool")
        sleep(8)
        capture("03-pools")

        // 4) Pool monitor — the seeded watch's card (per-miner hashrate, workers, payouts).
        //    SHOT_ADDR may also be an F2Pool read-only page link (SHOT_POOL=F2Pool).
        if let addr = env["SHOT_ADDR"], !addr.isEmpty {
            tapTab(app, "Monitor")
            // Guard against the app having been backgrounded/obscured (a stray keyboard
            // earlier left it not-frontmost in one run) — re-foreground before shooting.
            if app.state != .runningForeground { app.activate() }
            // Wait for the seeded watch card to actually render (its title = pool label).
            _ = app.staticTexts[env["SHOT_POOL"] ?? "HeroMiners"].waitForExistence(timeout: 20)
            sleep(10)                  // per-miner + on-chain income fetch fills the card
            capture("04-monitor")
        }

        // 5) Price alerts — the seeded rule list (设置 → 通知 → 价格提醒, pushed at launch).
        if let ref = env["SHOT_PRICE_ALERTS"], !ref.isEmpty {
            tapTab(app, "Settings")
            if app.state != .runningForeground { app.activate() }
            _ = app.staticTexts["My Alerts"].waitForExistence(timeout: 10)
            sleep(6)                   // reference price + 5m/1h/24h change fetch
            capture("05-alerts")
        }

        // 6) Trade — SafeTrade market: live PEARL/USDT price + candlestick K-line, demo
        //    balances + open orders (seeded via SHOT_TRADE_DEMO). The Trade tab only
        //    exists in TRADE_ENABLED builds, which the screenshot build is.
        tapTab(app, "Trade")
        if app.state != .runningForeground { app.activate() }
        _ = app.buttons["Sell"].waitForExistence(timeout: 10)   // order form is up
        sleep(8)                       // public ticker + k-line fetch fills the chart
        capture("06-trade")

        // 7) Security info — the self-custody card the wallet image lifts out (设置 → 安全性说明,
        //    pushed at launch by SHOT_SECURITY). A fresh launch: SHOT_PRICE_ALERTS would push too.
        app.terminate()
        app.launchEnvironment["SHOT_PRICE_ALERTS"] = nil
        app.launchEnvironment["SHOT_SECURITY"] = "1"
        app.launchEnvironment["SHOT_TAB"] = "4"
        app.launch()
        _ = app.staticTexts["Self-custody wallet"].waitForExistence(timeout: 15)
        sleep(3)
        capture("07-security")
    }

    // MARK: - flows

    private func importWalletIfNeeded(_ app: XCUIApplication) {
        let restore = app.buttons["Restore Wallet from Recovery Phrase"]
        guard restore.waitForExistence(timeout: 25) else { return }   // already has a wallet
        restore.tap()

        let phrase = app.textViews.firstMatch
        XCTAssertTrue(phrase.waitForExistence(timeout: 10), "phrase field missing")
        phrase.tap()
        phrase.typeText(testMnemonic)

        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 3) { done.tap() }

        let recover = app.buttons["Restore Wallet"]
        XCTAssertTrue(recover.waitForExistence(timeout: 5), "restore button missing")
        if !recover.isHittable { app.swipeUp() }
        recover.tap()
    }

    // MARK: - helpers

    private func dismissIntroBanner(_ app: XCUIApplication) {
        let gotIt = app.buttons["Got it"]
        if gotIt.waitForExistence(timeout: 3) && gotIt.isHittable { gotIt.tap() }
    }

    private func tapTab(_ app: XCUIApplication, _ label: String) {
        // iPhone: bottom tab bar. iPad (iOS 18+): top tab bar, exposed as buttons.
        // .firstMatch so a duplicate match never throws "multiple matching elements"
        // (which previously halted the whole test on iPad).
        let inBar = app.tabBars.buttons[label].firstMatch
        if inBar.waitForExistence(timeout: 6) && inBar.isHittable { inBar.tap(); return }
        let any = app.buttons[label].firstMatch
        if any.waitForExistence(timeout: 6) { any.tap() }
    }

    /// Tap a section pill inside the Mining monitor.
    private func tapPill(_ app: XCUIApplication, _ label: String) {
        let b = app.buttons[label].firstMatch
        if b.waitForExistence(timeout: 6) { b.tap() }
    }
}
