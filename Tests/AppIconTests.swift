import Foundation
import Testing
import UIKit
@testable import Pearl

struct AppIconChoiceTests {
    /// A defaults domain of its own, emptied before and after.
    private func scratch(_ body: (UserDefaults) -> Void) {
        let name = "AppIconChoiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }

    @Test func aNewInstallGetsThePearlIcon() {
        scratch { defaults in
            AppIconChoice.adoptDefault(in: defaults, launches: 0)
            #expect(defaults.string(forKey: AppIconChoice.key) == "pearl")
        }
    }

    @Test func anInstallThatHasLaunchedBeforeKeepsTheClassicIcon() {
        scratch { defaults in
            AppIconChoice.adoptDefault(in: defaults, launches: 12)
            #expect(defaults.string(forKey: AppIconChoice.key) == "classic")
        }
    }

    @Test func theChoiceIsMadeOnce() {
        scratch { defaults in
            // Decided as a new install; every later launch has a count above zero.
            AppIconChoice.adoptDefault(in: defaults, launches: 0)
            AppIconChoice.adoptDefault(in: defaults, launches: 5)
            #expect(defaults.string(forKey: AppIconChoice.key) == "pearl")
            // And what the user picked in 设置 is never overridden.
            defaults.set("classic", forKey: AppIconChoice.key)
            AppIconChoice.adoptDefault(in: defaults, launches: 0)
            #expect(defaults.string(forKey: AppIconChoice.key) == "classic")
            defaults.set("pearl", forKey: AppIconChoice.key)
            AppIconChoice.adoptDefault(in: defaults, launches: 12)
            #expect(defaults.string(forKey: AppIconChoice.key) == "pearl")
            defaults.set("modern", forKey: AppIconChoice.key)
            AppIconChoice.adoptDefault(in: defaults, launches: 12)
            #expect(defaults.string(forKey: AppIconChoice.key) == "modern")
        }
    }

    @Test func thePearlIsPrimaryAndPreviousIconsRemainSelectable() {
        // nil is the bundle's own icon: the one the App Store and a fresh install show.
        #expect(AppIconChoice.pearl.alternateIconName == nil)
        #expect(AppIconChoice.modern.alternateIconName == "AppIconModern")
        #expect(AppIconChoice.classic.alternateIconName == "AppIconClassic")
        #expect(AppIconChoice.allCases.first == .pearl)
        #expect(AppIconChoice(stored: nil) == .pearl)
        #expect(AppIconChoice(stored: "nonsense") == .pearl)
        #expect(AppIconChoice(stored: "modern") == .modern)
        #expect(AppIconChoice(stored: "classic") == .classic)
        #expect(AppIconChoice(stored: "pearl") == .pearl)
    }

    @Test func existingPearlAlternatesNeedNoIconChange() {
        #expect(AppIconChoice.pearl.isApplied(alternateName: nil))
        #expect(AppIconChoice.pearl.isApplied(alternateName: "AppIconPearl"))
        #expect(!AppIconChoice.modern.isApplied(alternateName: nil))
        #expect(AppIconChoice.modern.isApplied(alternateName: "AppIconModern"))
        #expect(!AppIconChoice.pearl.isApplied(alternateName: "AppIconModern"))
    }

    /// A picker entry alone is insufficient: iOS needs the alternate registered by actool.
    @MainActor @Test func shippedBundleRegistersEverySelectableIcon() throws {
        #expect(UIApplication.shared.supportsAlternateIcons)
        // Read the physical plist: Bundle's runtime dictionary resolves device-qualified keys.
        let data = try Data(contentsOf: Bundle.main.bundleURL.appending(path: "Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let icons = info[key] as? [String: Any]
            let alternates = icons?["CFBundleAlternateIcons"] as? [String: Any]
            let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
            #expect(primary?["CFBundleIconName"] as? String == "AppIcon")
            let legacyPearl = alternates?["AppIconPearl"] as? [String: Any]
            #expect(legacyPearl?["CFBundleIconName"] as? String == "AppIconPearl")
            for choice in AppIconChoice.allCases {
                #expect(UIImage(named: choice.imageName) != nil, "Missing picker image: \(choice)")
                if let name = choice.alternateIconName {
                    let entry = alternates?[name] as? [String: Any]
                    #expect(entry?["CFBundleIconName"] as? String == name, "Unregistered \(name) in \(key)")
                }
            }
        }
    }
}
