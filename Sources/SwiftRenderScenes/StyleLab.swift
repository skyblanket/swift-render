import SwiftUI
import SwiftRender

/// StyleLab — one scene, sixteen renderers.
///
///   swift run swift-render check StyleLab
///   swift run swift-render render StyleLab --out out/stylelab.mp4
///
/// A single hero shot (a faceted gem turning over a sunset sea) is sampled once
/// per frame into a 320×180 `PixelGrid` and re-rendered by every `Stylize`
/// renderer: pixel art, 1-bit dither, Game Boy, ASCII, halftone, CMYK, mosaic,
/// LED wall, engraving, crosshatch, pointillism, bricks, cross-stitch, low-poly,
/// blueprint and thermal. 128 BPM, 22 bars:
///   0–1 the clean shot · 2–17 one style per bar (wipes on the bar line)
///   18–19 all sixteen live in a 4×4 wall · 20–21 lockup
public struct StyleLab: RenderScene {
    public static let defaultDuration: Double = 41.25
    public static var ownsPostFX: Bool { true }

    static let bpm: Double = 128
    static let beat: Double = 60.0 / bpm
    static let bar: Double = beat * 4
    static let styleStart: Double = bar * 2
    static let gridStart: Double = bar * 18
    static let lockStart: Double = bar * 20
    static let fineStart: Double = bar * 16
    static let W: Double = 1920, H: Double = 1080
    static let full = CGSize(width: 1920, height: 1080)
    static let volt = Color(red: 0.78, green: 1.0, blue: 0.10)

    static let looks: [(Stylize.Style, String, String)] = [
        (.pixel, "PIXEL ART", "96 × 54 · 16-colour palette · ordered dither"),
        (.dither, "1-BIT DITHER", "320 × 180 · Bayer 8×8 · two inks"),
        (.gameBoy, "GAME BOY", "160 × 90 · four greens"),
        (.ascii, "ASCII", "4,800 glyphs · density is tone"),
        (.halftone, "HALFTONE", "one ink · 45° dot screen"),
        (.cmyk, "CMYK PRINT", "four screens · 0° 15° 75° 45° · multiply"),
        (.mosaic, "MOSAIC", "2,304 glass tiles · grout"),
        (.led, "LED WALL", "5,184 diodes · additive glow"),
        (.engraving, "ENGRAVING", "62 swelling lines · one fill"),
        (.crosshatch, "CROSSHATCH", "five pen layers · one stroke"),
        (.pointillism, "POINTILLISM", "5,940 dabs of pure colour"),
        (.bricks, "BRICKS", "48 × 27 studs · 16 colours"),
        (.crossStitch, "CROSS-STITCH", "2,880 stitches on aida"),
        (.lowPoly, "LOW-POLY", "896 drifting facets"),
        (.blueprint, "BLUEPRINT", "960 × 540 Sobel edges · cyanotype"),
        (.thermal, "THERMAL", "960 × 540 · luminance → iron palette"),
    ]

    // MARK: - Soundtrack (through-composed; a new motif for every style)

