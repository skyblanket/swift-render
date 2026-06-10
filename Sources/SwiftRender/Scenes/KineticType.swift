import SwiftUI

/// KineticType — a deep kinetic-typography study. Thirteen chapters, each a
/// distinct move from the genre's playbook, chained on a 0.6s beat grid.
///
///   swift run swift-render render KineticType --audio out/kinetic-type.wav
///
/// Chapters (2.4s each from 2.4; crashes on every cut):
///   01 beat slams      02 cascade+wave    03 stacked pattern
///   04 marquee crossfire 05 split-slice   06 ring + 3D flaps
///   07 zoom through O  08 elastic drop    09 letter-grid wave
///   10 knockout bars   11 odometer+tracking 12 chaos→order
///   13 weight pump     then recap flashes + lockup
public struct KineticType: RenderScene {
    public static let defaultDuration: Double = 42.0
    public static var ownsPostFX: Bool { true }

    static let chapters: [Double] = (1...14).map { 2.4 * Double($0) }

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let jolt = JustRenderIt.shake(t, impacts: chapters + [36.0], amp: 11)
        let fade = Ease.easeIn(Ease.clip(t, duration - 1.0, duration))

        return ZStack {
            Color.black.ignoresSafeArea()
            Timeline(t) {
                Clip(2.4) { l in introType(l) }
                Clip(2.4) { l in beatSlams(l) }
                Clip(2.4) { l in cascade(l) }
                Clip(2.4) { l in stackedPattern(l) }
                Clip(2.4) { l in crossfire(l) }
                Clip(2.4) { l in splitSlice(l) }
                Clip(2.4) { l in ringFlaps(l) }
                Clip(2.4) { l in zoomO(l) }
                Clip(2.4) { l in elasticDrop(l) }
                Clip(2.4) { l in gridWave(l) }
                Clip(2.4) { l in knockout(l) }
                Clip(2.4) { l in odometer(l) }
                Clip(2.4) { l in chaosOrder(l) }
                Clip(2.4) { l in weightPump(l) }
                Clip(2.4) { l in recap(l) }
                Clip(6.0) { l in lockup(l) }
            }
            .offset(jolt)
            flash(t)
        }
        .opacity(1 - fade)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PostFX(time: t, grainAmount: 0.10, vignetteAmount: 0.40))
    }

    // 00 · typewriter intro
    @ViewBuilder @MainActor
    static func introType(_ t: Double) -> some View {
        let line = "type, in motion."
        let typed = Int(Ease.clip(t, 0.15, 1.4) * Double(line.count))
        HStack(spacing: 2) {
            Text(String(line.prefix(typed)))
            Rectangle().fill(.white).frame(width: 16, height: 52)
                .opacity(Int(t * 4) % 2 == 0 ? 1 : 0)
        }
        .font(.system(size: 64, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
    }

    // 01 · words on the beat, alternating invert
    @ViewBuilder @MainActor
    static func beatSlams(_ t: Double) -> some View {
        let words = ["EVERY", "WORD", "ON", "BEAT."]
        let idx = min(3, Int(t / 0.6))
        let p = Ease.easeOut(min(1, (t - Double(idx) * 0.6) / 0.16))
        let inv = idx % 2 == 1
        ZStack {
            (inv ? Color.white : Color.black).ignoresSafeArea()
            Text(words[idx])
                .font(.system(size: 330, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(inv ? .black : .white)
                .modifier(JustRenderIt.Slant(height: 330))
                .scaleEffect(1.35 - 0.35 * p)
                .blur(radius: (1 - p) * 9)
        }
    }

    // 02 · cascade in, then ride a sine wave
    @ViewBuilder @MainActor
    static func cascade(_ t: Double) -> some View {
        let word = Array("CASCADE")
        HStack(spacing: 6) {
            ForEach(0..<word.count, id: \.self) { i in
                let drop = Ease.spring(max(0, t - Double(i) * 0.07), from: -900, to: 0,
                                       response: 0.5, dampingFraction: 0.55)
                let wave = Ease.clip(t, 1.0, 1.3) * sin(t * 7 + Double(i) * 0.8) * 46
                Text(String(word[i]))
                    .font(.system(size: 250, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
                    .offset(y: CGFloat(drop + wave))
            }
        }
    }

    // 03 · stacked repetition, phase-offset wave, hot middle row
    @ViewBuilder @MainActor
    static func stackedPattern(_ t: Double) -> some View {
        VStack(spacing: -16) {
            ForEach(0..<13, id: \.self) { row in
                let inP = Ease.easeOut(Ease.clip(t, Double(row) * 0.035, 0.3 + Double(row) * 0.035))
                let hot = row == 6
                Text("PATTERN")
                    .font(.system(size: 130, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(hot ? Color.black : .white.opacity(0.85))
                    .padding(.horizontal, hot ? 20 : 0)
                    .background(hot ? Color.white : Color.clear)
                    .offset(x: CGFloat(sin(t * 2.4 + Double(row) * 0.48)) * 240)
                    .opacity(inP)
            }
        }
    }

    // 04 · marquee crossfire — opposing angled strips
    @ViewBuilder @MainActor
    static func crossfire(_ t: Double) -> some View {
        let line = "MOTION ✦ RHYTHM ✦ FLOW ✦ TYPE ✦ "
        let copy = String(repeating: line, count: 8)
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let enter = Ease.easeOut(Ease.clip(t, Double(i) * 0.1, 0.4 + Double(i) * 0.1))
                Text(copy)
                    .font(.system(size: 110, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize()
                    .offset(x: CGFloat(420.0 * t) - 2600)
                    .offset(y: CGFloat(i - 1) * 360)
                    .rotationEffect(.degrees(12))
                    .opacity(enter)
            }
            ForEach(0..<3, id: \.self) { i in
                let enter = Ease.easeOut(Ease.clip(t, 0.15 + Double(i) * 0.1, 0.55 + Double(i) * 0.1))
                Text(copy)
                    .font(.system(size: 110, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.black)
                    .padding(.vertical, 4)
                    .background(.white)
                    .fixedSize()
                    .offset(x: 800 - CGFloat(460.0 * t))
                    .offset(y: CGFloat(i - 1) * 360 + 180)
                    .rotationEffect(.degrees(-12))
                    .opacity(enter)
            }
        }
        .scaleEffect(1.3)
    }

    // 05 · split-slice: halves shear apart, reveal tracking expansion
    @ViewBuilder @MainActor
    static func splitSlice(_ t: Double) -> some View {
        let slide = Ease.easeInOut(Ease.clip(t, 0.6, 1.1))
        let track = CGFloat(4 + Ease.easeOut(Ease.clip(t, 0.8, 2.0)) * 56)
        ZStack {
            Text("W I D E")
                .font(.system(size: 150, weight: .black)).fontWidth(.condensed)
                .tracking(track)
                .foregroundStyle(.white.opacity(0.95))
                .opacity(slide)
            // two halves of SPLIT shearing off
            ForEach(0..<2, id: \.self) { half in
                Text("SPLIT")
                    .font(.system(size: 300, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
                    .frame(height: 320)
                    .clipShape(Rectangle().offset(y: half == 0 ? -80 : 80).size(width: 1920, height: 160))
                    .offset(x: CGFloat(slide) * (half == 0 ? -1100 : 1100),
                            y: 0)
                    .opacity(1 - Ease.clip(t, 1.05, 1.15))
            }
        }
    }

    // 06 · rotating ring + split-flap center
    @ViewBuilder @MainActor
    static func ringFlaps(_ t: Double) -> some View {
        let words = ["FLIP", "SPIN", "TURN", "FLIP"]
        let beat = Int(t / 0.6)
        let local = (t - Double(beat) * 0.6) / 0.6
        let flip = Ease.easeInOut(min(1, local / 0.4)) * 180
        ZStack {
            Kinetic.typeRing("KINETIC ✦ TYPOGRAPHY ✦ IN ✦ ORBIT ✦ ",
                             radius: 390, angle: t * 40, size: 36)
                .opacity(Ease.easeOut(min(1, t / 0.4)))
            Text(words[min(3, beat)])
                .font(.system(size: 210, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
                .rotation3DEffect(.degrees(flip < 90 ? flip : flip - 180),
                                  axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .opacity(flip < 90 ? 1 : 1)
        }
    }

    // 07 · zoom through the counter of the O
    @ViewBuilder @MainActor
    static func zoomO(_ t: Double) -> some View {
        let z = Ease.easeIn(Ease.clip(t, 0.5, 1.7))
        let scale = 1 + z * 30
        ZStack {
            Color.white.opacity(Ease.clip(t, 1.5, 1.7)).ignoresSafeArea()
            Text("THROUGH")
                .font(.system(size: 120, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.black)
                .opacity(Ease.clip(t, 1.7, 1.9))
            Text("ZOOM")
                .font(.system(size: 300, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
                .scaleEffect(CGFloat(scale), anchor: UnitPoint(x: 0.638, y: 0.42))
                .opacity(1 - Ease.clip(t, 1.62, 1.72))
        }
    }

    // 08 · elastic drop with squash & stretch
    @ViewBuilder @MainActor
    static func elasticDrop(_ t: Double) -> some View {
        let word = Array("BOUNCE")
        HStack(spacing: 8) {
            ForEach(0..<word.count, id: \.self) { i in
                let lt = max(0, t - 0.15 - Double(i) * 0.09)
                let p = Ease.elastic(Ease.clip(lt, 0, 1.1))
                let squash = 1 + (1 - min(1, lt * 2)) * 0.5
                Text(String(word[i]))
                    .font(.system(size: 260, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
                    .scaleEffect(x: CGFloat(2 - squash), y: CGFloat(squash), anchor: .bottom)
                    .offset(y: CGFloat(1 - p) * -700)
            }
        }
        .offset(y: 60)
    }

    // 09 · letter grid flips in a diagonal wave to spell MOTION
    @ViewBuilder @MainActor
    static func gridWave(_ t: Double) -> some View {
        let target = Array("MOTION")
        VStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(0..<10, id: \.self) { col in
                        let delay = Double(row + col) * 0.085
                        let flip = Ease.easeInOut(Ease.clip(t, 0.2 + delay, 0.7 + delay))
                        let isTarget = row == 2 && col >= 2 && col < 8
                        let noise = LaunchFilm.hash01(Double(row * 31 + col) * 7.7)
                        let ch = isTarget && flip > 0.5
                            ? String(target[col - 2])
                            : String(Array("XKWZVNTRGM")[Int(noise * 10) % 10])
                        Text(ch)
                            .font(.system(size: 120, weight: .black, design: .monospaced))
                            .foregroundStyle(isTarget && flip > 0.5 ? Color.black : .white.opacity(0.55))
                            .frame(width: 150, height: 170)
                            .background(isTarget && flip > 0.5 ? Color.white : Color.white.opacity(0.06))
                            .rotation3DEffect(.degrees(flip * 180 < 90 ? flip * 180 : flip * 180 - 180),
                                              axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                    }
                }
            }
        }
        .scaleEffect(1.12)
    }

    // 10 · knockout bars sliding opposite ways
    @ViewBuilder @MainActor
    static func knockout(_ t: Double) -> some View {
        let words = ["BOLD", "HEAVY", "BLACK", "LOUD", "RAW"]
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 14) {
                ForEach(0..<5, id: \.self) { i in
                    let enter = Ease.easeOutBack(Ease.clip(t, Double(i) * 0.09, 0.45 + Double(i) * 0.09))
                    let dir: CGFloat = i % 2 == 0 ? 1 : -1
                    HStack(spacing: 50) {
                        ForEach(0..<3, id: \.self) { _ in
                            Text(words[i])
                                .font(.system(size: 120, weight: .black)).fontWidth(.condensed)
                                .foregroundStyle(.white)
                        }
                    }
                    .fixedSize()
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .background(.black)
                    .offset(x: dir * (CGFloat(1 - enter) * 1900 + CGFloat(t) * 60))
                }
            }
        }
    }

    // 11 · odometer + tracking compress
    @ViewBuilder @MainActor
    static func odometer(_ t: Double) -> some View {
        let track = CGFloat(40 - Ease.easeOut(Ease.clip(t, 0.3, 1.6)) * 34)
        VStack(spacing: 30) {
            HStack(spacing: 6) {
                Kinetic.digitRoll(2, t: t, delay: 0.10, size: 230)
                Kinetic.digitRoll(3, t: t, delay: 0.22, size: 230)
                Kinetic.digitRoll(0, t: t, delay: 0.34, size: 230)
                Kinetic.digitRoll(4, t: t, delay: 0.46, size: 230)
            }
            Text("FRAMES OF PURE TYPE")
                .font(.system(size: 40, weight: .black)).fontWidth(.condensed)
                .tracking(track)
                .foregroundStyle(.white.opacity(0.85))
        }
    }

    // 12 · chaos explodes, order reassembles
    @ViewBuilder @MainActor
    static func chaosOrder(_ t: Double) -> some View {
        let out = Ease.easeIn(Ease.clip(t, 0.5, 0.95))
        let back = Ease.easeOutBack(Ease.clip(t, 1.1, 1.7))
        let word = t < 1.05 ? Array("CHAOS") : Array("ORDER")
        let spread = t < 1.05 ? out : 1 - back
        HStack(spacing: 10) {
            ForEach(0..<word.count, id: \.self) { i in
                let hx = LaunchFilm.hash01(Double(i) * 12.9 + 3) * 2 - 1
                let hy = LaunchFilm.hash01(Double(i) * 7.3 + 8) * 2 - 1
                let hr = LaunchFilm.hash01(Double(i) * 5.1) * 2 - 1
                Text(String(word[i]))
                    .font(.system(size: 280, weight: .black)).fontWidth(.condensed)
                    .foregroundStyle(.white)
                    .rotationEffect(.degrees(hr * 160 * spread))
                    .offset(x: CGFloat(hx * 800 * spread), y: CGFloat(hy * 500 * spread))
                    .opacity(1 - spread * 0.25)
            }
        }
    }

    // 13 · weight pump on the beat, strobing invert
    @ViewBuilder @MainActor
    static func weightPump(_ t: Double) -> some View {
        let beat = Int(t / 0.3)
        let heavy = beat % 2 == 0
        let inv = beat % 4 >= 2
        ZStack {
            (inv ? Color.white : Color.black).ignoresSafeArea()
            Text("PUMP")
                .font(.system(size: heavy ? 360 : 300, weight: heavy ? .black : .ultraLight))
                .fontWidth(heavy ? .condensed : .expanded)
                .foregroundStyle(inv ? .black : .white)
        }
    }

    // 14 · recap flashes — eight moves in 2.4s
    @ViewBuilder @MainActor
    static func recap(_ t: Double) -> some View {
        let words = ["BEAT.", "WAVE.", "GRID.", "SPLIT.", "SPIN.", "BOUNCE.", "CHAOS.", "TYPE."]
        let idx = min(7, Int(t / 0.3))
        let inv = idx % 2 == 1
        ZStack {
            (inv ? Color.white : Color.black).ignoresSafeArea()
            Text(words[idx])
                .font(.system(size: 290, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(inv ? .black : .white)
                .modifier(JustRenderIt.Slant(height: 290))
        }
    }

    // 15 · lockup
    @ViewBuilder @MainActor
    static func lockup(_ t: Double) -> some View {
        let p = Ease.easeOut(min(1, t / 0.2))
        let sweep = Ease.easeInOut(Ease.clip(t, 0.4, 0.9))
        let sub = Ease.easeOut(Ease.clip(t, 0.9, 1.4))
        VStack(spacing: 28) {
            Text("TYPE. IN. MOTION.")
                .font(.system(size: 170, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
                .modifier(JustRenderIt.Slant(height: 170))
                .scaleEffect(1.2 - 0.2 * p)
            Rectangle().fill(.white)
                .frame(width: CGFloat(sweep) * 980, height: 10)
                .rotationEffect(.degrees(-2.5))
            Text("swift-render · github.com/skyblanket/swift-render")
                .font(.system(size: 28, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .opacity(sub)
        }
    }

    @MainActor
    static func flash(_ t: Double) -> some View {
        let hit = chapters.map { max(0, 1 - abs(t - $0) / 0.06) }.max() ?? 0
        return Color.white.opacity(hit * 0.8).ignoresSafeArea()
    }
}
