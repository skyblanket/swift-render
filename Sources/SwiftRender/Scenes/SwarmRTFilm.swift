import SwiftUI

/// SwarmRTFilm — the 45s field-manual film. White paper, black ink, red/orange
/// accents, all-mono type, and a living colony of procedural bugs (BugRig) as
/// the process metaphor. Motion system: ease-out-quart entrances, ease-out-expo
/// hero moves, linear counters, exits at 2/3 enter duration. Score by layers:
/// drone bed / insect foley / type mechanics / punctuation (two booms total).
///
///   swift run swift-render render SwarmRTFilm
///
/// Sections:  S0 0.0 specimen   S1 3.2 the problem   S2 7.2 spawn
///            S3 11.0 runtime   S4 14.6 agent loop   S5 19.4 supervision
///            S6 24.2 numbers   S7 28.4 batteries    S8 32.6 proof
///            S9 36.8 ship
public struct SwarmRTFilm: RenderScene {
    public static let defaultDuration: Double = 45.0
    public static var ownsPostFX: Bool { true }

    // MARK: - Design system

    static let paper = Color(red: 0.980, green: 0.965, blue: 0.937)
    static let ink = Color(red: 0.075, green: 0.070, blue: 0.065)
    static let red = Color(red: 0.898, green: 0.224, blue: 0.110)
    static let orange = Color(red: 0.949, green: 0.522, blue: 0.102)

    static let starts: [Double] = [0.0, 3.2, 7.2, 11.0, 14.6, 19.4, 24.2, 28.4, 32.6, 36.8]
    static let hudLabels = ["00 / SPECIMEN", "01 / THE PROBLEM", "02 / SPAWN", "03 / RUNTIME",
                            "04 / AGENT LOOP", "05 / SUPERVISION", "06 / NUMBERS",
                            "07 / BATTERIES", "08 / PROOF", "09 / SHIP"]

    static func h(_ x: Double) -> Double { BugRig.hash01(x) }
    /// ease-out-quart — the workhorse entrance curve
    static func outQuart(_ x: Double) -> Double { let p = min(1, max(0, x)); return 1 - pow(1 - p, 4) }
    /// ease-out-expo — hero moves, 700–1200ms
    static func outExpo(_ x: Double) -> Double {
        let p = min(1, max(0, x)); return p >= 1 ? 1 : 1 - pow(2, -10 * p)
    }

    // MARK: - Score (sound-engineered: bed / foley / mechanics / punctuation)