    public static func soundtrack(duration: Double) -> Score? {
        var ev: [ScoreEvent] = []
        func at(_ b: Int, _ beats: Double = 0) -> Double { Double(b) * bar + beats * beat }
        let m = Note.midi

        // harmony — changes every two bars
        let harmony: [(Int, Int, Chord, Int)] = [
            (0, 2, .minor9(.a3), 45), (2, 2, .minor9(.a3), 45), (4, 2, .major7(.f3), 41), (6, 2, .add9(.c4), 48),
            (8, 2, .sus4(.g3), 43), (10, 2, .minor7(.d4), 50), (12, 2, .major7(.f3), 41), (14, 2, .minor9(.a3), 45),
            (16, 2, .dom7(.e3), 40), (18, 1, .minor7(.a3), 45), (19, 1, .sus4(.g3), 43), (20, 2, .major7(.c4), 48),
        ]
        func slot(_ b: Int) -> (Chord, Int) {
            for (b0, n, ch, root) in harmony where b >= b0 && b < b0 + n { return (ch, root) }
            return (.minor7(.a3), 45)
        }
        for (b0, n, ch, _) in harmony {
            ev += chordPad(ch, at: at(b0), duration: Double(n) * bar + 0.4, amp: 0.028)
        }

        // intro
        ev += boom(at: 0.25, amp: 0.45, duration: 1.8)
        ev += melody([(1, .e5), (2.5, .a5), (4, .c6), (5.5, .b5)], start: 0, bpm: bpm, amp: 0.09)
        every(beat, from: beat, to: bar * 2) { hat(at: $0, amp: 0.05) }.forEach { ev.append($0) }
        ev += boom(at: at(1), amp: 0.4, duration: 1.4); ev += clap(at: at(1), amp: 0.14)
        ev += swell(Chord.minor9(.a4), into: at(2), duration: bar, amp: 0.05)
        ev += boom(at: at(2), amp: 0.6, duration: 1.6); ev += crash(at: at(2), amp: 0.2)

        // bass — four patterns so no bar literally repeats under a held chord
        let bassA: [[(Double, Int, Double)]] = [
            [(0, 0, 1.5), (2.5, 12, 0.5), (3, 7, 1)],
            [(0, 0, 1), (1.5, 0, 0.5), (2, 7, 1), (3.5, 12, 0.5)],
        ]
        let bassB: [[(Double, Int, Double)]] = [
            [(0, 0, 0.45), (0.5, 0, 0.45), (1, 0, 0.45), (1.5, 12, 0.45), (2, 0, 0.45), (2.5, 0, 0.45), (3, 7, 0.45), (3.5, 12, 0.45)],
            [(0, 0, 0.45), (0.5, 12, 0.45), (1, 0, 0.45), (1.5, 7, 0.45), (2, 0, 0.45), (2.5, 12, 0.45), (3, 10, 0.45), (3.5, 7, 0.45)],
        ]
        for b in 2..<18 {
            let root: Int = slot(b).1
            let pattern = b < 10 ? bassA[b % 2] : bassB[b % 2]
            for (pos, semi, len) in pattern {
                ev += triBass(m(root + semi), at: at(b, pos), amp: 0.27, duration: len * beat)
            }
        }

        // drums — half-time, then four-on-the-floor, with a fill into the wall
        for b in 2..<18 {
            let driving: Bool = b >= 10
            for q in 0..<4 {
                if driving || q % 2 == 0 { ev += kick(at: at(b, Double(q)), amp: driving ? 0.62 : 0.5) }
                if q % 2 == 1 { ev += clap(at: at(b, Double(q)), amp: driving ? 0.2 : 0.13) }
            }
            for e in 0..<8 where h(b * 8 + e) > (driving ? 0.12 : 0.35) {
                let off: Bool = e % 2 == 1
                ev += hat(at: at(b, Double(e) * 0.5), amp: off ? 0.055 : 0.03, pan: off ? 0.3 : -0.3)
            }
        }
        for s in 0..<4 { ev += clap(at: at(17, 3 + Double(s) * 0.25), amp: 0.12 + 0.05 * Double(s)) }

        // one motif per style
        for i in 0..<16 {
            let b: Int = i + 2
            let ch: Chord = slot(b).0
            let up: Chord = ch.transposed(12)
            let t0: Double = at(b), t1: Double = at(b + 1)
            switch i {
            case 0: ev += arpeggio(up, from: t0, to: t1, step: beat / 4, amp: 0.05, pattern: .upDown, instrument: .chip)
            case 1: ev += arpeggio(ch, from: t0, to: t1, step: beat / 2, amp: 0.10, pattern: .up)
            case 2: ev += melody([(0, up.notes[0]), (0.5, up.notes[2]), (1, up.notes[1]), (2, up.notes[2]), (2.5, up.notes[0])],
                                 start: t0, bpm: bpm, amp: 0.07, instrument: .chip)
            case 3:
                for s in 0..<16 where h(300 + s) > 0.25 {
                    ev += chip(up.notes[s % 2 == 0 ? 0 : 2], at: t0 + Double(s) * beat / 4, amp: 0.035, duration: 0.06)
                }
            case 4: ev += melody([(0, up.notes[2]), (1.5, up.notes[1]), (3, up.notes[3])], start: t0, bpm: bpm, amp: 0.11)
            case 5:
                ev += strum(ch, at: t0, amp: 0.08); ev += strum(up, at: t0 + beat * 2.5, amp: 0.07)
                ev += bell(up.notes[2], at: t0 + beat * 3.5, amp: 0.08)
            case 6: ev += arpeggio(up, from: t0, to: t1, step: beat / 3, amp: 0.08, pattern: .down)
            case 7: ev += arpeggio(up.transposed(12), from: t0, to: t1, step: beat / 2, amp: 0.045, pattern: .up, instrument: .chip)
            case 8: ev += melody([(0, up.notes[2]), (1, up.notes[1]), (2, up.notes[0]), (3, ch.notes[2])], start: t0, bpm: bpm, amp: 0.10)
            case 9: ev += arpeggio(ch, from: t0, to: t1, step: beat / 4, amp: 0.07, pattern: .upDown)
            case 10:
                for s in 0..<11 {
                    let note: Note = Scale.majorPentatonic.degree(Int(h(500 + s) * 10), root: .f4)
                    ev += bell(note, at: t0 + h(600 + s) * bar * 0.92, amp: 0.06, duration: 1.0, pan: h(700 + s) * 1.6 - 0.8)
                }
            case 11: for q in 0..<4 { ev += strum(q % 2 == 0 ? ch : up, at: t0 + Double(q) * beat, amp: 0.065) }
            case 12:
                for e in 0..<8 { ev += pluck(up.notes[e % 2 == 0 ? 0 : 1], at: t0 + Double(e) * beat / 2, amp: 0.085, duration: 0.5) }
            case 13: ev += arpeggio(up, from: t0, to: t1, step: beat * 2 / 3, amp: 0.10, pattern: .up, instrument: .bell)
            case 14:
                for s in 0..<8 {
                    ev += chip(Scale.dorian.degree(s, root: .e4), at: t0 + Double(s) * beat / 2, amp: 0.055)
                }
            default:
                ev += arpeggio(up, from: t0, to: t1, step: beat / 4, amp: 0.075, pattern: .up)
                ev += swell(Chord.dom7(.e4), into: t1, duration: bar, amp: 0.045)
            }
        }

        // the wall: a rising pentatonic blip per tile, then drums return
        ev += boom(at: at(18), amp: 0.7, duration: 1.6); ev += crash(at: at(18), amp: 0.22)
        for i in 0..<16 {
            let note: Note = Scale.minorPentatonic.degree(i, root: .a3)
            ev += chip(note, at: at(18) + Double(i) * beat / 4, amp: 0.07, duration: 0.14, pan: Double(i % 4) * 0.4 - 0.6)
        }
        for q in 0..<4 { ev += kick(at: at(19, Double(q)), amp: 0.62) }
        for e in 0..<8 { ev += hat(at: at(19, Double(e) * 0.5), amp: 0.05, pan: e % 2 == 0 ? -0.3 : 0.3) }
        ev += melody([(0, .d5), (1, .g5), (2, .a5), (3, .d5)], start: at(19), bpm: bpm, amp: 0.09)
        ev += triBass(m(43), at: at(19), amp: 0.27, duration: bar * 0.95)
        ev += swell(Chord.sus4(.g4), into: at(20), duration: bar, amp: 0.055)

        // lockup
        ev += boom(at: at(20), amp: 1.0, duration: 2.4); ev += crash(at: at(20), amp: 0.3)
        ev += triBass(m(36), at: at(20), amp: 0.3, duration: bar * 1.6)
        ev += melody([(0, .c5), (0.5, .e5), (1, .g5), (1.5, .b5), (2.5, .c6), (4, .g5), (5, .e5)],
                     start: at(20), bpm: bpm, amp: 0.10)
        return Score(duration: duration) { ev }
    }

