import SwiftUI

/// Hook card — "a wall of records. made from your voice."
/// Pure black bg, Inter typography, modern mograph patterns:
/// - Snappy mask reveals (no bouncy springs)
/// - Reverse scale on the headline (oversized → 1.0, comes toward camera)
/// - Per-line ease-out timing (reads naturally, line-by-line)
public struct IGHook: RenderScene {
    public static let defaultDuration: Double = 2.0

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        // Sequential reveals — tighter, snappier curves
        let p1 = Ease.easeOut(Ease.clip(t, 0.05, 0.40))   // "a wall of"
        let p2 = Ease.easeOut(Ease.clip(t, 0.30, 0.85))   // "records." headline
        let p3 = Ease.easeOut(Ease.clip(t, 0.85, 1.20))   // "made from your"
        let p4 = Ease.easeOut(Ease.clip(t, 1.10, 1.55))   // "voice." accent

        // Headline reverse-scale — oversized (1.18) → 1.0, comes toward camera
        let headlineScale = 1.18 - 0.18 * CGFloat(p2)

        // Master fade-out
        let outP = Ease.easeIn(Ease.clip(t, duration - 0.18, duration))
        let masterOpacity = 1.0 - outP

        let brandRed = Color(red: 0.91, green: 0.30, blue: 0.27)
        let inkColor = Color(red: 0.96, green: 0.95, blue: 0.92)

        return ZStack {
            // PURE BLACK — no gradient
            Color.black.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                // "a wall of" — light weight, secondary
                Text("a wall of")
                    .font(.custom("Inter-Light", size: 80))
                    .foregroundColor(inkColor.opacity(0.50))
                    .tracking(-1.5)
                    .opacity(p1)
                    .mask(
                        Rectangle()
                            .frame(height: CGFloat(p1) * 100)
                            .frame(maxHeight: .infinity, alignment: .top)
                    )

                // "records." — headline, mask reveal + reverse scale
                Text("records.")
                    .font(.custom("Inter-Black", size: 220))
                    .foregroundColor(inkColor)
                    .tracking(-12)
                    .scaleEffect(headlineScale, anchor: .leading)
                    .opacity(p2)
                    .mask(
                        Rectangle()
                            .frame(height: CGFloat(p2) * 280)
                            .frame(maxHeight: .infinity, alignment: .top)
                    )
                    .padding(.top, -4)
                    .padding(.bottom, 28)

                // "made from your"
                Text("made from your")
                    .font(.custom("Inter-Medium", size: 56))
                    .foregroundColor(inkColor.opacity(0.45))
                    .tracking(-1)
                    .opacity(p3)
                    .mask(
                        Rectangle()
                            .frame(height: CGFloat(p3) * 70)
                            .frame(maxHeight: .infinity, alignment: .top)
                    )

                // "voice." — brand red accent on the payoff word
                Text("voice.")
                    .font(.custom("Inter-Bold", size: 144))
                    .foregroundColor(brandRed)
                    .tracking(-5)
                    .opacity(p4)
                    .mask(
                        Rectangle()
                            .frame(height: CGFloat(p4) * 184)
                            .frame(maxHeight: .infinity, alignment: .top)
                    )
                    .padding(.top, 4)

                Spacer()
            }
            .padding(.horizontal, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(masterOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
