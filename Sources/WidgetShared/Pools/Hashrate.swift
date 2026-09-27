import Foundation

// MARK: - Hashrate + loose-number helpers, shared by the app and the widget extensions
//
// ONE formatter and ONE parser for both processes. The app writes each pool's hashrate
// string into the widget snapshot and the widget re-formats it on its own refresh, so when
// the two carried separate copies the same rig flipped between "270.12 TH/s" (app) and
// "270 TH/s" (widget) depending on who wrote last.

/// Human-readable hashrate from raw H/s. 0 reads "0 H/s" — a real, honest zero (a pool that
/// reports nothing is shown as "—" by the caller, which is the one that knows the difference).
func formatHashrate(_ hps: Double) -> String {
    let units: [(String, Double)] = [("EH/s", 1e18), ("PH/s", 1e15), ("TH/s", 1e12), ("GH/s", 1e9), ("MH/s", 1e6), ("kH/s", 1e3)]
    for (u, v) in units where hps >= v { return String(format: "%.2f %@", hps / v, u) }
    return String(format: "%.0f H/s", hps)
}

/// Inverse of `formatHashrate`: parse "240.30 TH/s" → raw H/s. 0 if unparseable. The unit is
/// matched case-insensitively ("KH/s" and "kH/s" both occur in the wild).
func parseHashrate(_ s: String) -> Double {
    let parts = s.split(separator: " ")
    // Strip grouping separators ("1,234.56 TH/s") before parsing so a comma-grouped
    // value isn't silently treated as 0.
    let numStr = String(parts.first ?? "").replacingOccurrences(of: ",", with: "")
    guard let v = Double(numStr) else { return 0 }
    let unit = (parts.count > 1 ? String(parts[1]) : "H/s").uppercased()
    let mult: [String: Double] = ["EH/S": 1e18, "PH/S": 1e15, "TH/S": 1e12,
                                  "GH/S": 1e9, "MH/S": 1e6, "KH/S": 1e3, "H/S": 1]
    return v * (mult[unit] ?? 1)
}

extension Double {
    /// Self when non-zero, else `fallback`. Lets a per-worker 1h hashrate fall back
    /// to the live rate for pools that don't report a distinct 1h figure.
    func nonZeroOr(_ fallback: Double) -> Double { self != 0 ? self : fallback }
}

/// Pool APIs are inconsistent about JSON types — amounts and timestamps arrive as strings in
/// one field and numbers in its sibling, sometimes within one response, and F2Pool renders
/// money with grouping commas ("1,234.5"). Decode any of those to a Double; anything else
/// (null, an object) reads as 0 rather than failing the whole payload.
struct FlexDouble: Decodable, Sendable {
    let value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self),
                let d = Double(s.replacingOccurrences(of: ",", with: "")) { value = d }
        else { value = 0 }
    }
}
