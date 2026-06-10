import SwiftUI

/// LaunchFilm — the swift-render OSS launch video.
///
/// 55 seconds, built entirely on the public API it advertises:
/// Timeline/Clip sequencing, analytic springs, Metal shaders (incl. the
/// warpTunnel fake-3D raymarch), Canvas starfield, rotation3DEffect cards,
/// and a genuinely audio-reactive segment driven by the synthesized
/// soundtrack (tools/make_launch_audio.py — hit times mirror these clips).
///
///   swift run swift-render render LaunchFilm --audio out/launch.wav \
///       --out out/launch-film.mp4
///
/// Chapters (all hard cuts; white flash overlay at each boundary):
///   0.0  hook          "your video framework runs a browser."
///   4.2  title         SWIFT-RENDER drop
///   7.2  01 pure fn    (t: Double) -> View
///  10.8  02 springs    four curves racing
///  14.4  03 timeline   clips sliding onto a track
///  18.0  04 shaders    2×2 live Metal wall
///  21.6  05 3D         starfield + warpTunnel + perspective cards
///  25.2  06 audio      bars literally hearing this soundtrack
///  28.8  07 speed      render race vs chromium
///  32.4  08 determinism byte-identical runs
///  36.0  09 ai-native  prompt → code → frame
///  39.6  the NO wall   no chromium / no node / no keyframes
///  43.2  JUST/RENDER/IT. slams
///  45.0  lockup + slash
///  49.0  URL + CTA, fade out
public struct LaunchFilm: AudioReactiveScene {
    public static let defaultDuration: Double = 55.0
    public static var ownsPostFX: Bool { true }

    static let volt = Color.white   // monochrome redesign: accent = white
    static let boundaries: [Double] = [4.2, 7.2, 10.8, 14.4, 18.0, 21.6,
                                       25.2, 28.8, 32.4, 36.0, 39.6, 43.2, 45.0]