    public static func soundtrack(duration: Double) -> Score? {
        Score(duration: duration) {
            // ─── BED: evolving drone foundation ─────────────────────────
            drone(Note(92.0), from: 0.0, for: 11.0, amp: 0.05)
            drone(Note(95.5), from: 0.0, for: 11.0, amp: 0.045)
            drone(Note(46.0), from: 7.2, for: 3.8, amp: 0.06)
            drone(.a1, from: 11.0, for: 3.6, amp: 0.08)
            drone(Note(56.5), from: 11.0, for: 3.6, amp: 0.04)
            drone(.e1, from: 14.6, for: 4.8, amp: 0.05)
            drone(Note(41.9), from: 14.6, for: 4.8, amp: 0.03)
            drone(Note(82.4), from: 19.4, for: 1.1, amp: 0.06)   // tension pair, ends 20.5:
            drone(Note(84.5), from: 19.4, for: 1.1, amp: 0.05)   // 0.4s dead air before the snap
            drone(.a1, from: 21.4, for: 2.8, amp: 0.06)
            drone(.a1, from: 24.2, for: 12.6, amp: 0.07)
            drone(.e2, from: 24.2, for: 12.6, amp: 0.05)
            drone(.a2, from: 36.8, for: 3.2, amp: 0.04)
            drone(.a1, from: 40.0, for: 5.0, amp: 0.07)
            drone(.e2, from: 40.0, for: 5.0, amp: 0.05)

            // ─── INSECT FOLEY: chitter density tracks the population ────
            every(0.21, from: 0.3, to: 2.0) { t in
                h(t) > 0.55 ? hat(at: t, amp: 0.05, pan: -0.25 + (h(t * 3.1) - 0.5) * 0.2) : []
            }
            hat(at: 1.55, amp: 0.06, pan: -0.22)   // antennae twitch, two flicks
            hat(at: 1.66, amp: 0.06, pan: -0.18)
            every(0.16, from: 7.4, to: 11.0) { t in
                h(t) < (t - 7.2) / 3.8 ? hat(at: t, amp: 0.06, pan: (h(t * 1.7) * 2 - 1) * 0.8) : []
            }
            every(0.09, from: 9.2, to: 11.0) { t in
                h(t * 2.9) < 0.5 ? hat(at: t, amp: 0.05, pan: (h(t * 0.7) * 2 - 1) * 0.9) : []
            }
            every(0.13, from: 11.2, to: 14.6) { t in
                h(t * 2.3) < 0.55 ? hat(at: t, amp: 0.05, pan: (h(t * 1.9) * 2 - 1) * 0.7) : []
            }
            every(0.2, from: 14.6, to: 19.4) { t in
                h(t * 3.3) < 0.2 ? hat(at: t, amp: 0.035, pan: (h(t * 1.1) * 2 - 1) * 0.6) : []
            }
            every(0.12, from: 19.4, to: 20.5) { t in   // hard stop at 20.5
                h(t * 2.1) < 0.6 ? hat(at: t, amp: 0.055, pan: (h(t * 1.5) * 2 - 1) * 0.7) : []
            }
            hat(at: 21.90, amp: 0.07, pan: -0.6)   // replacement scurries in
            hat(at: 21.96, amp: 0.07, pan: -0.4)
            hat(at: 22.03, amp: 0.06, pan: -0.2)
            hat(at: 22.11, amp: 0.06, pan: 0.0)
            every(0.12, from: 21.3, to: 24.2) { t in
                h(t * 2.7) < 0.55 ? hat(at: t, amp: 0.05, pan: (h(t * 1.3) * 2 - 1) * 0.7) : []
            }
            every(0.14, from: 24.2, to: 36.8) { t in
                h(t * 1.9) < 0.45 ? hat(at: t, amp: 0.05, pan: (h(t * 0.9) * 2 - 1) * 0.75) : []
            }
            every(0.15, from: 36.8, to: 43.4) { t in
                h(t * 2.4) < 0.4 ? hat(at: t, amp: 0.045, pan: (h(t * 1.6) * 2 - 1) * 0.7) : []
            }
            every(0.11, from: 43.4, to: 44.4) { t in
                h(t * 3.7) < (44.7 - t) / 1.3 * 0.7 ? hat(at: t, amp: 0.04, pan: (h(t * 1.3) * 2 - 1) * 0.95) : []
            }
            hat(at: 44.5, amp: 0.06, pan: 0.4)     // the last lone click

            // ─── TYPE MECHANICS: typewriters, ticks, carriage returns ───
            every(0.07, from: 1.9, to: 3.0) { t in hat(at: t, amp: 0.02, pan: 0.2) }
            every(0.06, from: 3.3, to: 4.25) { t in hat(at: t, amp: 0.02, pan: 0.1) }
            every(0.029, from: 15.1, to: 17.7) { t in
                h(t * 7.3) > 0.2 ? hat(at: t, amp: 0.022, pan: 0.12) : []
            }
            clap(at: 15.72, amp: 0.1, pan: 0.15)   // carriage returns per code line
            clap(at: 16.31, amp: 0.1, pan: 0.15)
            clap(at: 16.90, amp: 0.1, pan: 0.15)
            clap(at: 17.35, amp: 0.1, pan: 0.15)
            clap(at: 17.70, amp: 0.12, pan: 0.15)
            every(0.55, from: 28.6, to: 31.4) { t in
                hat(at: t, amp: 0.03, pan: -0.15)
                    + hat(at: t + 0.06, amp: 0.03, pan: -0.1)
                    + hat(at: t + 0.13, amp: 0.03, pan: -0.05)
                    + clap(at: t + 0.3, amp: 0.2, pan: (h(t) - 0.5) * 0.5)
            }
            clap(at: 31.9, amp: 0.15, pan: 0)      // caption stamp
            every(0.045, from: 37.0, to: 38.6) { t in
                h(t * 5.1) > 0.15 ? hat(at: t, amp: 0.025, pan: -0.1) : []
            }
            clap(at: 38.62, amp: 0.12, pan: -0.1)  // return key
            clap(at: 38.72, amp: 0.22, pan: 0)     // success line
            hat(at: 38.72, amp: 0.05, pan: 0)

            // ─── PUNCTUATION: cuts, stamps, exactly two booms ────────────
            kick(at: 3.2, amp: 0.4); clap(at: 3.2, amp: 0.3, pan: 0)
            kick(at: 7.2, amp: 0.4); clap(at: 7.2, amp: 0.3, pan: 0)
            every(0.05, from: 7.3, to: 10.6) { t in
                h(t * 4.3) < 0.5 ? hat(at: t, amp: 0.02, pan: 0.25) : []
            }
            clap(at: 4.72, amp: 0.25, pan: -0.1)
            clap(at: 5.32, amp: 0.25, pan: 0.1)
            clap(at: 5.92, amp: 0.25, pan: -0.1)
            kick(at: 6.5, amp: 0.5); clap(at: 6.5, amp: 0.35, pan: 0)
            boom(at: 11.0, amp: 0.85, duration: 2.4)                 // BOOM #1: wordmark
            kick(at: 11.0, amp: 0.6); clap(at: 11.0, amp: 0.35, pan: 0)
            kick(at: 14.6, amp: 0.4); clap(at: 14.6, amp: 0.3, pan: 0)
            kick(at: 19.4, amp: 0.4); clap(at: 19.4, amp: 0.3, pan: 0)
            clap(at: 20.9, amp: 0.5, pan: 0)                         // the death snap
            boom(at: 20.9, amp: 0.35, duration: 1.2)
            kick(at: 21.4, amp: 0.35)
            kick(at: 24.2, amp: 0.55); clap(at: 24.2, amp: 0.3, pan: 0)
            bass(.a1, at: 24.2, duration: 0.8, amp: 0.3)
            kick(at: 25.6, amp: 0.55); clap(at: 25.6, amp: 0.3, pan: 0)
            bass(.c2, at: 25.6, duration: 0.8, amp: 0.3)
            kick(at: 27.0, amp: 0.55); clap(at: 27.0, amp: 0.3, pan: 0)
            bass(.e2, at: 27.0, duration: 0.8, amp: 0.3)
            kick(at: 28.4, amp: 0.4); clap(at: 28.4, amp: 0.3, pan: 0)
            kick(at: 32.6, amp: 0.4); clap(at: 32.6, amp: 0.3, pan: 0)
            bass(.a2, at: 33.05, duration: 0.4, amp: 0.25)
            bass(.g2, at: 33.55, duration: 0.4, amp: 0.25)
            bass(.g2, at: 34.05, duration: 0.4, amp: 0.25)
            bass(.e1, at: 34.55, duration: 0.4, amp: 0.22)
            kick(at: 36.8, amp: 0.4); clap(at: 36.8, amp: 0.3, pan: 0)
            boom(at: 40.0, amp: 0.95, duration: 2.8)                 // BOOM #2: lockup
            kick(at: 40.0, amp: 0.6); clap(at: 40.0, amp: 0.4, pan: 0)
        }
    }

