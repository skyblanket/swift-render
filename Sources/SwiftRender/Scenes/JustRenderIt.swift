import SwiftUI

/// JustRenderIt — a Nike-style brand ad for swift-render itself.
///
/// Cinema letterbox, stark black/white + volt accent, kick-synced cuts.
/// Pair with the generated beat track (see tools/make_jri_audio.py):
///   swift run swift-render render JustRenderIt --audio out/jri.wav --out out/just-render-it.mp4
///
/// Timeline (audio hits live at the same timestamps):
///   0.00–2.20  cold open — typewriter "EVERY FRAME. EARNED." + heartbeat kicks
///   2.20–5.40  slam quad — NO TIMELINES / NO KEYFRAMES / NO BROWSER / NO MERCY
///   5.40–8.20  speed — counter rolls to 100 FPS, speed lines, render-stat flex
///   8.20–10.80 texture — smokeFlow shader, "MOTION IS WON / FRAME BY FRAME."
///  10.80–12.45 finale slams — JUST / RENDER / IT.
///  12.45–13.40 lockup — JUST RENDER IT. + volt slash sweep + 808 boom
///  13.40–15.00 outro — swift-render. + repo URL, fade to black
public struct JustRenderIt: RenderScene {
    public static let defaultDuration: Double = 15.0
    public static var ownsPostFX: Bool { true }

    static let volt = Color(red: 0.78, green: 1.0, blue: 0.10)

    // Timeline anchors — keep in sync with tools/make_jri_audio.py
    static let phraseTimes: [Double] = [2.2, 3.0, 3.8, 4.6]
    static let phrases = ["NO TIMELINES", "NO KEYFRAMES", "NO BROWSER", "NO MERCY"]
    static let speedStart = 5.4
    static let textureStart = 8.2
    static let finaleTimes: [Double] = [10.8, 11.35, 11.9]
    static let finaleWords = ["JUST", "RENDER", "IT."]
    static let lockupStart = 12.45
    static let outroStart = 13.4

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let impacts = phraseTimes + [speedStart] + finaleTimes + [lockupStart]
        let jolt = shake(t, impacts: impacts, amp: 16)
        let fade = Ease.easeIn(Ease.clip(t, duration - 0.5, duration))

