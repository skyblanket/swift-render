import SwiftUI
import SwiftRender

/// Sizzle — a 15-second, beat-synced showcase of swift-render itself.
///
///   swift run swift-render render Sizzle --out out/sizzle.mp4
///
/// Eight bars at 128 BPM (1.875s each). Every cut sits on the beat grid and
/// the soundtrack is declared below from the SAME `chapters` array that drives
/// the Timeline, so the crashes land on the cuts by construction. The scene is
/// audio-reactive to its own synthesized score — `audio.band(.bass, at: t)` is
/// reading the kicks this file wrote.
///
///   bar 0   0.00  hook — typewriter: "every frame is a pure function of t."
///   bar 1   1.88  four word-slams, one per beat (WRITE / A VIEW. / RENDER / AN MP4.)
///   bar 2   3.75  22 SHADERS — 2x2 live Metal gallery, one tile per beat
///   bar 3   5.63  ANALYTIC SPRINGS — code card + four easings race
///   bar 4   7.50  3D — rotation3DEffect cards over the `monoTunnel` shader
///   bar 5   9.38  IT HEARS ITS OWN BEAT — FFT bars + bass ring
///   bar 6  11.25  900 frames in 7s — this reel's own render, odometer under a swell
///   bar 7  13.13  lockup + URL, fade to black
public struct Sizzle: AudioReactiveScene {
    public static let defaultDuration: Double = 15.0
    public static var ownsPostFX: Bool { true }

    static let volt = Color(red: 0.78, green: 1.0, blue: 0.10)
    static let bpm: Double = 128
    static let beat: Double = 60.0 / bpm                       // 0.46875s
    static let bar: Double = beat * 4                          // 1.875s — one chapter
    static let chapters: [Double] = (0...8).map { bar * Double($0) }   // 0 … 15.0

    // MARK: - Soundtrack — same constants as the Timeline, so nothing can drift.

    public static func soundtrack(duration: Double) -> Score? {
        Score(duration: duration) {
            // bar 0: ticking hats under the typewriter
            every(beat, from: 0, to: chapters[1]) { hat(at: $0, amp: 0.13) }
            every(beat, from: beat / 2, to: chapters[1]) { hat(at: $0, amp: 0.06, pan: 0.5) }

            // bars 1–6: the groove
            boom(at: chapters[1], amp: 0.9, duration: 1.6)
            fourOnFloor(from: chapters[1], to: chapters[7], bpm: bpm)
            hatSixteenths(from: chapters[1], to: chapters[7], bpm: bpm)
            bassline([.a1, .a1, .c2, .g1], from: chapters[1], to: chapters[7], bpm: bpm)
            crashes(at: Array(chapters[1...6]))

            // bar 6 → 7: a chord swell + kick fill into the lockup
            swell(.minor7(.a3), into: chapters[7], duration: bar, amp: 0.05)
            kicks(at: [chapters[7] - beat * 0.75, chapters[7] - beat * 0.5, chapters[7] - beat * 0.25], amp: 0.8)

            // bar 7: the 808 hit and a drone to fade on
            boom(at: chapters[7])
            crash(at: chapters[7], amp: 0.36)
            drone(.a1, from: chapters[7], for: bar, amp: 0.14)
        }
    }

    // MARK: - Body

