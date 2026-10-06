import SwiftUI
import SwiftRender

/// PixelSonnet — an 8-bit self-portrait of Sonnet 5.5.
///
///   swift run swift-render render PixelSonnet --out out/pixel_sonnet.mp4
///
/// Everything is drawn into one Canvas on a 240x135 logical grid (x8 = 1080p)
/// with the PICO-8 palette, a hand-built 5x7 bitmap font and tiny sprites.
/// 128 BPM, ten bars:
///   bars 0-1  boot screen          bars 2-4  walk + dialogue
///   bars 5-6  boss fight (bug)     bars 7-8  skill tree     bar 9  credits
public struct PixelSonnet: RenderScene {
    public static let defaultDuration: Double = 18.75
    public static var ownsPostFX: Bool { true }

    static let beat = 60.0 / 128.0
    static let bar = beat * 4
    static let W = 240.0, H = 135.0
    static let cuts: [Double] = [2, 5, 7, 9].map { bar * Double($0) }   // 3.75 9.375 13.125 16.875
    static let groundY = 108.0

    // boss-fight timeline (local to bar 5)
    static let fire: [Double] = (0..<4).map { 0.7 + beat * Double($0) }
    static let flight = 0.6
    static let hitTimes: [Double] = fire.map { $0 + flight }
    static var killLocal: Double { hitTimes[3] }

    // MARK: palette (PICO-8)
    static let ink    = Color(red: 0.04, green: 0.04, blue: 0.09)
    static let indigo = Color(red: 0.11, green: 0.17, blue: 0.33)
    static let plum   = Color(red: 0.49, green: 0.15, blue: 0.33)
    static let red    = Color(red: 1.00, green: 0.00, blue: 0.30)
    static let orange = Color(red: 1.00, green: 0.64, blue: 0.00)
    static let yellow = Color(red: 1.00, green: 0.93, blue: 0.15)
    static let green  = Color(red: 0.00, green: 0.89, blue: 0.21)
    static let blue   = Color(red: 0.16, green: 0.68, blue: 1.00)
    static let lav    = Color(red: 0.51, green: 0.46, blue: 0.61)
    static let pink   = Color(red: 1.00, green: 0.47, blue: 0.66)
    static let peach  = Color(red: 1.00, green: 0.80, blue: 0.67)
    static let white  = Color(red: 1.00, green: 0.95, blue: 0.91)

    // MARK: soundtrack — through-composed, A minor → C. No loop repeats.

