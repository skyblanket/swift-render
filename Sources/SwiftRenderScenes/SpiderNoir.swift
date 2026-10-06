import SwiftUI
import SwiftRender

/// SpiderNoir — a 21-second noir short in two colours.
///
///   swift run swift-render render SpiderNoir --out out/spider_noir.mp4
///
/// The scene is authored in grayscale (gradients, rain, a procedurally walked
/// spider with two-bone IK legs, a web that spins itself) and the whole frame is
/// pushed through `Dither.render` (Components/Dither.swift): an 8x8 Bayer
/// threshold to charcoal + cream. Subtitles sit crisp on top, in the letterbox.
///
/// 80 BPM, seven 3-second bars:
///   0 city + rain   1 descent   2 close-up   3 web spins   4 the catch
///   5 venetian blinds   6 title
public struct SpiderNoir: RenderScene {
    public static let defaultDuration: Double = 21.0
    public static var ownsPostFX: Bool { true }

    static let beat = 0.75
    static let bar = 3.0
    static let W = 1920.0, H = 1080.0
    static let barH = 120.0

    static let charcoal = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let cream = Color(red: 0.94, green: 0.90, blue: 0.80)

    static let lines = [
        "The city never sleeps. Neither do I.",
        "Eight legs. One thread.",
        "I don't chase trouble. I wait for it.",
        "A web is just a promise. Spun slowly.",
        "Every tug tells a story.",
        "They call me the Weaver. I call it rent.",
        "a swift-render picture",
    ]

    static func g(_ v: Double, _ a: Double = 1) -> Color { Color(white: v).opacity(a) }
    static func h(_ n: Int) -> Double {
        let x = sin(Double(n) * 12.9898 + 4.1414) * 43758.5453
        return x - floor(x)
    }

    // MARK: soundtrack — slow noir jazz: walking bass, brushes, vibes, rain