        return ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if t < phraseTimes[0] {
                    coldOpen(t)
                } else if t < speedStart {
                    slamQuad(t)
                } else if t < textureStart {
                    speed(t - speedStart)
                } else if t < finaleTimes[0] {
                    texture(t - textureStart)
                } else if t < outroStart {
                    finale(t)
                } else {
                    outro(t - outroStart)
                }
            }
            .offset(jolt)

            letterbox()
        }
        .opacity(1 - fade)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PostFX(time: t, grainAmount: 0.13, vignetteAmount: 0.5))
    }

    // MARK: - 0 · cold open

    @ViewBuilder @MainActor
    static func coldOpen(_ t: Double) -> some View {
        let line = "EVERY FRAME. EARNED."
        let typed = Int(Ease.clip(t, 0.25, 1.6) * Double(line.count))
        let shown = String(line.prefix(typed))
        let cursorOn = Int(t * 4) % 2 == 0 && t < 1.8
        let breathe = 0.05 + 0.03 * sin(t * 3.4)

        ZStack {
            RadialGradient(colors: [Color.white.opacity(breathe), .clear],
                           center: .center, startRadius: 0, endRadius: 700)
                .ignoresSafeArea()
            HStack(spacing: 2) {
                Text(shown)
                Rectangle().fill(volt).frame(width: 14, height: 30)
                    .opacity(cursorOn ? 1 : 0)
            }
            .font(.system(size: 30, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .tracking(6)
        }
    }

    // MARK: - 1 · slam quad

    @ViewBuilder @MainActor
    static func slamQuad(_ t: Double) -> some View {
        let idx = lastIndex(of: phraseTimes, before: t)
        let local = t - phraseTimes[idx]
        let punch = Ease.easeOut(min(1, local / 0.22))
        let fromLeft = idx % 2 == 0
        let slide = CGFloat(1 - punch) * (fromLeft ? -700 : 700)
        let isLast = idx == phrases.count - 1

        ZStack {
            Color.black.ignoresSafeArea()
            Text(phrases[idx])
                .font(.system(size: 190, weight: .black))
                .fontWidth(.condensed)
                .italic()
                .foregroundStyle(isLast ? volt : Color.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(width: 1680)
                .modifier(Slant(height: 190))
                .offset(x: slide)
                .scaleEffect(1.12 - 0.12 * punch)
                .blur(radius: (1 - punch) * 8)
        }
    }

    // MARK: - 2 · speed

    @ViewBuilder @MainActor
    static func speed(_ t: Double) -> some View {
        let count = Int(Ease.easeOut(Ease.clip(t, 0.1, 1.3)) * 100)
        let statP = Ease.easeOut(Ease.clip(t, 1.4, 1.9))

        ZStack {
            Color.black.ignoresSafeArea()
            speedLines(t)

            VStack(spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    Text("\(count)")
                        .font(.system(size: 330, weight: .black))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text("FPS")
                        .font(.system(size: 130, weight: .black))
                        .foregroundStyle(volt)
                }
                .fontWidth(.condensed)
                .italic()
                .modifier(Slant(height: 330))

                Text("900 FRAMES · 1080P · RENDERED IN 9 SECONDS")
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .tracking(8)
                    .foregroundStyle(.white.opacity(0.75))
                    .opacity(statP)
                    .offset(y: CGFloat(1 - statP) * 14)
            }
        }
    }

    @MainActor
    static func speedLines(_ t: Double) -> some View {
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                let r1 = hash01(Double(i) * 12.9898)
                let r2 = hash01(Double(i) * 78.233 + 5)
                let y = CGFloat(r1 * 1000 - 500)
                let speed = 2600.0 + r2 * 2200.0
                let x = 2600.0 - (speed * t).truncatingRemainder(dividingBy: 5200.0)
                Rectangle()
                    .fill(Color.white.opacity(0.30 + r2 * 0.35))
                    .frame(width: 420 + CGFloat(r1) * 500, height: 3 + CGFloat(r2) * 7)
                    .offset(x: CGFloat(x), y: y)
            }
        }
        .rotationEffect(.degrees(-16))
        .scaleEffect(1.4)
    }

    // MARK: - 3 · texture

    @ViewBuilder @MainActor
    static func texture(_ t: Double) -> some View {
        let inP = Ease.easeOut(Ease.clip(t, 0, 0.5))
        let l1 = Ease.easeOut(Ease.clip(t, 0.4, 1.0))
        let l2 = Ease.easeOut(Ease.clip(t, 0.9, 1.5))

        ZStack {
            Rectangle()
                .fill(.black)
                .colorEffect(
                    ShaderLibrary.bundle(.module).smokeFlow(
                        .float2(1920, 1080), .float(Float(t * 0.7 + 4.0))
                    )
                )
                .opacity(0.55 * inP)
                .scaleEffect(1.25 - 0.08 * Ease.clip(t, 0, 2.6))
                .ignoresSafeArea()

            VStack(spacing: 10) {
                Text("MOTION IS WON")
                    .foregroundStyle(.white)
                    .opacity(l1)
                    .offset(y: CGFloat(1 - l1) * 30)
                Text("FRAME BY FRAME.")
                    .foregroundStyle(volt)
                    .opacity(l2)
                    .offset(y: CGFloat(1 - l2) * 30)
            }
            .font(.system(size: 150, weight: .black))
            .fontWidth(.condensed)
            .italic()
            .modifier(Slant(height: 150))
            .shadow(color: .black.opacity(0.8), radius: 20)
        }
    }

    // MARK: - 4 · finale slams + lockup

    @ViewBuilder @MainActor
    static func finale(_ t: Double) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if t < lockupStart {
                let idx = lastIndex(of: finaleTimes, before: t)
                let local = t - finaleTimes[idx]
                let punch = Ease.easeOut(min(1, local / 0.18))
                Text(finaleWords[idx])
                    .font(.system(size: 300, weight: .black))
                    .fontWidth(.condensed)
                    .italic()
                    .foregroundStyle(idx == 2 ? volt : Color.white)
                    .modifier(Slant(height: 300))
                    .scaleEffect(1.35 - 0.35 * punch)
                    .blur(radius: (1 - punch) * 10)
            } else {
                lockup(t - lockupStart)
            }
        }
    }

    @ViewBuilder @MainActor
    static func lockup(_ t: Double) -> some View {
        let inP = Ease.easeOut(min(1, t / 0.2))
        let sweep = Ease.easeInOut(Ease.clip(t, 0.15, 0.55))

        VStack(spacing: 30) {
            Text("JUST RENDER IT.")
                .font(.system(size: 170, weight: .black))
                .fontWidth(.condensed)
                .italic()
                .foregroundStyle(.white)
                .modifier(Slant(height: 170))
                .scaleEffect(1.18 - 0.18 * inP)

            Rectangle()
                .fill(volt)
                .frame(width: CGFloat(sweep) * 980, height: 14)
                .rotationEffect(.degrees(-3))
                .offset(x: CGFloat(1 - sweep) * -60)
        }
    }

    // MARK: - 5 · outro

    @ViewBuilder @MainActor
    static func outro(_ t: Double) -> some View {
        let p = Ease.easeOut(min(1, t / 0.5))
        VStack(spacing: 20) {
            Text("swift-render.")
                .font(.system(size: 86, weight: .semibold))
                .foregroundStyle(.white)
            Text("github.com/skyblanket/swift-render")
                .font(.system(size: 24, design: .monospaced))
                .foregroundStyle(volt.opacity(0.9))
        }
        .opacity(p)
        .scaleEffect(0.97 + 0.03 * CGFloat(p))
    }

    // MARK: - helpers

    static func letterbox() -> some View {
        VStack {
            Rectangle().fill(.black).frame(height: 96)
            Spacer()
            Rectangle().fill(.black).frame(height: 96)
        }
        .ignoresSafeArea()
    }

    /// Index of the latest anchor at or before `t` (assumes t >= anchors[0]).
    static func lastIndex(of anchors: [Double], before t: Double) -> Int {
        var idx = 0
        for (i, a) in anchors.enumerated() where t >= a { idx = i }
        return idx
    }

    /// SF has no condensed-italic face, so `.italic()` silently no-ops there.
    /// Fake the athletic forward lean with a shear, re-centered for `height`.
    struct Slant: ViewModifier {
        var height: CGFloat
        func body(content: Content) -> some View {
            content
                .transformEffect(CGAffineTransform(a: 1, b: 0, c: -0.14, d: 1,
                                                   tx: 0.07 * height, ty: 0))
        }
    }

    static func hash01(_ x: Double) -> Double {
        abs((sin(x) * 43758.5453).truncatingRemainder(dividingBy: 1.0))
    }

    /// Deterministic decaying camera shake summed over impact times.
    static func shake(_ t: Double, impacts: [Double], amp: Double) -> CGSize {
        var dx = 0.0, dy = 0.0
        for i in impacts where t >= i && t - i < 0.6 {
            let dt = t - i
            let e = exp(-dt * 11) * amp
            dx += sin(dt * 131 + i * 7) * e
            dy += cos(dt * 167 + i * 13) * e * 0.6
        }
        return CGSize(width: dx, height: dy)
    }
}
