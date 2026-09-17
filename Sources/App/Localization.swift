import SwiftUI
import Combine

// ============================================================
// Pearl Localization
// ------------------------------------------------------------
// In-app, runtime-switchable localization for the five shipped
// languages. The app ships its UI copy keyed by the original
// Simplified-Chinese source string — `Loc("设置")` returns the
// translation for the currently-selected language, falling back
// to English, then to the Chinese key itself, when a translation
// is missing.
//
// Why key by the source string (instead of "settings.title")?
//   • Zero collision risk when many files are localized at once.
//   • The default/fallback is always meaningful (the real copy).
//   • The diff stays tiny: Text("设置") -> Text(Loc("设置")).
//
// Translations live in <lang>.lproj/Localizable.strings; lookups
// go through `bundle.localizedString(forKey:value:table:)` with a
// sentinel value, so a missing entry transparently falls through to
// the English table, and only then to the Chinese source key.
//
// Runtime switching: the user can pick a language in Settings that
// overrides the system one. We resolve a per-language `.lproj`
// bundle and read from it directly, so the choice takes effect
// immediately regardless of the device language. The root view
// keys its identity on the language, forcing a full rebuild so
// every `Loc(...)` call site re-evaluates on switch.
// ============================================================

// MARK: - Supported languages

enum AppLanguage: String, CaseIterable, Identifiable {
    case system                  // follow the device language
    case en
    case ru
    case zhHant = "zh-Hant"      // 繁體中文
    case zhHans = "zh-Hans"      // 简体中文 (the source language)
    case vi
    case id                      // Bahasa Indonesia

    var id: String { rawValue }

    /// The `.lproj` resource code, or nil when following the system.
    var lprojCode: String? { self == .system ? nil : rawValue }

    /// Locale applied to the environment so dates/numbers and system
    /// controls match the chosen language.
    var locale: Locale {
        self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue)
    }

    /// Name shown in the picker — each language labelled in ITS OWN tongue,
    /// the platform convention. "跟随系统" is the only one that localizes.
    var displayName: String {
        switch self {
        case .system: return Loc("跟随系统")
        case .en:     return "English"
        case .ru:     return "Русский"
        case .zhHant: return "繁體中文"
        case .zhHans: return "简体中文"
        case .vi:     return "Tiếng Việt"
        case .id:     return "Bahasa Indonesia"
        }
    }
}

// MARK: - Nonisolated bundle holder

/// Holds the bundle the free `Loc(...)` functions read from. Kept separate
/// from the (main-actor) manager so `Loc(...)` is callable from ANY context —
/// view bodies, nonisolated model computed properties, background tasks.
/// The bundle only ever changes on the main thread during a deliberate user
/// action, so a racing read at worst returns the previous bundle — harmless.
final class LocBundleHolder: @unchecked Sendable {
    static let shared = LocBundleHolder()

    /// Bundle for the active language (defaults to system).
    var bundle: Bundle = .main

    /// English bundle, used as the fallback when the active language is missing
    /// a key. Resolved once and never mutated, so it's safe to read off any
    /// thread. `nil` only if en.lproj somehow isn't bundled.
    let english: Bundle? = {
        guard let path = Bundle.main.path(forResource: "en", ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()
}

// MARK: - Global lookup helpers

/// Localized copy for a Simplified-Chinese source key. Resolution order:
/// active-language bundle → English bundle → the source key itself. English is
/// the safety net so an untranslated string surfaces as English rather than as
/// raw Chinese to a non-Chinese user.
func Loc(_ key: String) -> String {
    let holder = LocBundleHolder.shared
    // A sentinel that can never be a legitimate translation, so a genuine hit
    // is distinguishable from a miss (which echoes the value back).
    let miss = "\u{1}\u{0}miss"
    let active = holder.bundle.localizedString(forKey: key, value: miss, table: "Localizable")
    if active != miss { return active }
    if let english = holder.english {
        let fallback = english.localizedString(forKey: key, value: miss, table: "Localizable")
        if fallback != miss { return fallback }
    }
    return key
}

/// Format variant: the localized template is a `String(format:)` pattern, e.g.
/// `Loc("价格 %@ USDT", priceText)`. Translators may reorder with `%1$@`, `%2$@`.
func Loc(_ key: String, _ args: CVarArg...) -> String {
    String(format: Loc(key), locale: LocBundleHolder.shared.locale, arguments: args)
}

/// Short, natural-language *relative* time in the ACTIVE app language, e.g.
/// "3 分钟前" / "3 minutes ago" / "昨天" / "2 天前". For compact rows where an
/// absolute date would wrap to a second line. Localized by the app's chosen
/// language (matching every `Loc(...)` call site), not just the device region.
func RelTime(_ date: Date, relativeTo now: Date = Date()) -> String {
    let f = RelativeDateTimeFormatter()
    f.locale = LocBundleHolder.shared.locale
    f.unitsStyle = .full        // 完整词，CJK 仍很短（"3分钟前"）
    f.dateTimeStyle = .named     // 优先「昨天/今天」等自然词
    return f.localizedString(for: date, relativeTo: now)
}

extension LocBundleHolder {
    /// Locale matching the active bundle — used by the format helper so that
    /// numbers embedded via `%d`/`%f` group correctly for the language.
    var locale: Locale {
        // `.main` corresponds to system; a per-language bundle to that language.
        if bundle == .main { return .autoupdatingCurrent }
        return Locale(identifier: languageCode ?? "")
    }

    /// The active `.lproj` code ("en", "zh-Hant", …), or nil when following the
    /// system. Published to the widget snapshot so the widget's formatters can
    /// match the in-app language.
    var languageCode: String? {
        if bundle == .main { return nil }
        return bundle.bundleURL.deletingPathExtension().lastPathComponent  // e.g. "ru"
    }
}

// MARK: - Manager (drives the picker + runtime switch)

@MainActor
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    static let storageKey = "app.language"

    @Published private(set) var language: AppLanguage

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: raw) ?? .system
        Self.applyBundle(for: language)
    }

    /// Change the active language: persists, re-points the lookup bundle,
    /// republishes (so observers/root rebuild), and mirrors to iCloud.
    func setLanguage(_ new: AppLanguage) {
        guard new != language else { return }
        language = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.storageKey)
        Self.applyBundle(for: new)
        CloudSync.push(Self.storageKey)
    }

    /// Re-read the stored language after an incoming iCloud change.
    func reloadFromDefaults() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguage.system.rawValue
        let new = AppLanguage(rawValue: raw) ?? .system
        guard new != language else { return }
        language = new
        Self.applyBundle(for: new)
    }

    private static func applyBundle(for language: AppLanguage) {
        if let code = language.lprojCode,
           let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            LocBundleHolder.shared.bundle = b
        } else {
            LocBundleHolder.shared.bundle = .main
        }
    }
}
