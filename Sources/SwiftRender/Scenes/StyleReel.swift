import SwiftUI

/// StyleReel — twelve aesthetics, one engine, zero assets.
///
/// The mechanic: each style arrives as a live card that springs to center,
/// the camera zooms INTO the card until its content fills the frame, the
/// style plays out in its own motion language, then the next card lands on
/// top of it. Closes on a live 4×3 collage of all twelve running at once.
///
///   swift run swift-render render StyleReel --audio out/reel.wav
///
/// Timing (style switches land on out/reel.wav crashes):
///   0.0–3.6   intro slams
///   3.6–32.4  12 styles × 2.4s — swiss, brutalist, bauhaus, synthwave,
///             glass, terminal, deco, vaporwave, blueprint, zine, aurora,
///             kinetic
///  32.4–38.4  live collage outro + URL
public struct StyleReel: RenderScene {
    public static let defaultDuration: Double = 38.4
    public static var ownsPostFX: Bool { true }

    static let styleNames = ["SWISS", "BRUTALIST", "BAUHAUS", "SYNTHWAVE",
                             "GLASS", "TERMINAL", "ART DECO", "VAPORWAVE",
                             "BLUEPRINT", "ZINE", "AURORA", "KINETIC"]
    static let segStart = 3.6, segLen = 2.4
    static let outroStart = 32.4

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let switches = (0..<12).map { segStart + Double($0) * segLen } + [outroStart]
        let jolt = JustRenderIt.shake(t, impacts: switches, amp: 11)
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
            flash(t, hits: switches)
        }
        .opacity(1 - fade)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PostFX(time: t, grainAmount: 0.09, vignetteAmount: 0.38))
    }

    // MARK: intro

    @ViewBuilder @MainActor
    static func intro(_ t: Double) -> some View {
        let words: [(String, Double)] = [("EVERY STYLE.", 0.3), ("ONE ENGINE.", 1.3)]
        ZStack {
            LaunchFilm.starfield(t * 0.4, intensity: 0.4)
            VStack(spacing: 10) {
                ForEach(0..<2, id: \.self) { i in
                    let p = Ease.easeOut(min(1, max(0, (t - words[i].1) / 0.22)))
                    Text(words[i].0)
                        .font(.system(size: 170, weight: .black)).fontWidth(.condensed)
                        .foregroundStyle(.white)
                        .scaleEffect(1.3 - 0.3 * p)
                        .opacity(p)
                        .blur(radius: (1 - p) * 8)
                }
                Text("twelve aesthetics · 100% code · zero assets")
                    .font(.system(size: 26, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))
                    .opacity(Ease.easeOut(Ease.clip(t, 2.2, 2.7)))
                    .padding(.top, 26)
            }
        }
    }

    // MARK: the card-zoom machine

    @ViewBuilder @MainActor
    static func segment(_ i: Int, _ l: Double) -> some View {
        ZStack {
            // previous style keeps running underneath while the new card lands
            if l < 1.05 {
                if i == 0 {
                    LaunchFilm.starfield(3.6 + l, intensity: 0.4)
                } else {
                    styleView(i - 1, 2.4 + l)
                }
            }
            zoomCard(i, l)
        }
    }

    @MainActor
    static func zoomCard(_ i: Int, _ l: Double) -> some View {
        let enter = Ease.easeOutBack(Ease.clip(l, 0.0, 0.4), overshoot: 1.2)
        let zoom = Ease.easeInOut(Ease.clip(l, 0.45, 1.05))
        let dir: CGFloat = i % 2 == 0 ? 1 : -1
        let scale = (0.34 + 0.66 * zoom) * (0.7 + 0.3 * enter)
        let radius = (1 - zoom) * 80
        let tag = (1 - zoom) * enter

        return ZStack {
            styleView(i, l)
                .frame(width: 1920, height: 1080)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius)
                    .stroke(.white.opacity(0.85 * (1 - zoom)), lineWidth: 2.5))
                .overlay(alignment: .bottom) {
                    Text(styleNames[i])
                        .font(.system(size: 46, weight: .black, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 26).padding(.vertical, 10)
                        .background(.white)
                        .offset(y: 90)
                        .opacity(tag)
                }
                .shadow(color: .black.opacity(0.6 * (1 - zoom)), radius: 50, y: 18)
                .scaleEffect(CGFloat(scale))
                .offset(x: dir * CGFloat(1 - enter) * 1600,
                        y: CGFloat(1 - enter) * (i % 3 == 0 ? -300 : 240))
        }
    }

    // MARK: style dispatcher

    @ViewBuilder @MainActor
    static func styleView(_ i: Int, _ t: Double) -> some View {
        switch i {
        case 0: swiss(t)
        case 1: brutalist(t)
        case 2: bauhaus(t)
        case 3: synthwave(t)
        case 4: glass(t)
        case 5: terminal(t)
        case 6: artDeco(t)
        case 7: vaporwave(t)
        case 8: blueprint(t)
        case 9: zine(t)
        case 10: aurora(t)
        default: kineticStyle(t)
        }
    }

    // 01 · SWISS — grid precision, red accent, surgical slides
    @ViewBuilder @MainActor
    static func swiss(_ t: Double) -> some View {
        let bar = Ease.easeInOut(Ease.clip(t, 0.1, 0.7))
        let type = Ease.easeOut(Ease.clip(t, 0.4, 0.9))
        ZStack(alignment: .topLeading) {
            Color(white: 0.96).ignoresSafeArea()
            Rectangle().fill(Color(red: 0.86, green: 0.12, blue: 0.10))
                .frame(width: CGFloat(bar) * 1100, height: 150)
                .offset(x: 140, y: 240)
            VStack(alignment: .leading, spacing: 0) {
                Text("GRID.")
                    .font(.system(size: 230, weight: .black))
                    .foregroundStyle(.black)
                    .offset(x: CGFloat(1 - type) * -160)
                    .opacity(type)
                Text("Ordnung muss sein — 01 / 12")
                    .font(.system(size: 26, weight: .medium, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.7))
                    .opacity(Ease.clip(t, 0.9, 1.2))
            }
            .padding(.leading, 140).padding(.top, 380)
            ForEach(0..<3, id: \.self) { r in
                Rectangle().fill(.black.opacity(0.85)).frame(height: 3)
                    .frame(width: CGFloat(Ease.easeInOut(Ease.clip(t, 0.6 + Double(r) * 0.15, 1.2 + Double(r) * 0.15))) * 1640)
                    .offset(x: 140, y: CGFloat(760 + r * 70))
            }
        }
    }

    // 02 · BRUTALIST — raw, oversized, stop-motion jitter
    @ViewBuilder @MainActor
    static func brutalist(_ t: Double) -> some View {
        let q = (t * 12).rounded(.down)
        let jx = CGFloat(LaunchFilm.hash01(q * 3.3) * 2 - 1) * 7
        let jr = (LaunchFilm.hash01(q * 7.7) * 2 - 1) * 1.4
        ZStack {
            Color.white.ignoresSafeArea()
            Rectangle().stroke(.black, lineWidth: 26).padding(46)
            Text("RAW")
                .font(.system(size: 480, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.black)
                .offset(x: jx)
                .rotationEffect(.degrees(jr))
            Text("✱")
                .font(.system(size: 130, weight: .black))
                .foregroundStyle(.black)
                .rotationEffect(.degrees(t * 120))
                .offset(x: 700, y: -340)
            Text("NO  GRIDS  NO  GODS")
                .font(.system(size: 30, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.black)
                .offset(y: 380)
        }
    }

    // 03 · BAUHAUS — primary geometry on springs
    @ViewBuilder @MainActor
    static func bauhaus(_ t: Double) -> some View {
        let s1 = Ease.spring(max(0, t - 0.1), from: 0, to: 1, response: 0.5, dampingFraction: 0.5)
        let s2 = Ease.spring(max(0, t - 0.3), from: 0, to: 1, response: 0.5, dampingFraction: 0.5)
        let s3 = Ease.spring(max(0, t - 0.5), from: 0, to: 1, response: 0.5, dampingFraction: 0.5)
        ZStack {
            Color(red: 0.93, green: 0.89, blue: 0.82).ignoresSafeArea()
            Circle().fill(Color(red: 0.83, green: 0.18, blue: 0.14))
                .frame(width: 430, height: 430)
                .scaleEffect(CGFloat(s1))
                .offset(x: -380, y: -120)
            ReelTriangle().fill(Color(red: 0.16, green: 0.32, blue: 0.62))
                .frame(width: 420, height: 380)
                .scaleEffect(CGFloat(s2))
                .rotationEffect(.degrees(t * 18))
                .offset(x: 330, y: 60)
            Circle().trim(from: 0, to: 0.5)
                .stroke(Color(red: 0.93, green: 0.72, blue: 0.12), lineWidth: 60)
                .frame(width: 560, height: 560)
                .rotationEffect(.degrees(-t * 28))
                .scaleEffect(CGFloat(s3))
                .offset(y: 180)
            Text("form folgt funktion")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.black.opacity(0.85))
                .offset(y: 430)
                .opacity(Ease.clip(t, 0.8, 1.1))
        }
    }

    // 04 · SYNTHWAVE — neon grid, flicker-on glow
    @ViewBuilder @MainActor
    static func synthwave(_ t: Double) -> some View {
        let flick = LaunchFilm.hash01((t * 28).rounded(.down) * 1.7) > (t < 0.7 ? 0.45 : 0.02) ? 1.0 : 0.35
        ZStack {
            Rectangle().fill(.black)
                .colorEffect(ShaderLibrary.bundle(.module).neonGrid(
                    .float2(1920, 1080), .float(Float(t * 0.8 + 2))))
                .ignoresSafeArea()
            Text("MIDNIGHT")
                .font(.system(size: 200, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(Color(red: 0.2, green: 0.95, blue: 1.0))
                .shadow(color: Color(red: 0.2, green: 0.9, blue: 1.0).opacity(0.9), radius: 30)
                .shadow(color: Color(red: 0.95, green: 0.2, blue: 0.8).opacity(0.7), radius: 60)
                .opacity(flick)
                .offset(y: -100)
        }
    }

    // 05 · GLASS — frosted cards over drifting blobs
    @ViewBuilder @MainActor
    static func glass(_ t: Double) -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.10, blue: 0.30),
                                    Color(red: 0.05, green: 0.22, blue: 0.34)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            Circle().fill(Color(red: 0.45, green: 0.35, blue: 1.0).opacity(0.55))
                .frame(width: 700, height: 700).blur(radius: 90)
                .offset(x: CGFloat(sin(t * 0.7)) * 300 - 200, y: -160)
            Circle().fill(Color(red: 0.2, green: 0.85, blue: 0.9).opacity(0.5))
                .frame(width: 560, height: 560).blur(radius: 80)
                .offset(x: CGFloat(cos(t * 0.55)) * 260 + 320, y: 220)
            ForEach(0..<2, id: \.self) { c in
                let p = Ease.spring(max(0, t - 0.15 - Double(c) * 0.2), from: 0, to: 1, response: 0.6, dampingFraction: 0.7)
                RoundedRectangle(cornerRadius: 34)
                    .fill(.white.opacity(0.10))
                    .stroke(.white.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 640, height: 360)
                    .overlay(
                        VStack(alignment: .leading, spacing: 14) {
                            Text(c == 0 ? "frosted." : "layered.")
                                .font(.system(size: 64, weight: .semibold))
                                .foregroundStyle(.white)
                            Capsule().fill(.white.opacity(0.4)).frame(width: 220, height: 10)
                            Capsule().fill(.white.opacity(0.25)).frame(width: 140, height: 10)
                        }.padding(40), alignment: .topLeading)
                    .rotationEffect(.degrees(c == 0 ? -4 : 5))
                    .offset(x: c == 0 ? -240 : 290, y: (c == 0 ? -60 : 130) + CGFloat(sin(t * 0.9 + Double(c))) * 14)
                    .scaleEffect(CGFloat(0.6 + 0.4 * p))
                    .opacity(p)
            }
        }
    }

    // 06 · TERMINAL — green phosphor, type-on, glitch slices
    @ViewBuilder @MainActor
    static func terminal(_ t: Double) -> some View {
        let lines = ["$ swift run swift-render render StyleReel",
                     "[swift-render] 2304 frames → reel.mp4",
                     "[swift-render] done in 19.4s",
                     "$ _"]
        let green = Color(red: 0.25, green: 1.0, blue: 0.45)
        let glitch = LaunchFilm.hash01((t * 9).rounded(.down) * 2.3) > 0.8
        ZStack(alignment: .topLeading) {
            Color(red: 0.01, green: 0.05, blue: 0.02).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                ForEach(0..<lines.count, id: \.self) { i in
                    let st = 0.15 + Double(i) * 0.5
                    let typed = Int(Ease.clip(t, st, st + 0.4) * Double(lines[i].count))
                    Text(String(lines[i].prefix(typed)))
                        .font(.system(size: 40, weight: .medium, design: .monospaced))
                        .foregroundStyle(green)
                        .shadow(color: green.opacity(0.7), radius: 8)
                }
            }
            .padding(120)
            .offset(x: glitch ? 14 : 0)
            ForEach(0..<14, id: \.self) { i in
                Rectangle().fill(.black.opacity(0.22))
                    .frame(width: 1920, height: 5)
                    .offset(y: CGFloat(i) * 80 + CGFloat((t * 36).truncatingRemainder(dividingBy: 80)))
            }
        }
    }

    // 07 · ART DECO — gold fans on black, elegant trim reveals
    @ViewBuilder @MainActor
    static func artDeco(_ t: Double) -> some View {
        let gold = Color(red: 0.86, green: 0.72, blue: 0.34)
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.06).ignoresSafeArea()
            ForEach(0..<7, id: \.self) { i in
                let p = Ease.easeInOut(Ease.clip(t, 0.1 + Double(i) * 0.06, 0.7 + Double(i) * 0.06))
                Circle().trim(from: 0.5, to: 0.5 + 0.5 * p)
                    .stroke(gold.opacity(0.85 - Double(i) * 0.09), lineWidth: 5)
                    .frame(width: CGFloat(280 + i * 150), height: CGFloat(280 + i * 150))
                    .offset(y: 200)
            }
            VStack(spacing: 10) {
                Text("THE GRAND")
                    .font(.system(size: 120, weight: .semibold, design: .serif))
                    .foregroundStyle(gold)
                    .opacity(Ease.easeOut(Ease.clip(t, 0.6, 1.1)))
                Text("· EST. MMXXVI ·")
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .foregroundStyle(gold.opacity(0.8))
                    .tracking(10)
                    .opacity(Ease.easeOut(Ease.clip(t, 1.0, 1.4)))
            }
            .offset(y: -130)
        }
    }

    // 08 · VAPORWAVE — chrome type over a sunset grid
    @ViewBuilder @MainActor
    static func vaporwave(_ t: Double) -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.18, green: 0.04, blue: 0.35),
                                    Color(red: 0.95, green: 0.35, blue: 0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Circle()
                .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.85, blue: 0.4),
                                              Color(red: 0.98, green: 0.3, blue: 0.55)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 520, height: 520)
                .offset(y: -90 + CGFloat(Ease.easeOut(Ease.clip(t, 0, 1.4))) * 40)
            Rectangle().fill(.black)
                .colorEffect(ShaderLibrary.bundle(.module).neonGrid(
                    .float2(1920, 1080), .float(Float(t * 0.5))))
                .frame(height: 420)
                .opacity(0.85)
                .offset(y: 330)
            Text("ＤＲＥＡＭ")
                .font(.system(size: 170, weight: .black))
                .foregroundStyle(LinearGradient(colors: [.white, Color(red: 0.7, green: 0.9, blue: 1.0),
                                                         Color(red: 0.35, green: 0.45, blue: 0.9)],
                                                startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 8)
                .scaleEffect(1 + 0.03 * CGFloat(sin(t * 1.2)))
                .offset(y: -110)
        }
    }

    // 09 · BLUEPRINT — wireframes drawing themselves
    @ViewBuilder @MainActor
    static func blueprint(_ t: Double) -> some View {
        let ink = Color(red: 0.85, green: 0.92, blue: 1.0)
        let draw = Ease.easeInOut(Ease.clip(t, 0.1, 1.3))
        ZStack {
            Color(red: 0.07, green: 0.18, blue: 0.42).ignoresSafeArea()
            ForEach(0..<5, id: \.self) { i in
                Rectangle().fill(ink.opacity(0.08)).frame(width: 1, height: 1080)
                    .offset(x: CGFloat(i - 2) * 330)
            }
            RoundedRectangle(cornerRadius: 30)
                .trim(from: 0, to: draw)
                .stroke(ink, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .frame(width: 900, height: 480)
            Circle().trim(from: 0, to: Ease.easeInOut(Ease.clip(t, 0.5, 1.6)))
                .stroke(ink, lineWidth: 2.5)
                .frame(width: 300, height: 300)
                .rotationEffect(.degrees(-90))
            Rectangle().fill(ink).frame(width: CGFloat(draw) * 900, height: 1.5).offset(y: 300)
            Text("FIG. 12 — MOTION ENGINE   scale 1:1")
                .font(.system(size: 26, weight: .medium, design: .monospaced))
                .foregroundStyle(ink.opacity(0.85))
                .offset(y: 350)
                .opacity(Ease.clip(t, 1.2, 1.5))
        }
    }

    // 10 · ZINE — paper collage, stop-motion at 8 fps
    @ViewBuilder @MainActor
    static func zine(_ t: Double) -> some View {
        let q = (t * 8).rounded(.down) / 8   // the whole style runs quantized
        ZStack {
            Color(red: 0.93, green: 0.90, blue: 0.84).ignoresSafeArea()
            ForEach(0..<5, id: \.self) { i in
                let h = LaunchFilm.hash01(Double(i) * 9.1 + q * 2.0)
                RoundedRectangle(cornerRadius: 4)
                    .fill([Color.black, Color(red: 0.85, green: 0.25, blue: 0.2),
                           Color(red: 0.95, green: 0.75, blue: 0.1)][i % 3])
                    .frame(width: CGFloat(220 + i * 60), height: CGFloat(140 + i * 30))
                    .rotationEffect(.degrees((h * 2 - 1) * 14))
                    .offset(x: CGFloat(LaunchFilm.hash01(Double(i) * 3.7) * 2 - 1) * 600,
                            y: CGFloat(LaunchFilm.hash01(Double(i) * 5.3) * 2 - 1) * 320)
            }
            Text("CUT + PASTE")
                .font(.system(size: 150, weight: .black))
                .foregroundStyle(.black)
                .rotationEffect(.degrees((LaunchFilm.hash01(q * 4.4) * 2 - 1) * 3))
                .background(Rectangle().fill(.white).padding(-18)
                    .rotationEffect(.degrees((LaunchFilm.hash01(q * 6.6) * 2 - 1) * 2)))
            Text("№ 10 — PHOTOCOPY FOREVER")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundStyle(.black)
                .padding(8).background(.white)
                .rotationEffect(.degrees(-4))
                .offset(x: -480, y: 390)
        }
    }

    // 11 · AURORA — fluid ink, weightless type
    @ViewBuilder @MainActor
    static func aurora(_ t: Double) -> some View {
        ZStack {
            Rectangle().fill(.black)
                .colorEffect(ShaderLibrary.bundle(.module).inkFlow(
                    .float2(1920, 1080), .float(Float(t * 0.5 + 14))))
                .ignoresSafeArea()
            Text("breathe")
                .font(.system(size: 150, weight: .thin))
                .foregroundStyle(.white.opacity(0.95))
                .tracking(30)
                .blur(radius: CGFloat(1 - Ease.easeOut(Ease.clip(t, 0.2, 1.2))) * 12)
                .opacity(Ease.easeOut(Ease.clip(t, 0.2, 1.0)))
                .scaleEffect(1 + 0.02 * CGFloat(sin(t * 0.8)))
        }
    }

    // 12 · KINETIC — invert word slams
    @ViewBuilder @MainActor
    static func kineticStyle(_ t: Double) -> some View {
        let words = ["MOVE", "FAST", "LOUD"]
        let idx = min(2, Int(t / 0.55))
        let p = Ease.easeOut(min(1, max(0, (t - Double(idx) * 0.55) / 0.16)))
        let inverted = idx % 2 == 1
        ZStack {
            (inverted ? Color.white : Color.black).ignoresSafeArea()
            Text(words[idx])
                .font(.system(size: 380, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(inverted ? .black : .white)
                .modifier(JustRenderIt.Slant(height: 380))
                .scaleEffect(1.3 - 0.3 * p)
                .blur(radius: (1 - p) * 9)
        }
    }

    // MARK: outro — all twelve, live, at once

    @ViewBuilder @MainActor
    static func collage(_ l: Double) -> some View {
        ZStack {
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(0..<4, id: \.self) { col in
                            let i = row * 4 + col
                            let p = Ease.easeOutBack(Ease.clip(l, 0.1 + Double(i) * 0.07, 0.5 + Double(i) * 0.07), overshoot: 1.1)
                            styleView(i, 3.0 + l)
                                .frame(width: 1920, height: 1080)
                                .scaleEffect(0.232)
                                .frame(width: 446, height: 251)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.25)))
                                .scaleEffect(CGFloat(0.5 + 0.5 * p))
                                .opacity(p)
                        }
                    }
                }
            }
            .scaleEffect(1.02)
            VStack(spacing: 14) {
                Text("ALL OF THIS IS CODE.")
                    .font(.system(size: 110, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.95), radius: 26)
                    .opacity(Ease.easeOut(Ease.clip(l, 1.3, 1.8)))
                Text("github.com/skyblanket/swift-render")
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.95), radius: 16)
                    .opacity(Ease.easeOut(Ease.clip(l, 1.7, 2.2)))
            }
        }
    }

    // MARK: shared

    @MainActor
    static func flash(_ t: Double, hits: [Double]) -> some View {
        let hit = hits.map { max(0, 1 - abs(t - $0) / 0.06) }.max() ?? 0
        return Color.white.opacity(hit * 0.8).ignoresSafeArea()
    }
}

/// Equilateral-ish triangle for the Bauhaus card.
struct ReelTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
