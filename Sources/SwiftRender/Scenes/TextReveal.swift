import SwiftUI

/// Generic kinetic-typography scene. A line of text reveals letter-by-letter
/// with a stagger, then holds, then exits. Use this as a hero card.
///
/// Public + parameterized so users can drop in their own copy.
public struct TextReveal: RenderScene {
    public static let defaultDuration: Double = 4.0

    /// Override globally if you don't want to subclass.
    public static var text: String = "swift-render."
    public static var subtitle: String = "programmatic motion graphics"

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let letters = Array(text)
        let exit = Ease.easeIn(Ease.clip(t, duration - 0.5, duration))
        let visibility = 1.0 - exit

        return ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                HStack(spacing: 2) {
                    ForEach(Array(letters.enumerated()), id: \.offset) { idx, ch in
                        let lStart = 0.20 + Double(idx) * 0.05
                        let lEnd = lStart + 0.45
                        let p = Ease.easeOut(Ease.clip(t, lStart, lEnd))
                        Text(String(ch))
                            .font(.system(size: 96, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .opacity(p)
                            .offset(y: CGFloat(1 - p) * 18)
                    }
                }

                let subP = Ease.easeOut(Ease.clip(t, 1.4, 2.2))
                Text(subtitle)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .opacity(subP)
                    .offset(y: CGFloat(1 - subP) * 10)
            }
            .opacity(visibility)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
