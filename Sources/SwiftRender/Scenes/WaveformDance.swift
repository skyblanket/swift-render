import SwiftUI

/// Centered audio waveform dancing with a synthetic envelope.
/// Adds an "OpenEar" wordmark above the bars so the scene has identity.
public struct WaveformDance: RenderScene {
    public static let defaultDuration: Double = 4.0

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let entry = Ease.easeOut(Ease.clip(t, 0.0, 0.5))
        let exit = Ease.easeIn(Ease.clip(t, duration - 0.4, duration))
        let visibility = entry * (1.0 - exit)
        let level = signal(t)
        let wordmarkP = Ease.easeOut(Ease.clip(t, 0.3, 1.1))

        return ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 36) {
                Text("OpenEar")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))
                    .tracking(3)
                    .opacity(wordmarkP)

                Waveform(
                    level: level, t: t,
                    barCount: 28, height: 140,
                    spacing: 6, minHeight: 4
                )
                .frame(width: 820, height: 140)

                Text("Your voice, on device.")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
            .opacity(visibility)
            .scaleEffect(0.97 + 0.03 * CGFloat(visibility))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func signal(_ t: Double) -> Float {
        let a = sin(t * 2.0) * 0.3 + 0.55
        let b = sin(t * 5.5) * 0.2
        let c = sin(t * 11.0) * 0.15
        return Float(max(0.20, min(1.0, a + b + c)))
    }
}
