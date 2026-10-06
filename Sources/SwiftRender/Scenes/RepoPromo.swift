import SwiftUI

/// RepoPromo — the repo selling itself, feature by feature, on a 0.6s beat grid.
///
///   swift run swift-render render RepoPromo
///
/// Chapters (2.4s each, crashes on every cut):
///   00 typed signature   01 wordmark slam   02 manifesto slams
///   03 code card         04 Metal moment    05 springs
///   06 speed odometer    07 determinism     08 terminal → lockup
public struct RepoPromo: RenderScene {
    public static let defaultDuration: Double = 25.2
    public static var ownsPostFX: Bool { true }

    static let chapters: [Double] = (1...8).map { 2.4 * Double($0) }
    static let lime = Color(red: 0.78, green: 1.0, blue: 0.102)   // #C7FF1A, the release-badge green

    public static func soundtrack(duration: Double) -> Score? {
        Score(duration: duration) {
            hat(at: 0.3, pan: -0.4); hat(at: 0.9, pan: 0.4); hat(at: 1.5, pan: -0.4)
            kick(at: 1.8, amp: 0.6)

            boom(at: chapters[0], amp: 0.8, duration: 1.5)
            fourOnFloor(from: chapters[0], to: chapters[7])
            hatSixteenths(from: chapters[0], to: chapters[7])
            bassline([.a1, .a1, .c2, .g1], from: chapters[0], to: chapters[7])
            crashes(at: chapters)

            boom(at: chapters[7])
            kicks(at: [19.8, 20.4], amp: 0.7)
            crash(at: 21.4, amp: 0.3)
            drone(.a1, from: 21.4, for: 3.6, amp: 0.14)
        }
    }

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let jolt = JustRenderIt.shake(t, impacts: chapters + [21.4], amp: 10)
        let fade = Ease.easeIn(Ease.clip(t, duration - 0.9, duration))

