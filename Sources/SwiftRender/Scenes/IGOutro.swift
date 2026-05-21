import SwiftUI

/// Slick outro — terminal/cursor aesthetic, single-moment hook.
/// 4.0s. Black bg. Cursor blinks → "openear.fyi" types out → tagline + price land.
/// No decoration, no lines, no gradient. Pure typography + cursor blink.
public struct IGOutro: RenderScene {
    public static let defaultDuration: Double = 4.0

    private static let domain = "openear.fyi"

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        // Cursor blink: visible 0 to 1.0s
        // Type starts at 1.0s, ends at 2.3s (1.3s for full URL = ~118ms/char)
        let typeStart = 1.0
        let typeEnd = 2.3
        let typeP = Ease.clip((t - typeStart) / (typeEnd - typeStart), 0.0, 1.0)
        let chars = Int(round(Double(domain.count) * typeP))
        let typed = String(domain.prefix(chars))

        // Cursor blink
        let cursorVisible = (Int(floor(t / 0.42)) % 2 == 0) ? 1.0 : 0.0
        let cursorOpacity = (t < 2.5) ? cursorVisible : (1.0 - Ease.clip((t - 2.5) / 0.3, 0, 1))

        // Tagline reveal: 2.5-3.2s
        let taglineP = Ease.easeOut(Ease.clip(t, 2.5, 3.2))
        let taglineY: CGFloat = (1 - CGFloat(taglineP)) * 18

        // Price reveal: 3.2-3.7s, smaller, subtle
        let priceP = Ease.easeOut(Ease.clip(t, 3.1, 3.7))

        // Master fade-out last 0.3s
        let outP = Ease.easeIn(Ease.clip(t, duration - 0.3, duration))
        let masterOpacity = 1.0 - outP

        let brandRed = Color(red: 0.91, green: 0.30, blue: 0.27)
        let inkColor = Color(red: 0.96, green: 0.95, blue: 0.92)

        return ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Domain + cursor — center anchor
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(typed)
                        .font(.custom("Inter-Bold", size: 80))
                        .foregroundColor(inkColor)
                        .tracking(-2)

                    Rectangle()
                        .fill(brandRed)
                        .frame(width: 8, height: 80)
                        .opacity(cursorOpacity)
                        .offset(y: 6)
                }
                .frame(maxWidth: .infinity, alignment: .center)

                // Tagline — the slick punchline
                Text("your voice. always yours.")
                    .font(.custom("Inter-Light", size: 44))
                    .foregroundColor(inkColor.opacity(0.55))
                    .tracking(-0.5)
                    .padding(.top, 56)
                    .opacity(taglineP)
                    .offset(y: taglineY)

                // Price tag — small, tucked
                HStack(spacing: 12) {
                    Circle()
                        .fill(brandRed.opacity(0.9))
                        .frame(width: 8, height: 8)

                    Text("$29 once · no subscription")
                        .font(.custom("Inter-Medium", size: 26))
                        .foregroundColor(inkColor.opacity(0.45))
                        .tracking(1)
                }
                .padding(.top, 40)
                .opacity(priceP)

                Spacer()
            }
            .opacity(masterOpacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
