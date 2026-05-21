import SwiftUI

/// Three cards float in from the right, snap into a 3D-stacked arrangement
/// with foilHolographic shimmer. Generic motion-graphics primitive — great
/// for "feature card reveal" beats.
public struct CardStack: RenderScene {
    public static let defaultDuration: Double = 5.0

    private struct Card {
        let title: String
        let tag: String
    }

    private static let cards: [Card] = [
        Card(title: "Render", tag: "01"),
        Card(title: "Compose", tag: "02"),
        Card(title: "Ship", tag: "03"),
    ]

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let exit = Ease.easeIn(Ease.clip(t, duration - 0.5, duration))
        let visibility = 1.0 - exit

        return ZStack {
            Color.black.ignoresSafeArea()

            // Subtle radial vignette tint
            RadialGradient(
                colors: [Color.white.opacity(0.03), .clear],
                center: .center, startRadius: 0, endRadius: 900
            )
            .blendMode(.screen)
            .ignoresSafeArea()

            ZStack {
                ForEach(Array(cards.enumerated()), id: \.offset) { idx, card in
                    cardView(card, index: idx, t: t)
                }
            }
            .opacity(visibility)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    @MainActor
    private static func cardView(_ card: Card, index: Int, t: Double) -> some View {
        let entryStart = 0.2 + Double(index) * 0.18
        let entryEnd = entryStart + 0.9
        let p = Ease.easeOut(Ease.clip(t, entryStart, entryEnd))

        let xOffset: CGFloat = CGFloat(1 - p) * 600    // slides in from right
        let yOffset: CGFloat = CGFloat(index - 1) * 32  // final stack offset
        let stackTilt: CGFloat = CGFloat(index - 1) * -4

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(white: 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
                .colorEffect(
                    ShaderLibrary.bundle(.module).foilHolographic(
                        .float2(480, 280),
                        .float(Float(index) + 1.0),
                        .float(0.5)
                    )
                )
                .shadow(color: .black.opacity(0.7), radius: 28, x: 0, y: 18)

            VStack(alignment: .leading, spacing: 6) {
                Text(card.tag)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.45))
                Text(card.title)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 32)
        }
        .frame(width: 480, height: 280)
        .rotationEffect(.degrees(Double(stackTilt) * 0.5))
        .offset(x: xOffset + CGFloat(index - 1) * 28, y: yOffset)
        .opacity(p)
        .zIndex(Double(-index))
    }
}