    public static func soundtrack(duration: Double) -> Score? {
        var ev: [ScoreEvent] = []
        func at(_ b: Int, _ beats: Double) -> Double { Double(b) * bar + beats * beat }
        let m = Note.midi

        let chords: [[Int]] = [
            [50, 53, 57, 64], [55, 58, 62, 65], [55, 61, 64, 67], [50, 53, 57, 62],
            [53, 58, 62, 65], [55, 61, 64, 67], [50, 53, 57, 64],
        ]
        for (b, tones) in chords.enumerated() {
            for (i, n) in tones.enumerated() {
                ev += pad(m(n), at: at(b, 0), amp: 0.03, duration: bar + 0.5, pan: Double(i - 1) * 0.3)
            }
        }

        let walk: [[Int]] = [
            [38, 41, 45, 42], [43, 46, 50, 44], [45, 49, 52, 48], [38, 41, 45, 43],
            [46, 50, 53, 50], [45, 49, 52, 39],
        ]
        for (b, notes) in walk.enumerated() {
            for (i, n) in notes.enumerated() {
                ev += triBass(m(n), at: at(b, Double(i)), amp: 0.3, duration: beat * 0.88)
                ev += triBass(m(n + 12), at: at(b, Double(i)), amp: 0.05, duration: beat * 0.8)
            }
        }
        ev += triBass(m(38), at: at(6, 0), amp: 0.3, duration: 2.8)

        // brushes: swung ride, feathered kick, soft snare
        for b in 0..<6 {
            for x in [0.0, 1.0, 1.667, 2.0, 3.0, 3.667] {
                ev += hat(at: at(b, x), amp: 0.045, pan: 0.3)
            }
            for x in [1.0, 3.0] { ev += clap(at: at(b, x), amp: 0.06) }
            if b >= 1 { for x in [0.0, 2.0] { ev += kick(at: at(b, x), amp: 0.2) } }
        }
        // rain patter
        for i in 0..<130 { ev += hat(at: h(i + 500) * duration, amp: 0.012 + 0.012 * h(i + 900), pan: (h(i + 300) - 0.5) * 1.6) }
        ev += boom(at: 0, amp: 0.22, duration: 2.4)

        // piano comping (voicing = chord tones, staggered)
        let comp: [Int: [Double]] = [1: [1.667], 2: [1.0, 2.667], 3: [1.667, 3.333], 4: [0.667, 2.0, 3.333], 5: [1.0, 2.667]]
        for (b, times) in comp {
            for x in times {
                for (i, n) in chords[b].dropFirst().enumerated() {
                    ev += pluck(m(n + 12), at: at(b, x) + Double(i) * 0.012, amp: 0.07, duration: 0.7, pan: Double(i - 1) * 0.25)
                }
            }
        }

        // vibes melody
        let tune: [Int: [(Double, Int)]] = [
            0: [(1.5, 74), (2.5, 69)],
            1: [(0, 70), (1, 74), (2.667, 72)],
            2: [(0, 73), (1.667, 76), (3, 79)],
            3: [(0, 74), (1.5, 77), (2.5, 76), (3.333, 74)],
            4: [(0, 77), (1, 81), (2, 77), (3, 74)],
            5: [(0, 73), (1, 76), (2, 79), (3, 82)],
            6: [(0, 74), (0.667, 77), (1.333, 81), (2, 86)],
        ]
        for (b, notes) in tune {
            for (x, n) in notes { ev += bell(m(n), at: at(b, x), amp: 0.1, duration: b == 6 ? 2.4 : 1.6, pan: Double(n % 7 - 3) * 0.12) }
        }

        // moments: descent, landing, the catch, the title
        ev += pluck(m(45), at: at(2, 0), amp: 0.14)
        ev += pluck(m(40), at: at(4, 0.8), amp: 0.2); ev += boom(at: at(4, 0.8), amp: 0.35, duration: 0.9)
        ev += crash(at: at(4, 1.6), amp: 0.1); ev += bell(m(86), at: at(4, 1.6), amp: 0.09)
        ev += boom(at: at(6, 0), amp: 0.5, duration: 2.0); ev += crash(at: at(6, 0), amp: 0.15)

        return Score(duration: duration) { ev }
    }

    // MARK: body

