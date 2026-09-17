import SwiftUI
import Combine

// ============================================================
// Pearl Currency
// ------------------------------------------------------------
// USD is the app's PRIMARY fiat — every fiat value is computed in
// USD first (PRL prices, on-chain income, mining economics). The
// user may additionally pick ONE secondary currency to show
// alongside, e.g. "$52.96 · ¥359", or pick "none" to show USD only.
//
// Exchange rates are USD-based and pulled once from
// open.er-api.com/v6/latest/USD (free, no key — already used in the
// pool monitor). They're cached on disk and only refetched when the
// cache is older than a day, satisfying "check once per day".
// ============================================================

// MARK: - A fiat currency the user can pick as the secondary display

struct FiatCurrency: Identifiable, Hashable {
    let code: String     // ISO 4217, e.g. "CNY"
    let symbol: String   // display symbol, e.g. "¥"
    let nameKey: String  // Simplified-Chinese name, localized via Loc(...)
    let decimals: Int    // fraction digits when formatting

    var id: String { code }
    var localizedName: String { Loc(nameKey) }
}

enum Fiat {
    /// The fixed primary currency.
    static let usd = FiatCurrency(code: "USD", symbol: "$", nameKey: "美元", decimals: 2)

    /// Curated set the user can choose as the secondary display currency.
    static let secondaries: [FiatCurrency] = [
        FiatCurrency(code: "CNY", symbol: "¥",   nameKey: "人民币",   decimals: 2),
        FiatCurrency(code: "TWD", symbol: "NT$", nameKey: "新台币",   decimals: 0),
        FiatCurrency(code: "HKD", symbol: "HK$", nameKey: "港币",     decimals: 2),
        FiatCurrency(code: "RUB", symbol: "₽",   nameKey: "卢布",     decimals: 2),
        FiatCurrency(code: "VND", symbol: "₫",   nameKey: "越南盾",   decimals: 0),
        FiatCurrency(code: "IDR", symbol: "Rp",  nameKey: "印尼盾",   decimals: 0),
        FiatCurrency(code: "EUR", symbol: "€",   nameKey: "欧元",     decimals: 2),
        FiatCurrency(code: "JPY", symbol: "¥",   nameKey: "日元",     decimals: 0),
        FiatCurrency(code: "KRW", symbol: "₩",   nameKey: "韩元",     decimals: 0),
        FiatCurrency(code: "GBP", symbol: "£",   nameKey: "英镑",     decimals: 2),
        FiatCurrency(code: "SGD", symbol: "S$",  nameKey: "新加坡元", decimals: 2),
        FiatCurrency(code: "AUD", symbol: "A$",  nameKey: "澳元",     decimals: 2),
        FiatCurrency(code: "CAD", symbol: "C$",  nameKey: "加元",     decimals: 2),
    ]

    static func find(_ code: String) -> FiatCurrency? {
        code == usd.code ? usd : secondaries.first { $0.code == code }
    }

    /// Sentinel preferences for the secondary slot.
    static let auto = "__auto__"   // follow the chosen language
    static let none = ""           // show USD only

    /// Sensible default secondary for a given app language.
    static func defaultSecondary(for language: AppLanguage) -> String {
        switch language {
        case .zhHans: return "CNY"
        case .zhHant: return "TWD"
        case .ru:     return "RUB"
        case .vi:     return "VND"
        case .id:     return "IDR"
        case .en:     return none
        case .system:
            // Match the device region's currency if it's one we support, else none.
            let code = Locale.current.currency?.identifier ?? ""
            return secondaries.contains { $0.code == code } ? code : none
        }
    }
}

// MARK: - Manager

@MainActor
final class CurrencyManager: ObservableObject {
    /// Shared instance — also read by non-view models (e.g. PRLStore) that need
    /// the secondary currency + live rate without an environment injection.
    static let shared = CurrencyManager()

    /// USD -> currency-code rate (e.g. rates["CNY"] = 7.12).
    @Published private(set) var rates: [String: Double] = [:]
    @Published private(set) var lastUpdated: Date?
    /// User preference: Fiat.auto, Fiat.none, or a currency code.
    @Published private(set) var secondaryPref: String