    @MainActor
    public static func body(at t: Double, duration: Double, audio: AudioTrack) -> some View {
        let pumpGate = 1 - Ease.clip(t, 42.6, 43.2)   // FFT pump off after the build
        let bass = audio.band(.bass, at: t) * pumpGate
        let fade = Ease.easeIn(Ease.clip(t, duration - 1.0, duration))
        // Nike-style impact shake: decaying jitter on every cut + finale slams,
        // and a heavy one on the 808 lockup hit. Deterministic, kick-synced.
        let hits = [3.0] + boundaries + [43.8, 44.4]
        var jolt = JustRenderIt.shake(t, impacts: hits, amp: 13)
        let big = JustRenderIt.shake(t, impacts: [45.0], amp: 30)
        jolt = CGSize(width: jolt.width + big.width, height: jolt.height + big.height)

        return ZStack {
            Color.black.ignoresSafeArea()

            Timeline(t) {
                Clip(4.2) { l in hook(l) }
                Clip(3.0) { l in title(l) }
                Clip(3.6) { l in pureFn(l) }
                Clip(3.6) { l in springs(l) }
                Clip(3.6) { l in timelineCard(l) }
                Clip(3.6) { l in shaderWall(l) }
                Clip(3.6) { l in threeD(l) }
                Clip(3.6) { l in audioRx(l, audio: audio, base: 25.2) }
                Clip(3.6) { l in speedRace(l) }
                Clip(3.6) { l in determinism(l) }
                Clip(3.6) { l in aiNative(l) }
                Clip(3.6) { l in noWall(l) }
                Clip(1.8) { l in slams(l) }
                Clip(4.0) { l in lockup(l) }
                Clip(6.0) { l in outro(l) }
                Clip(at: 0, for: duration) { l in hud(l, total: duration) }
            }
            .scaleEffect(1 + 0.018 * CGFloat(bass))   // the whole film breathes with the sub
            .offset(jolt)

            flash(t)
        }
        .opacity(1 - fade)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PostFX(time: t, grainAmount: 0.11, vignetteAmount: 0.42))
    }

    // MARK: hook

    @ViewBuilder @MainActor
    static func hook(_ t: Double) -> some View {
        if t < 3.0 {
            let line = "your video framework runs a browser."
            let typed = Int(Ease.clip(t, 0.3, 2.2) * Double(line.count))
            HStack(spacing: 2) {
                Text(String(line.prefix(typed)))
                Rectangle().fill(volt).frame(width: 13, height: 30)
                    .opacity(Int(t * 4) % 2 == 0 ? 1 : 0)
            }
            .font(.system(size: 32, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .tracking(4)
        } else {
            let p = Ease.easeOut(min(1, (t - 3.0) / 0.25))
            ZStack {
                Color.white.ignoresSafeArea()
                Text("ours doesn't.")
                    .font(.system(size: 150, weight: .black))
                    .fontWidth(.condensed)
                    .foregroundStyle(.black)
                    .scaleEffect(1.25 - 0.25 * p)
                    .blur(radius: (1 - p) * 8)
            }
        }
    }

    // MARK: title

    @ViewBuilder @MainActor
    static func title(_ t: Double) -> some View {
        let punch = Ease.easeOut(min(1, t / 0.3))
        let sub = Ease.easeOut(Ease.clip(t, 0.45, 1.0))
        let sweep = Ease.easeInOut(Ease.clip(t, 0.4, 0.95))
        ZStack {
            burst(t)
            VStack(spacing: 26) {
                Text("SWIFT-RENDER")
                    .font(.system(size: 200, weight: .black))
                    .fontWidth(.condensed)
                    .foregroundStyle(.white)
                    .scaleEffect(1.35 - 0.35 * punch)
                    .blur(radius: (1 - punch) * 12)
                Rectangle().fill(volt)
                    .frame(width: CGFloat(sweep) * 900, height: 10)
                    .rotationEffect(.degrees(-2.5))
                Text("SwiftUI scenes + Metal shaders → MP4")
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(volt)
                    .opacity(sub)
                    .offset(y: CGFloat(1 - sub) * 16)
            }
        }
    }

    /// Radial particle burst behind the title slam. Canvas, deterministic.
    @MainActor
    static func burst(_ t: Double) -> some View {
        Canvas { ctx, size in
            let p = min(1, t / 1.1)
            guard p < 1 else { return }
            let e = 1 - pow(1 - p, 3)
            for i in 0..<90 {
                let a = hash01(Double(i) * 12.9898) * 2 * .pi
                let sp = 300 + hash01(Double(i) * 78.233 + 5) * 700
                let x = size.width / 2 + CGFloat(cos(a) * sp * e)
                let y = size.height / 2 + CGFloat(sin(a) * sp * e)
                let r = CGFloat(1 + hash01(Double(i) * 3.7) * 3) * CGFloat(1 - e)
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(.white.opacity((1 - p) * 0.9)))
            }
        }
        .ignoresSafeArea()
    }

    // MARK: 01 · pure function

    @ViewBuilder @MainActor
    static func pureFn(_ t: Double) -> some View {
        let bounce = Ease.spring(max(0, t - 0.4), from: 0, to: 1, response: 0.55, dampingFraction: 0.45)
        VStack(spacing: 50) {
            Text("(t: Double) → View")
                .font(.system(size: 110, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .opacity(Ease.easeOut(min(1, t / 0.4)))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12)).frame(width: 1100, height: 8)
                Circle().fill(volt).frame(width: 56, height: 56)
                    .offset(x: CGFloat(bounce) * 1044)
            }
            Text("no hooks. no state. no races. nothing to hallucinate.")
                .font(.system(size: 26, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .opacity(Ease.easeOut(Ease.clip(t, 0.9, 1.4)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) { chip("01 · PURE FUNCTION OF TIME") }
    }

    // MARK: 02 · springs

    @ViewBuilder @MainActor
    static func springs(_ t: Double) -> some View {
        let curves: [(String, (Double) -> Double)] = [
            ("spring", { Ease.spring($0, from: 0, to: 1, response: 0.45, dampingFraction: 0.5) }),
            ("easeOutBack", { Ease.easeOutBack(Ease.clip($0, 0, 0.8)) }),
            ("bounce", { Ease.bounce(Ease.clip($0, 0, 1.0)) }),
            ("elastic", { Ease.elastic(Ease.clip($0, 0, 1.1)) }),
        ]
        VStack(spacing: 30) {
            Text("ANALYTIC SPRINGS")
                .font(.system(size: 84, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
            ForEach(0..<4, id: \.self) { i in
                let v = curves[i].1(max(0, t - 0.3 - Double(i) * 0.1))
                HStack(spacing: 22) {
                    Text(curves[i].0)
                        .font(.system(size: 24, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 260, alignment: .trailing)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.10)).frame(width: 980, height: 6)
                        Circle().fill(volt).frame(width: 36, height: 36)
                            .offset(x: CGFloat(v) * 944)
                    }
                }
            }
            Text("closed-form. scrub any frame, get the same pixels.")
                .font(.system(size: 24, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .opacity(Ease.easeOut(Ease.clip(t, 1.6, 2.1)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) { chip("02 · SPRINGS, SOLVED ANALYTICALLY") }
    }

    // MARK: 03 · timeline

    @ViewBuilder @MainActor
    static func timelineCard(_ t: Double) -> some View {
        let labels = ["Clip(2.0)", "Clip(3.0).transition(.slide())", "Clip(2.5).transition(.fade())"]
        let widths: [CGFloat] = [300, 460, 380]
        let colors: [Color] = [volt, .white, volt.opacity(0.7)]
        VStack(spacing: 60) {
            Text("TIMELINE")
                .font(.system(size: 84, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.10)).frame(width: 1240, height: 3)
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        let p = Ease.easeOutBack(Ease.clip(t, 0.3 + Double(i) * 0.35, 0.9 + Double(i) * 0.35))
                        RoundedRectangle(cornerRadius: 12)
                            .fill(colors[i].opacity(0.25))
                            .stroke(colors[i], lineWidth: 2)
                            .frame(width: widths[i], height: 90)
                            .overlay(Text(labels[i])
                                .font(.system(size: 19, design: .monospaced))
                                .foregroundStyle(.white))
                            .offset(y: CGFloat(1 - p) * -260)
                            .opacity(p > 0 ? 1 : 0)
                    }
                }
            }
            Text("local time per clip · transitions overlap automatically · overlays pin anywhere")
                .font(.system(size: 24, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .opacity(Ease.easeOut(Ease.clip(t, 1.7, 2.2)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) { chip("03 · SEQUENCING WITHOUT SEGMENT MATH") }
    }

    // MARK: 04 · shader wall

    @ViewBuilder @MainActor
    static func shaderWall(_ t: Double) -> some View {
        let inP = Ease.easeOut(min(1, t / 0.4))
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                shaderTile("metaballs", t) { sz, tt in
                    ShaderLibrary.bundle(.module).metaballs(.float2(sz, sz * 0.5635), .float(tt))
                }
                shaderTile("inkFlow", t) { sz, tt in
                    ShaderLibrary.bundle(.module).inkFlow(.float2(sz, sz * 0.5635), .float(tt))
                }
            }
            HStack(spacing: 6) {
                shaderTile("interference", t) { sz, tt in
                    ShaderLibrary.bundle(.module).interference(.float2(sz, sz * 0.5635), .float(tt))
                }
                shaderTile("voronoiInk", t) { sz, tt in
                    ShaderLibrary.bundle(.module).voronoiInk(.float2(sz, sz * 0.5635), .float(tt))
                }
            }
        }
        .scaleEffect(1.04 - 0.04 * inP)
        .opacity(inP)
        .overlay {
            Text("REAL METAL")
                .font(.system(size: 150, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
                .blendMode(.difference)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) { chip("04 · RAYMARCHED ON THE GPU, NO WEBGL") }
    }

    @MainActor
    static func shaderTile(_ name: String, _ t: Double,
                           _ make: (Float, Float) -> Shader) -> some View {
        Rectangle()
            .fill(.black)
            .colorEffect(make(956, Float(t * 0.7 + 3)))
            .frame(width: 956, height: 537)
            .overlay(alignment: .bottomTrailing) {
                Text(name)
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(10)
            }
    }

    // MARK: 05 · 3D

    @ViewBuilder @MainActor
    static func threeD(_ t: Double) -> some View {
        let inP = Ease.easeOut(min(1, t / 0.4))
        ZStack {
            Rectangle().fill(.black)
                .colorEffect(ShaderLibrary.bundle(.module).monoTunnel(
                    .float2(1920, 1080), .float(Float(t))))
                .opacity(0.85 * inP)
                .ignoresSafeArea()
            starfield(t, intensity: 0.8)
            HStack(spacing: -40) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = t * 46 + Double(i - 1) * 28
                    card3D(["SWIFTUI", "METAL", "60 FPS"][i], angle: phase, depth: i)
                }
            }
            VStack {
                Spacer()
                Text("rotation3DEffect · Canvas starfield · raymarched tunnel — all deterministic")
                    .font(.system(size: 23, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.bottom, 130)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) { chip("05 · 3D, NO ENGINE REQUIRED") }
    }

    @MainActor
    static func card3D(_ label: String, angle: Double, depth: Int) -> some View {
        RoundedRectangle(cornerRadius: 22)
            .fill(.black.opacity(0.75))
            .stroke(volt, lineWidth: 2.5)
            .frame(width: 330, height: 430)
            .overlay(
                Text(label)
                    .font(.system(size: 44, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
            )
            .rotation3DEffect(.degrees(sin(angle * .pi / 180) * 32),
                              axis: (x: 0, y: 1, z: 0), perspective: 0.65)
            .rotation3DEffect(.degrees(6), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
            .offset(y: CGFloat(depth - 1) * 14)
            .shadow(color: volt.opacity(0.25), radius: 30)
    }

    /// Perspective-projected 3D starfield. Pure Canvas, pure hash, pure t.
    @MainActor
    static func starfield(_ t: Double, intensity: Double) -> some View {
        Canvas { ctx, size in
            for i in 0..<320 {
                let h1 = hash01(Double(i) * 12.9898)
                let h2 = hash01(Double(i) * 78.233 + 3)
                let h3 = hash01(Double(i) * 45.164 + 7)
                let speed = 0.22 + h3 * 0.5
                let cycle = 1.7
                let z = max(0.06, 1.0 - ((t * speed + h2 * cycle)
                    .truncatingRemainder(dividingBy: cycle)) / cycle)
                let x = (h1 * 2 - 1) * 1.25, y = (h2 * 2 - 1) * 0.8
                let px = size.width / 2 + CGFloat(x / z) * size.width * 0.5
                let py = size.height / 2 + CGFloat(y / z) * size.height * 0.5
                let zp = min(z + 0.02, 1.0)
                let qx = size.width / 2 + CGFloat(x / zp) * size.width * 0.5
                let qy = size.height / 2 + CGFloat(y / zp) * size.height * 0.5
                var path = Path()
                path.move(to: CGPoint(x: qx, y: qy))
                path.addLine(to: CGPoint(x: px, y: py))
                ctx.stroke(path, with: .color(.white.opacity((1 - z) * intensity)),
                           lineWidth: max(0.8, (1 - z) * 2.6))
            }
        }
        .ignoresSafeArea()
    }

    // MARK: 06 · audio-reactive

    @ViewBuilder @MainActor
    static func audioRx(_ t: Double, audio: AudioTrack, base: Double) -> some View {
        let g = base + t                       // global time — envelopes are global
        let level = audio.level(at: g)
        let bass = audio.band(.bass, at: g)
        let high = audio.band(.high, at: g)
        ZStack {
            RadialGradient(colors: [Color.white.opacity(0.04 + 0.14 * bass), .clear],
                           center: .center, startRadius: 0, endRadius: 950)
                .ignoresSafeArea()
            HStack(alignment: .center, spacing: 7) {
                ForEach(0..<64, id: \.self) { i in
                    let phase = Double(i) / 64.0 * 0.16
                    let v = audio.level(at: max(0, g - phase))
                    Capsule().fill(Color.white.opacity(0.25 + 0.55 * high))
                        .frame(width: 13, height: 30 + 540 * v)
                }
            }
            VStack(spacing: 10) {
                Text("THIS FRAME HEARS THE MUSIC")
                    .font(.system(size: 92, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white.opacity(0.35 + 0.65 * level))
                    .blendMode(.difference)
                Text("audio.band(.bass, at: t) — FFT analyzed once, read as a pure function")
                    .font(.system(size: 23, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) { chip("06 · AUDIO-REACTIVE, STILL DETERMINISTIC") }
    }

    // MARK: 07 · speed race

    @ViewBuilder @MainActor
    static func speedRace(_ t: Double) -> some View {
        let us = Ease.easeOut(Ease.clip(t, 0.35, 1.45))
        let them = Ease.clip(t, 0.35, 3.4) * 0.16
        VStack(spacing: 54) {
            Text("RENDER RACE · 900 FRAMES · 1080P60")
                .font(.system(size: 56, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
            raceRow("swift-render", sub: "native ImageRenderer + Metal",
                    p: us, color: volt,
                    tag: us >= 1 ? "DONE · 6.4s · ~140fps" : "rendering…")
            raceRow("remotion", sub: "headless Chromium screenshots",
                    p: them, color: .white.opacity(0.30),
                    tag: "rendering… (typical ~15–30fps)")
            Text("same machine. same frames. no contest.")
                .font(.system(size: 24, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .opacity(Ease.easeOut(Ease.clip(t, 1.8, 2.3)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) { chip("07 · 5–10× FASTER LOCAL RENDERS") }
    }

    @MainActor
    static func raceRow(_ name: String, sub: String, p: Double, color: Color, tag: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.system(size: 34, weight: .black)).fontWidth(.condensed)
                Text(sub).font(.system(size: 19, design: .monospaced)).opacity(0.55)
                Spacer()
                Text(tag).font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(color)
            }
            .foregroundStyle(.white)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.10)).frame(height: 26)
                Capsule().fill(color).frame(width: max(8, CGFloat(p) * 1300), height: 26)
            }
        }
        .frame(width: 1300)
    }

    // MARK: 08 · determinism

    @ViewBuilder @MainActor
    static func determinism(_ t: Double) -> some View {
        let inP = Ease.easeOut(min(1, t / 0.5))
        let check = Ease.easeOutBack(Ease.clip(t, 1.2, 1.7))
        HStack(spacing: 70) {
            ForEach(0..<2, id: \.self) { run in
                VStack(spacing: 16) {
                    Rectangle().fill(.black)
                        .colorEffect(ShaderLibrary.bundle(.module).inkFlow(
                            .float2(560, 315), .float(4.31)))   // same t on purpose
                        .frame(width: 560, height: 315)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.25)))
                    Text("RUN \(run + 1) · t = 4.31")
                        .font(.system(size: 21, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("sha256: 9f3aa1…e2c4")
                        .font(.system(size: 19, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .opacity(inP)
        .overlay {
            VStack(spacing: 4) {
                Text("BYTE-IDENTICAL")
                    .font(.system(size: 96, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(volt)
                Text("XCTAssertEqual(runA, runB) — enforced in CI")
                    .font(.system(size: 23, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .scaleEffect(CGFloat(check))
            .shadow(color: .black.opacity(0.9), radius: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) { chip("08 · DETERMINISM, TESTED NOT PROMISED") }
    }

    // MARK: 09 · AI-native

    @ViewBuilder @MainActor
    static func aiNative(_ t: Double) -> some View {
        let code = "Text(\"hello.\").opacity(Ease.clip(t, 0, 0.4))"
        let typed = Int(Ease.clip(t, 0.2, 1.5) * Double(code.count))
        let result = Ease.easeOut(Ease.clip(t, 1.6, 2.1))
        VStack(spacing: 44) {
            Text("LLMS WRITE THIS. FIRST TRY.")
                .font(.system(size: 84, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 14) {
                Text("> make me a fade-in title")
                    .foregroundStyle(.white.opacity(0.5))
                Text(String(code.prefix(typed)))
                    .foregroundStyle(volt)
            }
            .font(.system(size: 28, design: .monospaced))
            .padding(34)
            .frame(width: 1100, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.15)))
            Text("hello.")
                .font(.system(size: 66, weight: .semibold))
                .foregroundStyle(.white)
                .opacity(result)
            Text("this film is one Swift file — written by an AI, frames + soundtrack")
                .font(.system(size: 23, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
                .opacity(Ease.easeOut(Ease.clip(t, 2.3, 2.8)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) { chip("09 · BUILT FOR THE AI ERA") }
    }

    // MARK: the NO wall

    @ViewBuilder @MainActor
    static func noWall(_ t: Double) -> some View {
        let lines = ["NO CHROMIUM", "NO NODE_MODULES", "NO KEYFRAMES", "NO TIMELINE GUI", "NO RENDER FARM"]
        VStack(spacing: 4) {
            ForEach(0..<lines.count, id: \.self) { i in
                let p = Ease.easeOut(Ease.clip(t, 0.15 + Double(i) * 0.42, 0.43 + Double(i) * 0.42))
                Text(lines[i])
                    .font(.system(size: 124, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white.opacity(0.92))
                    .modifier(JustRenderIt.Slant(height: 124))
                    .scaleEffect(1.22 - 0.22 * p)
                    .opacity(p)
                    .blur(radius: (1 - p) * 6)
            }
            let just = Ease.easeOut(Ease.clip(t, 2.5, 2.85))
            Text("JUST SWIFT.")
                .font(.system(size: 124, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(volt)
                .modifier(JustRenderIt.Slant(height: 124))
                .scaleEffect(1.3 - 0.3 * just)
                .opacity(just)
        }
    }

    // MARK: finale

    @ViewBuilder @MainActor
    static func slams(_ t: Double) -> some View {
        let words = ["JUST", "RENDER", "IT."]
        let idx = min(2, Int(t / 0.6))
        let p = Ease.easeOut(min(1, (t - Double(idx) * 0.6) / 0.18))
        Text(words[idx])
            .font(.system(size: 320, weight: .black)).fontWidth(.condensed)
            .foregroundStyle(idx == 2 ? volt : .white)
            .modifier(JustRenderIt.Slant(height: 320))
            .scaleEffect(1.35 - 0.35 * p)
            .blur(radius: (1 - p) * 10)
    }

    @ViewBuilder @MainActor
    static func lockup(_ t: Double) -> some View {
        let inP = Ease.easeOut(min(1, t / 0.2))
        let sweep = Ease.easeInOut(Ease.clip(t, 0.15, 0.6))
        VStack(spacing: 32) {
            Text("JUST RENDER IT.")
                .font(.system(size: 180, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
                .modifier(JustRenderIt.Slant(height: 180))
                .scaleEffect(1.16 - 0.16 * inP)
            Rectangle().fill(volt)
                .frame(width: CGFloat(sweep) * 1050, height: 14)
                .rotationEffect(.degrees(-3))
        }
    }

    @ViewBuilder @MainActor
    static func outro(_ t: Double) -> some View {
        let letters = Array("swift-render.")
        let sweep = Ease.easeInOut(Ease.clip(t, 0.7, 1.25))
        let urlP = Ease.easeOut(Ease.clip(t, 1.1, 1.6))
        let mitP = Ease.easeOut(Ease.clip(t, 1.5, 2.0))
        VStack(spacing: 28) {
            HStack(spacing: 2) {
                ForEach(Array(letters.enumerated()), id: \.offset) { idx, ch in
                    let st = 0.1 + Double(idx) * 0.04
                    let p = Ease.easeOut(Ease.clip(t, st, st + 0.35))
                    Text(String(ch))
                        .font(.system(size: 110, weight: .semibold))
                        .foregroundStyle(.white)
                        .opacity(p)
                        .blur(radius: (1 - p) * 9)
                        .offset(y: CGFloat(1 - p) * 24)
                }
            }
            Rectangle().fill(.white)
                .frame(width: CGFloat(sweep) * 760, height: 4)
            Text("github.com/skyblanket/swift-render")
                .font(.system(size: 30, design: .monospaced))
                .foregroundStyle(volt)
                .opacity(urlP)
                .offset(y: CGFloat(1 - urlP) * 12)
            Text("MIT · open source · macOS 14+")
                .font(.system(size: 22, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .opacity(mitP)
        }
    }

    // MARK: shared

    @MainActor
    static func chip(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 21, weight: .semibold, design: .monospaced))
            .foregroundStyle(.black)
            .padding(.horizontal, 18).padding(.vertical, 9)
            .background(volt)
            .padding(.leading, 60)
            .padding(.bottom, 86)
    }

    @MainActor
    static func hud(_ t: Double, total: Double) -> some View {
        VStack {
            HStack {
                Text("swift-render v0.5.0 — launch film")
                Spacer()
                Text(String(format: "%05.2fs", t))
            }
            .font(.system(size: 17, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .blendMode(.difference)
            .opacity(0.55)
            .padding(.horizontal, 40).padding(.top, 30)
            Spacer()
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.08)).frame(height: 4)
                Rectangle().fill(volt).frame(width: CGFloat(t / total) * 1920, height: 4)
            }
        }
        .ignoresSafeArea()
    }

    @MainActor
    static func flash(_ t: Double) -> some View {
        let hit = boundaries.map { max(0, 1 - abs(t - $0) / 0.07) }.max() ?? 0
        return Color.white.opacity(hit * 0.85).ignoresSafeArea()
    }

    static func hash01(_ x: Double) -> Double {
        abs((sin(x) * 43758.5453).truncatingRemainder(dividingBy: 1.0))
    }
}