    @MainActor
    public static func body(at t: Double, duration: Double) -> some View {
        let cuts = (1...6).map { Double($0) * bar }
        let dip = max(cuts.map { max(0, 1 - abs(t - $0) / 0.14) }.max() ?? 0,
                      1 - Ease.clip(t, 0, 0.5), Ease.clip(t, duration - 0.9, duration))
        let flick = 0.03 + 0.05 * h(Int(t * 24))

        let frame = ZStack {
            Color.black
            Timeline(t) {
                Clip(bar) { l in city(l) }
                Clip(bar) { l in descent(l) }
                Clip(bar) { l in closeup(l) }
                Clip(bar) { l in spin(l) }
                Clip(bar) { l in thecatch(l) }
                Clip(bar) { l in blinds(l) }
                Clip(bar) { l in title(l) }
            }
            Rectangle().fill(RadialGradient(colors: [.clear, .black.opacity(0.7)],
                                            center: .center, startRadius: 560, endRadius: 1300))
            grain(t)
            Color.black.opacity(flick)
            Color.black.opacity(dip)
            VStack { Color.black.frame(height: barH); Spacer(); Color.black.frame(height: barH) }
        }

        return ZStack {
            Dither.render(frame, size: CGSize(width: W, height: H), cell: 3,
                          palette: [charcoal, cream], contrast: 1.3, bias: 0.07)
            subtitles(t)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(charcoal)
    }

    // MARK: overlays

    @MainActor static func grain(_ t: Double) -> some View {
        Canvas { ctx, size in
            let f = Int(t * 24)
            for i in 0..<70 {
                let x = h(f * 131 + i) * size.width, y = h(f * 71 + i + 40) * size.height
                ctx.fill(Path(CGRect(x: x, y: y, width: 3, height: 3)), with: .color(g(0.9, 0.55)))
            }
            if h(f + 7) > 0.8 {
                let x = h(f + 11) * size.width
                ctx.fill(Path(CGRect(x: x, y: 0, width: 2, height: size.height)), with: .color(g(0.9, 0.35)))
            }
        }
        .allowsHitTesting(false)
    }

    @MainActor static func subtitles(_ t: Double) -> some View {
        let b = min(6, Int(t / bar))
        let lt = t - Double(b) * bar
        let line = lines[b]
        let typed = Int(Ease.clip(lt, 0.3, 1.7) * Double(line.count))
        let out = 1 - Ease.clip(lt, bar - 0.35, bar - 0.1)
        let isTitle = b == 6
        return VStack {
            Spacer()
            Text(String(line.prefix(isTitle ? line.count : typed)))
                .font(isTitle ? .system(size: 34, weight: .medium, design: .monospaced)
                              : .system(size: 54, weight: .medium, design: .serif).italic())
                .tracking(isTitle ? 8 : 0)
                .foregroundStyle(cream)
                .opacity(isTitle ? Ease.easeOut(Ease.clip(lt, 1.2, 1.8)) * (1 - Ease.clip(t, 20.1, 20.9)) : out)
                .frame(height: barH)
        }
    }

    // MARK: shared drawing

    static func rain(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, count: Int, alpha: Double = 0.5) {
        for i in 0..<count {
            let x = h(i) * size.width * 1.15 - 100
            let sp = 1500 + h(i + 60) * 700
            let y = (h(i + 120) * (size.height + 300) + t * sp).truncatingRemainder(dividingBy: size.height + 300) - 150
            let len = 50 + h(i + 200) * 70
            var p = Path(); p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x - len * 0.16, y: y + len))
            ctx.stroke(p, with: .color(g(1.0, alpha * (0.5 + 0.5 * h(i + 300)))), lineWidth: 4)
        }
    }

    static func dust(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double, count: Int) {
        for i in 0..<count {
            let x = (h(i + 700) * size.width + sin(t * 0.4 + Double(i)) * 30 + t * 14).truncatingRemainder(dividingBy: size.width)
            let y = (h(i + 800) * size.height + t * (12 + h(i) * 18)).truncatingRemainder(dividingBy: size.height)
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 4, height: 4)), with: .color(g(0.95, 0.5 + 0.4 * h(i + 900))))
        }
    }

    static func pool(_ ctx: GraphicsContext, _ c: CGPoint, r: Double, v: Double = 0.95) {
        ctx.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)),
                 with: .radialGradient(Gradient(stops: [.init(color: g(v), location: 0), .init(color: g(v * 0.55), location: 0.45), .init(color: g(0), location: 1)]),
                                       center: c, startRadius: 0, endRadius: r))
    }

    // MARK: spider

    static func spider(_ ctx: GraphicsContext, _ c: CGPoint, ang: Double, s: Double, ph: Double,
                       fill: Color, mark: Color) {
        let f = CGPoint(x: cos(ang), y: sin(ang)), r = CGPoint(x: -sin(ang), y: cos(ang))
        func P(_ fw: Double, _ lat: Double) -> CGPoint {
            CGPoint(x: c.x + (f.x * fw + r.x * lat) * s, y: c.y + (f.y * fw + r.y * lat) * s)
        }
        let hipFw: [Double] = [32, 18, 6, -8]
        let rest: [(Double, Double)] = [(105, 100), (52, 128), (-10, 135), (-72, 118)]
        let L1 = 84.0 * s, L2 = 100.0 * s
        for side in [-1.0, 1.0] {
            for k in 0..<4 {
                let grp = Double((k + (side > 0 ? 1 : 0)) % 2) * 0.5
                let a = 2 * Double.pi * (ph + grp)
                let step = sin(a) * 24, lift = max(0, cos(a)) * 14
                var foot = P(rest[k].0 + step, side * (rest[k].1 - lift))
                let hip = P(hipFw[k], side * 14)
                var dx = foot.x - hip.x, dy = foot.y - hip.y
                var d = hypot(dx, dy)
                let maxD = (L1 + L2) * 0.985
                if d > maxD { foot = CGPoint(x: hip.x + dx / d * maxD, y: hip.y + dy / d * maxD); dx = foot.x - hip.x; dy = foot.y - hip.y; d = maxD }
                if d < 1 { continue }
                let a1 = (d * d + L1 * L1 - L2 * L2) / (2 * d)
                let hh = max(0, L1 * L1 - a1 * a1).squareRoot()
                let ux = dx / d, uy = dy / d
                let k1 = CGPoint(x: hip.x + ux * a1 - uy * hh, y: hip.y + uy * a1 + ux * hh)
                let k2 = CGPoint(x: hip.x + ux * a1 + uy * hh, y: hip.y + uy * a1 - ux * hh)
                let knee = hypot(k1.x - c.x, k1.y - c.y) > hypot(k2.x - c.x, k2.y - c.y) ? k1 : k2
                var path = Path(); path.move(to: hip); path.addLine(to: knee); path.addLine(to: foot)
                ctx.stroke(path, with: .color(fill), style: StrokeStyle(lineWidth: 7 * s, lineCap: .round, lineJoin: .round))
            }
        }
        var cc = ctx
        cc.translateBy(x: c.x, y: c.y); cc.rotate(by: .radians(ang)); cc.scaleBy(x: s, y: s)
        cc.fill(Path(ellipseIn: CGRect(x: -90, y: -36, width: 92, height: 72)), with: .color(fill))
        cc.fill(Path(ellipseIn: CGRect(x: -12, y: -21, width: 52, height: 42)), with: .color(fill))
        cc.fill(Path(ellipseIn: CGRect(x: 30, y: -12, width: 24, height: 24)), with: .color(fill))
        var hg = Path()
        hg.move(to: CGPoint(x: -72, y: -13)); hg.addLine(to: CGPoint(x: -72, y: 13)); hg.addLine(to: CGPoint(x: -44, y: 0)); hg.closeSubpath()
        hg.move(to: CGPoint(x: -16, y: -13)); hg.addLine(to: CGPoint(x: -16, y: 13)); hg.addLine(to: CGPoint(x: -44, y: 0)); hg.closeSubpath()
        cc.fill(hg, with: .color(mark))
        for e in [-5.0, 5.0] { cc.fill(Path(ellipseIn: CGRect(x: 46, y: e - 2.5, width: 5, height: 5)), with: .color(mark)) }
    }

    // MARK: web

    static let webN = 12, webTurns = 6

    static func webCrossings(_ c: CGPoint, _ R: Double) -> [CGPoint] {
        var pts: [CGPoint] = []
        for m in 0..<(webN * webTurns) {
            let i = m % webN
            let a = 2 * Double.pi * Double(i) / Double(webN) + (h(i) - 0.5) * 0.12
            let len = 0.92 + 0.1 * h(i + 30)
            let rr = (40 + (R - 40) * Double(m + 1) / Double(webN * webTurns)) * len
            pts.append(CGPoint(x: c.x + cos(a) * rr, y: c.y + sin(a) * rr))
        }
        return pts
    }

    static func drawWeb(_ ctx: GraphicsContext, _ c: CGPoint, _ R: Double, p: Double,
                        warp: (CGPoint) -> CGPoint = { $0 }, color: Color = g(0.95)) {
        func seg(_ path: inout Path, _ a: CGPoint, _ b: CGPoint, n: Int, first: Bool) {
            for s in 0...n {
                let u = Double(s) / Double(n)
                let q = warp(CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u))
                if s == 0 && first { path.move(to: q) } else { path.addLine(to: q) }
            }
        }
        // spokes
        for i in 0..<webN {
            let a = 2 * Double.pi * Double(i) / Double(webN) + (h(i) - 0.5) * 0.12
            let len = R * (0.92 + 0.1 * h(i + 30))
            let sp = max(0, min(1, (p / 0.3) * 1.6 - Double(i) / Double(webN) * 0.6))
            if sp <= 0 { continue }
            let end = CGPoint(x: c.x + cos(a) * len * sp, y: c.y + sin(a) * len * sp)
            var path = Path(); seg(&path, c, end, n: 12, first: true)
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 6, lineCap: .round))
        }
        // spiral
        let pts = webCrossings(c, R)
        let sp = max(0, min(1, (p - 0.25) / 0.75))
        let count = sp * Double(pts.count)
        let whole = Int(count)
        if whole >= 1 {
            var path = Path()
            for m in 1..<(min(whole, pts.count)) { seg(&path, pts[m - 1], pts[m], n: 5, first: m == 1) }
            if whole < pts.count, whole >= 1 {
                let u = count - Double(whole)
                let a = pts[whole - 1], b = pts[whole]
                seg(&path, a, CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u), n: 5, first: false)
            }
            ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            for m in stride(from: 4, to: min(whole, pts.count), by: 5) {
                let q = warp(pts[m])
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 8, y: q.y - 8, width: 16, height: 16)), with: .color(g(1)))
            }
        }
    }

    static func webTip(_ c: CGPoint, _ R: Double, p: Double, t: Double) -> (CGPoint, Double) {
        let pts = webCrossings(c, R)
        let sp = max(0, min(1, (p - 0.25) / 0.75))
        if sp <= 0 { return (c, t * 0.6) }
        let idx = min(pts.count - 2, Int(sp * Double(pts.count - 1)))
        let u = sp * Double(pts.count - 1) - Double(idx)
        let a = pts[idx], b = pts[idx + 1]
        return (CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u), atan2(b.y - a.y, b.x - a.x))
    }

    // MARK: bar 0 · city

    @ViewBuilder @MainActor
    static func city(_ t: Double) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [g(0.14), g(0.55), g(0.85)]),
                                           startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            let moon = CGPoint(x: 1400, y: 310)
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(Gradient(colors: [g(0.85, 0.7), g(0, 0)]), center: moon, startRadius: 0, endRadius: 520))
            ctx.fill(Path(ellipseIn: CGRect(x: moon.x - 88, y: moon.y - 88, width: 176, height: 176)), with: .color(g(1)))
            for (cx, cy, r) in [(-30.0, -20.0, 22.0), (25.0, 18.0, 15.0), (-5.0, 40.0, 9.0)] {
                ctx.fill(Path(ellipseIn: CGRect(x: moon.x + cx - r, y: moon.y + cy - r, width: r * 2, height: r * 2)), with: .color(g(0.82)))
            }
            for layer in 0..<3 {
                let shade = [0.18, 0.08, 0.0][layer]
                var x = -40.0 + Double(layer) * 37
                var bi = 0
                while x < size.width {
                    let w = 90 + h(bi + layer * 50) * 120
                    let top = 560 + Double(layer) * 80 - h(bi + layer * 90 + 7) * (250 - Double(layer) * 40)
                    ctx.fill(Path(CGRect(x: x, y: top, width: w, height: size.height - top)), with: .color(g(shade)))
                    if layer < 2 {
                        var wy = top + 24
                        var wi = 0
                        while wy < size.height - 40 {
                            var wx = x + 14
                            while wx < x + w - 20 {
                                let lit = h(bi * 100 + wi + layer * 7000) > 0.78 && (Int(t * 2) + wi) % 13 != 0
                                if lit { ctx.fill(Path(CGRect(x: wx, y: wy, width: 12, height: 16)), with: .color(g(0.95))) }
                                wx += 28; wi += 1
                            }
                            wy += 36
                        }
                    }
                    x += w + 8; bi += 1
                }
            }
            rain(ctx, size, t, count: 200)
        }
        .scaleEffect(1 + 0.07 * t / bar)
    }

    // MARK: bar 1 · descent

    @ViewBuilder @MainActor
    static func descent(_ t: Double) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(g(0.02)))
            let cx = size.width / 2
            var cone = Path()
            cone.move(to: CGPoint(x: cx - 50, y: 0)); cone.addLine(to: CGPoint(x: cx + 50, y: 0))
            cone.addLine(to: CGPoint(x: cx + 520, y: size.height)); cone.addLine(to: CGPoint(x: cx - 520, y: size.height)); cone.closeSubpath()
            ctx.fill(cone, with: .linearGradient(Gradient(colors: [g(0.95), g(0.55)]), startPoint: CGPoint(x: cx, y: 0), endPoint: CGPoint(x: cx, y: size.height)))
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 520, y: size.height - 120, width: 1040, height: 190)),
                     with: .radialGradient(Gradient(colors: [g(1), g(0.4, 0)]), center: CGPoint(x: cx, y: size.height - 25), startRadius: 0, endRadius: 520))
            dust(ctx, size, t, count: 50)
            let p = Ease.easeInOut(Ease.clip(t, 0.2, 2.7))
            let x = cx + sin(t * 1.3) * 16
            let y = 140 + (size.height * 0.66) * p
            var th = Path(); th.move(to: CGPoint(x: x, y: 0)); th.addLine(to: CGPoint(x: x, y: y))
            ctx.stroke(th, with: .color(g(0.0)), lineWidth: 5)
            spider(ctx, CGPoint(x: x, y: y), ang: Double.pi / 2, s: 0.95, ph: t * 1.4, fill: g(0.0), mark: g(0.9))
            rain(ctx, size, t, count: 60, alpha: 0.25)
        }
    }

    // MARK: bar 2 · close-up

    @ViewBuilder @MainActor
    static func closeup(_ t: Double) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(g(0.02)))
            pool(ctx, CGPoint(x: size.width * 0.5, y: size.height * 0.52), r: 640)
            dust(ctx, size, t, count: 40)
            let ang = -Double.pi / 2 + sin(t * 0.8) * 0.55
            spider(ctx, CGPoint(x: size.width * 0.5 + sin(t * 0.6) * 20, y: size.height * 0.52), ang: ang, s: 1.55, ph: t * 1.3, fill: g(0.0), mark: g(0.92))
        }
        .scaleEffect(1 + 0.12 * t / bar)
    }

    // MARK: bar 3 · the web spins itself

    @ViewBuilder @MainActor
    static func spin(_ t: Double) -> some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(g(0.03)))
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(Gradient(colors: [g(0.5), g(0)]), center: c, startRadius: 0, endRadius: 760))
            var shaft = Path()
            shaft.move(to: CGPoint(x: 1100, y: 0)); shaft.addLine(to: CGPoint(x: 1500, y: 0))
            shaft.addLine(to: CGPoint(x: 700, y: size.height)); shaft.addLine(to: CGPoint(x: 300, y: size.height)); shaft.closeSubpath()
            ctx.fill(shaft, with: .color(g(0.16)))
            dust(ctx, size, t, count: 40)
            let p = Ease.clip(t, 0.2, 2.7)
            drawWeb(ctx, c, 480, p: p)
            let tip = webTip(c, 480, p: p, t: t)
            spider(ctx, tip.0, ang: tip.1, s: 0.6, ph: t * 3.2, fill: g(0.0), mark: g(0.95))
        }
    }

    // MARK: bar 4 · the catch

    @ViewBuilder @MainActor
    static func thecatch(_ t: Double) -> some View {
        let hitT = 0.8
        let e = t > hitT ? 9 * exp(-(t - hitT) * 9) : 0
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(g(0.03)))
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(Gradient(colors: [g(0.48), g(0)]), center: c, startRadius: 0, endRadius: 760))
            let pts = webCrossings(c, 480)
            let target = pts[webN * 3 + 2]
            let tt = t - hitT
            let warp: (CGPoint) -> CGPoint = { q in
                guard tt > 0 else { return q }
                let d = hypot(q.x - target.x, q.y - target.y)
                let amp = 16 * exp(-d / 280) * exp(-tt * 1.2) * sin(20 * tt - d * 0.03)
                let ux = (q.x - target.x) / max(d, 1), uy = (q.y - target.y) / max(d, 1)
                return CGPoint(x: q.x - uy * amp, y: q.y + ux * amp)
            }
            drawWeb(ctx, c, 480, p: 1, warp: warp)
            // fly
            var fp: CGPoint
            if t < hitT {
                let u = Ease.easeIn(t / hitT)
                fp = CGPoint(x: size.width * 0.98 + (target.x - size.width * 0.98) * u, y: size.height * 0.08 + (target.y - size.height * 0.08) * u)
            } else {
                let j = 5 * exp(-tt * 0.5)
                fp = CGPoint(x: target.x + sin(t * 70) * j, y: target.y + cos(t * 83) * j)
            }
            var fc = ctx
            fc.translateBy(x: fp.x, y: fp.y)
            for w in [-1.0, 1.0] {
                var wc = fc
                wc.rotate(by: .radians(w * (0.7 + 0.5 * sin(t * 160))))
                wc.fill(Path(ellipseIn: CGRect(x: w > 0 ? 3 : -48, y: -11, width: 45, height: 22)), with: .color(g(0.8, 0.7)))
            }
            fc.fill(Path(ellipseIn: CGRect(x: -11, y: -18, width: 22, height: 36)), with: .color(g(1)))
            // spider dash
            let run = Ease.easeInOut(Ease.clip(t, 1.0, 1.6))
            let goal = CGPoint(x: target.x - (target.x - c.x) * 0.08, y: target.y - (target.y - c.y) * 0.08)
            let sp = CGPoint(x: c.x + (goal.x - c.x) * run, y: c.y + (goal.y - c.y) * run)
            let ang = atan2(target.y - c.y, target.x - c.x)
            spider(ctx, sp, ang: ang, s: 0.62, ph: run > 0 && run < 1 ? t * 9 : t * 0.8, fill: g(0.0), mark: g(0.95))
            // impact rings
            for k in 0..<3 {
                let rt = tt - Double(k) * 0.12
                if rt > 0 && rt < 0.8 {
                    let r = rt * 380
                    ctx.stroke(Path(ellipseIn: CGRect(x: target.x - r, y: target.y - r, width: r * 2, height: r * 2)),
                               with: .color(g(1, 0.9 * (1 - rt / 0.8))), lineWidth: 7)
                }
            }
            rain(ctx, size, t, count: 70, alpha: 0.3)
        }
        .offset(x: sin(t * 90) * e, y: cos(t * 70) * e)
    }

    // MARK: bar 5 · venetian blinds

    @ViewBuilder @MainActor
    static func blinds(_ t: Double) -> some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [g(0.20), g(0.05)]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            var lc = ctx
            lc.translateBy(x: size.width / 2, y: size.height / 2)
            lc.rotate(by: .degrees(-7))
            let shift = sin(t * 0.9) * 22
            for i in -9..<10 {
                let y = Double(i) * 74 + shift
                lc.fill(Path(CGRect(x: -1500, y: y, width: 3000, height: 36)),
                        with: .linearGradient(Gradient(colors: [g(1.0), g(0.45)]), startPoint: CGPoint(x: -900, y: 0), endPoint: CGPoint(x: 900, y: 0)))
            }
            dust(ctx, size, t, count: 30)
            let p = Ease.easeInOut(t / bar)
            let x = -300 + (size.width + 600) * p
            spider(ctx, CGPoint(x: x, y: size.height * 0.5 + sin(t * 2) * 16), ang: 0, s: 2.1, ph: t * 1.8, fill: g(0.0), mark: g(0.9))
        }
    }

    static func titleBackdrop(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let full = Path(CGRect(origin: .zero, size: size))
        let mid = CGPoint(x: size.width / 2, y: size.height / 2)
        ctx.fill(full, with: .color(g(0.03)))
        ctx.fill(full, with: .radialGradient(Gradient(colors: [g(0.45), g(0)]), center: mid, startRadius: 0, endRadius: 820))
        let wp: Double = Ease.easeOut(Ease.clip(t, 0, 1.4))
        let corners: [(CGPoint, Double, Double)] = [(CGPoint(x: 0, y: 0), 1.0, 1.0), (CGPoint(x: size.width, y: 0), -1.0, 1.0)]
        for (corner, sx, sy) in corners {
            for i in 0..<5 {
                let a: Double = Double.pi / 2 * (Double(i) + 0.5) / 5
                let reach: Double = 780 * wp
                let end = CGPoint(x: corner.x + sx * cos(a) * reach, y: corner.y + sy * sin(a) * reach)
                var p = Path(); p.move(to: corner); p.addLine(to: end)
                ctx.stroke(p, with: .color(g(0.85)), lineWidth: 6)
            }
            for r in 1...6 {
                var p = Path()
                let rr: Double = Double(r) * 120 * wp
                for i in 0...5 {
                    let a: Double = Double.pi / 2 * (Double(i) + 0.5) / 5
                    let pt = CGPoint(x: corner.x + sx * cos(a) * rr, y: corner.y + sy * sin(a) * rr)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                ctx.stroke(p, with: .color(g(0.85)), lineWidth: 5)
            }
        }
        let sway: Double = sin(t * 1.6) * 20
        let len: Double = 330 + 260 * Ease.easeOut(Ease.clip(t, 0.1, 1.4))
        let anchorX: Double = size.width * 0.84
        let x: Double = anchorX + sway
        var th = Path(); th.move(to: CGPoint(x: anchorX, y: 0)); th.addLine(to: CGPoint(x: x, y: len))
        ctx.stroke(th, with: .color(g(0.95)), lineWidth: 5)
        spider(ctx, CGPoint(x: x, y: len), ang: Double.pi / 2 + sway * 0.004, s: 0.95, ph: t * 1.2, fill: g(0.95), mark: g(0.0))
    }

    // MARK: bar 6 · title

    @ViewBuilder @MainActor
    static func title(_ t: Double) -> some View {
        let pop: Double = Ease.spring(t, from: 1.18, to: 1.0, response: 0.5, dampingFraction: 0.7)
        let appear: Double = Ease.easeOut(Ease.clip(t, 0, 0.25))
        let rule: Double = Ease.easeOut(Ease.clip(t, 0.5, 1.1))
        ZStack {
            Canvas { ctx, size in titleBackdrop(ctx, size, t) }
            VStack(spacing: -30) {
                Text("SPIDER")
                    .font(.system(size: 290, weight: .black, design: .serif))
                    .tracking(14)
                Text("NOIR")
                    .font(.system(size: 290, weight: .heavy, design: .serif)).italic()
                    .tracking(26)
            }
            .foregroundStyle(LinearGradient(colors: [g(1.0), g(0.62)], startPoint: .top, endPoint: .bottom))
            .scaleEffect(pop)
            .opacity(appear)
            VStack {
                Spacer()
                Rectangle().fill(g(0.95)).frame(width: 900 * rule, height: 4).padding(.bottom, 175)
            }
        }
    }
}