    static func h(_ n: Int) -> Double {
        let x: Double = sin(Double(n) * 12.9898 + 4.1414) * 43758.5453
        return x - floor(x)
    }

    // MARK: - Body

    @MainActor
    public static func body(at t: Double, duration: Double) -> some View {
        let shot = Canvas { ctx, size in drawShot(ctx, size, t) }
        let grid: PixelGrid = PixelGrid.sample(shot, size: full, cols: 320)
            ?? PixelGrid(cols: 1, rows: 1, data: [0, 0, 0, 255])
        // blueprint + thermal want real detail: give them a 960-wide snapshot once they are on screen
        let fine: PixelGrid = t >= fineStart ? (PixelGrid.sample(shot, size: full, cols: 960) ?? grid) : grid
        let fadeIn: Double = 1 - Ease.clip(t, 0, 0.35)
        let fadeOut: Double = Ease.easeIn(Ease.clip(t, duration - 0.9, duration))
        return ZStack {
            Color.black
            stage(t, grid, fine)
            Color.black.opacity(max(fadeIn, fadeOut))
        }
        .frame(width: W, height: H)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    @ViewBuilder @MainActor
    static func stage(_ t: Double, _ grid: PixelGrid, _ fine: PixelGrid) -> some View {
        if t < styleStart {
            ZStack {
                Canvas { ctx, size in drawShot(ctx, size, t) }
                introType(t)
            }
        } else if t < gridStart {
            styleRun(t, grid, fine)
        } else {
            wall(t, grid, fine)
        }
    }

    // MARK: intro

    @ViewBuilder @MainActor
    static func introType(_ t: Double) -> some View {
        let second: Bool = t >= bar
        let local: Double = second ? t - bar : t - 0.9
        let pop: Double = Ease.spring(max(0, local), from: 1.4, to: 1.0, response: 0.3, dampingFraction: 0.62)
        let leave: Double = Ease.easeIn(Ease.clip(t, styleStart - 0.2, styleStart))
        let tag: Double = Ease.easeOut(Ease.clip(t, 0.3, 0.7)) * (1 - leave)
        ZStack {
            Text("THE SHOT  ·  one SwiftUI Canvas  ·  sampled to 320 × 180 every frame")
                .font(.system(size: 25, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 22).padding(.vertical, 12)
                .background(Capsule().fill(Color.black.opacity(0.72)))
                .opacity(tag)
                .frame(width: W, height: H, alignment: .topLeading)
                .offset(x: 56, y: 56)
            HStack(spacing: 34) {
                if second {
                    Text("SIXTEEN").foregroundStyle(volt)
                    Text("RENDERERS.").foregroundStyle(.white)
                } else {
                    Text("ONE SCENE.").foregroundStyle(.white)
                }
            }
            .font(.system(size: second ? 215 : 250, weight: .black)).fontWidth(.condensed)
            .shadow(color: .black.opacity(0.6), radius: 24, y: 6)
            .scaleEffect(pop)
            .opacity(local >= 0 ? 1 - leave : 0)
            .position(x: W / 2, y: H * 0.835)
        }
        .frame(width: W, height: H)
    }

    // MARK: one style per bar

    @MainActor
    static func layer(_ index: Int, _ grid: PixelGrid, _ fine: PixelGrid, _ t: Double) -> AnyView {
        if index < 0 { return AnyView(Canvas { ctx, size in drawShot(ctx, size, t) }.frame(width: W, height: H)) }
        return AnyView(Stylize.view(looks[index].0, grid: index >= 14 ? fine : grid, size: full, density: 1, t: t))
    }

    @ViewBuilder @MainActor
    static func styleRun(_ t: Double, _ grid: PixelGrid, _ fine: PixelGrid) -> some View {
        let i: Int = min(15, Int((t - styleStart) / bar))
        let local: Double = t - styleStart - Double(i) * bar
        let p: Double = Ease.easeInOut(Ease.clip(local, 0, 0.42))
        let dir: Int = i % 4
        ZStack(alignment: .topLeading) {
            if p < 1 { layer(i - 1, grid, fine, t) }
            layer(i, grid, fine, t).mask(alignment: .topLeading) { wipeMask(dir, p) }
            if p < 1 { wipeEdge(dir, p) }
            label(i, local)
            pips(i)
        }
        .frame(width: W, height: H)
    }

    @ViewBuilder @MainActor
    static func wipeMask(_ dir: Int, _ p: Double) -> some View {
        switch dir {
        case 0: Rectangle().frame(width: W * p, height: H)
        case 1: Rectangle().frame(width: W, height: H * p)
        case 2: Rectangle().frame(width: W * p, height: H).offset(x: W * (1 - p))
        default: Rectangle().frame(width: W, height: H * p).offset(y: H * (1 - p))
        }
    }

    @ViewBuilder @MainActor
    static func wipeEdge(_ dir: Int, _ p: Double) -> some View {
        let vertical: Bool = dir % 2 == 0
        let along: Double = dir < 2 ? p : 1 - p
        Rectangle().fill(.white)
            .frame(width: vertical ? 8 : W, height: vertical ? H : 8)
            .shadow(color: volt, radius: 18)
            .position(x: vertical ? W * along : W / 2, y: vertical ? H / 2 : H * along)
    }

    @ViewBuilder @MainActor
    static func label(_ i: Int, _ local: Double) -> some View {
        let rise: Double = Ease.spring(local, from: 46, to: 0, response: 0.36, dampingFraction: 0.74)
        let vis: Double = Ease.easeOut(Ease.clip(local, 0.04, 0.26))
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%02d / 16", i + 1))
                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                .foregroundStyle(volt)
            Text(looks[i].1)
                .font(.system(size: 118, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
            Text(looks[i].2)
                .font(.system(size: 25, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
        }
        .padding(.horizontal, 36).padding(.vertical, 22)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.black.opacity(0.84)))
        .offset(y: rise)
        .opacity(vis)
        .frame(width: W, height: H, alignment: .bottomLeading)
        .offset(x: 56, y: -56)
    }

    @ViewBuilder @MainActor
    static func pips(_ i: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(0..<16, id: \.self) { n in
                RoundedRectangle(cornerRadius: 4)
                    .fill(n == i ? volt : Color.white.opacity(n < i ? 0.85 : 0.22))
                    .frame(width: n == i ? 34 : 14, height: 14)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .background(Capsule().fill(Color.black.opacity(0.84)))
        .frame(width: W, height: H, alignment: .topTrailing)
        .offset(x: -56, y: 56)
    }

    // MARK: the wall — all sixteen, live

    @ViewBuilder @MainActor
    static func wall(_ t: Double, _ grid: PixelGrid, _ fine: PixelGrid) -> some View {
        let local: Double = t - gridStart
        let dim: Double = Ease.easeOut(Ease.clip(t, lockStart, lockStart + 0.45))
        let drift: Double = 1 + 0.025 * Ease.clip(t, gridStart + bar, lockStart + bar * 2)
        ZStack {
            Color(red: 0.03, green: 0.03, blue: 0.04)
            ForEach(0..<16, id: \.self) { i in
                let born: Double = Double(i) * beat / 4
                if local >= born {
                    let p: Double = Ease.spring(local - born, from: 0, to: 1, response: 0.3, dampingFraction: 0.68)
                    tile(i, i >= 14 ? fine : grid, t)
                        .scaleEffect(0.55 + 0.45 * p)
                        .opacity(min(1, p * 2.2))
                        .position(x: (Double(i % 4) + 0.5) * 480, y: (Double(i / 4) + 0.5) * 270)
                }
            }
            .scaleEffect(drift)
            Color.black.opacity(0.80 * dim)
            if t >= lockStart { lockup(t - lockStart) }
        }
        .frame(width: W, height: H)
    }

    @ViewBuilder @MainActor
    static func tile(_ i: Int, _ grid: PixelGrid, _ t: Double) -> some View {
        let size = CGSize(width: 464, height: 254)
        Stylize.view(looks[i].0, grid: grid, size: size, density: 0.5, t: t)
            .overlay(alignment: .bottomLeading) {
                Text(looks[i].1)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.84)))
                    .padding(9)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder @MainActor
    static func lockup(_ local: Double) -> some View {
        let pop: Double = Ease.spring(local, from: 1.3, to: 1.0, response: 0.4, dampingFraction: 0.62)
        let sub: Double = Ease.easeOut(Ease.clip(local, 0.4, 0.85))
        let foot: Double = Ease.easeOut(Ease.clip(local, 0.9, 1.3))
        VStack(spacing: 22) {
            Text("swift-render")
                .font(.system(size: 220, weight: .black)).fontWidth(.condensed)
                .foregroundStyle(.white)
                .scaleEffect(pop)
            Text("one scene  ·  sixteen renderers  ·  pure Swift")
                .font(.system(size: 38, weight: .medium, design: .monospaced))
                .foregroundStyle(volt)
                .opacity(sub).offset(y: (1 - sub) * 14)
            Text("github.com/skyblanket/swift-render")
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .opacity(foot)
                .padding(.top, 18)
        }
    }

    // MARK: - The shot: a faceted gem turning over a sunset sea

    static func g(_ r: Double, _ gr: Double, _ b: Double, _ a: Double = 1) -> Color {
        Color(red: r, green: gr, blue: b).opacity(a)
    }

    static func drawShot(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = Double(size.width), hgt = Double(size.height)
        let u: Double = w / 1920
        let hz: Double = hgt * 0.64
        let sunX: Double = 1330 * u, sunY: Double = 500 * u, sunR: Double = 250 * u

        // sky
        let sky = Gradient(stops: [
            .init(color: g(0.10, 0.06, 0.34), location: 0), .init(color: g(0.50, 0.14, 0.56), location: 0.45),
            .init(color: g(0.96, 0.35, 0.42), location: 0.82), .init(color: g(1.0, 0.66, 0.30), location: 1),
        ])
        ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: hz + 2)),
                 with: .linearGradient(sky, startPoint: .zero, endPoint: CGPoint(x: 0, y: hz)))
        for i in 0..<70 {
            let x: Double = h(i) * w, y: Double = h(i + 100) * hz * 0.55
            let tw: Double = 0.45 + 0.55 * sin(t * 2.6 + Double(i))
            let sz: Double = (3 + 3 * h(i + 200)) * u
            ctx.fill(Path(CGRect(x: x, y: y, width: sz, height: sz)), with: .color(g(1, 1, 1, max(0.15, tw))))
        }

        // sun: glow, disc, drifting stripes
        ctx.fill(Path(ellipseIn: CGRect(x: sunX - sunR * 2.1, y: sunY - sunR * 2.1, width: sunR * 4.2, height: sunR * 4.2)),
                 with: .radialGradient(Gradient(colors: [g(1, 0.6, 0.3, 0.55), g(1, 0.4, 0.4, 0)]),
                                       center: CGPoint(x: sunX, y: sunY), startRadius: sunR * 0.8, endRadius: sunR * 2.1))
        var disc = ctx
        disc.clip(to: Path(ellipseIn: CGRect(x: sunX - sunR, y: sunY - sunR, width: sunR * 2, height: sunR * 2)))
        disc.fill(Path(CGRect(x: sunX - sunR, y: sunY - sunR, width: sunR * 2, height: sunR * 2)),
                  with: .linearGradient(Gradient(colors: [g(1, 0.95, 0.40), g(1, 0.55, 0.25), g(1, 0.22, 0.50)]),
                                        startPoint: CGPoint(x: 0, y: sunY - sunR), endPoint: CGPoint(x: 0, y: sunY + sunR)))
        let drift: Double = (t * 0.22).truncatingRemainder(dividingBy: 1)
        for n in 0..<7 {
            let f: Double = (Double(n) + drift) / 7
            let y: Double = sunY - sunR * 0.05 + f * sunR * 1.05
            disc.fill(Path(CGRect(x: sunX - sunR, y: y, width: sunR * 2, height: (5 + 30 * f) * u)),
                      with: .color(g(0.86, 0.24, 0.44)))
        }

        // clouds
        for n in 0..<3 {
            let cw: Double = (420 + 160 * h(n + 40)) * u
            let span: Double = w + cw * 2
            let cx: Double = (h(n + 50) * span + t * (14 + 8 * Double(n)) * u).truncatingRemainder(dividingBy: span) - cw
            let cy: Double = (230 + Double(n) * 95) * u
            ctx.fill(Path(roundedRect: CGRect(x: cx, y: cy, width: cw, height: 34 * u), cornerRadius: 17 * u),
                     with: .color(g(1.0, 0.62, 0.68, 0.55)))
            ctx.fill(Path(roundedRect: CGRect(x: cx + cw * 0.2, y: cy + 30 * u, width: cw * 0.6, height: 22 * u), cornerRadius: 11 * u),
                     with: .color(g(1.0, 0.62, 0.68, 0.40)))
        }

        // mountains
        ridge(ctx, w, hz, u, base: 110, amp: 80, seed: 0.0, color: g(0.33, 0.11, 0.42))
        ridge(ctx, w, hz, u, base: 50, amp: 55, seed: 2.2, color: g(0.13, 0.05, 0.24))

        // sea + reflections
        ctx.fill(Path(CGRect(x: 0, y: hz, width: w, height: hgt - hz)),
                 with: .linearGradient(Gradient(colors: [g(0.20, 0.07, 0.34), g(0.03, 0.02, 0.11)]),
                                       startPoint: CGPoint(x: 0, y: hz), endPoint: CGPoint(x: 0, y: hgt)))
        ctx.fill(Path(CGRect(x: 0, y: hz - 2 * u, width: w, height: 5 * u)), with: .color(g(1, 0.75, 0.5, 0.8)))
        for n in 0..<13 {
            let y: Double = hz + (16 + Double(n) * 28) * u
            let wob: Double = 0.62 + 0.38 * sin(t * 2.2 + Double(n) * 1.3)
            let rw: Double = (90 + Double(n) * 34) * u * wob
            let rx: Double = sunX + sin(t * 1.1 + Double(n)) * 14 * u
            ctx.fill(Path(roundedRect: CGRect(x: rx - rw / 2, y: y, width: rw, height: 10 * u), cornerRadius: 5 * u),
                     with: .color(g(1.0, 0.55, 0.35, 0.9 - Double(n) * 0.045)))
        }
        let gemX: Double = 790 * u, gemY: Double = (425 + sin(t * 1.2) * 14) * u, gemR: Double = 265 * u
        for n in 0..<7 {
            let y: Double = hz + (30 + Double(n) * 44) * u
            let rw: Double = (230 - Double(n) * 22) * u * (0.6 + 0.4 * sin(t * 2.6 + Double(n) * 0.9))
            ctx.fill(Path(roundedRect: CGRect(x: gemX - rw / 2, y: y, width: rw, height: 9 * u), cornerRadius: 4.5 * u),
                     with: .color(g(0.35, 0.85, 1.0, 0.75 - Double(n) * 0.08)))
        }

        // orbiting orbs (behind), gem, orbs (in front)
        orbs(ctx, gemX, gemY, u, t, front: false)
        gem(ctx, gemX, gemY, gemR, t)
        orbs(ctx, gemX, gemY, u, t, front: true)
    }

