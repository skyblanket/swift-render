import SwiftUI

/// OpenEar hero opener. Pure function of t.
///
/// 0.0–0.8s : logo fades + scales in
/// 0.8–3.0s : two staggered pulse rings + breath
/// 3.0–4.0s : "OPENEAR" letters drop in
/// 4.0–5.0s : tagline fades in
/// 5.0–6.0s : continuous gentle breath hold
public struct LogoReveal: RenderScene {
    public static let defaultDuration: Double = 6.0

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let entryFade = Ease.easeOut(Ease.clip(t, 0.0, 0.8))
        let entryScale: CGFloat = 0.94 + 0.06 * CGFloat(entryFade)
        let breath = breathProgress(t)
        let breathScale: CGFloat = 1.0 + 0.02 * CGFloat(breath)
        let glowOpacity: Double = 0.10 + 0.55 * breath
        let exit = Ease.easeIn(Ease.clip(t, duration - 0.5, duration))
        let visibility = 1.0 - exit

        return ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 84) {
                logoStack(
                    entryFade: entryFade,
                    entryScale: entryScale,
                    breathScale: breathScale,
                    glowOpacity: glowOpacity,
                    t: t
                )

                wordmark(t: t)
                    .opacity(entryFade)
            }
            .opacity(visibility)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private static func breathProgress(_ t: Double) -> Double {
        if t < 0.8 { return 0 }
        if t <= 3.2 {
            // Bell curve from 0.8 to 3.2 peaking around 2.0
            let p = Ease.clip(t, 0.8, 3.2)
            return Ease.easeInOut(p < 0.5 ? p * 2 : (1 - p) * 2)
        }
        if t > 4.5 {
            let phase = (t - 4.5) / 2.5
            return 0.45 * (0.5 + 0.5 * sin(phase * .pi * 2 - .pi / 2))
        }
        return 0
    }

    @ViewBuilder
    @MainActor
    private static func logoStack(entryFade: Double, entryScale: CGFloat, breathScale: CGFloat, glowOpacity: Double, t: Double) -> some View {
        ZStack {
            // Soft red ambient glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 1.0, green: 0.18, blue: 0.13).opacity(0.65), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 240
                    )
                )
                .frame(width: 680, height: 680)
                .opacity(glowOpacity)
                .blendMode(.screen)
                .blur(radius: 32)

            // Two pulse rings staggered
            pulseRing(at: t, start: 0.9, end: 2.6, maxRadius: 320)
            pulseRing(at: t, start: 1.4, end: 3.1, maxRadius: 380)

            // App icon
            bundledImage("app-icon")
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .frame(width: 360, height: 360)
                .scaleEffect(entryScale * breathScale)
                .opacity(entryFade)
        }
        .frame(width: 680, height: 680)
    }

    @ViewBuilder
    @MainActor
    private static func pulseRing(at t: Double, start: Double, end: Double, maxRadius: CGFloat) -> some View {
        let p = Ease.easeOut(Ease.clip(t, start, end))
        let radius: CGFloat = CGFloat(p) * maxRadius + 80
        let opacity: Double = (1.0 - p) * 0.55
        Circle()
            .strokeBorder(Color(red: 1.0, green: 0.25, blue: 0.20).opacity(opacity), lineWidth: 1.4)
            .frame(width: radius * 2, height: radius * 2)
            .blendMode(.screen)
    }

    @ViewBuilder
    @MainActor
    private static func wordmark(t: Double) -> some View {
        let letters = Array("OPENEAR")
        VStack(spacing: 18) {
            HStack(spacing: 2) {
                ForEach(Array(letters.enumerated()), id: \.offset) { idx, ch in
                    let letterStart = 3.0 + Double(idx) * 0.05
                    let letterEnd = letterStart + 0.55
                    let p = Ease.easeOut(Ease.clip(t, letterStart, letterEnd))
                    Text(String(ch))
                        .font(.system(size: 60, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(Color.white)
                        .opacity(p)
                        .offset(y: CGFloat(1 - p) * 14)
                }
            }

            let tagP = Ease.easeOut(Ease.clip(t, 4.0, 4.9))
            Text("Your Mac listens now.")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.55))
                .opacity(tagP)
        }
    }
}
