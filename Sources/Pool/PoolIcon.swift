import SwiftUI

// The pools' own logos (each pool's site icon), bundled in Assets.xcassets as
// pool-*.imageset — square, opaque tiles, so nothing is fetched to draw a row and a
// dark mark still reads in dark mode.
//
// Each is one 180 px PNG: the site's largest icon, trimmed and centred at about 80 % on
// a white plate (Lucky Pool's and Pearl Fortune's are tiles already and fill it).
// PearlHash publishes only a 48 px favicon; its glyph was enlarged and re-cut.

extension PoolKind {
    /// This pool's logo in the asset catalog.
    var iconAsset: String {
        switch self {
        case .alphaPool:    return "pool-alphapool"
        case .luckyPool:    return "pool-luckypool"
        case .heroMiners:   return "pool-herominers"
        case .pearlFortune: return "pool-pearlfortune"
        case .pearlHash:    return "pool-pearlhash"
        case .kryptex:      return "pool-kryptex"
        case .f2pool:       return "pool-f2pool"
        }
    }
}

/// A pool's logo on a rounded tile, sized like PearlIconBadge so the two can stand in
/// for each other in a row.
struct PoolIcon: View {
    let pool: PoolKind
    var size: CGFloat = 38

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Image(pool.iconAsset)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)   // the pool's name is always written next to it
    }
}