    static func ridge(_ ctx: GraphicsContext, _ w: Double, _ hz: Double, _ u: Double,
                      base: Double, amp: Double, seed: Double, color: Color) {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: hz + 2))
        var x: Double = 0
        while x <= w + 8 {
            let k: Double = x / u
            let a: Double = sin(k * 0.0042 + seed) * 0.55 + sin(k * 0.011 + seed * 2.3) * 0.3 + sin(k * 0.027 + seed) * 0.15
            let y: Double = hz - (base + amp * a) * u
            p.addLine(to: CGPoint(x: x, y: min(hz + 2, y)))
            x += 8
        }
        p.addLine(to: CGPoint(x: w, y: hz + 2))
        p.closeSubpath()
        ctx.fill(p, with: .color(color))
    }

    static func orbs(_ ctx: GraphicsContext, _ cx: Double, _ cy: Double, _ u: Double, _ t: Double, front: Bool) {
        let specs: [(Double, Double, Color, Color)] = [
            (0, 50, g(1.0, 0.95, 0.55), g(0.95, 0.35, 0.15)),
            (Double.pi, 36, g(1.0, 0.85, 0.95), g(0.75, 0.15, 0.55)),
        ]
        for (phase, radius, light, dark) in specs {
            let a: Double = t * 1.35 + phase
            let z: Double = sin(a)
            if (z > 0) != front { continue }
            let x: Double = cx + cos(a) * 440 * u
            let y: Double = cy + sin(a) * 95 * u + 10 * u
            let r: Double = radius * u * (1 + 0.16 * z)
            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect),
                     with: .radialGradient(Gradient(colors: [light, dark]),
                                           center: CGPoint(x: x + r * 0.32, y: y - r * 0.36), startRadius: 0, endRadius: r * 1.5))
        }
    }

    // icosahedron
    static let icoV: [(Double, Double, Double)] = {
        let p: Double = (1 + 5.0.squareRoot()) / 2
        let raw: [(Double, Double, Double)] = [
            (-1, p, 0), (1, p, 0), (-1, -p, 0), (1, -p, 0), (0, -1, p), (0, 1, p),
            (0, -1, -p), (0, 1, -p), (p, 0, -1), (p, 0, 1), (-p, 0, -1), (-p, 0, 1),
        ]
        let len: Double = (1 + p * p).squareRoot()
        return raw.map { ($0.0 / len, $0.1 / len, $0.2 / len) }
    }()
    static let icoF: [(Int, Int, Int)] = [
        (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
        (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
    ]

    static func gem(_ ctx: GraphicsContext, _ cx: Double, _ cy: Double, _ radius: Double, _ t: Double) {
        let ay: Double = t * 0.8, ax: Double = 0.5 + 0.18 * sin(t * 0.5)
        let cay: Double = cos(ay), say: Double = sin(ay), cax: Double = cos(ax), sax: Double = sin(ax)
        let v: [(Double, Double, Double)] = icoV.map { p in
            let x1: Double = p.0 * cay + p.2 * say
            let z1: Double = -p.0 * say + p.2 * cay
            let y2: Double = p.1 * cax - z1 * sax
            let z2: Double = p.1 * sax + z1 * cax
            return (x1, y2, z2)
        }
        func project(_ p: (Double, Double, Double)) -> CGPoint {
            let k: Double = radius / (1 - p.2 * 0.14)
            return CGPoint(x: cx + p.0 * k, y: cy + p.1 * k)
        }
        let lightLen: Double = (0.5 * 0.5 + 0.6 * 0.6 + 0.62 * 0.62).squareRoot()
        let lx: Double = 0.5 / lightLen, ly: Double = -0.6 / lightLen, lz: Double = 0.62 / lightLen
        for (n, f) in icoF.enumerated() {
            let a = v[f.0], b = v[f.1], c = v[f.2]
            var nx: Double = (a.0 + b.0 + c.0) / 3, ny: Double = (a.1 + b.1 + c.1) / 3, nz: Double = (a.2 + b.2 + c.2) / 3
            let len: Double = (nx * nx + ny * ny + nz * nz).squareRoot()
            nx /= len; ny /= len; nz /= len
            if nz <= 0 { continue }
            let lit: Double = max(0, nx * lx + ny * ly + nz * lz)
            let warm: Double = max(0, nx) * (1 - lit) * 0.45
            let tint: Double = (h(n + 900) - 0.5) * 0.08
            var r: Double, gr: Double, bl: Double
            if lit < 0.55 {
                let f0: Double = lit / 0.55
                r = 0.02 + (0.05 - 0.02) * f0; gr = 0.03 + (0.62 - 0.03) * f0; bl = 0.16 + (0.92 - 0.16) * f0
            } else {
                let f1: Double = (lit - 0.55) / 0.45
                r = 0.05 + (0.88 - 0.05) * f1; gr = 0.62 + (1.0 - 0.62) * f1; bl = 0.92 + (1.0 - 0.92) * f1
            }
            r += warm * 0.95 + tint; gr += warm * 0.25 + tint; bl += warm * 0.35
            var face = Path()
            face.move(to: project(a)); face.addLine(to: project(b)); face.addLine(to: project(c)); face.closeSubpath()
            ctx.fill(face, with: .color(g(min(1, r), min(1, gr), min(1, bl))))
            ctx.stroke(face, with: .color(g(1, 1, 1, 0.38)), style: StrokeStyle(lineWidth: radius * 0.011, lineJoin: .round))
        }
    }
}
