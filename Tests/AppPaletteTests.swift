import Foundation
import Testing
@testable import Pearl

struct AppPaletteTests {
    /// An install without a saved preference starts on modern silver.
    @Test func theDefaultIsModernSilver() {
        #expect(AppPalette(stored: nil) == .modern)
        #expect(AppPalette(stored: "sepia") == .modern)
    }

    /// An install that was here before the picker keeps classic blue; only a new one
    /// starts on modern silver, and either way the answer is recorded once.
    @Test func anUpdateKeepsThePaletteTheInstallHad() {
        #expect(AppPalette.initial(launchedBefore: true) == .classic)
        #expect(AppPalette.initial(launchedBefore: false) == .modern)
        let name = "palette-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        #expect(AppPalette.adoptDefault(in: d, launches: 12) == .classic)
        #expect(d.string(forKey: AppPalette.key) == "classic")
        // Recorded: the launch count growing later changes nothing, nor does a new default.
        #expect(AppPalette.adoptDefault(in: d, launches: 0) == .classic)
        d.set("mono", forKey: AppPalette.key)
        #expect(AppPalette.adoptDefault(in: d, launches: 12) == .modern)
        d.removeObject(forKey: AppPalette.key)
        #expect(AppPalette.adoptDefault(in: d, launches: 0) == .modern)
        #expect(d.string(forKey: AppPalette.key) == "mono")
    }

    @Test func aStoredChoiceIsKept() {
        #expect(AppPalette(stored: "mono") == .modern)
        #expect(AppPalette(stored: "classic") == .classic)
    }

    /// 设置 lists the default first.
    @Test func modernSilverIsListedFirst() {
        #expect(AppPalette.allCases == [.modern, .classic])
    }

    /// The pearl icon and modern-silver palette remain separate defaults.
    @Test func thePaletteIsNotTheIcon() {
        #expect(AppPalette.key != AppIconChoice.key)
        #expect(AppIconChoice.initial(launchedBefore: false) == .pearl)
        #expect(AppPalette(stored: nil) == .modern)
    }
}
