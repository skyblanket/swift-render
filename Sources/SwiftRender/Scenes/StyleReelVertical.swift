import SwiftUI

/// StyleReelVertical — the 9:16 cut of StyleReel for Reels/Shorts/TikTok.
/// Reuses every style scene as a live 16:9 card floating in portrait; zooms
/// to width-fill with the starfield breathing in the bands above and below.
///
///   swift run swift-render render StyleReelVertical --width 1080 --height 1920 \
///       --audio out/reel.wav --out out/style-reel-vert.mp4
public struct StyleReelVertical: RenderScene {
    public static let defaultDuration: Double = 38.4
    public static var ownsPostFX: Bool { true }

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let switches = (0..<12).map { StyleReel.segStart + Double($0) * StyleReel.segLen } + [StyleReel.outroStart]
        let jolt = JustRenderIt.shake(t, impacts: switches, amp: 10)
        let fade = Ease.easeIn(Ease.clip(t, duration - 1.0, duration))

        return ZStack {
            Color.black.ignoresSafeArea()
            Timeline(t) {
                Clip(3.6) { l in intro(l) }
                for i in 0..<12 {
                    Clip(2.4) { l in segment(i, l) }
                }
                Clip(6.0) { l in collage(l) }
            }
            .offset(jolt)
            StyleReel.flash(t, hits: switches)
        }
        .opacity(1 - fade)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PostFX(time: t, grainAmount: 0.09, vignetteAmount: 0.38))
    }

    @ViewBuilder @MainActor
    static func intro(_ t: Double) -> some View {
        ZStack {
            LaunchFilm.starfield(t * 0.4, intensity: 0.4)
            VStack(spacing: 14) {
                let p1 = Ease.easeOut(min(1, max(0, (t - 0.3) / 0.22)))
                let p2 = Ease.easeOut(min(1, max(0, (t - 1.3) / 0.22)))
                Text("EVERY\nSTYLE.")
                    .font(.system(size: 170, weight: .black)).fontWidth(.condensed)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .scaleEffect(1.3 - 0.3 * p1).opacity(p1).blur(radius: (1 - p1) * 8)
                Text("ONE\nENGINE.")
                    .font(.system(size: 170, weight: .black)).fontWidth(.condensed)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .scaleEffect(1.3 - 0.3 * p2).opacity(p2).blur(radius: (1 - p2) * 8)
                Text("100% code · zero assets")
                    .font(.system(size: 30, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .opacity(Ease.easeOut(Ease.clip(t, 2.2, 2.7)))
                    .padding(.top, 30)
            }
        }
    }

    @ViewBuilder @MainActor
    static func segment(_ i: Int, _ l: Double) -> some View {
        ZStack {
            // the bands above/below the card stay alive
            LaunchFilm.starfield(3.6 + Double(i) * 2.4 + l, intensity: 0.45)
            if l < 1.05, i > 0 {
                StyleReel.styleView(i - 1, 2.4 + l)
                    .frame(width: 1920, height: 1080)
                    .scaleEffect(0.5625)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            card(i, l)
        }
    }

    @MainActor
    static func card(_ i: Int, _ l: Double) -> some View {
        let enter = Ease.easeOutBack(Ease.clip(l, 0.0, 0.4), overshoot: 1.2)
        let zoom = Ease.easeInOut(Ease.clip(l, 0.45, 1.05))
        // 0.34 card → 0.5625 width-fill (1080/1920)
        let scale = (0.34 + (0.5625 - 0.34) * zoom) * (0.7 + 0.3 * enter)
        let radius = (1 - zoom) * 80 + 8
        return StyleReel.styleView(i, l)
            .frame(width: 1920, height: 1080)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius)
                .stroke(.white.opacity(0.85 * (1 - zoom) + 0.15), lineWidth: 2.5))
            .overlay(alignment: .bottom) {
                Text(StyleReel.styleNames[i])
                    .font(.system(size: 52, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 28).padding(.vertical, 12)
                    .background(.white)
                    .offset(y: 110)
                    .opacity(enter * (1 - 0.4 * zoom))
            }
            .shadow(color: .black.opacity(0.6), radius: 46, y: 16)
            .scaleEffect(CGFloat(scale))
            .offset(x: (i % 2 == 0 ? 1 : -1) * CGFloat(1 - enter) * 1200,
                    y: CGFloat(1 - enter) * (i % 3 == 0 ? -500 : 420))
    }

    @ViewBuilder @MainActor
    static func collage(_ l: Double) -> some View {
        ZStack {
            LaunchFilm.starfield(36 + l, intensity: 0.35)
            VStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 12) {
                        ForEach(0..<2, id: \.self) { col in
                            let i = row * 2 + col
                            let p = Ease.easeOutBack(Ease.clip(l, 0.1 + Double(i) * 0.06, 0.45 + Double(i) * 0.06), overshoot: 1.1)
                            StyleReel.styleView(i, 3.0 + l)
                                .frame(width: 1920, height: 1080)
                                .scaleEffect(0.272)
                                .frame(width: 522, height: 294)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.25)))
                                .scaleEffect(CGFloat(0.5 + 0.5 * p))
                                .opacity(p)
                        }
                    }
                }
            }
            VStack(spacing: 12) {
                Text("ALL OF THIS\nIS CODE.")
                    .font(.system(size: 120, weight: .black)).fontWidth(.condensed)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.95), radius: 28)
                    .opacity(Ease.easeOut(Ease.clip(l, 1.3, 1.8)))
                Text("github.com/skyblanket\n/swift-render")
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.95), radius: 16)
                    .opacity(Ease.easeOut(Ease.clip(l, 1.7, 2.2)))
            }
        }
    }
}
