import SwiftUI

/// LaunchFilm2 — the general-audience cut. No jargon on screen; the film
/// explains itself: an AI wrote this video as code, here's why that beats
/// both editing software and pixel-dreaming AI video generators.
///
/// Chapter map (cuts land on the launch.wav hit map):
///   0.0  hook        cinematic 3D drift — "Nobody edited this video."
///   4.2  title       "AN AI WROTE IT." glyphs assemble
///   7.2  explainer   code types on the left, the shot builds on the right
///  16.8  old way     keyframe-editor pain
///  20.0  ai slop     melting text, the famous tell
///  23.2  exact       whip to crisp, snapped grid
///  26.4  3D flash    tunnel + cards
///  29.6  hears music waveform of THIS track, cut markers, live playhead
///  32.8  any style   same shot re-skinned 4x
///  36.0  one line    quiet: change .red → .blue, whole scene sweeps
///  42.4  speed       render bar races the riser
///  46.0  slams       FREE / OPEN / YOURS
///  47.8  lockup      swift-render — video is code now.
///  51.4  outro       URL + blinking cursor
public struct LaunchFilm2: AudioReactiveScene {
    public static let defaultDuration: Double = 57.5
    public static var ownsPostFX: Bool { true }

    static let boundaries: [Double] = [4.2, 7.2, 16.8, 20.0, 23.2, 26.4,
                                       29.6, 32.8, 36.0, 42.4, 46.0, 47.8, 51.4]

