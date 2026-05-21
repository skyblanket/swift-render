import SwiftUI

/// Album sleeve + spinning vinyl disc, side-by-side composition.
/// Sleeve on left, disc on right with disc never overlapping the sleeve's
/// label area. Both use the real OpenEar Metal shaders.
public struct VinylSpin: RenderScene {
    public static let defaultDuration: Double = 6.0

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let entry = Ease.easeOut(Ease.clip(t, 0.0, 1.4))
        let exit = Ease.easeIn(Ease.clip(t, duration - 0.5, duration))
        let visibility = entry * (1.0 - exit)

        // Disc enters from behind sleeve and slides right
        let slideP = Ease.easeOut(Ease.clip(t, 0.6, 2.2))
        let discOffsetX: CGFloat = -160 + 480 * CGFloat(slideP)

        let rotation = (t / 4.0) * 360.0
        let labelP = Ease.easeOut(Ease.clip(t, 2.6, 3.6))

        return ZStack {
            Color.black.ignoresSafeArea()

            // Warm backdrop
            RadialGradient(
                colors: [
                    Color(red: 0.16, green: 0.04, blue: 0.04).opacity(0.7),
                    Color.black,
                ],
                center: .center, startRadius: 0, endRadius: 1100
            )
            .ignoresSafeArea()

            // Composition: sleeve fixed left-of-center, disc slides out to its right
            ZStack {
                SleeveView(
                    size: 460,
                    seed: 7,
                    mouseNorm: CGPoint(x: 0.30, y: 0.28),
                    glossiness: 1.0
                )
                .offset(x: -240)
                .scaleEffect(0.94 + 0.06 * CGFloat(entry))

                ZStack {
                    VinylDiscView(
                        labelColor: Color(red: 0.45, green: 0.12, blue: 0.11),
                        accentColor: .white,
                        size: 460,
                        seed: 3,
                        title: "OpenEar Launch",
                        date: "APR 28 2026",
                        externalSpinAngle: rotation
                    )
                    .shadow(color: .black.opacity(0.75), radius: 36, x: 6, y: 22)

                    // Soft warm-light overlay matching shader's upper-left key
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.92, blue: 0.78).opacity(0.28),
                                    .clear,
                                ],
                                center: UnitPoint(x: 0.28, y: 0.22),
                                startRadius: 4,
                                endRadius: 280
                            )
                        )
                        .frame(width: 460, height: 460)
                        .blendMode(.screen)
                        .allowsHitTesting(false)
                }
                .offset(x: discOffsetX)
            }
            .opacity(visibility)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Caption beneath
            VStack {
                Spacer()
                VStack(spacing: 8) {
                    Text("Mastered Locally")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white)
                    Text("Every word stays on your Mac.")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .opacity(labelP * visibility)
                .offset(y: CGFloat(1 - labelP) * 14)
                .padding(.bottom, 120)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
