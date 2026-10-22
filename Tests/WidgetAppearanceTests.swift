import Foundation
import Testing
@testable import Pearl

struct WidgetAppearanceTests {
    @Test func anUnpublishedInstallUsesModernDefaults() {
        #expect(WidgetAppearance().isModern)
        #expect(WidgetAppearance().icon == "pearl")
        #expect(WidgetAppearance().symbolName == "pearl")
        #expect(WidgetAppearance(palette: "unknown", icon: "unknown", mode: "unknown") == WidgetAppearance())
    }

    @Test func paletteAndIconCanBeChosenIndependently() {
        let a = WidgetAppearance(palette: "classic", icon: "modern", mode: "dark")
        #expect(!a.isModern)
        #expect(a.icon == "modern")
        #expect(a.symbolName == "pearl")
        let b = WidgetAppearance(palette: "mono", icon: "classic", mode: "light")
        #expect(b.isModern)
        #expect(b.icon == "classic")
        #expect(b.symbolName == "pearl")
        let c = WidgetAppearance(palette: "classic", icon: "pearl", mode: "dark")
        #expect(c.icon == "pearl")
        #expect(c.symbolName == "pearl")
    }

    @Test func anotherProcessCanReadTheChoiceWithoutChangingBalances() {
        let domain = "WidgetAppearanceTests.\(UUID().uuidString)"
        let app = UserDefaults(suiteName: domain)!
        defer { app.removePersistentDomain(forName: domain) }
        // Data refreshes use another key; visual settings must survive those writes.
        let choice = WidgetAppearance(palette: "classic", icon: "pearl", mode: "dark")
        #expect(choice.save(to: app))
        app.set(Data("balance snapshot".utf8), forKey: "widget.snapshot.v3")
        let widget = UserDefaults(suiteName: domain)!
        #expect(WidgetAppearance.load(from: widget) == choice)
        #expect(!choice.save(to: app))
        #expect(WidgetAppearance().save(to: app))
        #expect(WidgetAppearance.load(from: widget) == WidgetAppearance())
        #expect(app.data(forKey: "widget.snapshot.v3") == Data("balance snapshot".utf8))
    }
}
