import SwiftUI

/// Onboarding-style welcome reveal with a real spring-bounce on each row.
public struct WelcomeSplash: RenderScene {
    public static let defaultDuration: Double = 6.0

    private static let features: [(String, String)] = [
        ("waveform", "Hold a key. Talk. Release."),
        ("lock.shield.fill", "Fully on device. Nothing leaves your Mac."),
        ("brain.head.profile", "Searchable memory. Every word, recallable."),
    ]

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let iconP = Ease.easeOut(Ease.clip(t, 0.0, 0.9))
        let iconOvershoot = max(0, sin(Ease.clip(t, 0.0, 1.4) * .pi)) * 0.06
        let iconScale: CGFloat = (0.6 + 0.4 * CGFloat(iconP)) + CGFloat(iconOvershoot)
        let wordmarkP = Ease.easeOut(Ease.clip(t, 1.0, 1.6))
        let exit = Ease.easeIn(Ease.clip(t, duration - 0.5, duration))
        let visibility = 1.0 - exit

        return ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 38) {
                bundledImage("app-icon")
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .scaleEffect(iconScale)
                    .opacity(iconP)
                    .shadow(color: .red.opacity(0.30), radius: 36)

                VStack(spacing: 6) {
                    Text("OpenEar")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(.white)
                        .opacity(wordmarkP)
                        .offset(y: CGFloat(1 - wordmarkP) * 12)

                    Text("Welcome.")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.5))
                        .opacity(wordmarkP)
                        .offset(y: CGFloat(1 - wordmarkP) * 8)
                }

                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(features.enumerated()), id: \.offset) { idx, feat in
                        let rowStart = 1.8 + Double(idx) * 0.30
                        // Spring response: heavy ease-out + slight overshoot
                        let raw = Ease.clip(t, rowStart, rowStart + 0.55)
                        let spring = springEaseOut(raw)
                        FeatureRow(symbol: feat.0, text: feat.1)
                            .opacity(min(1.0, raw * 2))
                            .offset(x: CGFloat(1 - spring) * -22)
                            .scaleEffect(0.94 + 0.06 * CGFloat(spring), anchor: .leading)
                    }
                }
                .padding(.top, 12)
            }
            .opacity(visibility)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Mild spring/overshoot easing
    private static func springEaseOut(_ x: Double) -> Double {
        let p = max(0, min(1, x))
        // Cubic with overshoot: peaks slightly above 1.0 around 0.7
        let s = 1.70158
        let q = p - 1
        return 1 + (s + 1) * q * q * q + s * q * q
    }
}

private struct FeatureRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.white.opacity(0.06)).frame(width: 32, height: 32)
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
            }
            Text(text)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.85))
        }
    }
}
