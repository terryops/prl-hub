import XCTest

/// The K-line zooms with a two-finger pinch (it used to have a 30 / 60 / 120 picker) and
/// pans with a sideways drag, and the page still scrolls from a swipe that starts on the chart.
@MainActor final class TradeChartUITests: XCTestCase {
    func testPinchZoomsTheCandles() {
        executionTimeAllowance = 60
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-app.language", "zh-Hans",
                               "-ui.appearance", "light"]
        app.launchEnvironment = ["SHOT_MEMORY_KEYCHAIN": "1", "SHOT_TAB": "1", "SHOT_TRADE_DEMO": "1"]
        app.launch()
        let caption = app.staticTexts["candle-count"].firstMatch
        XCTAssertTrue(caption.waitForExistence(timeout: 20))
        XCTAssertFalse(app.segmentedControls["candle-count"].exists)
        let chart = app.otherElements["candle-chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 20))   // the candles land a beat after the card
        XCTAssertGreaterThan(chart.frame.height, 300)
        // Bring the whole plot clear of both bars, or a pinching finger lands on a tab or on
        // the navigation bar (a pinch starts from the plot's corners). Held at the end of
        // the drag, so the page stops there instead of coasting on.
        let header = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
        header.press(forDuration: 0.05, thenDragTo: header.withOffset(CGVector(dx: 0, dy: -200)),
                     withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertGreaterThan(chart.frame.minY, 150)
        XCTAssertLessThan(chart.frame.maxY, app.frame.maxY - 150)
        capture("kline-start")

        // Wherever the last run left the zoom (a launch argument can't pin it: the
        // argument domain would also hide what the pinch stores), spreading twice ends
        // at the closest view, and pinching from there brings candles back in.
        chart.pinch(withScale: 4, velocity: 4)
        chart.pinch(withScale: 4, velocity: 4)
        XCTAssertEqual(count(caption), 20, "Spreading should leave fewer, wider candles")
        capture("kline-zoomed-in")

        // Zoomed in, the older candles are a sideways drag away: dragging right brings
        // them in, the page stays where it is, and dragging back ends at the latest again.
        let latest = dates(app), top = caption.frame.minY
        XCTAssertFalse(latest.isEmpty)
        let left = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let right = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        left.press(forDuration: 0.02, thenDragTo: right)
        let older = dates(app)
        XCTAssertNotEqual(older, latest, "Dragging right should bring older candles in")
        XCTAssertFalse(older.isEmpty)
        XCTAssertEqual(caption.frame.minY, top, accuracy: 1, "A sideways drag must not scroll the page")
        XCTAssertEqual(count(caption), 20)
        capture("kline-panned")
        right.press(forDuration: 0.02, thenDragTo: left)
        right.press(forDuration: 0.02, thenDragTo: left)
        XCTAssertEqual(dates(app), latest, "Dragging back should end at the latest candle")
        XCTAssertEqual(caption.frame.minY, top, accuracy: 1, "Nor may dragging back, with nothing left to pan")

        chart.pinch(withScale: 0.4, velocity: -1)
        let zoomedOut = count(caption)
        XCTAssertGreaterThan(zoomedOut, 20, "Pinching should bring in more candles")
        chart.pinch(withScale: 0.4, velocity: -1)
        XCTAssertGreaterThan(count(caption), zoomedOut)
        capture("kline-zoomed-out")

        // A one-finger swipe that starts on the chart still scrolls the page.
        let y = caption.frame.minY
        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        start.press(forDuration: 0.02, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -200)))
        XCTAssertLessThan(caption.frame.minY, y - 100)
    }

    /// The button beside the period picker opens the K-line on the whole screen, turned
    /// sideways even under 锁定竖屏 (on by default), and closing it stands the app up again.
    func testFullScreenChart() {
        executionTimeAllowance = 60
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-app.language", "zh-Hans",
                               "-ui.appearance", "light"]
        app.launchEnvironment = ["SHOT_MEMORY_KEYCHAIN": "1", "SHOT_TAB": "1", "SHOT_TRADE_DEMO": "1"]
        app.launch()
        let window = app.windows.firstMatch
        let open = app.buttons["candle-fullscreen"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 20))
        open.tap()

        let close = app.buttons["candle-fullscreen-close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        sleep(1)                       // the turn to landscape animates
        XCTAssertGreaterThan(window.frame.width, window.frame.height, "Full screen should be landscape")
        XCTAssertFalse(app.tabBars.firstMatch.isHittable, "The chart should cover the tab bar")
        let chart = app.otherElements["candle-chart"].firstMatch
        if chart.waitForExistence(timeout: 20) {   // the candles land a beat after the cover
            XCTAssertGreaterThan(chart.frame.width, chart.frame.height)
            XCTAssertGreaterThan(chart.frame.height, window.frame.height * 0.5)
        }
        capture("kline-fullscreen")

        close.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        sleep(1)                       // and back upright
        XCTAssertFalse(close.exists)
        XCTAssertLessThan(window.frame.width, window.frame.height, "锁定竖屏 should stand the app up again")
        capture("kline-fullscreen-closed")
    }

    /// The time of every candle on screen (Swift Charts describes each wick as "low到high"
    /// with its time as the value), from one snapshot of the hierarchy.
    private func dates(_ app: XCUIApplication) -> Set<String> {
        guard let root = try? app.snapshot() else { return [] }
        var found = Set<String>(), queue: [XCUIElementSnapshot] = [root]
        while let e = queue.popLast() {
            if e.label.contains("到"), let value = e.value as? String, !value.isEmpty { found.insert(value) }
            queue.append(contentsOf: e.children)
        }
        return found
    }

    private func count(_ caption: XCUIElement) -> Int {
        Int((caption.value as? String ?? "").filter(\.isNumber)) ?? -1
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
