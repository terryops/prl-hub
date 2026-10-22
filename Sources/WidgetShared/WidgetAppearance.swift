import Foundation

/// Published separately from balances so a widget's network refresh cannot overwrite
/// a theme or icon the user just selected in the app.
struct WidgetAppearance: Codable, Equatable {
    var palette: String
    var icon: String
    var mode: String

    init(palette: String? = nil, icon: String? = nil, mode: String? = nil) {
        self.palette = palette == "classic" ? "classic" : "mono"
        self.icon = ["modern", "classic"].contains(icon ?? "") ? icon! : "pearl"
        self.mode = ["light", "dark"].contains(mode ?? "") ? mode! : "system"
    }

    var isModern: Bool { palette != "classic" }
    /// Compact widgets use the small pearl as their brand mark.
    var symbolName: String { "pearl" }
    private static let key = "widget.appearance.v1"

    static func load(from defaults: UserDefaults? = WidgetStore.defaults) -> Self {
        guard let data = defaults?.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return Self(palette: value.palette, icon: value.icon, mode: value.mode)
    }

    @discardableResult
    func save(to defaults: UserDefaults? = WidgetStore.defaults) -> Bool {
        guard let defaults else { return false }
        if defaults.data(forKey: Self.key) != nil, Self.load(from: defaults) == self { return false }
        guard let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.key)
        return true
    }
}