    // MARK: - Body

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let fade = Ease.easeIn(Ease.clip(t, 44.2, 45.0))
        return ZStack {
            paper.ignoresSafeArea()
            colony(t)
            Timeline(t) {
                Clip(3.2) { l in s0Specimen(l) }
                Clip(4.0) { l in s1Problem(l) }
                Clip(3.8) { l in s2Spawn(l) }
                Clip(3.6) { l in s3Wordmark(l) }
                Clip(4.8) { l in s4Code(l) }
                Clip(4.8) { l in s5Supervision(l) }
                Clip(4.2) { l in s6Stats(l) }
                Clip(4.2) { l in s7Batteries(l) }
                Clip(4.2) { l in s8Proof(l) }
                Clip(8.2) { l in s9Ship(l) }
            }
            hud(t)
            paper.opacity(fade).ignoresSafeArea()   // fade to paper, not black
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PostFX(time: t, grainAmount: 0.07, vignetteAmount: 0.14))
    }

    // MARK: - Hero bug (S0–S2): scripted waypoint walk, phase from arc length

    static let heroKeys: [(t: Double, x: Double, y: Double)] = [
        (0.0, -90, 640), (1.35, 600, 615), (2.35, 600, 615),
        (3.2, 648, 662), (4.4, 648, 662), (5.3, 705, 700),
        (7.25, 762, 728), (8.3, 762, 728), (9.6, 380, 828),
        (11.0, 235, 862), (12.4, -90, 905),
    ]
    static let heroScale = 1.05
    static let heroCum: [Double] = {
        var out: [Double] = [0]
        for i in 1..<heroKeys.count {
            let dx = heroKeys[i].x - heroKeys[i - 1].x, dy = heroKeys[i].y - heroKeys[i - 1].y
            out.append(out[i - 1] + sqrt(dx * dx + dy * dy))
        }
        return out
    }()

    static func heroState(_ t: Double) -> (x: Double, y: Double, heading: Double, phase: Double)? {
        guard t < heroKeys[heroKeys.count - 1].t else { return nil }
        var k = 0
        for i in 0..<(heroKeys.count - 1) where t >= heroKeys[i].t { k = i }
        let a = heroKeys[k], b = heroKeys[k + 1]
        let u = Ease.easeInOut(min(1, max(0, (t - a.t) / max(b.t - a.t, 1e-9))))
        let x = a.x + (b.x - a.x) * u, y = a.y + (b.y - a.y) * u
        var dir = atan2(b.y - a.y, b.x - a.x)
        if abs(b.x - a.x) < 1 && abs(b.y - a.y) < 1 {   // paused segment: hold previous heading
            var j = k
            while j > 0 && abs(heroKeys[j + 1].x - heroKeys[j].x) < 1 && abs(heroKeys[j + 1].y - heroKeys[j].y) < 1 { j -= 1 }
            dir = atan2(heroKeys[j + 1].y - heroKeys[j].y, heroKeys[j + 1].x - heroKeys[j].x)
        }
        let dist = heroCum[k] + (heroCum[k + 1] - heroCum[k]) * u
        return (x, y, dir, dist / (7.0 * heroScale))
    }

    // MARK: - Ambient colony

    static func population(_ t: Double) -> Int {
        if t < 7.25 { return 0 }
        if t < 10.6 { return 1 + Int((t - 7.25) / 3.35 * 149) }   // linear, matches counter
        if t < 14.6 { return 150 }
        if t < 15.6 { return 150 - Int((t - 14.6) * 60) }
        if t < 36.8 { return 90 }
        if t < 37.6 { return 90 + Int((t - 36.8) * 25) }
        return 110
    }

    /// Two candidate wander-rects per section: (x, y, w, h). Bugs stay out of
    /// each section's text zone; regions shift at cuts so the colony migrates.
    static let regions: [[(Double, Double, Double, Double)]] = [
        [(200, 700, 500, 250), (200, 700, 500, 250)],              // S0 (unused, pop 0)
        [(200, 750, 500, 200), (200, 750, 500, 200)],              // S1 (unused)
        [(620, 430, 1210, 470), (840, 300, 700, 120)],             // S2 clear of counter + code line
        [(150, 110, 1620, 220), (150, 800, 1620, 190)],            // S3 top + bottom bands
        [(90, 160, 290, 760), (1540, 160, 290, 760)],              // S4 side margins
        [(150, 860, 1620, 140), (1100, 130, 700, 160)],            // S5 bottom band + top right
        [(150, 110, 1620, 170), (150, 830, 1620, 170)],            // S6 bands
        [(1480, 160, 340, 760), (150, 130, 1300, 100)],            // S7 right margin + top
        [(150, 850, 1620, 150), (90, 160, 280, 640)],              // S8 bottom + left
        [(150, 130, 1620, 180), (150, 800, 1620, 180)],            // S9 bands until ring forms
    ]

    static func sectionIndex(_ t: Double) -> Int {
        var s = 0
        for (i, st) in starts.enumerated() where t >= st { s = i }
        return s
    }

    /// Text keep-out rects per section (x, y, w, h) — ambient bugs fade to
    /// nothing inside these and within a 50px soft margin around them.
    static let keepouts: [Int: [(Double, Double, Double, Double)]] = [
        2: [(100, 120, 720, 320), (1140, 140, 700, 150)],
        3: [(330, 360, 1260, 430)],
        4: [(360, 280, 1200, 580)],
        5: [(950, 250, 780, 580), (630, 370, 280, 110)],
        6: [(460, 320, 1000, 540)],
        7: [(430, 210, 1060, 660)],
        8: [(290, 280, 1340, 520)],
        9: [(500, 430, 920, 320)],
    ]

    /// 1 → fully visible, 0 → hidden. Soft-fades bugs near section text and
    /// at the HUD frame so nothing crawls over type or chrome.
    static func visFactor(_ x: Double, _ y: Double, _ s: Int) -> Double {
        var f = min(1, max(0, (x - 66) / 40)) * min(1, max(0, (1854 - x) / 40))
            * min(1, max(0, (y - 98) / 40)) * min(1, max(0, (982 - y) / 40))
        guard f > 0 else { return 0 }
        for r in keepouts[s] ?? [] {
            if x >= r.0 - 50 && x <= r.0 + r.2 + 50 && y >= r.1 - 50 && y <= r.1 + r.3 + 50 {
                let dx = max(max(r.0 - x, x - (r.0 + r.2)), 0)
                let dy = max(max(r.1 - y, y - (r.1 + r.3)), 0)
                let inside = dx == 0 && dy == 0
                let d = inside ? 0 : sqrt(dx * dx + dy * dy)
                f *= min(1, d / 50)
                if f <= 0 { return 0 }
            }
        }
        return f
    }

    static func anchor(_ i: Int, _ s: Int) -> (Double, Double) {
        let fi = Double(i), fs = Double(s)
        let opts = regions[s]
        let r = h(fi * 7.7 + fs * 13.3) > 0.5 ? opts[0] : opts[1]
        return (r.0 + h(fi * 3.1 + fs * 29.7) * r.2, r.1 + h(fi * 5.3 + fs * 31.9) * r.3)
    }

    static func ambientPos(_ i: Int, _ t: Double) -> (Double, Double) {
        let fi = Double(i)
        let s = sectionIndex(t)
        var (ax, ay) = anchor(i, s)
        if s > 0 {
            let tIn = t - starts[s]
            if tIn < 0.7 {
                let (px, py) = anchor(i, s - 1)
                let u = Ease.easeInOut(tIn / 0.7)
                ax = px + (ax - px) * u
                ay = py + (ay - py) * u
            }
        }
        // dart-cell wander around the anchor
        let rate = 0.9 + h(fi * 5.9) * 1.1
        let phase = h(fi * 6.1) * 7
        let cell = floor(t * rate + phase)
        let frac = t * rate + phase - cell
        let snap = outQuart(min(1, frac * 2.0))
        let amp = 26.0 + h(fi * 9.7) * 42
        let j0x = (h(fi * 11.1 + cell * 17.7) - 0.5) * 2 * amp
        let j0y = (h(fi * 12.3 + cell * 19.3) - 0.5) * 2 * amp
        let j1x = (h(fi * 11.1 + (cell + 1) * 17.7) - 0.5) * 2 * amp
        let j1y = (h(fi * 12.3 + (cell + 1) * 19.3) - 0.5) * 2 * amp
        var x = ax + j0x + (j1x - j0x) * snap
        var y = ay + j0y + (j1y - j0y) * snap
        // S9: fall into the orbit ring around the lockup (clears all type)
        if t > 39.6 {
            let m = outQuart(Ease.clip(t, 39.6, 40.8))
            let n = Double(max(population(t), 1))
            let ringAng = fi / n * 2 * .pi + t * 0.22
            let jitter = (h(fi * 3.3) - 0.5) * 48
            let rx = 960 + cos(ringAng) * (620 + jitter)
            let ry = 560 + sin(ringAng) * (330 + jitter * 0.55)
            // damp the wander so orbiting bugs stay on the path, off the glyphs
            x = ax + (x - ax) * (1 - 0.85 * m)
            y = ay + (y - ay) * (1 - 0.85 * m)
            x += (rx - x) * m
            y += (ry - y) * m
        }
        // disperse
        if t > 43.4 {
            let d = Ease.easeIn(Ease.clip(t, 43.4, 44.7))
            let dx = x - 960, dy = y - 560
            let len = max(sqrt(dx * dx + dy * dy), 1)
            x += dx / len * d * 1500
            y += dy / len * d * 1500
        }
        return (x, y)
    }

    // MARK: - S5 cluster (drawn in the master canvas so links stay hairlines)

    static let clusterPts: [(Double, Double)] = [(400, 375), (665, 350), (330, 565),
                                                 (560, 540), (705, 615), (430, 725)]
    static let clusterLinks: [(Int, Int)] = [(0, 1), (0, 2), (1, 3), (0, 3), (2, 3),
                                             (3, 4), (2, 5), (4, 5), (1, 4), (3, 5)]
    static let deadIdx = 3

    // MARK: - The colony canvas

    @MainActor
    static func colony(_ t: Double) -> some View {
        Canvas { ctx, _ in
            // hero
            if let hero = heroState(t), hero.x > -95 {
                BugRig.draw(&ctx, x: hero.x, y: hero.y, heading: hero.heading,
                            scale: heroScale, gaitPhase: hero.phase,
                            ink: ink, accent: red, dead: false, detail: true)
            }
            // ambient colony
            let pop = population(t)
            for i in 0..<pop {
                let fi = Double(i)
                var born: Double
                if i >= 90 && t >= 36.8 {
                    born = outQuart(Ease.clip(t, 36.8 + Double(i - 90) * 0.03, 36.8 + Double(i - 90) * 0.03 + 0.3))
                } else {
                    let b1 = 7.25 + 3.35 * fi / 149.0
                    born = outQuart(Ease.clip(t, b1, b1 + 0.3))
                }
                if born <= 0.02 { continue }
                let (x, y) = ambientPos(i, t)
                if x < -60 || x > 1980 || y < -60 || y > 1140 { continue }
                let vis = visFactor(x, y, sectionIndex(t))
                if vis <= 0.03 { continue }
                let (px, py) = ambientPos(i, t - 0.06)
                let heading = atan2(y - py, x - px)
                let medium = i % 13 == 0
                let scale = (medium ? 0.42 : 0.17 + h(fi * 9.1) * 0.13) * born
                BugRig.draw(&ctx, x: x, y: y, heading: heading,
                            scale: scale, gaitPhase: t * (5 + h(fi) * 3),
                            ink: ink.opacity(vis), accent: red.opacity(vis),
                            dead: false, detail: medium)
            }
            // S5 supervision cluster
            if t > 19.4 && t < 24.25 {
                drawCluster(&ctx, t)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    static let clusterScale = 0.78

    static func drawCluster(_ ctx: inout GraphicsContext, _ t: Double) {
        let tIn = t - 19.4
        let fadeOut = 1 - Ease.clip(t, 24.0, 24.2)
        let dead = t >= 20.9
        let corpseFade = (1 - Ease.clip(t, 23.0, 23.4)) * fadeOut
        let dashFade = (1 - Ease.clip(t, 22.6, 23.0)) * fadeOut
        // replacement bug: scurries in 21.9→22.7, then holds position
        let repU = outQuart(Ease.clip(t, 21.9, 22.7))
        let repPos = (60.0 + (585.0 - 60.0) * repU, 480.0 + (470.0 - 480.0) * repU)
        let repHeading = atan2(470.0 - 480.0, 585.0 - 60.0)

        // links
        for (a, b) in clusterLinks {
            let la = outQuart(Ease.clip(tIn, 0.15 + Double(a + b) * 0.02, 0.55 + Double(a + b) * 0.02))
            let touchesDead = a == deadIdx || b == deadIdx
            let pa = clusterPts[a], pb = clusterPts[b]
            var path = Path()
            path.move(to: CGPoint(x: pa.0, y: pa.1))
            path.addLine(to: CGPoint(x: pa.0 + (pb.0 - pa.0) * la, y: pa.1 + (pb.1 - pa.1) * la))
            if touchesDead && dead {
                if dashFade > 0.01 {
                    ctx.stroke(path, with: .color(red.opacity(0.55 * dashFade)),
                               style: StrokeStyle(lineWidth: 1.4, dash: [5, 5]))
                }
            } else {
                ctx.stroke(path, with: .color(ink.opacity(0.38 * fadeOut)), lineWidth: 1.4)
            }
        }
        // the mesh heals: solid links re-form to the replacement, staggered
        if t > 22.5 {
            for (k, target) in [0, 1, 4].enumerated() {
                let lp = outQuart(Ease.clip(t, 22.5 + Double(k) * 0.12, 22.85 + Double(k) * 0.12))
                let pa = repPos, pb = clusterPts[target]
                var path = Path()
                path.move(to: CGPoint(x: pa.0, y: pa.1))
                path.addLine(to: CGPoint(x: pa.0 + (pb.0 - pa.0) * lp, y: pa.1 + (pb.1 - pa.1) * lp))
                ctx.stroke(path, with: .color(ink.opacity(0.38 * fadeOut)), lineWidth: 1.4)
            }
        }
        // supervisor pulse ring: three pulses around the corpse
        for pulseStart in [21.4, 21.9, 22.4] {
            let pulse = Ease.clip(t, pulseStart, pulseStart + 0.55)
            if pulse > 0 && pulse < 1 {
                let p = clusterPts[deadIdx]
                let r = 26 + outQuart(pulse) * 120
                ctx.stroke(Path(ellipseIn: CGRect(x: p.0 - r, y: p.1 - r, width: r * 2, height: r * 2)),
                           with: .color(red.opacity((1 - pulse) * 0.8)), lineWidth: 3.5)
            }
        }
        // exit-signal pointer (fades with the corpse)
        if t > 21.1 {
            let a = outQuart(Ease.clip(t, 21.1, 21.35))
            var path = Path()
            path.move(to: CGPoint(x: 700, y: 432))
            path.addLine(to: CGPoint(x: 700 - (700 - 585) * a, y: 432 + (525 - 432) * a))
            ctx.stroke(path, with: .color(red.opacity(0.85 * corpseFade)), lineWidth: 1.4)
        }
        // the six bugs
        for (i, p) in clusterPts.enumerated() {
            let born = outQuart(Ease.clip(tIn, 0.1 + Double(i) * 0.06, 0.38 + Double(i) * 0.06))
            if born <= 0.02 { continue }
            let idle = sin(t * 1.7 + Double(i) * 2.1) * 0.12
            let isDead = i == deadIdx && dead
            let alpha = isDead ? 0.62 * corpseFade : fadeOut   // corpses go gray instantly
            if alpha <= 0.02 { continue }
            BugRig.draw(&ctx, x: p.0, y: p.1 + (isDead ? 4 : 0),
                        heading: h(Double(i) * 21.3) * 2 * .pi,
                        scale: clusterScale * born, gaitPhase: 3 + idle,
                        ink: ink.opacity(alpha), accent: red,
                        dead: isDead, detail: true)
        }
        // replacement bug
        if t > 21.9 {
            let walking = t < 22.7
            BugRig.draw(&ctx, x: repPos.0, y: repPos.1,
                        heading: walking ? repHeading : h(99.7) * 2 * .pi,
                        scale: clusterScale, gaitPhase: walking ? (repU * 525) / (7.0 * clusterScale) : 75.0,
                        ink: ink.opacity(fadeOut), accent: red, dead: false, detail: true)
        }
    }

    // MARK: - S0 · specimen

    @ViewBuilder @MainActor
    static func s0Specimen(_ t: Double) -> some View {
        let boxIn = outQuart(Ease.clip(t, 1.88, 2.12))
        let line = "PROCESS Nº 000001"
        let sub1 = "heap: isolated · stack: 2 KB"
        let sub2 = "state: receiving"
        let typed = Int(Ease.clip(t, 1.9, 2.5) * Double(line.count))
        let s1v = Ease.clip(t, 2.5, 2.75), s2v = Ease.clip(t, 2.75, 3.0)
        ZStack {
            // pointer hairline from bug to the label
            SpecPointer(a: CGPoint(x: 640, y: 585), b: CGPoint(x: 812, y: 505),
                        progress: boxIn, color: ink.opacity(0.6))
            VStack(alignment: .leading, spacing: 10) {
                Text(String(line.prefix(typed)))
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(ink)
                Text(String(sub1.prefix(Int(s1v * Double(sub1.count)))))
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.65))
                Text(String(sub2.prefix(Int(s2v * Double(sub2.count)))))
                    .font(.system(size: 17, design: .monospaced))
                    .foregroundStyle(red)
            }
            .padding(18)
            .frame(width: 420, height: 150, alignment: .topLeading)
            .background(Rectangle().stroke(ink.opacity(0.7), lineWidth: 1.3).background(paper.opacity(0.85)))
            .position(x: 1040, y: 460)
            .opacity(boxIn)
            .offset(y: (1 - boxIn) * 8)
        }
    }

    // MARK: - S1 · the problem

    @ViewBuilder @MainActor
    static func s1Problem(_ t: Double) -> some View {
        let l1 = "your AI agents need"
        let l2 = "a runtime."
        let t1 = Int(Ease.clip(t, 0.1, 0.6) * Double(l1.count))
        let t2 = Int(Ease.clip(t, 0.6, 1.05) * Double(l2.count))
        // (text, strike time, strike-line width matched to the text)
        let strikes: [(String, Double, Double)] = [("asyncio + hope", 1.5, 345),
                                                   ("a container per agent", 2.1, 512),
                                                   ("threads and locks", 2.7, 418)]
        let chipIn = outExpo(Ease.clip(t, 3.3, 3.8))
        let exit = Ease.easeIn(Ease.clip(t, 3.8, 4.0))
        VStack(alignment: .leading, spacing: 34) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(l1.prefix(t1)))
                    .font(.system(size: 58, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ink)
                Text(String(l2.prefix(t2)))
                    .font(.system(size: 104, weight: .black, design: .monospaced))
                    .foregroundStyle(ink)
            }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(0..<strikes.count, id: \.self) { i in
                    let appear = outQuart(Ease.clip(t, strikes[i].1 - 0.15, strikes[i].1 + 0.09))
                    let strike = outQuart(Ease.clip(t, strikes[i].1, strikes[i].1 + 0.24))
                    HStack(spacing: 18) {
                        Text(strikes[i].0)
                            .font(.system(size: 40, weight: .medium, design: .monospaced))
                            .foregroundStyle(ink.opacity(0.72))
                            .overlay(alignment: .leading) {
                                Rectangle().fill(red)
                                    .frame(width: CGFloat(strike * strikes[i].2), height: 5)
                                    .offset(y: 1)
                            }
                        Text("✕")
                            .font(.system(size: 34, weight: .black, design: .monospaced))
                            .foregroundStyle(red)
                            .opacity(strike >= 0.99 ? 1 : 0)
                    }
                    .opacity(appear)
                    .offset(x: (1 - appear) * -10)
                }
            }
            Text("swarmrt")
                .font(.system(size: 52, weight: .black, design: .monospaced))
                .foregroundStyle(paper)
                .padding(.horizontal, 26).padding(.vertical, 12)
                .background(Rectangle().fill(red))
                .scaleEffect(0.96 + 0.04 * chipIn, anchor: .leading)
                .opacity(chipIn)
        }
        .frame(width: 1250, alignment: .leading)
        .position(x: 760, y: 520)
        .opacity(1 - exit)
        .offset(y: exit * -12)
    }

    // MARK: - S2 · spawn

    @ViewBuilder @MainActor
    static func s2Spawn(_ t: Double) -> some View {
        let absT = t + 7.2
        let count = min(150, max(1, 1 + Int((absT - 7.3) / 3.1 * 149)))   // LINEAR roll
        let line = "pid = spawn(agent(state))"
        let typed = Int(Ease.clip(t, 0.3, 1.4) * Double(line.count))
        let capIn = outQuart(Ease.clip(t, 1.7, 2.0))
        let exit = Ease.easeIn(Ease.clip(t, 3.6, 3.8))
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%06d", count))
                    .font(.system(size: 128, weight: .black, design: .monospaced))
                    .foregroundStyle(ink)
                HStack(spacing: 14) {
                    Rectangle().fill(red).frame(width: 46, height: 5)
                    Text("PROCESSES / LIVE")
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .tracking(8)
                        .foregroundStyle(red)
                }
                Text("100,000+ per node — we drew 150.")
                    .font(.system(size: 20, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.6))
                    .padding(.top, 10)
                    .opacity(capIn)
            }
            .padding(.top, 130).padding(.leading, 120)
            VStack(alignment: .trailing, spacing: 14) {
                HStack(spacing: 2) {
                    Text(String(line.prefix(typed)))
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ink)
                    Rectangle().fill(red).frame(width: 14, height: 34)
                        .opacity(Int(t * 4) % 2 == 0 ? 1 : 0)
                }
                Text("cheap enough to never think twice.")
                    .font(.system(size: 22, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.6))
                    .opacity(capIn)
                    .offset(y: (1 - capIn) * 8)
            }
            .padding(.top, 170)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 130)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(1 - exit)
    }

    // MARK: - S3 · wordmark

    @ViewBuilder @MainActor
    static func s3Wordmark(_ t: Double) -> some View {
        let heroIn = outQuart(Ease.clip(t, 0.0, 0.28))        // press-stamp: 1.05 → 1.00
        let fadeIn = Ease.clip(t, 0.0, 0.12)
        let bar = outQuart(Ease.clip(t, 0.5, 0.8))
        let sub1 = outQuart(Ease.clip(t, 0.9, 1.14))
        let sub2 = outQuart(Ease.clip(t, 1.3, 1.54))
        let chip = outQuart(Ease.clip(t, 1.8, 2.04))
        let exit = Ease.easeIn(Ease.clip(t, 3.4, 3.6))
        VStack(spacing: 30) {
            Text("swarmrt")
                .font(.system(size: 224, weight: .black, design: .monospaced))
                .foregroundStyle(ink)
                .scaleEffect(1.05 - 0.05 * heroIn)
                .opacity(fadeIn)
            Rectangle().fill(red)
                .frame(width: CGFloat(bar) * 780, height: 10)
            VStack(spacing: 12) {
                Text("a BEAM-shaped runtime for the AI-agent era.")
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ink)
                    .opacity(sub1)
                    .offset(y: (1 - sub1) * 8)
                Text("no VM · no GC pauses · boots in <10 ms · one native binary")
                    .font(.system(size: 24, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.65))
                    .opacity(sub2)
                    .offset(y: (1 - sub2) * 8)
            }
            Text("WRITTEN IN C · MIT")
                .font(.system(size: 19, weight: .bold, design: .monospaced))
                .tracking(6)
                .foregroundStyle(orange)
                .opacity(chip)
        }
        .offset(y: 20)
        .opacity(1 - exit)
        .offset(y: exit * -12)
    }

    // MARK: - S4 · the agent loop (typewriter code card)

    static let codeLines: [(String, Color)] = [
        ("fun agent(state) {", ink.opacity(0.55)),
        ("  receive {", red),
        ("    {'task', job} -> agent(run(state, job))", ink),
        ("    'stop'        -> exit('normal')", ink),
        ("  }", red),
        ("}", ink.opacity(0.55)),
    ]
    /// cumulative char counts + the time each line finishes (mirrors the claps)
    static let codeCum: [Int] = { var c = 0; return codeLines.map { c += $0.0.count; return c } }()
    static let codeDone: [Double] = [15.72, 16.31, 16.90, 17.35, 17.52, 17.70]

    static func codeChars(_ absT: Double) -> Int {
        guard absT > 15.1 else { return 0 }
        var prevT = 15.1, prevC = 0
        for (i, doneT) in codeDone.enumerated() {
            if absT < doneT {
                let u = (absT - prevT) / max(doneT - prevT, 1e-9)
                return prevC + Int(u * Double(codeCum[i] - prevC))
            }
            prevT = doneT; prevC = codeCum[i]
        }
        return codeCum[codeCum.count - 1]
    }

    @ViewBuilder @MainActor
    static func s4Code(_ t: Double) -> some View {
        let absT = t + 14.6
        let cardIn = outQuart(Ease.clip(t, 0.05, 0.35))
        let chars = codeChars(absT)
        let capIn = outQuart(Ease.clip(t, 3.5, 3.8))
        let exit = Ease.easeIn(Ease.clip(t, 4.6, 4.8))
        VStack(alignment: .leading, spacing: 24) {
            ZStack(alignment: .topLeading) {
                Rectangle().fill(ink).offset(x: 12, y: 12)          // print-offset shadow block
                Rectangle().fill(paper)
                    .overlay(Rectangle().stroke(ink, lineWidth: 2.5))
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("FIG. 04 — THE AGENT LOOP")
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                            .tracking(4)
                            .foregroundStyle(red)
                        Spacer()
                        Text("agent.sw")
                            .font(.system(size: 18, design: .monospaced))
                            .foregroundStyle(ink.opacity(0.5))
                    }
                    .padding(.bottom, 26)
                    ForEach(0..<codeLines.count, id: \.self) { i in
                        let prev = i == 0 ? 0 : codeCum[i - 1]
                        let visible = max(0, min(codeLines[i].0.count, chars - prev))
                        HStack(alignment: .top, spacing: 20) {
                            Text(String(format: "%02d", i + 1))
                                .font(.system(size: 17, design: .monospaced))
                                .foregroundStyle(red.opacity(0.55))
                                .padding(.top, 6)
                            HStack(spacing: 0) {
                                Text(String(codeLines[i].0.prefix(visible)))
                                    .font(.system(size: 31, weight: .medium, design: .monospaced))
                                    .foregroundStyle(codeLines[i].1)
                                if visible < codeLines[i].0.count && chars >= prev && absT < 17.75 {
                                    Rectangle().fill(red).frame(width: 15, height: 32)
                                        .opacity(Int(absT * 4) % 2 == 0 ? 1 : 0)
                                }
                            }
                        }
                        .frame(height: 44, alignment: .leading)
                        .opacity(visible > 0 || chars >= prev ? 1 : 0)
                    }
                }
                .padding(38)
            }
            .frame(width: 1130, height: 420)
            .scaleEffect(0.96 + 0.04 * cardIn)
            .opacity(cardIn)
            .offset(y: (1 - cardIn) * 10)
            Text("sw — a model that has never seen it writes it right, first try.")
                .font(.system(size: 25, design: .monospaced))
                .foregroundStyle(ink.opacity(0.75))
                .opacity(capIn)
                .offset(y: (1 - capIn) * 8)
        }
        .position(x: 960, y: 545)
        .opacity(1 - exit)
    }

    // MARK: - S5 · supervision

    @ViewBuilder @MainActor
    static func s5Supervision(_ t: Double) -> some View {
        let s1 = outExpo(Ease.clip(t, 0.5, 1.2))       // "processes crash."
        let s1f = Ease.clip(t, 0.5, 0.72)
        let s2 = outExpo(Ease.clip(t, 2.5, 3.2))       // "the swarm doesn't."
        let s2f = Ease.clip(t, 2.5, 2.72)
        let sub = outQuart(Ease.clip(t, 3.2, 3.5))
        let label = outQuart(Ease.clip(t, 1.7, 1.94))
        let exit = Ease.easeIn(Ease.clip(t, 4.6, 4.8))
        ZStack {
            VStack(alignment: .leading, spacing: 30) {
                Text("processes crash.")
                    .font(.system(size: 62, weight: .black, design: .monospaced))
                    .foregroundStyle(ink)
                    .scaleEffect(0.95 + 0.05 * s1, anchor: .leading)
                    .opacity(s1f)
                Text("the swarm\ndoesn't.")
                    .font(.system(size: 96, weight: .black, design: .monospaced))
                    .foregroundStyle(ink)
                    .scaleEffect(0.95 + 0.05 * s2, anchor: .leading)
                    .opacity(s2f)
                Text("link · monitor · trap_exit · supervise\n— in the language, not a sidecar.")
                    .font(.system(size: 24, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.65))
                    .opacity(sub)
                    .offset(y: (1 - sub) * 8)
            }
            .frame(width: 660, alignment: .leading)
            .position(x: 1345, y: 540)
            Text("EXIT SIGNAL")
                .font(.system(size: 19, weight: .bold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(paper)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Rectangle().fill(red))
                .position(x: 770, y: 420)
                .opacity(label)
                .offset(y: (1 - label) * 6)
        }
        .opacity(1 - exit)
    }

    // MARK: - S6 · numbers

    @ViewBuilder @MainActor
    static func s6Stats(_ t: Double) -> some View {
        let stats: [(String, String, String)] = [
            ("150", "ns", "CONTEXT SWITCH"),
            ("<10", "ms", "COLD BOOT"),
            ("<250", "KB", "THE COMPILED BINARY"),
        ]
        let idx = min(2, Int(t / 1.4))
        let local = t - Double(idx) * 1.4
        let stamp = outExpo(min(1, local / 0.6))
        let fadeIn = Ease.clip(local, 0, 0.18)
        let label = outQuart(Ease.clip(local, 0.3, 0.54))
        let brackets = outQuart(Ease.clip(local, 0.15, 0.45))
        VStack(spacing: 30) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(stats[idx].0)
                    .font(.system(size: 250, weight: .black, design: .monospaced))
                    .foregroundStyle(ink)
                Text(stats[idx].1)
                    .font(.system(size: 110, weight: .black, design: .monospaced))
                    .foregroundStyle(red)
            }
            .scaleEffect(0.95 + 0.05 * stamp)
            .opacity(fadeIn)
            HStack(spacing: 26) {
                DimensionLine(width: 170 * brackets, tick: 12, color: ink.opacity(0.5))
                Text(stats[idx].2)
                    .font(.system(size: 27, weight: .bold, design: .monospaced))
                    .tracking(10)
                    .foregroundStyle(ink.opacity(0.8))
                    .opacity(label)
                DimensionLine(width: 170 * brackets, tick: 12, color: ink.opacity(0.5))
            }
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(i == idx ? red : ink.opacity(0.25))
                        .frame(width: 9, height: 9)
                }
            }
            .padding(.top, 8)
        }
        .offset(y: 10)
    }

    // MARK: - S7 · batteries

    @ViewBuilder @MainActor
    static func s7Batteries(_ t: Double) -> some View {
        let rows = ["sqlite", "mcp client + server", "http · websocket",
                    "sandboxed shell", "cross-compile", "supervision trees"]
        let head = outQuart(Ease.clip(t, 0.05, 0.29))
        let cap = outExpo(Ease.clip(t, 3.5, 4.0))
        let exit = Ease.easeIn(Ease.clip(t, 4.05, 4.2))
        VStack(alignment: .leading, spacing: 22) {
            Text("INCLUDED IN THE RUNTIME")
                .font(.system(size: 21, weight: .bold, design: .monospaced))
                .tracking(8)
                .foregroundStyle(red)
                .opacity(head)
                .padding(.bottom, 8)
            ForEach(0..<rows.count, id: \.self) { i in
                let rowT = 0.2 + Double(i) * 0.55
                let rowIn = outQuart(Ease.clip(t, rowT, rowT + 0.18))
                let tick = outQuart(Ease.clip(t, rowT + 0.3, rowT + 0.42))
                HStack(spacing: 0) {
                    Text(rows[i])
                        .font(.system(size: 35, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ink)
                    Spacer(minLength: 20)
                    Rectangle().fill(ink.opacity(0.25)).frame(height: 1.4)
                        .frame(maxWidth: .infinity)
                        .offset(y: 6)
                    Spacer(minLength: 20)
                    Text("[ ✓ ]")
                        .font(.system(size: 32, weight: .black, design: .monospaced))
                        .foregroundStyle(red)
                        .scaleEffect(0.9 + 0.1 * tick)
                        .opacity(tick)
                }
                .frame(width: 880)
                .opacity(rowIn)
                .offset(x: (1 - rowIn) * -10)
            }
            Text("batteries in the binary.")
                .font(.system(size: 44, weight: .black, design: .monospaced))
                .foregroundStyle(ink)
                .padding(.top, 20)
                .opacity(cap)
                .offset(y: (1 - cap) * 10)
        }
        .position(x: 960, y: 540)
        .opacity(1 - exit)
    }

    // MARK: - S8 · proof

    @ViewBuilder @MainActor
    static func s8Proof(_ t: Double) -> some View {
        let bars: [(String, Double, Color, String)] = [
            ("claude sonnet 4.5", 1.00, red, "100%"),
            ("gpt-4.1", 0.90, ink, "90%"),
            ("gemini 2.5 flash", 0.90, ink, "90%"),
            ("non-reasoning baseline", 0.30, ink.opacity(0.3), "30%"),
        ]
        let head = outQuart(Ease.clip(t, 0.15, 0.45))
        let sub = outQuart(Ease.clip(t, 0.45, 0.69))
        let exit = Ease.easeIn(Ease.clip(t, 4.05, 4.2))
        VStack(alignment: .leading, spacing: 26) {
            Text("a language no model saw in training.")
                .font(.system(size: 42, weight: .black, design: .monospaced))
                .foregroundStyle(ink)
                .opacity(head)
                .offset(y: (1 - head) * 8)
            Text("single-shot codegen, from the docs alone — eval/, receipts included.")
                .font(.system(size: 23, design: .monospaced))
                .foregroundStyle(ink.opacity(0.65))
                .opacity(sub)
                .offset(y: (1 - sub) * 6)
                .padding(.bottom, 22)
            ForEach(0..<bars.count, id: \.self) { i in
                let fillT = 0.4 + Double(i) * 0.5
                let rowIn = outQuart(Ease.clip(t, fillT - 0.1, fillT + 0.14))
                let fill = outQuart(Ease.clip(t, fillT, fillT + 0.5))
                HStack(spacing: 22) {
                    Text(bars[i].0)
                        .font(.system(size: 25, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ink)
                        .frame(width: 350, alignment: .trailing)
                    ZStack(alignment: .leading) {
                        Rectangle().fill(ink.opacity(0.12)).frame(width: 700, height: 34)
                        Rectangle().fill(bars[i].2)
                            .frame(width: 700 * CGFloat(fill * bars[i].1), height: 34)
                    }
                    Text(bars[i].3)
                        .font(.system(size: 25, weight: .black, design: .monospaced))
                        .foregroundStyle(i == 0 ? red : ink.opacity(0.8))
                        .opacity(fill >= 0.97 ? 1 : 0)
                }
                .opacity(rowIn)
                .offset(x: (1 - rowIn) * -10)
            }
        }
        .position(x: 960, y: 520)
        .opacity(1 - exit)
    }

    // MARK: - S9 · ship

    @ViewBuilder @MainActor
    static func s9Ship(_ t: Double) -> some View {
        let cmd = "git clone github.com/skyblanket/swarmrt && cd swarmrt && make swc"
        let typed = Int(Ease.clip(t, 0.2, 1.8) * Double(cmd.count))
        let ok = outQuart(Ease.clip(t, 1.9, 2.14))
        let termExit = Ease.easeIn(Ease.clip(t, 3.05, 3.22))
        let lockIn = outQuart(Ease.clip(t, 3.2, 3.48))     // press-stamp with the boom
        let lockFade = Ease.clip(t, 3.2, 3.32)
        let url = outQuart(Ease.clip(t, 3.9, 4.14))
        let sub = outQuart(Ease.clip(t, 4.4, 4.64))
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 0) {
                    Text("$ ").foregroundStyle(red)
                    Text(String(cmd.prefix(typed))).foregroundStyle(ink)
                    Rectangle().fill(ink).frame(width: 14, height: 28)
                        .opacity(Int(t * 4) % 2 == 0 ? 1 : 0)
                }
                .font(.system(size: 27, weight: .semibold, design: .monospaced))
                Text("✓ swc + libswarmrt built — no VM, nothing else to install")
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .foregroundStyle(red)
                    .opacity(ok)
                    .offset(y: (1 - ok) * 8)
            }
            .frame(width: 1240, alignment: .leading)
            .position(x: 960, y: 480)
            .opacity(1 - termExit)
            .offset(y: termExit * -14)
            VStack(spacing: 26) {
                Text("swarmrt")
                    .font(.system(size: 196, weight: .black, design: .monospaced))
                    .foregroundStyle(ink)
                    .scaleEffect(1.05 - 0.05 * lockIn)
                    .opacity(lockFade)
                Text("github.com/skyblanket/swarmrt")
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.85))
                    .opacity(url)
                    .offset(y: (1 - url) * 8)
                Text("MIT · WRITTEN IN C · ERLANG'S SUPERPOWER, COMPILED")
                    .font(.system(size: 21, weight: .bold, design: .monospaced))
                    .tracking(6)
                    .foregroundStyle(ink.opacity(0.55))
                    .opacity(sub)
            }
            .position(x: 960, y: 555)
        }
    }

    // MARK: - HUD: field-manual chrome (hairline frame, ticks, timecode)

    @ViewBuilder @MainActor
    static func hud(_ t: Double) -> some View {
        let hudIn = Ease.clip(t, 0.1, 0.7)
        let s = sectionIndex(t)
        let frame = Int(t * 60) % 60
        let ss = Int(t) % 60
        let mm = Int(t) / 60
        ZStack {
            Rectangle()
                .stroke(ink.opacity(0.35), lineWidth: 1.2)
                .padding(36)
            CornerTicks(inset: 36, len: 14, color: ink.opacity(0.55))
            VStack {
                HStack {
                    Text("SWARMRT — FIELD MANUAL FOR THE AGENT ERA")
                        .tracking(3)
                    Spacer()
                    Text(hudLabels[s])
                        .tracking(3)
                        .foregroundStyle(red)
                }
                Spacer()
                HStack {
                    Text(String(format: "TC %02d:%02d:%02d", mm, ss, frame))
                        .tracking(2)
                    Spacer()
                    Text("1920×1080 · 60 FPS · DETERMINISTIC RENDER")
                        .tracking(2)
                }
            }
            .font(.system(size: 15, weight: .semibold, design: .monospaced))
            .foregroundStyle(ink.opacity(0.5))
            .padding(.horizontal, 52)
            .padding(.vertical, 47)
        }
        .opacity(hudIn)
    }
}