    private static let prefKey  = "currency.secondary"
    private static let ratesKey = "currency.rates"
    private static let atKey    = "currency.ratesAt"
    private static let maxAge: TimeInterval = 24 * 3600   // refresh at most once a day

    init() {
        secondaryPref = UserDefaults.standard.string(forKey: Self.prefKey) ?? Fiat.auto
        if let data = UserDefaults.standard.data(forKey: Self.ratesKey),
           let cached = try? JSONDecoder().decode([String: Double].self, from: data) {
            rates = cached
        }
        let at = UserDefaults.standard.double(forKey: Self.atKey)
        if at > 0 { lastUpdated = Date(timeIntervalSince1970: at) }
    }

    // MARK: preference

    func setSecondaryPref(_ pref: String) {
        guard pref != secondaryPref else { return }
        secondaryPref = pref
        UserDefaults.standard.set(pref, forKey: Self.prefKey)
        CloudSync.push(Self.prefKey)
    }

    /// Re-read the preference after an incoming iCloud change.
    func reloadFromDefaults() {
        let pref = UserDefaults.standard.string(forKey: Self.prefKey) ?? Fiat.auto
        if pref != secondaryPref { secondaryPref = pref }
    }

    /// The resolved secondary currency for the active language, or nil when the
    /// user chose "none" (or "auto" resolved to none, e.g. English).
    var secondary: FiatCurrency? {
        let code = secondaryPref == Fiat.auto
            ? Fiat.defaultSecondary(for: LocalizationManager.shared.language)
            : secondaryPref
        return code.isEmpty ? nil : Fiat.find(code)
    }

    func rate(_ code: String) -> Double? { code == Fiat.usd.code ? 1 : rates[code] }

    /// Human-readable live rate for the current secondary, e.g. "1 USD = 7.12 CNY".
    /// nil when there's no secondary currency or its rate hasn't loaded yet.
    func rateLine() -> String? {
        guard let s = secondary, let r = rate(s.code) else { return nil }
        let digits = r >= 1000 ? 0 : (r >= 20 ? 1 : 2)
        return "1 USD = " + Self.number(r, digits) + " " + s.code
    }

    // MARK: refresh

    /// Fetch only when we have never fetched or the cache is older than a day.
    func refreshIfStale() async {
        if let at = lastUpdated, Date().timeIntervalSince(at) < Self.maxAge, !rates.isEmpty { return }
        await refresh()
    }

    /// Pull the full USD rate table from open.er-api.com and cache it.
    func refresh() async {
        guard let fetched = await Self.fetchRates() else { return }
        rates = fetched
        let now = Date()
        lastUpdated = now
        if let data = try? JSONEncoder().encode(fetched) {
            UserDefaults.standard.set(data, forKey: Self.ratesKey)
        }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.atKey)
    }

    private static func fetchRates() async -> [String: Double]? {
        var req = URLRequest(url: URL(string: "https://open.er-api.com/v6/latest/USD")!)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["rates"] as? [String: Any] else { return nil }
        var out: [String: Double] = [:]
        for (k, v) in raw {
            if let n = v as? NSNumber { out[k] = n.doubleValue }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: formatting

    /// Primary (USD) string, e.g. "$52.96".
    func primaryString(_ usd: Double) -> String {
        Fiat.usd.symbol + Self.number(usd, Fiat.usd.decimals)
    }

    /// Secondary string for a USD amount, e.g. "¥359" — nil when there's no
    /// secondary currency or its rate hasn't loaded yet.
    func secondaryString(_ usd: Double) -> String? {
        guard let s = secondary, let r = rate(s.code) else { return nil }
        return s.symbol + Self.number(usd * r, s.decimals)
    }

    /// "$52.96 · ¥359" — the primary always, the secondary appended when set.
    /// `separator` lets callers match local layout (default " · ").
    func dual(_ usd: Double, separator: String = " · ") -> String {
        let primary = primaryString(usd)
        if let sec = secondaryString(usd) { return primary + separator + sec }
        return primary
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    private static func number(_ v: Double, _ decimals: Int) -> String {
        guard v.isFinite else { return "—" }
        let f = formatter
        f.maximumFractionDigits = decimals
        f.minimumFractionDigits = decimals
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.\(decimals)f", v)
    }
}
