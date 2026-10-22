import SwiftUI

/// The classic wallet balance and desktop widgets share the full backdrop,
/// including its soft highlights, so equal base colours also look alike.
struct ClassicNightBackground: View {
    nonisolated static var gradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 53 / 255, green: 92 / 255, blue: 141 / 255),
                Color(red: 60 / 255, green: 91 / 255, blue: 144 / 255),
                Color(red: 68 / 255, green: 89 / 255, blue: 145 / 255)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        GeometryReader { geometry in
            // Keep the wallet's highlights in the same corners at every widget size.
            let horizontalScale = geometry.size.width / 354
            let verticalScale = geometry.size.height / 132
            ZStack {
                Self.gradient
                glow(.white.opacity(0.18), diameter: 150 * horizontalScale)
                    .offset(x: -90 * horizontalScale, y: -60 * verticalScale)
                glow(Color(red: 0.36, green: 0.72, blue: 0.92).opacity(0.30), diameter: 130 * horizontalScale)
                    .offset(x: 120 * horizontalScale, y: 60 * verticalScale)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func glow(_ color: Color, diameter: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: diameter / 2))
            .frame(width: diameter, height: diameter)
            .blur(radius: diameter * 0.08)
    }
}