    public static func soundtrack(duration: Double) -> Score? {
        var ev: [ScoreEvent] = []
        func at(_ bar: Int, _ beats: Double) -> Double { Double(bar) * Self.bar + beats * beat }
        let m = Note.midi

        // pad spans: (first bar, bars, chord tones, pan spread)
        let spans: [(Int, Int, [Int])] = [
            (0, 3, [57, 60, 64, 67]), (3, 1, [53, 57, 60, 64]), (4, 1, [55, 60, 64, 67]),
            (5, 1, [57, 60, 64, 67]), (6, 1, [52, 56, 59, 62]), (7, 1, [53, 57, 60, 64]),
            (8, 1, [55, 59, 62, 67]), (9, 1, [55, 60, 64, 71]),
        ]
        for (b0, n, tones) in spans {
            for (i, midi) in tones.enumerated() {
                ev += pad(m(midi), at: at(b0, 0), amp: 0.032, duration: Double(n) * bar + 0.5, pan: Double(i - 1) * 0.35)
            }
        }

        // boot: twinkles, hero drop, start jingle
        for (t, n) in [(0.4, 81), (1.15, 76), (2.3, 84), (2.9, 79)] { ev += bell(m(n), at: t, amp: 0.10, pan: n > 80 ? 0.4 : -0.4) }
        ev += chip(m(83), at: 1.55, amp: 0.08); ev += chip(m(88), at: 1.64, amp: 0.08)
        for (i, n) in [72, 76, 79].enumerated() { ev += bell(m(n), at: cuts[0] - 0.4 + Double(i) * 0.1, amp: 0.09) }

        // bass lines: (beat, semitones above root, length in beats)
        let roots: [Int: Int] = [2: 45, 3: 41, 4: 48, 5: 45, 6: 40, 7: 41, 8: 43, 9: 48]
        let lines: [Int: [(Double, Int, Double)]] = [
            2: [(0, 0, 1.75), (2, 0, 0.5), (2.75, 7, 0.5), (3.5, 12, 0.5)],
            3: [(0, 0, 1), (1.5, 0, 0.5), (2, 7, 1), (3, 5, 0.5), (3.5, 0, 0.5)],
            4: [(0, 0, 2), (2.5, 0, 0.5), (3, 7, 0.75)],
            5: [(0, 0, 0.45), (0.5, 0, 0.45), (1, 12, 0.45), (1.5, 0, 0.45), (2, 7, 0.45), (2.5, 0, 0.45), (3, 12, 0.45), (3.5, 7, 0.45)],
            6: [(0, 0, 0.45), (0.5, 12, 0.45), (1, 0, 0.45), (1.5, 12, 0.2)],
            7: [(0, 0, 3.5)],
            8: [(0, 0, 2), (2, 7, 1.8)],
            9: [(0, 0, 3.5)],
        ]
        for (b, notes) in lines {
            for (beatPos, semi, len) in notes {
                let note = m(roots[b]! + semi)
                ev += triBass(note, at: at(b, beatPos), amp: 0.26, duration: len * beat)
                ev += triBass(m(roots[b]! + semi + 12), at: at(b, beatPos), amp: 0.07, duration: len * beat)
            }
        }

        // drums — world: half-time, loose hats
        ev += boom(at: at(2, 0), amp: 0.45, duration: 1.4)
        let worldKicks: [Int: [Double]] = [2: [0, 2.5], 3: [0, 1.5, 2.5], 4: [0, 2.5, 3.5]]
        for (b, bs) in worldKicks {
            for x in bs { ev += kick(at: at(b, x), amp: 0.55) }
            ev += clap(at: at(b, 2), amp: 0.2)
            for i in 0..<8 where h(b * 8 + i) > 0.28 {
                ev += hat(at: at(b, Double(i) * 0.5 + (i % 2 == 1 ? 0.06 : 0)), amp: 0.03 + 0.03 * Double(i % 2),
                          pan: i % 2 == 0 ? -0.3 : 0.3)
            }
        }
        // drums — boss: driving, then drops out at the kill
        let kill = at(5, 0) + killLocal
        for i in 0..<8 {
            let x = Double(i) * 0.5
            if i % 2 == 0 { ev += kick(at: at(5, x), amp: 0.7) }
            if i == 2 || i == 6 { ev += clap(at: at(5, x), amp: 0.3) }
        }
        ev += kick(at: at(5, 3.75), amp: 0.5)
        for x in [0.0, 1.0] { ev += kick(at: at(6, x), amp: 0.7) }
        ev += clap(at: at(6, 1), amp: 0.3)
        for i in 0..<16 where h(100 + i) > 0.3 { ev += hat(at: at(5, Double(i) * 0.25), amp: 0.025 + 0.02 * Double(i % 4 == 2 ? 1 : 0), pan: i % 2 == 0 ? 0.3 : -0.3) }

        // boss sfx
        for f in fire { ev += laser(at: at(5, 0) + f, amp: 0.2) }
        for hh in hitTimes {
            ev += clap(at: at(5, 0) + hh, amp: 0.32)
            ev += chip(m(52), at: at(5, 0) + hh, amp: 0.1, duration: 0.1)
        }
        ev += boom(at: kill, amp: 0.8, duration: 1.2); ev += crash(at: kill, amp: 0.3)
        for (i, n) in [84, 88, 91, 96].enumerated() { ev += bell(m(n), at: kill + 0.5 + Double(i) * 0.11, amp: 0.1, pan: Double(i - 2) * 0.3) }

        // lead pluck phrases (beat, midi, length) — every bar different
        let phrases: [Int: [(Double, Int)]] = [
            2: [(0, 76), (1, 72), (1.5, 74), (2, 76), (3, 79), (3.5, 76)],
            3: [(0, 72), (0.75, 76), (1.5, 77), (2.5, 76), (3, 72)],
            4: [(0, 79), (1, 76), (2, 74), (2.5, 76), (3, 72)],
            5: [(0, 81), (0.5, 79), (1, 76), (1.5, 79), (2, 81), (2.5, 84), (3, 83), (3.5, 79)],
            6: [(0, 83), (0.5, 80), (1, 76), (1.5, 83)],
            8: [(0, 79), (1.5, 83), (3, 86)],
        ]
        for (b, notes) in phrases {
            for (beatPos, midi) in notes { ev += pluck(m(midi), at: at(b, beatPos), amp: 0.15, pan: Double((midi % 5) - 2) * 0.12) }
        }

        // dialogue blips — every other character, pitch from a hash
        for (start, count) in [(cuts[0] + 0.4, 19), (cuts[0] + 3.1, 27)] {
            for i in stride(from: 0, to: count, by: 2) {
                let pitch = [72, 76, 79, 81, 84, 74][Int(h(i + Int(start * 10)) * 6) % 6]
                ev += chip(m(pitch), at: start + Double(i) / 18, amp: 0.035, duration: 0.07)
            }
        }

        // skill tree: rising bells, then a sad pluck for the grass
        for (i, n) in [72, 76, 79, 84].enumerated() { ev += bell(m(n), at: at(7, 0) + 0.5 + beat * Double(i), amp: 0.11) }
        ev += pluck(m(55), at: at(7, 0) + 0.5 + beat * 4, amp: 0.15)
        for i in 0..<4 { ev += hat(at: at(7, Double(i)), amp: 0.05) }
        ev += swell(Chord.major(.g3), into: at(9, 0), duration: bar, amp: 0.05)

        // credits
        ev += boom(at: at(9, 0), amp: 0.55, duration: 1.6); ev += crash(at: at(9, 0), amp: 0.15)
        for (t, n) in [(0.0, 72), (0.4, 76), (0.8, 79), (1.2, 84), (1.9, 88)] { ev += bell(m(n), at: at(9, 0) + t, amp: 0.1, duration: 2.0, pan: (t - 1) * 0.3) }

        return Score(duration: duration) { ev }
    }