// MARK: - Small drawing helpers

/// A hairline from a → b that draws on with `progress`.
struct SpecPointer: View {
    let a: CGPoint, b: CGPoint
    let progress: Double
    let color: Color
    var body: some View {
        Canvas { ctx, _ in
            var path = Path()
            path.move(to: a)
            path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * progress,
                                     y: a.y + (b.y - a.y) * progress))
            ctx.stroke(path, with: .color(color), lineWidth: 1.3)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

/// Dimension line with end ticks — spec-sheet furniture.
struct DimensionLine: View {
    let width: Double
    let tick: Double
    let color: Color
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 1.4, height: tick)
            Rectangle().fill(color).frame(width: max(0, width), height: 1.4)
            Rectangle().fill(color).frame(width: 1.4, height: tick)
        }
    }
}

/// Registration ticks just outside the HUD frame corners.
struct CornerTicks: View {
    let inset: Double
    let len: Double
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let pts = [CGPoint(x: inset, y: inset),
                       CGPoint(x: size.width - inset, y: inset),
                       CGPoint(x: inset, y: size.height - inset),
                       CGPoint(x: size.width - inset, y: size.height - inset)]
            for p in pts {
                var hline = Path(); var vline = Path()
                let dx: Double = p.x < size.width / 2 ? -1 : 1
                let dy: Double = p.y < size.height / 2 ? -1 : 1
                hline.move(to: p); hline.addLine(to: CGPoint(x: p.x + dx * len, y: p.y))
                vline.move(to: p); vline.addLine(to: CGPoint(x: p.x, y: p.y + dy * len))
                ctx.stroke(hline, with: .color(color), lineWidth: 1.4)
                ctx.stroke(vline, with: .color(color), lineWidth: 1.4)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