        return ZStack {
            Color.black.ignoresSafeArea()
            Timeline(t) {
                Clip(2.4) { l in typedSignature(l) }
                Clip(2.4) { l in wordmarkSlam(l) }
                Clip(2.4) { l in manifesto(l) }
                Clip(2.4) { l in codeCard(l) }
                Clip(2.4) { l in metalMoment(l) }
                Clip(2.4) { l in springs(l) }
                Clip(2.4) { l in speed(l) }
                Clip(2.4) { l in determinism(l) }
                Clip(6.0) { l in outro(l) }
            }
            .offset(jolt)
            flash(t)
        }
        .opacity(1 - fade)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PostFX(time: t, grainAmount: 0.10, vignetteAmount: 0.40))
    }

    // 00 · the whole API, typed
    @ViewBuilder @MainActor
    static func typedSignature(_ t: Double) -> some View {
        let line = "(t: Double) -> some View"
        let typed = Int(Ease.clip(t, 0.15, 1.3) * Double(line.count))
        let caption = Ease.easeOut(Ease.clip(t, 1.5, 1.9))
        VStack(spacing: 26) {
            HStack(spacing: 2) {
                Text(String(line.prefix(typed)))
                Rectangle().fill(lime).frame(width: 18, height: 56)
                    .opacity(Int(t * 4) % 2 == 0 ? 1 : 0)
            }
            .font(.system(size: 68, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            Text("// every frame of video is this function")
                .font(.system(size: 26, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .opacity(caption)
        }
    }

    // 01 · wordmark slam
    @ViewBuilder @MainActor
    static func wordmarkSlam(_ t: Double) -> some View {
        let p = Ease.easeOut(min(1, t / 0.18))
        let sweep = Ease.easeInOut(Ease.clip(t, 0.5, 1.0))
        let sub = Ease.easeOut(Ease.clip(t, 0.9, 1.4))
        VStack(spacing: 26) {
            Text("swift-render")
                .font(.system(size: 168, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
                .scaleEffect(1.35 - 0.35 * p)
                .blur(radius: (1 - p) * 10)
            Rectangle().fill(lime)
                .frame(width: CGFloat(sweep) * 860, height: 10)
            Text("programmatic motion graphics in pure Swift")
                .font(.system(size: 34, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .opacity(sub)
        }
    }

    // 02 · manifesto, one claim per beat
    @ViewBuilder @MainActor
    static func manifesto(_ t: Double) -> some View {
        let words = ["NO BROWSER.", "NO NODE.", "NO KEYFRAMES.", "JUST SWIFT."]
        let idx = min(3, Int(t / 0.6))
        let p = Ease.easeOut(min(1, (t - Double(idx) * 0.6) / 0.16))
        let bg: Color = idx == 3 ? lime : (idx % 2 == 1 ? .white : .black)
        let fg: Color = idx == 3 ? .black : (idx % 2 == 1 ? .black : .white)
        ZStack {
            bg.ignoresSafeArea()
            Text(words[idx])
                .font(.system(size: 250, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(fg)
                .modifier(JustRenderIt.Slant(height: 250))
                .scaleEffect(1.3 - 0.3 * p)
                .blur(radius: (1 - p) * 8)
        }
    }

    // 03 · the code card — a real scene, seven lines
    @ViewBuilder @MainActor
    static func codeCard(_ t: Double) -> some View {
        let lines: [(String, Color)] = [
            ("struct Hello: RenderScene {", .white.opacity(0.55)),
            ("    static func body(at t: Double) -> some View {", .white.opacity(0.55)),
            ("        Text(\"hello.\")", .white),
            ("            .scaleEffect(Ease.spring(t, from: 0.8, to: 1))", lime),
            ("            .opacity(Ease.clip(t, 0, 0.4))", lime),
            ("    }", .white.opacity(0.55)),
            ("}", .white.opacity(0.55)),
        ]
        let head = Ease.easeOut(Ease.clip(t, 0.0, 0.35))
        VStack(alignment: .leading, spacing: 30) {
            Text("A SCENE IS A PURE FUNCTION OF TIME")
                .font(.system(size: 40, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
                .opacity(head)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(0..<lines.count, id: \.self) { i in
                    let p = stagger(t, i, step: 0.09, ramp: 0.35, start: 0.25)
                    Text(lines[i].0)
                        .font(.system(size: 34, weight: .medium, design: .monospaced))
                        .foregroundStyle(lines[i].1)
                        .offset(x: CGFloat(1 - p) * -70)
                        .opacity(p)
                }
            }
            .padding(44)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(white: 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12), lineWidth: 1))
        }
    }

    // 04 · real Metal, full bleed
    @ViewBuilder @MainActor
    static func metalMoment(_ t: Double) -> some View {
        let title = Ease.easeOut(min(1, t / 0.25))
        let sub = Ease.easeOut(Ease.clip(t, 0.6, 1.0))
        ZStack {
            Rectangle().fill(.black)
                .colorEffect(ShaderLibrary.bundle(.module).galaxy(
                    .float2(1920, 1080), .float(Float(t) * 0.8 + 2)))
                .ignoresSafeArea()
            VStack(spacing: 20) {
                Text("REAL METAL.")
                    .font(.system(size: 220, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
                    .modifier(JustRenderIt.Slant(height: 220))
                    .scaleEffect(1.25 - 0.25 * title)
                    .blur(radius: (1 - title) * 8)
                Text("23 SHADERS BUILT IN · THIS ONE IS LIVE")
                    .font(.system(size: 32, weight: .black)).fontWidth(.condensed)
                    .tracking(6)
                    .foregroundStyle(lime)
                    .shadow(color: .black.opacity(0.8), radius: 10)
                    .opacity(sub)
            }
        }
    }

    // 05 · springs — solved, not simulated
    @ViewBuilder @MainActor
    static func springs(_ t: Double) -> some View {
        let word = Array("SPRINGS")
        let cap = Ease.easeOut(Ease.clip(t, 1.1, 1.5))
        VStack(spacing: 44) {
            HStack(spacing: 10) {
                ForEach(0..<word.count, id: \.self) { i in
                    let drop = Ease.spring(max(0, t - 0.1 - Double(i) * 0.08),
                                           from: -850, to: 0,
                                           response: 0.55, dampingFraction: 0.42)
                    Text(String(word[i]))
                        .font(.system(size: 240, weight: .black)).fontWidth(.condensed)
                        .foregroundStyle(.white)
                        .offset(y: CGFloat(drop))
                }
            }
            Text("CLOSED-FORM · SCRUB ANY FRAME · SAME PIXELS")
                .font(.system(size: 32, weight: .black)).fontWidth(.condensed)
                .tracking(6)
                .foregroundStyle(lime)
                .opacity(cap)
        }
    }

    // 06 · the speed claim
    @ViewBuilder @MainActor
    static func speed(_ t: Double) -> some View {
        let cap = Ease.easeOut(Ease.clip(t, 0.9, 1.3))
        VStack(spacing: 36) {
            HStack(spacing: 8) {
                Kinetic.digitRoll(1, t: t, delay: 0.10, size: 260)
                Kinetic.digitRoll(4, t: t, delay: 0.24, size: 260)
                Kinetic.digitRoll(0, t: t, delay: 0.38, size: 260)
                Text("FPS")
                    .font(.system(size: 90, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(lime)
                    .offset(y: 60)
                    .opacity(cap)
            }
            Text("1080p60 RENDER SPEED · ON A MACBOOK")
                .font(.system(size: 32, weight: .black)).fontWidth(.condensed)
                .tracking(6)
                .foregroundStyle(.white.opacity(0.85))
                .opacity(cap)
        }
    }

    // 07 · determinism — two renders, zero drift
    @ViewBuilder @MainActor
    static func determinism(_ t: Double) -> some View {
        let cap = Ease.easeOut(Ease.clip(t, 1.0, 1.4))
        let eq = Ease.easeOutBack(Ease.clip(t, 0.7, 1.0))
        VStack(spacing: 40) {
            HStack(spacing: 46) {
                miniRender(t, label: "RENDER Nº1")
                Text("≡")
                    .font(.system(size: 150, weight: .black))
                    .foregroundStyle(lime)
                    .scaleEffect(CGFloat(eq))
                miniRender(t, label: "RENDER Nº2")
            }
            Text("BYTE-IDENTICAL · EVERY RUN · TESTED IN CI")
                .font(.system(size: 32, weight: .black)).fontWidth(.condensed)
                .tracking(6)
                .foregroundStyle(.white.opacity(0.85))
                .opacity(cap)
        }
    }

    @ViewBuilder @MainActor
    static func miniRender(_ t: Double, label: String) -> some View {
        let bounce = Ease.spring(max(0, t - 0.2), from: -140, to: 0,
                                 response: 0.5, dampingFraction: 0.45)
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.07))
                RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15), lineWidth: 1)
                VStack(spacing: 14) {
                    Circle().fill(lime).frame(width: 54, height: 54)
                        .offset(y: CGFloat(bounce))
                    Text("hello.")
                        .font(.system(size: 40, weight: .black))
                        .foregroundStyle(.white)
                        .opacity(Ease.clip(t, 0.5, 0.9))
                }
            }
            .frame(width: 430, height: 260)
            Text(label)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // 08 · terminal → lockup
    @ViewBuilder @MainActor
    static func outro(_ t: Double) -> some View {
        Timeline(t) {
            Clip(2.2) { l in terminal(l) }
            Clip(3.8) { l in lockup(l) }.transition(.flash())
        }
    }

    @ViewBuilder @MainActor
    static func terminal(_ t: Double) -> some View {
        let cmd = "swift run swift-render render RepoPromo"
        let typed = Int(Ease.clip(t, 0.1, 1.2) * Double(cmd.count))
        let done = Ease.easeOut(Ease.clip(t, 1.45, 1.65))
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Circle().fill(.red.opacity(0.8)).frame(width: 14)
                Circle().fill(.yellow.opacity(0.8)).frame(width: 14)
                Circle().fill(.green.opacity(0.8)).frame(width: 14)
            }
            HStack(spacing: 0) {
                Text("$ ").foregroundStyle(lime)
                Text(String(cmd.prefix(typed))).foregroundStyle(.white)
                Rectangle().fill(.white).frame(width: 14, height: 34)
                    .opacity(Int(t * 4) % 2 == 0 ? 1 : 0)
            }
            .font(.system(size: 30, weight: .medium, design: .monospaced))
            Text("✓ 1512 frames · 60 fps · rendered in 12s")
                .font(.system(size: 30, weight: .medium, design: .monospaced))
                .foregroundStyle(lime)
                .opacity(done)
        }
        .padding(52)
        .frame(width: 1100, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color(white: 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    @ViewBuilder @MainActor
    static func lockup(_ t: Double) -> some View {
        let p = Ease.easeOut(min(1, t / 0.2))
        let sweep = Ease.easeInOut(Ease.clip(t, 0.3, 0.8))
        let sub = Ease.easeOut(Ease.clip(t, 0.8, 1.3))
        VStack(spacing: 30) {
            Text("swift-render")
                .font(.system(size: 160, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
                .scaleEffect(1.2 - 0.2 * p)
            Rectangle().fill(lime)
                .frame(width: CGFloat(sweep) * 820, height: 10)
            VStack(spacing: 14) {
                Text("github.com/skyblanket/swift-render")
                    .font(.system(size: 30, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                Text("MIT · ZERO DEPENDENCIES · MACOS 14+")
                    .font(.system(size: 24, weight: .black)).fontWidth(.condensed)
                    .tracking(6)
                    .foregroundStyle(.white.opacity(0.45))
            }
            .opacity(sub)
        }
    }

    @MainActor
    static func flash(_ t: Double) -> some View {
        let hit = (chapters + [21.4]).map { max(0, 1 - abs(t - $0) / 0.06) }.max() ?? 0
        return Color.white.opacity(hit * 0.8).ignoresSafeArea()
    }
}
