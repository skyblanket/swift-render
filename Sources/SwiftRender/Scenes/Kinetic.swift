import SwiftUI

/// Kinetic — flagship kinetic-typography demo reel.
///
/// Five hard-cut movements over 12 seconds:
///   A  0.0–2.6   word slams — one word per beat, inverted flash frames
///   B  2.6–4.6   marquee strips — five rows of type scrolling both ways
///   C  4.6–7.0   shader bloom — galaxy Metal shader revealed by iris mask
///   D  7.0–9.2   type ring — rotating circular text + digit-roll counter
///   E  9.2–12.0  logo lockup — letter stagger, underline sweep, exit
///
/// A persistent timecode HUD runs in the corners (blend-mode difference so
/// it survives inverted frames). Every frame is a pure function of `t`.
public struct Kinetic: RenderScene {
    public static let defaultDuration: Double = 12.0
    public static var ownsPostFX: Bool { true }

    // Movement boundaries (seconds)
    static let segB = 2.6
    static let segC = 4.6
    static let segD = 7.0
    static let segE = 9.2

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
                if t < segB {
                    wordSlam(t)
                } else if t < segC {
                    marquee(t - segB)
                } else if t < segD {
                    shaderBloom(t - segC)
                } else if t < segE {
                    ringStats(t - segD)
                } else {
                    logoLockup(t - segE, len: duration - segE)
                }
            }

            hud(t)
            flash(t)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PostFX(time: t))
    }

    // MARK: - A · word slams

    @ViewBuilder @MainActor
    static func wordSlam(_ t: Double) -> some View {
        let words = ["EVERY", "FRAME", "IS", "A", "PURE", "FUNCTION", "OF", "TIME."]
        let lead = 0.2, slot = 0.3
        if t >= lead {
            let idx = min(words.count - 1, Int((t - lead) / slot))
            let local = (t - lead - Double(idx) * slot) / slot
            let inverted = idx % 2 == 1
            let punch = Ease.easeOut(min(1, local / 0.35))
            let scale = 1.30 - 0.30 * punch
            let rot = (inverted ? -2.0 : 2.0) * (1 - punch)

            ZStack {
                (inverted ? Color.white : Color.black).ignoresSafeArea()
                Text(words[idx])
                    .font(.system(size: 240, weight: .black))
                    .fontWidth(.condensed)
                    .foregroundStyle(inverted ? Color.black : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .frame(width: 1700)
                    .scaleEffect(scale)
                    .rotationEffect(.degrees(rot))
                    .blur(radius: (1 - punch) * 6)
            }
        } else {
            Color.black.ignoresSafeArea()
        }
    }

    // MARK: - B · marquee strips

    @ViewBuilder @MainActor
    static func marquee(_ t: Double) -> some View {
        let line = "SWIFT-RENDER ✦ MOTION GRAPHICS ✦ PURE SWIFT ✦ METAL SHADERS ✦ 60 FPS ✦ "
        let copy = String(repeating: line, count: 6)
        let speeds: [Double] = [340, -460, 380, -520, 330, -430, 360]

        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                ForEach(0..<7, id: \.self) { row in
                    let enter = Ease.easeOut(Ease.clip(t, Double(row) * 0.08, Double(row) * 0.08 + 0.4))
                    let v = speeds[row]
                    let slideFrom: Double = v > 0 ? -900 : 900
                    let anchor: Double = v > 0 ? -2400 : 800
                    let xOff = CGFloat(slideFrom * (1 - enter) + v * t + anchor)
                    let hot = row == 3

                    Text(copy)
                        .font(.system(size: 116, weight: .black))
                        .fontWidth(.condensed)
                        .foregroundStyle(hot ? Color.black : Color.white)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, hot ? 24 : 0)
                        .background(hot ? Color.white : Color.clear)
                        .offset(x: xOff)
                        .opacity(enter)
                }
            }
            .rotationEffect(.degrees(-4))
            .scaleEffect(1.18)
        }
    }

    // MARK: - C · shader bloom

    @ViewBuilder @MainActor
    static func shaderBloom(_ t: Double) -> some View {
        let reveal = Ease.easeOut(Ease.clip(t, 0, 0.6))
        let settle = Ease.easeOut(Ease.clip(t, 0.15, 1.2))
        let tracking = CGFloat(44 - 38 * settle)

        ZStack {
            Rectangle()
                .fill(.black)
                .colorEffect(
                    ShaderLibrary.bundle(.module).galaxy(
                        .float2(1920, 1080), .float(Float(t * 0.8 + 2.0))
                    )
                )
                .scaleEffect(1.18 - 0.10 * settle)
                .mask(Circle().frame(width: CGFloat(reveal) * 2600,
                                     height: CGFloat(reveal) * 2600))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Text("REAL")
                    .font(.system(size: 250, weight: .black))
                Text("METAL")
                    .font(.system(size: 250, weight: .black))
            }
            .fontWidth(.condensed)
            .tracking(tracking)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 24)
            .opacity(settle)
            .scaleEffect(0.96 + 0.04 * settle)

            VStack {
                Spacer()
                Text("ShaderLibrary.bundle(.module).galaxy(size, time)")
                    .font(.system(size: 22, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .opacity(Ease.easeOut(Ease.clip(t, 0.9, 1.5)))
                    .padding(.bottom, 110)
            }
        }
    }

    // MARK: - D · type ring + digit roll

    @ViewBuilder @MainActor
    static func ringStats(_ t: Double) -> some View {
        let grow = Ease.easeOut(Ease.clip(t, 0, 0.5))

        ZStack {
            Rectangle()
                .fill(.black)
                .colorEffect(
                    ShaderLibrary.bundle(.module).neonGrid(
                        .float2(1920, 1080), .float(Float(t * 0.6))
                    )
                )
                .opacity(0.22)
                .ignoresSafeArea()

            typeRing("PROGRAMMATIC MOTION GRAPHICS ✦ SWIFT-RENDER ✦ NATIVE ✦ ",
                     radius: 380, angle: t * 34, size: 34)
                .scaleEffect(0.7 + 0.3 * grow)
                .opacity(grow)

            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    digitRoll(1, t: t, delay: 0.10, size: 210)
                    digitRoll(0, t: t, delay: 0.24, size: 210)
                    digitRoll(0, t: t, delay: 0.38, size: 210)
                }
                Text("FPS RENDER SPEED")
                    .font(.system(size: 30, weight: .bold))
                    .tracking(10)
                    .foregroundStyle(.white.opacity(0.7))
                    .opacity(Ease.easeOut(Ease.clip(t, 0.9, 1.4)))
            }
            .opacity(grow)
        }
    }

    /// Characters of `text` laid out around a circle, rotating at `angle`.
    @MainActor
    static func typeRing(_ text: String, radius: CGFloat, angle: Double, size: CGFloat) -> some View {
        let chars = Array(text)
        return ZStack {
            ForEach(Array(chars.enumerated()), id: \.offset) { idx, ch in
                let a = Double(idx) / Double(chars.count) * 360.0 + angle
                Text(String(ch))
                    .font(.system(size: size, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .offset(y: -radius)
                    .rotationEffect(.degrees(a))
            }
        }
    }

    /// One odometer column that rolls through the strip and lands on `target`.
    @MainActor
    static func digitRoll(_ target: Int, t: Double, delay: Double, size: CGFloat) -> some View {
        let h = size * 1.04
        let p = Ease.easeOut(Ease.clip(t, delay, delay + 0.9))
        let pos = p * Double(20 + target)   // ends exactly on a strip index ≡ target (mod 10)
        return VStack(spacing: 0) {
            ForEach(0..<40, id: \.self) { i in
                Text("\(i % 10)")
                    .font(.system(size: size, weight: .black))
                    .fontWidth(.condensed)
                    .foregroundStyle(.white)
                    .frame(height: h)
            }
        }
        .offset(y: -CGFloat(pos) * h + h * 19.5)
        .frame(width: size * 0.62, height: h)
        .clipped()
    }

    // MARK: - E · logo lockup

    @ViewBuilder @MainActor
    static func logoLockup(_ t: Double, len: Double) -> some View {
        let letters = Array("swift-render.")
        let exit = Ease.easeIn(Ease.clip(t, len - 0.45, len))

        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 26) {
                HStack(spacing: 2) {
                    ForEach(Array(letters.enumerated()), id: \.offset) { idx, ch in
                        let s = 0.1 + Double(idx) * 0.045
                        let p = Ease.easeOut(Ease.clip(t, s, s + 0.4))
                        Text(String(ch))
                            .font(.system(size: 120, weight: .semibold))
                            .foregroundStyle(.white)
                            .opacity(p)
                            .blur(radius: (1 - p) * 10)
                            .offset(y: CGFloat(1 - p) * 26)
                    }
                }

                let sweep = Ease.easeInOut(Ease.clip(t, 0.85, 1.45))
                Rectangle()
                    .fill(.white)
                    .frame(width: CGFloat(sweep) * 780, height: 4)

                let subP = Ease.easeOut(Ease.clip(t, 1.25, 1.85))
                Text("SwiftUI scenes + Metal shaders → MP4")
                    .font(.system(size: 26, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .opacity(subP)
                    .offset(y: CGFloat(1 - subP) * 12)
            }
            .scaleEffect(1.0 + CGFloat(exit) * 0.05)
            .opacity(1 - exit)
        }
    }

    // MARK: - HUD + flash frames

    @MainActor
    static func hud(_ t: Double) -> some View {
        let f = Int((t * 60).rounded(.down))
        let tc = String(format: "00:%02d:%02d", Int(t), f % 60)
        return VStack {
            HStack {
                Text("SWIFT-RENDER")
                Spacer()
                Text(tc)
            }
            Spacer()
            HStack {
                Text("1920×1080 / 60FPS")
                Spacer()
                Text(String(format: "F %04d", f))
            }
        }
        .font(.system(size: 19, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .blendMode(.difference)
        .opacity(0.6)
        .padding(38)
    }

    /// Two-ish-frame white flash at every movement boundary.
    @MainActor
    static func flash(_ t: Double) -> some View {
        let hit = [segB, segC, segD, segE]
            .map { max(0, 1 - abs(t - $0) / 0.07) }
            .max() ?? 0
        return Color.white.opacity(hit * 0.9).ignoresSafeArea()
    }
}