    @MainActor
    public static func body(at t: Double, duration: Double, audio: AudioTrack) -> some View {
        let pumpGate = 1 - Ease.clip(t, 45.4, 46.0)
        let bass = audio.band(.bass, at: t) * pumpGate
        let fade = Ease.easeIn(Ease.clip(t, duration - 1.0, duration))
        let hits = [3.4] + boundaries + [46.6, 47.2]
        var jolt = JustRenderIt.shake(t, impacts: hits, amp: 12)
        let big = JustRenderIt.shake(t, impacts: [47.8], amp: 28)
        jolt = CGSize(width: jolt.width + big.width, height: jolt.height + big.height)

        return ZStack {
            Color.black.ignoresSafeArea()
            Timeline(t) {
                Clip(4.2) { l in hook(l) }
                Clip(3.0) { l in title(l) }
                Clip(9.6) { l in explainer(l) }
                Clip(3.2) { l in oldWay(l) }
                Clip(3.2) { l in aiSlop(l) }
                Clip(3.2) { l in exact(l) }
                Clip(3.2) { l in flash3D(l) }
                Clip(3.2) { l in hearsMusic(l, audio: audio, base: 29.6, total: duration) }
                Clip(3.2) { l in anyStyle(l) }
                Clip(6.4) { l in oneLine(l) }
                Clip(3.6) { l in speed(l) }
                Clip(1.8) { l in slams(l) }
                Clip(3.6) { l in lockup(l) }
                Clip(6.1) { l in outro(l) }
            }
            .scaleEffect(1 + 0.016 * CGFloat(bass))
            .offset(jolt)
            flashOverlay(t)
        }
        .opacity(1 - fade)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PostFX(time: t, grainAmount: 0.10, vignetteAmount: 0.42))
    }

    // MARK: 1 · hook — looks like a film, not a demo

    @ViewBuilder @MainActor
    static func hook(_ t: Double) -> some View {
        let textP = Ease.easeOut(Ease.clip(t, 1.0, 1.8))
        ZStack {
            Rectangle().fill(.black)
                .colorEffect(ShaderLibrary.bundle(.module).monoTunnel(
                    .float2(1920, 1080), .float(Float(t * 0.25 + 8.0))))
                .opacity(0.5)
                .ignoresSafeArea()
            LaunchFilm.starfield(t * 0.5, intensity: 0.5)
            Text("Nobody edited this video.")
                .font(.system(size: 76, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(textP)
                .blur(radius: (1 - textP) * 6)
                .shadow(color: .black.opacity(0.8), radius: 18)
        }
    }

    // MARK: 2 · title — glyphs assemble

    @ViewBuilder @MainActor
    static func title(_ t: Double) -> some View {
        VStack(spacing: 22) {
            assembledText("AN AI WROTE IT.", size: 160, t: t, start: 0.0)
            Text("as code — not as guessed pixels")
                .font(.system(size: 30, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .opacity(Ease.easeOut(Ease.clip(t, 0.7, 1.2)))
        }
    }

    /// Letters fly in from scattered offsets — type literally becoming the frame.
    @MainActor
    static func assembledText(_ s: String, size: CGFloat, t: Double, start: Double) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(s.enumerated()), id: \.offset) { i, ch in
                let h1 = LaunchFilm.hash01(Double(i) * 12.9898)
                let h2 = LaunchFilm.hash01(Double(i) * 78.233 + 4)
                let p = Ease.easeOut(Ease.clip(t, start + Double(i) * 0.018, start + 0.32 + Double(i) * 0.018))
                Text(String(ch))
                    .font(.system(size: size, weight: .black))
                    .fontWidth(.condensed)
                    .foregroundStyle(.white)
                    .opacity(p)
                    .blur(radius: (1 - p) * 8)
                    .offset(x: CGFloat(1 - p) * CGFloat(h1 * 2 - 1) * 500,
                            y: CGFloat(1 - p) * CGFloat(h2 * 2 - 1) * 320)
            }
        }
    }

    // MARK: 3 · explainer — code on the left builds the shot on the right

    static let demoCode: [(String, Double)] = [   // (line, time it lands)
        ("Circle()", 1.2),
        ("  .fill(.cyan)", 2.4),
        ("  .bounce(t)", 3.8),
        ("Text(\"hello.\")", 5.4),
        ("  .fadeIn(t)", 6.6),
        ("background(.stars)", 7.9),
    ]

    @ViewBuilder @MainActor
    static func explainer(_ t: Double) -> some View {
        let headP = Ease.easeOut(Ease.clip(t, 0.1, 0.6))
        VStack(spacing: 40) {
            Text("Every frame is a line of code")
                .font(.system(size: 64, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
                .opacity(headP)
            HStack(spacing: 50) {
                codePanel(t)
                demoPanel(t)
            }
        }
    }

    @MainActor
    static func codePanel(_ t: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<demoCode.count, id: \.self) { i in
                let (line, at) = demoCode[i]
                let typed = Int(Ease.clip(t, at - 1.0, at) * Double(line.count))
                let active = t >= at - 1.0 && t < at + 0.5
                Text(String(line.prefix(typed)) + (active ? "▌" : ""))
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                    .foregroundStyle(active ? Color.white : .white.opacity(0.55))
                    .frame(height: 36, alignment: .leading)
            }
        }
        .padding(36)
        .frame(width: 640, height: 420, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.2)))
    }

    @MainActor
    static func demoPanel(_ t: Double) -> some View {
        let circleIn = Ease.easeOut(Ease.clip(t, 1.2, 1.6))
        let cyanIn = Ease.clip(t, 2.4, 2.6)
        let bounce = t >= 3.8 ? Ease.spring(max(0, (t - 3.8).truncatingRemainder(dividingBy: 1.6)), from: -120, to: 0, response: 0.55, dampingFraction: 0.5) : 0
        let helloIn = Ease.easeOut(Ease.clip(t, 5.4, 5.9))
        let starsIn = Ease.clip(t, 7.9, 8.3)
        return ZStack {
            RoundedRectangle(cornerRadius: 18).fill(.black)
            LaunchFilm.starfield(t * 0.4, intensity: 0.6 * starsIn)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            VStack(spacing: 30) {
                Circle()
                    .fill(cyanIn > 0 ? Color.cyan : Color.white)
                    .frame(width: 110, height: 110)
                    .offset(y: CGFloat(bounce))
                    .opacity(circleIn)
                Text("hello.")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(helloIn)
            }
        }
        .frame(width: 640, height: 420)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.2)))
    }

    // MARK: 4 · the old way — keyframe purgatory

    @ViewBuilder @MainActor
    static func oldWay(_ t: Double) -> some View {
        let inP = Ease.easeOut(min(1, t / 0.4))
        VStack(spacing: 44) {
            Text("The old way: hours of keyframes")
                .font(.system(size: 64, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white.opacity(0.85))
            VStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { track in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.07))
                            .frame(width: 1300, height: 44)
                        HStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { k in
                                let h = LaunchFilm.hash01(Double(track * 31 + k) * 7.13)
                                Rectangle().fill(.white.opacity(0.5))
                                    .frame(width: 9, height: 9)
                                    .rotationEffect(.degrees(45))
                                    .offset(x: CGFloat(h) * 1250)
                                    .opacity(h > 0.35 ? 1 : 0)
                            }
                        }
                    }
                }
            }
            .overlay(
                Rectangle().fill(.red.opacity(0.8)).frame(width: 2, height: 290)
                    .offset(x: -650 + CGFloat(Ease.clip(t, 0, 3.2)) * 240)   // playhead crawls
            )
            Text("…and one change means doing it all again")
                .font(.system(size: 26, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .opacity(Ease.easeOut(Ease.clip(t, 1.6, 2.1)))
        }
        .opacity(inP)
        .grayscale(1)
    }

    // MARK: 5 · ai slop — the famous melting-text tell

    @ViewBuilder @MainActor
    static func aiSlop(_ t: Double) -> some View {
        ZStack {
            Rectangle().fill(.black)
                .colorEffect(ShaderLibrary.bundle(.module).inkFlow(
                    .float2(1920, 1080), .float(Float(t * 1.4 + 9))))
                .opacity(0.45)
                .ignoresSafeArea()
            VStack(spacing: 36) {
                Text("AI video: pretty… until it melts")
                    .font(.system(size: 64, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
                garbledText("LAUNCH DAY", t: t)
                Text("garbled text · morphing logos · six fingers")
                    .font(.system(size: 26, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .opacity(Ease.easeOut(Ease.clip(t, 1.4, 1.9)))
            }
        }
    }

    /// What every AI-video text overlay actually looks like.
    @MainActor
    static func garbledText(_ s: String, t: Double) -> some View {
        let pool = Array("ΛΔЯ#&ØΞ¥ /\\N0WΓ")
        let step = floor(t * 6)   // re-garble at 6 Hz
        return HStack(spacing: 6) {
            ForEach(Array(s.enumerated()), id: \.offset) { i, ch in
                let h = LaunchFilm.hash01(Double(i) * 17.77 + step * 3.1)
                let garbled = h > 0.45 && ch != " "
                let shown = garbled ? pool[Int(h * 1000) % pool.count] : ch
                Text(String(shown))
                    .font(.system(size: 120, weight: .black))
                    .fontWidth(.condensed)
                    .foregroundStyle(.white.opacity(0.9))
                    .offset(y: CGFloat(LaunchFilm.hash01(Double(i) * 3.3 + step) * 2 - 1) * 14)
                    .rotationEffect(.degrees((LaunchFilm.hash01(Double(i) + step * 1.7) * 2 - 1) * 7))
                    .blur(radius: garbled ? 1.8 : 0.6)
                    .scaleEffect(y: 1 + CGFloat(LaunchFilm.hash01(Double(i) * 5.5 + step) * 0.35))
            }
        }
    }

    // MARK: 6 · exact — whip to crisp

    @ViewBuilder @MainActor
    static func exact(_ t: Double) -> some View {
        VStack(spacing: 40) {
            Text("Code is exact. Every pixel.")
                .font(.system(size: 64, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
            HStack(spacing: 14) {
                ForEach(0..<8, id: \.self) { i in
                    let p = Ease.easeOutBack(Ease.clip(t, 0.15 + Double(i) * 0.05, 0.5 + Double(i) * 0.05))
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white, lineWidth: 3)
                        .frame(width: 130, height: 130)
                        .overlay(Text("\(i + 1)").font(.system(size: 44, weight: .black)).foregroundStyle(.white))
                        .scaleEffect(CGFloat(0.4 + 0.6 * p))
                        .opacity(p)
                }
            }
            Text("LAUNCH DAY")
                .font(.system(size: 120, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
                .opacity(Ease.easeOut(Ease.clip(t, 0.9, 1.3)))
            Text("same input → the same video. every single time.")
                .font(.system(size: 26, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .opacity(Ease.easeOut(Ease.clip(t, 1.5, 2.0)))
        }
    }

    // MARK: 7 · 3D flash

    @ViewBuilder @MainActor
    static func flash3D(_ t: Double) -> some View {
        ZStack {
            Rectangle().fill(.black)
                .colorEffect(ShaderLibrary.bundle(.module).monoTunnel(
                    .float2(1920, 1080), .float(Float(t + 3))))
                .opacity(0.85).ignoresSafeArea()
            LaunchFilm.starfield(t, intensity: 0.8)
            HStack(spacing: -40) {
                ForEach(0..<3, id: \.self) { i in
                    LaunchFilm.card3D(["REAL", "3D", "DEPTH"][i], angle: t * 46 + Double(i - 1) * 28, depth: i)
                }
            }
            VStack { Spacer()
                Text("Real 3D — drawn by your Mac, not dreamed")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 12)
                    .padding(.bottom, 90)
            }
        }
    }

    // MARK: 8 · it hears the music — self-referential waveform

    @ViewBuilder @MainActor
    static func hearsMusic(_ t: Double, audio: AudioTrack, base: Double, total: Double) -> some View {
        let g = base + t
        let bass = audio.band(.bass, at: g)
        VStack(spacing: 44) {
            Text("It hears the music")
                .font(.system(size: 64, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
                .scaleEffect(1 + 0.05 * CGFloat(bass))
            ZStack(alignment: .leading) {
                // the actual envelope of the track you are hearing
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<160, id: \.self) { i in
                        let ts = Double(i) / 160.0 * total
                        let v = audio.level(at: ts)
                        Capsule()
                            .fill(ts <= g ? Color.white : Color.white.opacity(0.25))
                            .frame(width: 5, height: 14 + 170 * v)
                    }
                }
                // cut markers — the hits you've been feeling
                ForEach(0..<boundaries.count, id: \.self) { i in
                    Rectangle().fill(.white.opacity(0.8))
                        .frame(width: 2, height: 220)
                        .offset(x: CGFloat(boundaries[i] / total) * 1276)
                }
                Rectangle().fill(.white).frame(width: 3, height: 240)
                    .offset(x: CGFloat(g / total) * 1276)
            }
            .frame(width: 1280, height: 240)
            Text("this is THIS soundtrack — every cut lands on a hit, automatically")
                .font(.system(size: 26, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .opacity(Ease.easeOut(Ease.clip(t, 1.2, 1.7)))
        }
    }

    // MARK: 9 · any style, same code

    @ViewBuilder @MainActor
    static func anyStyle(_ t: Double) -> some View {
        let styleIdx = min(3, Int(t / 0.8))
        let local = t - Double(styleIdx) * 0.8
        let bounce = Ease.spring(local, from: -90, to: 0, response: 0.5, dampingFraction: 0.55)
        let styles: [(bg: Color, fg: Color, accent: Color, name: String)] = [
            (.black, .white, .cyan, "NEON"),
            (Color(red: 0.96, green: 0.95, blue: 0.91), .black, Color(red: 0.85, green: 0.3, blue: 0.12), "PRINT"),
            (Color(red: 0.05, green: 0.15, blue: 0.45), .white, Color(red: 0.45, green: 0.75, blue: 1.0), "BLUEPRINT"),
            (Color(red: 0.07, green: 0.05, blue: 0.05), Color(red: 1.0, green: 0.78, blue: 0.3), Color(red: 0.85, green: 0.3, blue: 0.12), "GOLD"),
        ]
        let s = styles[styleIdx]
        ZStack {
            s.bg.ignoresSafeArea()
            VStack(spacing: 36) {
                Text("Any style. Same code.")
                    .font(.system(size: 64, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(s.fg)
                HStack(spacing: 28) {
                    Circle().fill(s.accent).frame(width: 90, height: 90)
                        .offset(y: CGFloat(bounce))
                    Text(s.name)
                        .font(.system(size: 110, weight: .black)).fontWidth(.condensed)
                        .foregroundStyle(s.fg)
                }
                Text("one scene · four skins · zero re-rolls")
                    .font(.system(size: 26, design: .monospaced))
                    .foregroundStyle(s.fg.opacity(0.6))
            }
        }
    }

    // MARK: 10 · change one line (the quiet magic)

    @ViewBuilder @MainActor
    static func oneLine(_ t: Double) -> some View {
        // "red" erases at 1.5–2.1, "blue" types 2.3–2.9, the wave sweeps at 3.4
        let erase = Ease.clip(t, 1.5, 2.1)
        let typeB = Ease.clip(t, 2.3, 2.9)
        let sweep = Ease.easeInOut(Ease.clip(t, 3.4, 4.4))
        let redCount = Int((1 - erase) * 3)
        let blueCount = Int(typeB * 4)
        let word = String("red".prefix(redCount)) + String("blue".prefix(blueCount))
        let accent = Color(red: 1 - 0.8 * sweep, green: 0.25, blue: 0.25 + 0.75 * sweep)
        ZStack {
            ForEach(0..<14, id: \.self) { i in
                let a = Double(i) / 14 * 2 * .pi
                Circle().fill(accent.opacity(0.5))
                    .frame(width: 18, height: 18)
                    .offset(x: cos(a + t * 0.4) * 430, y: sin(a + t * 0.4) * 280)
            }
            VStack(spacing: 50) {
                Text("Change one line…")
                    .font(.system(size: 60, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
                    .opacity(Ease.easeOut(Ease.clip(t, 0.2, 0.7)))
                HStack(spacing: 0) {
                    Text("accent = .")
                        .foregroundStyle(.white.opacity(0.7))
                    Text(word)
                        .foregroundStyle(accent)
                    Rectangle().fill(.white).frame(width: 4, height: 52)
                        .opacity(t > 1.2 && t < 3.2 && Int(t * 4) % 2 == 0 ? 1 : 0)
                }
                .font(.system(size: 54, weight: .bold, design: .monospaced))
                Text("…and the whole video changes with it")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(accent)
                    .opacity(Ease.easeOut(Ease.clip(t, 4.6, 5.2)))
            }
        }
    }

    // MARK: 11 · speed

    @ViewBuilder @MainActor
    static func speed(_ t: Double) -> some View {
        let p = Ease.easeInOut(Ease.clip(t, 0.2, 3.0))
        let frames = Int(p * 3450)
        VStack(spacing: 44) {
            Text("This film rendered in 26 seconds")
                .font(.system(size: 64, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12)).frame(width: 1200, height: 30)
                Capsule().fill(.white).frame(width: max(10, CGFloat(p) * 1200), height: 30)
            }
            HStack(spacing: 60) {
                Text("frame \(frames) / 3450").monospacedDigit()
                Text("on a MacBook — no render farm")
            }
            .font(.system(size: 27, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: 12–14 · slams, lockup, outro

    @ViewBuilder @MainActor
    static func slams(_ t: Double) -> some View {
        let words = ["FREE.", "OPEN.", "YOURS."]
        let idx = min(2, Int(t / 0.6))
        let p = Ease.easeOut(min(1, (t - Double(idx) * 0.6) / 0.18))
        let inverted = idx == 1
        ZStack {
            (inverted ? Color.white : Color.black).ignoresSafeArea()
            Text(words[idx])
                .font(.system(size: 300, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(inverted ? .black : .white)
                .modifier(JustRenderIt.Slant(height: 300))
                .scaleEffect(1.35 - 0.35 * p)
                .blur(radius: (1 - p) * 10)
        }
    }

    @ViewBuilder @MainActor
    static func lockup(_ t: Double) -> some View {
        VStack(spacing: 30) {
            assembledText("SWIFT-RENDER", size: 150, t: t, start: 0.05)
            Rectangle().fill(.white)
                .frame(width: CGFloat(Ease.easeInOut(Ease.clip(t, 0.5, 0.95))) * 900, height: 8)
                .rotationEffect(.degrees(-2.5))
            Text("video is code now.")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .opacity(Ease.easeOut(Ease.clip(t, 0.9, 1.4)))
        }
    }

    @ViewBuilder @MainActor
    static func outro(_ t: Double) -> some View {
        let p = Ease.easeOut(min(1, t / 0.5))
        let cta = Ease.easeOut(Ease.clip(t, 0.9, 1.4))
        VStack(spacing: 30) {
            HStack(spacing: 2) {
                Text("github.com/skyblanket/swift-render")
                    .font(.system(size: 44, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Rectangle().fill(.white).frame(width: 18, height: 44)
                    .opacity(Int(t * 3) % 2 == 0 ? 1 : 0)
            }
            Text("free forever · open source · works with any AI that writes code")
                .font(.system(size: 26, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
                .opacity(cta)
        }
        .opacity(p)
    }

    // MARK: shared

    @MainActor
    static func flashOverlay(_ t: Double) -> some View {
        let hit = boundaries.map { max(0, 1 - abs(t - $0) / 0.07) }.max() ?? 0
        return Color.white.opacity(hit * 0.85).ignoresSafeArea()
    }
}
