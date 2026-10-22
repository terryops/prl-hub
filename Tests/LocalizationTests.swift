import Foundation
import Testing
@testable import Pearl

/// 设置 → 语言: every language listed there ships a complete string table. A key missing
/// from one falls back to English mid-screen, and a translation that lost or retyped a
/// `%@` prints garbage — or crashes `String(format:)` — only in that language.
struct LocalizationTests {
    private static let codes = AppLanguage.allCases.compactMap(\.lprojCode)

    private static func table(_ code: String) -> [String: String] {
        guard let dir = Bundle.main.path(forResource: code, ofType: "lproj") else { return [:] }
        return NSDictionary(contentsOfFile: dir + "/Localizable.strings") as? [String: String] ?? [:]
    }

    /// The arguments a format string takes, by position: "%2$@ of %1$d" → [1: "d", 2: "@"].
    /// `%%` is a literal and takes none.
    private static func arguments(_ s: String) -> [Int: String] {
        let spec = #/%(?:(\d+)\$)?(@|lld|ld|d|u|s|(?:\.\d+)?f)|%%/#
        var out: [Int: String] = [:], next = 0
        for m in s.matches(of: spec) {
            guard let kind = m.output.2 else { continue }
            let index: Int
            if let p = m.output.1 { index = Int(p) ?? 0 } else { next += 1; index = next }
            out[index] = kind.hasSuffix("f") ? "f" : String(kind)
        }
        return out
    }

    @Test func everyLanguageHasEveryString() {
        let english = Set(Self.table("en").keys)
        #expect(english.count > 900)
        for code in Self.codes {
            let keys = Set(Self.table(code).keys)
            #expect(english.subtracting(keys).isEmpty, "\(code) is missing \(english.subtracting(keys).sorted().prefix(5))")
            #expect(keys.subtracting(english).isEmpty, "\(code) has strings English lacks: \(keys.subtracting(english).sorted().prefix(5))")
        }
    }

    @Test func translationsTakeTheSameArguments() {
        let english = Self.table("en")
        for code in Self.codes where code != "en" {
            for (key, value) in Self.table(code) {
                guard let source = english[key] else { continue }
                #expect(Self.arguments(value) == Self.arguments(source), "\(code): \(key)")
            }
        }
    }

    /// The prompt iOS shows before Face ID, and the name under the icon.
    @Test func everyLanguageHasItsSystemStrings() {
        for code in Self.codes {
            let dir = Bundle.main.path(forResource: code, ofType: "lproj") ?? ""
            let info = NSDictionary(contentsOfFile: dir + "/InfoPlist.strings") as? [String: String] ?? [:]
            #expect(info["CFBundleDisplayName"] == "Pearl Hub", "\(code)")
            #expect(info["NSFaceIDUsageDescription"]?.isEmpty == false, "\(code)")
        }
    }

    /// Each language is named in itself, so nobody has to read another one to find theirs.
    @Test func everyLanguageHasItsOwnName() {
        let names = AppLanguage.allCases.filter { $0 != .system }.map(\.displayName)
        #expect(Set(names).count == names.count)
        #expect(!names.contains(""))
    }

    /// The alert service writes the notification in the language the app reports.
    @MainActor @Test func thePushLanguageIsOneTheAppShips() {
        #expect(Self.codes.contains(PriceAlertStore.pushLanguage))
    }
}
