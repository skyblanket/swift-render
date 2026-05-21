import SwiftUI

/// Caption strip for IG content sections — pure black, Inter typography.
/// Fills the top + bottom letterbox bands above/below the centered content.
/// Single-line caption that mask-reveals on entry, fades on exit.
public struct IGCaption: RenderScene {
    public static let defaultDuration: Double = 3.0

    public static var captionText: String = "every recording → a vinyl"

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        // Reveal: 0.0-0.6s, hold, fade out 0.4s before end
        let reveal = Ease.easeOut(Ease.clip(t, 0.05, 0.55))
        let outP = Ease.easeIn(Ease.clip(t, duration - 0.40, duration))
        let opacity = Double(reveal) * (1.0 - outP)

        let inkColor = Color(red: 0.96, green: 0.95, blue: 0.92)

        // Source video sits 16:9 letterboxed in 9:16 frame.
        // Top band: ~610px tall, bottom band: ~610px tall (1080 wide content,
        // 1920 tall canvas, content height = 607).
        return ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // TOP band — caption text
                ZStack {
                    Color.black

                    Text(captionText)
                        .font(.custom("Inter-Medium", size: 56))
                        .foregroundColor(inkColor.opacity(0.92))
                        .tracking(-0.5)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 960)
                        .padding(.horizontal, 40)
                        .opacity(opacity)
                        .mask(
                            Rectangle()
                                .frame(width: 1000 * CGFloat(reveal))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        )
                }
                .frame(height: 656)

                // Middle "content area" placeholder — transparent, video goes here
                Color.clear
                    .frame(height: 608)

                // BOTTOM band — accent dot + tagline
                ZStack {
                    Color.black

                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color(red: 0.91, green: 0.30, blue: 0.27))
                            .frame(width: 10, height: 10)
                            .opacity(opacity)

                        Text("local · never uploaded")
                            .font(.custom("Inter-Regular", size: 28))
                            .foregroundColor(inkColor.opacity(0.50))
                            .tracking(2)
                            .opacity(opacity)
                    }
                }
                .frame(height: 656)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
