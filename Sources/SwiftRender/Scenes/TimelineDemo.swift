import SwiftUI

/// TimelineDemo — dogfood for the Timeline/Clip/Transition API + spring easings.
///
/// Four sequential clips with three different transitions, plus a pinned
/// progress-bar overlay spanning the whole piece. Each clip body receives
/// LOCAL time starting at 0 — no hand-rolled segment offsets anywhere.
///
/// Sequential layout (transition overlaps subtract from the start):
///   title   0.00–2.20
///   springs 1.75–4.15   (slides in over title's last 0.45s)
///   shader  4.01–6.41   (flash cut)
///   outro   5.91–9.90   (0.5s crossfade)
public struct TimelineDemo: RenderScene {
    public static let defaultDuration: Double = 9.9

    static let volt = Color(red: 0.78, green: 1.0, blue: 0.10)

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Timeline(t) {
                Clip(2.2) { local in titleCard(local) }
                Clip(2.4) { local in springCard(local) }
                    .transition(.slide(0.45, from: .trailing))
                Clip(2.4) { local in shaderCard(local) }
                    .transition(.flash())
                Clip(3.99) { local in outroCard(local) }
                    .transition(.fade(0.5))
                Clip(at: 0, for: duration) { local in progressHUD(local, total: duration) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: clips — every one a pure function of LOCAL time

    @ViewBuilder @MainActor
    static func titleCard(_ t: Double) -> some View {
        let words = ["TIMELINE.", "CLIPS.", "TRANSITIONS."]
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                let p = stagger(t, i, step: 0.3, ramp: 0.5, start: 0.2)
                Text(words[i])
                    .font(.system(size: 130, weight: .black))
                    .fontWidth(.condensed)
                    .foregroundStyle(i == 2 ? volt : .white)
                    .opacity(p)
                    .offset(x: CGFloat(1 - p) * -60)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 200)
    }

    @ViewBuilder @MainActor
    static func springCard(_ t: Double) -> some View {
        let curves: [(String, (Double) -> Double)] = [
            ("spring 0.45/0.55", { Ease.spring($0, from: 0, to: 1, response: 0.45, dampingFraction: 0.55) }),
            ("easeOutBack", { Ease.easeOutBack(Ease.clip($0, 0, 0.8)) }),
            ("bounce", { Ease.bounce(Ease.clip($0, 0, 1.0)) }),
            ("elastic", { Ease.elastic(Ease.clip($0, 0, 1.1)) }),
        ]
        VStack(spacing: 44) {
            Text("ANALYTIC SPRINGS")
                .font(.system(size: 60, weight: .black))
                .fontWidth(.condensed)
                .foregroundStyle(.white)
            VStack(spacing: 30) {
                ForEach(0..<curves.count, id: \.self) { i in
                    let v = curves[i].1(max(0, t - 0.25 - Double(i) * 0.12))
                    HStack(spacing: 24) {
                        Text(curves[i].0)
                            .font(.system(size: 22, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 320, alignment: .trailing)
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.12)).frame(width: 900, height: 6)
                            Circle().fill(volt)
                                .frame(width: 34, height: 34)
                                .offset(x: CGFloat(v) * 866)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder @MainActor
    static func shaderCard(_ t: Double) -> some View {
        ZStack {
            Rectangle()
                .fill(.black)
                .colorEffect(
                    ShaderLibrary.bundle(.module).kaleidoscope(
                        .float2(1920, 1080), .float(Float(t * 0.5 + 1.0)), .float(8.0)
                    )
                )
                .ignoresSafeArea()
            Text("NESTED METAL")
                .font(.system(size: 170, weight: .black))
                .fontWidth(.condensed)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 26)
                .scaleEffect(1.0 + 0.04 * Ease.spring(t, from: 1, to: 0, response: 0.6, dampingFraction: 0.4))
        }
    }

    @ViewBuilder @MainActor
    static func outroCard(_ t: Double) -> some View {
        let inP = Ease.easeOut(Ease.clip(t, 0.1, 0.7))
        let exit = Ease.easeIn(Ease.clip(t, 3.4, 3.9))
        VStack(spacing: 24) {
            Text("swift-render")
                .font(.system(size: 110, weight: .semibold))
                .foregroundStyle(.white)
            Text("Timeline(t) { Clip(2.0) { local in … }.transition(.fade()) }")
                .font(.system(size: 24, design: .monospaced))
                .foregroundStyle(volt.opacity(0.9))
        }
        .opacity(inP * (1 - exit))
        .scaleEffect(0.97 + 0.03 * CGFloat(inP))
    }

    /// Pinned overlay — proves `Clip(at:for:)` floats over the sequence.
    @ViewBuilder @MainActor
    static func progressHUD(_ t: Double, total: Double) -> some View {
        VStack {
            Spacer()
            HStack {
                Text("TIMELINE DEMO")
                Spacer()
                Text(String(format: "%04.1fs / %04.1fs", t, total))
            }
            .font(.system(size: 17, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 44)
            .padding(.bottom, 18)
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.10)).frame(height: 5)
                Rectangle().fill(volt).frame(width: CGFloat(t / total) * 1920, height: 5)
            }
        }
        .ignoresSafeArea()
    }
}