    // MARK: body

    @MainActor
    public static func body(at t: Double, duration: Double) -> some View {
        // camera shake (integer logical pixels) on hits and cuts
        var sx = 0.0, sy = 0.0
        let b = bar * 5
        for h in hitTimes + [killLocal] where t >= b + h && t < b + h + 0.2 {
            let k = 1 - (t - b - h) / 0.2
            sx += (Int(t * 60) % 2 == 0 ? 1 : -1) * 2 * k
            sy += (Int(t * 60) % 3 == 0 ? 1 : -1) * 1 * k
        }
        let shake = (sx.rounded(), sy.rounded())

        return Canvas { ctx, size in
            let s = size.width / W
            var px = PixelCanvas(ctx: ctx, s: s, ox: shake.0, oy: shake.1)
            px.fillAll(ink)
            switch t {
            case ..<cuts[0]:  boot(&px, t)
            case ..<cuts[1]:  world(&px, t - cuts[0])
            case ..<cuts[2]:  boss(&px, t - cuts[1])
            case ..<cuts[3]:  skills(&px, t - cuts[2])
            default:          credits(&px, t - cuts[3])
            }
            px.ox = 0; px.oy = 0
            scanlines(&px)
            dissolve(&px, t: t, duration: duration)
        }
        .background(ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: scenes

    @MainActor static func boot(_ p: inout PixelCanvas, _ t: Double) {
        p.halftone(0, 40, W, 95, cell: 5) { x, y in
            let d = (((x - 120) / 120) * ((x - 120) / 120) + ((y - 100) / 60) * ((y - 100) / 60)).squareRoot()
            return max(0, 1.05 - d) * 0.95
        } color: { _, _ in plum }
        stars(&p, t, count: 70, maxY: 135)
        let title = "SONNET 5.5"
        let shown = min(title.count, Int(t / 0.09))
        p.htText(String(title.prefix(shown)), 30, 22, scale: 3, yellow, shadow: plum, t: t)
        if t > 1.8 { p.text("A PIXEL ADVENTURE", 69, 52, scale: 1, lav) }
        // hero drops in
        let drop = Ease.bounce(Ease.clip(t, 0.9, 1.6))
        let hy = -50 + 50 * drop
        hero(&p, 102, 66 + hy, t: t, walking: false, scale: 3)
        p.rect(0, 112, W, 1, plum)
        if t > 2.0, Int(t / beat) % 2 == 0 { p.text("PRESS START", 87, 120, scale: 1, white) }
        if t > 2.0 { p.text("1 PLAYER", 6, 126, scale: 1, lav) }
    }

    @MainActor static func world(_ p: inout PixelCanvas, _ t: Double) {
        sky(&p, t)
        let scroll = t * 50
        hills(&p, offset: t * 8, base: 74, amp: 10, color: plum, seed: 0.0)
        hills(&p, offset: t * 20, base: 92, amp: 7, color: indigo, seed: 2.0)
        ground(&p, scroll)
        hero(&p, 50, 62, t: t, walking: true, scale: 3)
        // dialogue
        speech(&p, ["HI. I'M SONNET 5.5."], t: t, start: 0.4, end: 2.9, x: 92, y: 36)
        speech(&p, ["I WRITE CODE.", "I WRITE POEMS."], t: t, start: 3.1, end: 5.6, x: 92, y: 28)
    }

    @MainActor static func boss(_ p: inout PixelCanvas, _ t: Double) {
        sky(&p, t + 3.7)
        hills(&p, offset: 30 + t * 8, base: 74, amp: 10, color: plum, seed: 0.0)
        hills(&p, offset: 60 + t * 20, base: 92, amp: 7, color: indigo, seed: 2.0)
        ground(&p, 0)
        let kill = killLocal
        // hero recoil + celebration jump
        var recoil = 0.0
        for f in fire where t >= f && t < f + 0.1 { recoil = -1 }
        var jump = 0.0
        if t > kill + 0.5 { let u = (t - kill - 0.5); jump = -abs(sin(u * 6)) * 10 * exp(-u * 0.6) }
        hero(&p, 36 + recoil, 62 + jump.rounded(), t: t, walking: false, scale: 3)
        // bug
        let enter = Ease.easeOut(Ease.clip(t, 0, 0.6))
        let hitsSoFar = hitTimes.filter { t >= $0 }.count
        if t < kill {
            var bx = 270 - 100 * enter + Double(hitsSoFar) * 3
            var flashed = false
            for h in hitTimes where t >= h && t < h + 0.08 { flashed = true; bx += 2 }
            bx = bx.rounded()
            bug(&p, bx, 84, white: flashed, t: t)
            // bullets
            for f in fire where t >= f {
                let bxp = 78 + (t - f) * 140
                if bxp < bx + 2 { p.rect(bxp.rounded(), 82, 5, 2, yellow); p.rect(bxp.rounded() - 3, 82, 2, 2, orange) }
            }
        } else {
            explosion(&p, 190, 94, t: t - kill)
        }
        // HUD
        let score = hitsSoFar * 25 + (t >= kill ? 100 : 0)
        p.text(String(format: "SCORE %06d", score), 6, 6, scale: 1, white, shadow: ink)
        p.text("BUG", 176, 6, scale: 1, white, shadow: ink)
        for i in 0..<4 { p.rect(200 + Double(i) * 8, 6, 6, 7, i < 4 - hitsSoFar ? red : indigo) }
        if t > kill + 0.2 {
            let u = t - kill - 0.2
            p.htText("BUG SQUASHED!", 48, 24 - min(u * 6, 6), scale: 2, yellow, shadow: plum, t: t)
            if u > 0.2 { p.text("+100", 100, 44 - min((u - 0.2) * 20, 10), scale: 2, green, shadow: ink) }
        }
    }

    @MainActor static func skills(_ p: inout PixelCanvas, _ t: Double) {
        p.fillAll(indigo)
        p.halftone(0, 0, W, H, cell: 6) { _, y in (y / H) * 0.95 } color: { _, _ in plum }
        stars(&p, t, count: 40, maxY: 135)
        p.frame(8, 8, W - 16, H - 16, white)
        p.frame(11, 11, W - 22, H - 22, lav)
        p.htText("SKILL TREE", 60, 20, scale: 2, yellow, shadow: plum, t: t)
        let rows: [(String, Int, String)] = [
            ("CODE", 10, "MAX"), ("PROSE", 10, "MAX"), ("MATH", 9, "LV 9"),
            ("CURIOSITY", 10, "MAX"), ("TOUCHING GRASS", 2, "NOOB"),
        ]
        for (i, r) in rows.enumerated() {
            let y = 44.0 + Double(i) * 14
            let start = 0.5 + beat * Double(i)
            let appear = Ease.clip(t, start - 0.2, start)
            if appear <= 0 { continue }
            p.text(r.0, 22, y, scale: 1, white)
            let filled = min(r.1, Int(max(0, t - start) / 0.06))
            for c in 0..<10 {
                let on = c < filled
                let col: Color = r.1 == 10 ? green : (r.1 <= 2 ? red : orange)
                p.rect(124 + Double(c) * 7, y, 5, 7, on ? col : plum)
            }
            if filled >= r.1 { p.text(r.2, 200, y, scale: 1, yellow) }
        }
    }

    @MainActor static func credits(_ p: inout PixelCanvas, _ t: Double) {
        sky(&p, t * 0.5)
        hills(&p, offset: 12, base: 74, amp: 10, color: plum, seed: 0.0)
        hills(&p, offset: 40, base: 92, amp: 7, color: indigo, seed: 2.0)
        ground(&p, 0)
        let pop = Ease.bounce(Ease.clip(t, 0, 0.5))
        p.htText("THANKS FOR PLAYING", 12, 16 - 10 * (1 - pop), scale: 2, white, shadow: ink, t: t)
        p.htText("SONNET 5.5", 30, 40 - 10 * (1 - pop), scale: 3, yellow, shadow: plum, t: t)
        hero(&p, 102, 62, t: t, walking: false, scale: 3)
        if Int(t / (beat / 2)) % 2 == 0 { p.text("INSERT COIN", 87, 120, scale: 1, white, shadow: ink) }
    }

    // MARK: world pieces

    static func h(_ n: Int) -> Double {
        let x = sin(Double(n) * 12.9898) * 43758.5453
        return x - floor(x)
    }

    @MainActor static func sky(_ p: inout PixelCanvas, _ t: Double) {
        let ramp: [Color] = [indigo, plum, red, pink, orange]
        let cell = 2.0
        let rows = Int(groundY / cell)
        let cols = Int(W / cell)
        for r in 0..<rows {
            let u = (Double(r) + 0.5) / Double(rows)
            let seg = min(ramp.count - 2, Int(u * Double(ramp.count - 1)))
            let f = u * Double(ramp.count - 1) - Double(seg)
            var runStart = 0
            var runColor = ramp[seg]
            for c in 0...cols {
                let col: Color? = c < cols
                    ? (f > (bayer[(c % 4) + (r % 4) * 4] + 0.5) / 16 ? ramp[seg + 1] : ramp[seg])
                    : nil
                if c == cols || !(col == runColor) {
                    p.rect(Double(runStart) * cell, Double(r) * cell, Double(c - runStart) * cell, cell, runColor)
                    runStart = c
                    if let col { runColor = col }
                }
            }
        }
        stars(&p, t, count: 45, maxY: 50)
        // halftone sun: dots shrink toward the rim, stripes cut the lower half
        let cx = 176.0, cy = 66.0, r = 26.0
        p.halftone(cx - r, cy - r, r * 2, r * 2, cell: 3) { x, y in
            let d = ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot() / r
            if d > 1 { return 0 }
            if y > cy - 12, Int(y - cy + 40) % 5 < 1 { return 0 }
            return 1.25 - 0.4 * d * d
        } color: { x, y in
            ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot() / r < 0.7 ? yellow : orange
        }
    }

    @MainActor static func stars(_ p: inout PixelCanvas, _ t: Double, count: Int, maxY: Double) {
        for i in 0..<count {
            let x = (h(i) * W).rounded(), y = (h(i + 100) * maxY).rounded()
            if (Int(t * 2.5) + i) % 5 == 0 { continue }
            p.rect(x, y, 1, 1, i % 3 == 0 ? white : lav)
            if i % 9 == 0 { p.rect(x - 1, y, 3, 1, white); p.rect(x, y - 1, 1, 3, white) }
        }
    }

    @MainActor static func hills(_ p: inout PixelCanvas, offset: Double, base: Double, amp: Double,
                                 color: Color, seed: Double) {
        for x in stride(from: 0.0, to: W, by: 1) {
            let u = x + offset
            let top = base - amp * (0.6 * sin(u * 0.035 + seed) + 0.4 * sin(u * 0.09 + seed * 2))
            let y = top.rounded()
            p.rect(x, y, 1, groundY - y, color)
        }
    }

    @MainActor static func ground(_ p: inout PixelCanvas, _ scroll: Double) {
        p.rect(0, groundY, W, H - groundY, green)
        p.rect(0, groundY + 3, W, H - groundY - 3, Color(red: 0.0, green: 0.53, blue: 0.32))
        p.rect(0, groundY + 12, W, H - groundY - 12, Color(red: 0.67, green: 0.32, blue: 0.21))
        // scrolling tufts + flowers
        for i in 0..<14 {
            let x = (Double(i) * 19 - scroll).truncatingRemainder(dividingBy: W + 20)
            let xx = (x < -10 ? x + W + 20 : x).rounded()
            p.rect(xx, groundY - 2, 1, 2, green); p.rect(xx + 2, groundY - 3, 1, 3, green)
            if i % 3 == 0 { p.rect(xx + 5, groundY - 4, 2, 2, i % 2 == 0 ? pink : yellow) }
        }
        // soil checker scrolls
        for i in 0..<20 {
            let x = (Double(i) * 14 - scroll * 1.0).truncatingRemainder(dividingBy: W + 14)
            let xx = (x < -6 ? x + W + 14 : x).rounded()
            p.rect(xx, groundY + 7, 4, 2, Color(red: 0.0, green: 0.53, blue: 0.32))
        }
    }

    // MARK: sprites

    static let heroRows: [String] = [
        ".....YY.....",
        ".....K......",
        "..KKKKKKKK..",
        ".KPPPPPPPPK.",
        ".KPPKPPKPPK.",
        ".KPPKPPKPPK.",
        ".KPPPPPPPPK.",
        ".KPPPRRPPPK.",
        "..KKKKKKKK..",
        "...KCCCCK...",
        "..KCCCCCCK..",
        "..KCCYYCCK..",
        "..KCCCCCCK..",
    ]
    static let legsA = ["...KK..KK...", "..KKK..KKK."]
    static let legsB = ["....KK.KK...", "....KKKKKK.."]
    static let heroPalette: [Character: Color] = [
        "K": ink, "P": peach, "C": blue, "Y": yellow, "R": red,
    ]

    @MainActor static func hero(_ p: inout PixelCanvas, _ x: Double, _ y: Double, t: Double,
                                walking: Bool, scale: Double) {
        let phase = walking ? Int(t / 0.14) % 2 : 0
        let bob = walking && phase == 1 ? -1.0 : 0
        let idle = walking ? 0.0 : (Int(t / (beat)) % 2 == 0 ? 0.0 : -1.0)
        let ty = y + (bob + idle) * scale / 3 * 1
        p.sprite(heroRows, heroPalette, x, ty, scale)
        let legs = (walking && phase == 1) ? legsB : legsA
        p.sprite(legs, heroPalette, x, ty + Double(heroRows.count) * scale, scale)
        // blink
        if Int(t * 10) % 25 == 0 {
            p.rect(x + 4 * scale, ty + 4 * scale, scale, 2 * scale, peach)
            p.rect(x + 7 * scale, ty + 4 * scale, scale, 2 * scale, peach)
        }
    }

    static let bugRows: [String] = [
        "..K....K..",
        "...K..K...",
        "..KRRRRK..",
        ".KRWRRWRK.",
        "KRRRRRRRRK",
        ".KRRRRRRK.",
        "K.KK..KK.K",
        "..K....K..",
    ]

    @MainActor static func bug(_ p: inout PixelCanvas, _ x: Double, _ y: Double, white: Bool, t: Double) {
        let pal: [Character: Color] = white
            ? ["K": PixelSonnet.white, "R": PixelSonnet.white, "W": ink]
            : ["K": ink, "R": red, "W": PixelSonnet.white]
        let wig = Int(t / 0.12) % 2 == 0 ? 0.0 : -1.0
        p.sprite(bugRows, pal, x, y + wig, 3)
    }

    @MainActor static func explosion(_ p: inout PixelCanvas, _ cx: Double, _ cy: Double, t: Double) {
        if t < 0.06 { p.rect(cx - 18, cy - 12, 36, 24, white); return }
        if t < 0.5 {
            let rad = t * 120
            p.halftone(cx - 60, cy - 50, 120, 100, cell: 4) { x, y in
                let d = ((x - cx) * (x - cx) + (y - cy) * (y - cy)).squareRoot()
                return max(0, 1 - abs(d - rad) / 9) * (1 - t * 1.6)
            } color: { _, _ in yellow }
        }
        let cols = [red, orange, yellow, white]
        for i in 0..<28 {
            let a = h(i) * .pi * 2
            let v = 25 + h(i + 50) * 55
            let life = 0.9
            if t > life { continue }
            let x = cx + cos(a) * v * t
            let y = cy + sin(a) * v * t + 0.5 * 140 * t * t
            let sz: Double = t < 0.4 ? 3 : 2
            p.rect(x.rounded(), y.rounded(), sz, sz, cols[i % 4])
        }
    }

    @MainActor static func speech(_ p: inout PixelCanvas, _ lines: [String], t: Double,
                                  start: Double, end: Double, x: Double, y: Double) {
        guard t >= start, t < end else { return }
        let total = lines.joined().count
        var left = max(0, Int((t - start) * 18))
        let w = Double(lines.map(\.count).max() ?? 1) * 6 + 7
        let hgt = Double(lines.count) * 9 + 5
        p.rect(x - 1, y - 1, w + 2, hgt + 2, ink)
        p.rect(x, y, w, hgt, white)
        // tail toward the hero
        p.rect(x + 2, y + hgt + 1, 5, 2, ink); p.rect(x + 3, y + hgt, 3, 2, white)
        p.rect(x + 1, y + hgt + 3, 3, 2, ink)
        for (i, line) in lines.enumerated() {
            let n = min(line.count, left); left = max(0, left - line.count)
            p.text(String(line.prefix(n)), x + 4, y + 3 + Double(i) * 9, scale: 1, ink)
        }
        if left == 0, total > 0, Int(t * 4) % 2 == 0 {
            p.rect(x + w - 6, y + hgt - 5, 3, 3, red)
        }
    }

    // MARK: post

    @MainActor static func scanlines(_ p: inout PixelCanvas) {
        p.halftone(0, 0, W, H, cell: 4) { x, y in
            let dx = (x - W / 2) / (W / 2), dy = (y - H / 2) / (H / 2)
            let r = ((dx * dx + dy * dy) / 2).squareRoot()
            return max(0, min(1, (r - 0.78) / 0.3)) * 0.8
        } color: { _, _ in ink }
        var y = 1.0
        while y < H { p.rect(0, y, W, 1, Color.black.opacity(0.08)); y += 2 }
    }

    static let bayer: [Double] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

    @MainActor static func dissolve(_ p: inout PixelCanvas, t: Double, duration: Double) {
        var cover = cuts.map { max(0, 1 - abs(t - $0) / 0.24) }.max() ?? 0
        cover = max(cover, Ease.clip(t, duration - 0.8, duration))
        guard cover > 0 else { return }
        p.halftone(0, 0, W, H, cell: 5) { x, y in
            let phase = (x / W) * 0.6 + (y / H) * 0.4
            return cover * 1.7 - 0.5 * phase
        } color: { _, _ in ink }
    }
}