    @MainActor
    public static func body(at t: Double, duration: Double, audio: AudioTrack) -> some View {
        let bass = audio.band(.bass, at: t)
        let fade = Ease.easeIn(Ease.clip(t, duration - 0.7, duration))

        let beatCuts = (1..<4).map { chapters[1] + beat * Double($0) }
        var jolt = JustRenderIt.shake(t, impacts: Array(chapters[1...7]), amp: 12)
        let small = JustRenderIt.shake(t, impacts: beatCuts, amp: 7)
        let big = JustRenderIt.shake(t, impacts: [chapters[7]], amp: 28)
        jolt.width += big.width + small.width
        jolt.height += big.height + small.height

        return ZStack {
            Color(red: 0.02, green: 0.02, blue: 0.025).ignoresSafeArea()
            Timeline(t) {
                Clip(bar) { l in hook(l) }
                Clip(bar) { l in slams(l) }
                Clip(bar) { l in gallery(l, bass: bass) }
                Clip(bar) { l in springs(l) }
                Clip(bar) { l in threeD(l) }
                Clip(bar) { l in reactive(l, audio: audio, global: t) }
                Clip(bar) { l in speed(l) }
                Clip(bar) { l in lockup(l) }
            }
            .offset(jolt)
            flash(t, extra: beatCuts)
            progress(t, total: duration)
        }
        .opacity(1 - fade)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PostFX(time: t, grainAmount: 0.07 * (1 - fade), vignetteAmount: 0.38))
    }

    // MARK: shared bits

    @ViewBuilder @MainActor
    static func shaderFill(_ name: String, _ t: Double, size: CGSize) -> some View {
        let lib = ShaderLibrary.swiftRender
        let sz = Shader.Argument.float2(Float(size.width), Float(size.height))
        let tt = Shader.Argument.float(Float(t))
        switch name {
        case "plasmaField":   Rectangle().fill(.black).colorEffect(lib.plasmaField(sz, tt, .float(1.6)))
        case "galaxy":        Rectangle().fill(.black).colorEffect(lib.galaxy(sz, tt))
        case "liquidMetal":   Rectangle().fill(.black).colorEffect(lib.liquidMetal(sz, tt))
        case "kaleidoscope":  Rectangle().fill(.black).colorEffect(lib.kaleidoscope(sz, tt, .float(7)))
        default:              Rectangle().fill(.black)
        }
    }

    @ViewBuilder @MainActor
    static func chip(_ text: String, dark: Bool = true) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .semibold, design: .monospaced))
            .foregroundStyle(dark ? Color.black : Color.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(dark ? volt : Color.white.opacity(0.14)))
    }

    // MARK: bar 0 · hook

    @ViewBuilder @MainActor
    static func hook(_ t: Double) -> some View {
        let line = "every frame is a pure function of t."
        let typed = Int(Ease.clip(t, 0.1, 1.25) * Double(line.count))
        let cursorOn = Int(t * 6) % 2 == 0
        let lift = Ease.easeIn(Ease.clip(t, 1.45, bar))
        ZStack {
            shaderFill("plasmaField", t * 0.4, size: CGSize(width: 1920, height: 1080))
                .opacity(0.10).ignoresSafeArea()
            HStack(spacing: 0) {
                Text(String(line.prefix(typed)))
                Text("\u{258C}").foregroundStyle(volt).opacity(cursorOn ? 1 : 0)
            }
            .font(.system(size: 64, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.95))
            .scaleEffect(1 + 0.35 * lift)
            .opacity(1 - lift)
            .blur(radius: lift * 12)
        }
    }

    // MARK: bar 1 · one word per beat

    @ViewBuilder @MainActor
    static func slams(_ t: Double) -> some View {
        let words = ["WRITE", "A VIEW.", "RENDER", "AN MP4."]
        let k = min(3, Int(t / beat))
        let lt = t - Double(k) * beat
        let pop = Ease.spring(lt, from: 1.55, to: 1.0, response: 0.28, dampingFraction: 0.6)
        let palette: [(Color, Color)] = [
            (.white, .black), (Color(red: 0.02, green: 0.02, blue: 0.025), .white),
            (volt, .black), (Color(red: 0.02, green: 0.02, blue: 0.025), volt),
        ]
        ZStack {
            palette[k].0.ignoresSafeArea()
            Text(words[k])
                .font(.system(size: 430, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(palette[k].1)
                .scaleEffect(pop)
            VStack {
                HStack {
                    Text("0\(k + 1) / 04")
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .foregroundStyle(palette[k].1.opacity(0.7))
                    Spacer()
                }
                Spacer()
            }
            .padding(70)
        }
    }

    // MARK: bar 2 · shader gallery

    @ViewBuilder @MainActor
    static func gallery(_ t: Double, bass: Double) -> some View {
        let names = ["plasmaField", "galaxy", "liquidMetal", "kaleidoscope"]
        let head = Ease.easeOut(Ease.clip(t, 0, 0.3))
        let tile = CGSize(width: 880, height: 330)
        VStack(alignment: .leading, spacing: 34) {
            HStack(alignment: .firstTextBaseline, spacing: 30) {
                Text("22 SHADERS.")
                    .font(.system(size: 150, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
                Text(".colorEffect · compiled by a SwiftPM plugin")
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .foregroundStyle(volt)
            }
            .opacity(head).offset(x: (1 - head) * -50)
            VStack(spacing: 22) {
                ForEach(0..<2, id: \.self) { r in
                    HStack(spacing: 22) {
                        ForEach(0..<2, id: \.self) { c in
                            let i: Int = r * 2 + c
                            let delay: Double = Double(i) * beat * 0.5
                            let p: Double = Ease.spring(max(0, t - delay),
                                                        from: 0, to: 1, response: 0.38, dampingFraction: 0.72)
                            let shaderT: Double = t + Double(i) * 3
                            ZStack(alignment: .topLeading) {
                                shaderFill(names[i], shaderT, size: tile)
                                    .frame(width: tile.width, height: tile.height)
                                chip(names[i]).padding(18)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 30))
                            .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.18), lineWidth: 2))
                            .scaleEffect(tileScale(p, bass))
                            .opacity(min(1.0, p * 1.6))
                        }
                    }
                }
            }
        }
    }

    static func tileScale(_ p: Double, _ bass: Double) -> CGFloat {
        CGFloat((0.82 + 0.18 * p) * (1 + 0.012 * bass))
    }

    // MARK: bar 3 · springs

    @ViewBuilder @MainActor
    static func springs(_ t: Double) -> some View {
        let curves: [(String, (Double) -> Double)] = [
            ("spring",       { Ease.spring($0, from: 0, to: 1, response: 0.45, dampingFraction: 0.55) }),
            ("easeOutBack",  { Ease.easeOutBack(Ease.clip($0, 0, 0.8)) }),
            ("bounce",       { Ease.bounce(Ease.clip($0, 0, 1.0)) }),
            ("elastic",      { Ease.elastic(Ease.clip($0, 0, 1.1)) }),
        ]
        let head = Ease.easeOut(Ease.clip(t, 0, 0.3))
        let card = Ease.easeOut(Ease.clip(t, 0.05, 0.4))
        VStack(alignment: .leading, spacing: 44) {
            VStack(alignment: .leading, spacing: 8) {
                Text("ANALYTIC SPRINGS")
                    .font(.system(size: 130, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
                Text("closed-form \u{00B7} scrub-safe \u{00B7} byte-identical")
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                    .foregroundStyle(volt)
            }
            .opacity(head).offset(x: (1 - head) * -50)
            HStack(alignment: .top, spacing: 36) {
                Text("Ease.spring(t,\n  from: 0, to: 1,\n  response: 0.45,\n  dampingFraction: 0.55)")
                    .font(.system(size: 26, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(32)
                    .frame(width: 520, height: 330, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 28).fill(.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.18), lineWidth: 2))
                    .opacity(card).offset(y: (1 - card) * 24)
                VStack(spacing: 30) {
                    ForEach(0..<curves.count, id: \.self) { i in
                        let v = curves[i].1(max(0, t - 0.2 - Double(i) * 0.1))
                        VStack(alignment: .leading, spacing: 10) {
                            Text(curves[i].0)
                                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                                .foregroundStyle(i == 0 ? volt : .white.opacity(0.65))
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.12)).frame(width: 1000, height: 8)
                                Capsule().fill(i == 0 ? volt : .white).frame(width: max(8, v * 1000), height: 8)
                                Circle().fill(i == 0 ? volt : .white)
                                    .frame(width: 34, height: 34)
                                    .offset(x: v * 1000 - 17)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 140)
    }

    // MARK: bar 4 · 3D

    @ViewBuilder @MainActor
    static func threeD(_ t: Double) -> some View {
        let inP = Ease.easeOut(Ease.clip(t, 0, 0.4))
        let labels = ["t", "\u{2192}", "View", "\u{2192}", "MP4"]
        ZStack {
            Rectangle().fill(.black)
                .colorEffect(ShaderLibrary.swiftRender.monoTunnel(
                    .float2(1920, 1080), .float(Float(t + 1.0))))
                .opacity(0.55 * inP)
                .ignoresSafeArea()
            HStack(spacing: -10) {
                ForEach(0..<5, id: \.self) { i in
                    let p = Ease.spring(max(0, t - 0.1 - Double(i) * 0.08),
                                        from: 0, to: 1, response: 0.55, dampingFraction: 0.7)
                    let angle = (1 - p) * 95 + sin(t * 1.6 + Double(i)) * 8 * p
                    let hot = i == 4
                    RoundedRectangle(cornerRadius: 30)
                        .fill(hot ? volt : Color.white.opacity(0.10))
                        .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.55), lineWidth: 2))
                        .overlay(
                            Text(labels[i])
                                .font(.system(size: 110, weight: .black)).fontWidth(.condensed)
                                .foregroundStyle(hot ? Color.black : .white)
                        )
                        .frame(width: 290, height: 420)
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
                        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                        .opacity(p)
                }
            }
            .rotation3DEffect(.degrees(8), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
            .offset(y: -50)
            VStack {
                Spacer()
                Text("REAL 3D. NO BROWSER.")
                    .font(.system(size: 96, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
                    .opacity(Ease.easeOut(Ease.clip(t, 0.6, 1.0)))
                    .padding(.bottom, 90)
            }
        }
    }

    // MARK: bar 5 · audio-reactive (reads the scene's own synthesized score)

    @ViewBuilder @MainActor
    static func reactive(_ l: Double, audio: AudioTrack, global t: Double) -> some View {
        let bass = audio.band(.bass, at: t)
        let high = audio.band(.high, at: t)
        let inP = Ease.easeOut(Ease.clip(l, 0, 0.3))
        let text = Ease.easeOut(Ease.clip(l, 0.15, 0.55))
        ZStack {
            Circle()
                .stroke(volt.opacity(0.25 + 0.5 * bass), lineWidth: 3 + 10 * bass)
                .frame(width: 560 + 260 * bass, height: 560 + 260 * bass)
                .blur(radius: 2 + 8 * bass)
                .offset(y: 170)
                .opacity(inP)
            HStack(alignment: .center, spacing: 14) {
                ForEach(0..<32, id: \.self) { i in
                    let phase = Double(abs(i - 16)) * 0.035
                    let v = audio.level(at: max(0, t - phase))
                    Capsule().fill(i % 4 == 0 ? volt : .white)
                        .frame(width: 30, height: 30 + 400 * v)
                }
            }
            .offset(y: 170)
            .opacity(0.95 * inP)
            VStack(spacing: 14) {
                Text("IT HEARS ITS OWN BEAT.")
                    .font(.system(size: 150, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
                    .scaleEffect(1 + 0.04 * high)
                Text("audio.band(.bass, at: t)   // FFT once, pure lookup forever")
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                    .foregroundStyle(volt)
            }
            .offset(y: -300)
            .opacity(text)
        }
    }

    // MARK: bar 6 · speed (this reel's own render: 900 frames, ~7s)

    @ViewBuilder @MainActor
    static func speed(_ t: Double) -> some View {
        let p = Ease.easeOut(Ease.clip(t, 0.05, 1.3))
        let frames = Int(p * 900)
        let secs = p * 7.1
        let swell = 1 + 0.05 * Ease.clip(t, 0, bar)
        let foot = Ease.easeOut(Ease.clip(t, 0.8, 1.2))
        ZStack {
            Rectangle().fill(.black)
                .colorEffect(ShaderLibrary.swiftRender.neonGrid(
                    .float2(1920, 1080), .float(Float(t * 0.7 + 2.0))))
                .opacity(0.45)
                .ignoresSafeArea()
            HStack(alignment: .firstTextBaseline, spacing: 70) {
                stat(frames.formatted(), "FRAMES")
                Text("in")
                    .font(.system(size: 90, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
                stat(String(format: "%.1fs", secs), "TO RENDER THIS REEL")
            }
            .scaleEffect(swell)
            VStack {
                Spacer()
                Text("1080p60 \u{00B7} zero dependencies \u{00B7} one Swift file")
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                    .foregroundStyle(volt)
                    .opacity(foot)
                    .padding(.bottom, 110)
            }
        }
    }

    @ViewBuilder @MainActor
    static func stat(_ big: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(big)
                .font(.system(size: 330, weight: .black)).fontWidth(.condensed)
                .monospacedDigit()
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 20)
            Text(label)
                .font(.system(size: 30, weight: .bold))
                .tracking(8)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: bar 7 · lockup

    @ViewBuilder @MainActor
    static func lockup(_ t: Double) -> some View {
        let s = Ease.spring(t, from: 1.25, to: 1.0, response: 0.4, dampingFraction: 0.6)
        let sub = Ease.easeOut(Ease.clip(t, 0.35, 0.8))
        let foot = Ease.easeOut(Ease.clip(t, 0.7, 1.1))
        ZStack {
            shaderFill("galaxy", t * 0.5, size: CGSize(width: 1920, height: 1080))
                .opacity(0.35).ignoresSafeArea()
            VStack(spacing: 26) {
                Text("swift-render")
                    .font(.system(size: 200, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
                    .scaleEffect(s)
                Text("SwiftUI + Metal  \u{2192}  MP4")
                    .font(.system(size: 44, weight: .medium, design: .monospaced))
                    .foregroundStyle(volt)
                    .opacity(sub)
                    .offset(y: (1 - sub) * 14)
                Text("github.com/skyblanket/swift-render")
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .opacity(foot)
                    .padding(.top, 24)
            }
        }
    }

    // MARK: cut flash + hairline progress

    @MainActor
    static func flash(_ t: Double, extra: [Double]) -> some View {
        let cuts: [Double] = Array(chapters[1...7]) + extra
        var hit: Double = 0
        for c in cuts { hit = max(hit, 1.0 - abs(t - c) / 0.06) }
        return Color.white.opacity(hit * 0.55).ignoresSafeArea()
    }

    @MainActor
    static func progress(_ t: Double, total: Double) -> some View {
        VStack {
            Spacer()
            HStack { Rectangle().fill(volt).frame(width: t / total * 1920, height: 4); Spacer(minLength: 0) }
        }
        .ignoresSafeArea()
    }
}
