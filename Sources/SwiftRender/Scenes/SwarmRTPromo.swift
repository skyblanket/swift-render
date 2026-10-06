import SwiftUI

/// SwarmRTPromo — the swarm sells the runtime. Otonomy-flavoured: signal red,
/// black ink, no drum groove — a living insect swarm carries the film.
///
///   swift run swift-render render SwarmRTPromo
///
/// Sections (cuts at `cuts`, blink-spliced, one persistent swarm throughout):
///   S0 one process        S1 spawn ramp        S2 wordmark
///   S3 code card          S4 crash & restart   S5 three stats
///   S6 batteries marquee  S7 ring lockup → disperse
public struct SwarmRTPromo: RenderScene {
    public static let defaultDuration: Double = 30.0
    public static var ownsPostFX: Bool { true }

    static let red = Color(red: 0.855, green: 0.122, blue: 0.086)   // signal red
    static let cardRed = Color(red: 1.0, green: 0.42, blue: 0.37)   // code accent on black
    static let cuts: [Double] = [3.0, 6.0, 9.6, 13.8, 17.6, 21.2, 24.4]

    // MARK: - Sound — no kit groove: hum, chitter, heartbeat, punctuation

    public static func soundtrack(duration: Double) -> Score? {
        Score(duration: duration) {
            // hum bed — detuned pairs beat against each other → insect buzz
            drone(Note(92.0), from: 0.0, for: 29.4, amp: 0.040)
            drone(Note(95.5), from: 0.3, for: 29.0, amp: 0.034)
            drone(Note(46.0), from: 6.0, for: 23.2, amp: 0.085)
            drone(Note(184.0), from: 6.0, for: 18.4, amp: 0.016)
            drone(Note(189.0), from: 6.2, for: 18.0, amp: 0.013)
            drone(Note(61.7), from: 17.6, for: 7.2, amp: 0.045)

            // chitter — jittered, panned clicks; density follows the population
            every(0.42, from: 0.5, to: 3.0) { t in
                hat(at: t + h(t * 7) * 0.25, amp: 0.022 + 0.018 * h(t * 13), pan: h(t * 3) * 1.6 - 0.8)
            }
            every(0.17, from: 3.0, to: 6.0) { t in
                hat(at: t + h(t * 7) * 0.12, amp: 0.026 + 0.02 * h(t * 13) + (t - 3.0) * 0.006,
                    pan: h(t * 3) * 1.8 - 0.9)
            }
            every(0.11, from: 6.0, to: 17.6) { t in
                hat(at: t + h(t * 7) * 0.08, amp: 0.024 + 0.016 * h(t * 13), pan: h(t * 3) * 1.8 - 0.9)
            }
            every(0.06, from: 17.6, to: 21.2) { t in
                hat(at: t + h(t * 7) * 0.05, amp: 0.028 + 0.014 * h(t * 13), pan: h(t * 3) * 1.8 - 0.9)
            }
            every(0.15, from: 21.2, to: 27.6) { t in
                hat(at: t + h(t * 7) * 0.10, amp: 0.020 + 0.014 * h(t * 13), pan: h(t * 3) * 1.6 - 0.8)
            }
            every(0.5, from: 27.6, to: 29.4) { t in
                h(t * 29) > 0.45 ? hat(at: t + h(t * 5) * 0.3, amp: 0.016, pan: h(t * 3) - 0.5) : []
            }

            // sporadic darts — dry snaps off-grid
            every(0.9, from: 1.0, to: 24.0) { t in
                h(t * 29) > 0.55
                    ? clap(at: t + h(t * 5) * 0.4, amp: 0.05, pan: h(t * 11) * 1.2 - 0.6)
                    : []
            }

            // heartbeat — slow sub pulse, the only "rhythm" in the film
            every(1.2, from: 9.6, to: 21.2) { t in
                bass(Note(41.2), at: t, duration: 0.28, amp: 0.14)
            }
            every(0.6, from: 21.2, to: 24.4) { t in
                bass(Note(46.0), at: t, duration: 0.22, amp: 0.10)
            }

            // punctuation
            boom(at: 6.0, amp: 0.85)
            clap(at: 14.7, amp: 0.5)                      // the kill
            boom(at: 14.7, amp: 0.42, duration: 1.2)
            kick(at: 17.6, amp: 0.5); kick(at: 18.8, amp: 0.5); kick(at: 20.0, amp: 0.5)
            boom(at: 24.4, amp: 0.9)
            hat(at: 29.15, amp: 0.05); hat(at: 29.4, amp: 0.03)
        }
    }

    // MARK: - Body

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let jolt = JustRenderIt.shake(t, impacts: [6.0, 14.7, 17.6, 18.8, 20.0, 24.4], amp: 7)
        let fade = Ease.easeIn(Ease.clip(t, duration - 0.8, duration))

        return ZStack {
            red.ignoresSafeArea()
            swarm(t)
            Timeline(t) {
                Clip(3.0) { l in s0OneProcess(l) }
                Clip(3.0) { l in s1SpawnRamp(l) }
                Clip(3.6) { l in s2Wordmark(l) }
                Clip(4.2) { l in s3CodeCard(l) }
                Clip(3.8) { l in s4CrashRestart(l) }
                Clip(3.6) { l in s5Stats(l) }
                Clip(3.2) { l in s6Marquee(l) }
                Clip(5.6) { l in s7Lockup(l) }
            }
            blink(t)
        }
        .offset(jolt)
        .opacity(1 - fade)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(PostFX(time: t, grainAmount: 0.12, vignetteAmount: 0.5))
    }

    // MARK: - The swarm — one persistent organism, pure function of t

    static func h(_ x: Double) -> Double {
        let s = sin(x * 127.1 + 311.7) * 43758.5453
        return s - floor(s)
    }

    /// Flock keyframes: (time, cx, cy, spread, alpha). Smoothstepped between.
    static let flockKeys: [(Double, Double, Double, Double, Double)] = [
        (0.0,  700, 560,  36, 1.00),
        (3.0,  960, 540, 130, 1.00),
        (6.0,  960, 310, 470, 0.90),
        (9.6, 1570, 250, 520, 0.45),
        (13.8, 1570, 260, 480, 0.40),
        (17.6, 960, 540, 720, 0.55),
        (21.2, 960, 880, 760, 0.40),
        (24.4, 960, 540, 420, 0.95),
        (30.0, 960, 540, 430, 0.95),
    ]

    static func flock(_ t: Double) -> (cx: Double, cy: Double, spread: Double, alpha: Double) {
        var a = flockKeys[0], b = flockKeys[flockKeys.count - 1]
        for i in 0..<(flockKeys.count - 1) where t >= flockKeys[i].0 && t < flockKeys[i + 1].0 {
            a = flockKeys[i]; b = flockKeys[i + 1]
        }
        if t >= flockKeys[flockKeys.count - 1].0 { a = b }
        let span = max(b.0 - a.0, 1e-9)
        let u = Ease.easeInOut(min(1, max(0, (t - a.0) / span)))
        return (a.1 + (b.1 - a.1) * u, a.2 + (b.2 - a.2) * u,
                a.3 + (b.3 - a.3) * u, a.4 + (b.4 - a.4) * u)
    }

    static func population(_ t: Double) -> Int {
        if t < 3.0 { return 1 }
        if t < 6.0 { return min(240, Int(pow(2.0, (t - 3.0) / 0.30))) }
        if t < 17.6 { return 240 }
        if t < 18.6 { return 240 + Int((t - 17.6) * 410) }
        if t < 24.4 { return 650 }
        return 320
    }

    /// When agent i first exists — drives its birth pop-in.
    static func birth(_ i: Int) -> Double {
        if i == 0 { return 0 }
        if i < 240 { return 3.0 + 0.30 * log2(Double(i + 1)) }
        return 17.6 + Double(i - 240) / 410.0
    }

    static func agentPos(_ i: Int, _ t: Double, cx: Double, cy: Double, spread: Double) -> (Double, Double) {
        let fi = Double(i)
        // orbital drift — wide ellipse, per-agent speed/direction
        let ang0 = h(fi * 1.3) * 2 * .pi
        let angV = (0.25 + h(fi * 2.1) * 0.5) * (h(fi * 3.7) > 0.5 ? 1.2 : -1.2)
        let rad = spread * (0.15 + 0.85 * pow(h(fi * 4.3), 0.7))
        let wob = 1 + 0.25 * sin(t * (0.8 + h(fi * 8.9) * 1.4) + fi)
        var x = cx + cos(ang0 + t * angV) * rad * wob * 1.35
        var y = cy + sin(ang0 + t * angV) * rad * wob * 0.75
        // stop-start darts — the insect move
        let rate = 1.4 + h(fi * 5.9) * 1.8
        let phase = h(fi * 6.1) * 7
        let cell = floor(t * rate + phase)
        let frac = t * rate + phase - cell
        let snap = Ease.easeOut(min(1, frac * 2.2))
        let amp = 14.0 + h(fi * 9.7) * 26
        let j0x = (h(fi * 11.1 + cell * 17.7) - 0.5) * 2 * amp
        let j0y = (h(fi * 12.3 + cell * 19.3) - 0.5) * 2 * amp
        let j1x = (h(fi * 11.1 + (cell + 1) * 17.7) - 0.5) * 2 * amp
        let j1y = (h(fi * 12.3 + (cell + 1) * 19.3) - 0.5) * 2 * amp
        x += j0x + (j1x - j0x) * snap
        y += j0y + (j1y - j0y) * snap
        // wing tremble
        x += sin(t * 31 * (0.7 + h(fi * 13.7)) + fi * 2.1) * 1.6
        y += cos(t * 27 * (0.7 + h(fi * 15.1)) + fi * 1.3) * 1.6
        return (x, y)
    }

    @MainActor
    static func swarm(_ t: Double) -> some View {
        Canvas { ctx, _ in
            let f = flock(t)
            let n = population(t)
            let ringM = Ease.easeInOut(Ease.clip(t, 24.4, 25.8))    // form the orbit ring
            let burst = Ease.easeIn(Ease.clip(t, 28.6, 29.8))       // final disperse
            for i in 0..<n {
                let fi = Double(i)
                let born = Ease.easeOutBack(Ease.clip(t, birth(i), birth(i) + 0.25))
                if born <= 0.01 { continue }
                let buzz = 1 + 0.22 * sin(t * (18 + h(fi * 23) * 18) + fi)
                let queen = i == 0 ? 2.4 : 1.0                       // one visible founder
                let baseSize = (4.2 + h(fi * 22) * 4.6) * buzz * born * queen
                let aBase = f.alpha * (0.65 + 0.35 * h(fi * 21)) * (1 - burst)
                for k in 0..<3 {                                     // motion trail
                    let tt = t - Double(k) * 0.033
                    var (x, y) = agentPos(i, tt, cx: f.cx, cy: f.cy, spread: f.spread)
                    if ringM > 0 {
                        let ringAng = fi / Double(max(n, 1)) * 2 * .pi + tt * 0.25
                        let ringR = 370.0 + (h(fi * 3.3) - 0.5) * 60
                        let rx = 960 + cos(ringAng) * ringR * 1.15
                        let ry = 540 + sin(ringAng) * ringR * 0.85
                        x += (rx - x) * ringM
                        y += (ry - y) * ringM
                    }
                    if burst > 0 {
                        let dx = x - 960, dy = y - 540
                        let len = max(sqrt(dx * dx + dy * dy), 1)
                        x += dx / len * burst * 1500
                        y += dy / len * burst * 1500
                    }
                    let s = baseSize * [1.0, 0.85, 0.7][k]
                    let a = aBase * [1.0, 0.35, 0.15][k]
                    ctx.fill(Path(ellipseIn: CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s * 0.82)),
                             with: .color(.black.opacity(a)))
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    // MARK: - S0 · one process

    @ViewBuilder @MainActor
    static func s0OneProcess(_ t: Double) -> some View {
        let vis = Ease.easeOut(Ease.clip(t, 0.9, 1.4)) * (1 - Ease.easeIn(Ease.clip(t, 2.5, 2.9)))
        VStack {
            Spacer()
            Text("this is a process.")
                .font(.system(size: 36, weight: .medium, design: .monospaced))
                .foregroundStyle(.black)
                .opacity(vis)
                .padding(.bottom, 180)
        }
    }

    // MARK: - S1 · spawn ramp

    @ViewBuilder @MainActor
    static func s1SpawnRamp(_ t: Double) -> some View {
        let absT = t + 3.0
        let n = population(absT)
        let line = "pid = spawn(agent(state))"
        let typed = Int(Ease.clip(t, 0.1, 1.1) * Double(line.count))
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(format: "%06d", n))
                    .font(.system(size: 92, weight: .black, design: .monospaced))
                    .foregroundStyle(.black)
                    .contentTransition(.identity)
                Text("PROCESSES")
                    .font(.system(size: 24, weight: .black)).fontWidth(.expanded)
                    .tracking(10)
                    .foregroundStyle(.black.opacity(0.7))
            }
            .padding(.top, 90).padding(.leading, 110)
            VStack {
                Spacer()
                HStack(spacing: 2) {
                    Text(String(line.prefix(typed)))
                    Rectangle().fill(.black).frame(width: 15, height: 36)
                        .opacity(Int(t * 4) % 2 == 0 ? 1 : 0)
                }
                .font(.system(size: 38, weight: .semibold, design: .monospaced))
                .foregroundStyle(.black)
                .padding(.bottom, 130)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - S2 · wordmark

    @ViewBuilder @MainActor
    static func s2Wordmark(_ t: Double) -> some View {
        let stamp = Ease.easeOutBack(Ease.clip(t, 0.05, 0.35))
        let sub = Ease.easeOut(Ease.clip(t, 0.7, 1.2))
        VStack(spacing: 36) {
            Text("swarmrt")
                .font(.system(size: 220, weight: .black)).fontWidth(.expanded)
                .foregroundStyle(.black)
                .scaleEffect(1.6 - 0.6 * stamp)
                .rotationEffect(.degrees((1 - stamp) * -4))
                .opacity(min(1, stamp * 2))
            Text("a BEAM-shaped runtime for the AI-agent era")
                .font(.system(size: 34, weight: .medium, design: .monospaced))
                .foregroundStyle(.black.opacity(0.85))
                .opacity(sub)
        }
        .offset(y: 40)
    }

    // MARK: - S3 · code card

    @ViewBuilder @MainActor
    static func s3CodeCard(_ t: Double) -> some View {
        let lines: [(String, Color)] = [
            ("fun agent(state) {", .white.opacity(0.6)),
            ("    receive {", cardRed),
            ("        {'task', job} -> agent(run(state, job))", .white.opacity(0.92)),
            ("        {'ask', from} -> send(from, state)", .white.opacity(0.92)),
            ("        'stop'        -> print(\"agent done\")", .white.opacity(0.92)),
            ("    }", cardRed),
            ("}", .white.opacity(0.6)),
            ("", .white),
            ("pid = spawn(agent(0))", cardRed),
        ]
        let head = Ease.easeOut(Ease.clip(t, 0.0, 0.35))
        let note = Ease.easeOut(Ease.clip(t, 1.6, 2.0))
        VStack(alignment: .leading, spacing: 26) {
            Text("an LLM writes this correctly, first try.")
                .font(.system(size: 44, weight: .black)).fontWidth(.expanded)
                .foregroundStyle(.black)
                .opacity(head)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<lines.count, id: \.self) { i in
                    let p = stagger(t, i, step: 0.08, ramp: 0.3, start: 0.25)
                    Text(lines[i].0.isEmpty ? " " : lines[i].0)
                        .font(.system(size: 29, weight: .medium, design: .monospaced))
                        .foregroundStyle(lines[i].1)
                        .lineLimit(1).fixedSize()
                        .offset(x: CGFloat(1 - p) * -60)
                        .opacity(p)
                }
            }
            .padding(40)
            .frame(width: 1080, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(.black))
            Text("sw · unseen in training · Sonnet 4.5 scores 10/10 · eval/ has the receipts")
                .font(.system(size: 24, weight: .medium, design: .monospaced))
                .foregroundStyle(.black.opacity(0.75))
                .opacity(note)
        }
    }

    // MARK: - S4 · crash & restart

    static let nodePts: [(Double, Double)] = (0..<10).map { i in
        let a = Double(i) / 10 * 2 * .pi + h(Double(i) * 4.7) * 0.9
        let r = 110 + h(Double(i) * 7.3) * 115
        return (490 + cos(a) * r * 1.15, 540 + sin(a) * r)
    }
    static let links: [(Int, Int)] = [(0, 1), (0, 3), (1, 2), (2, 4), (3, 5), (4, 6),
                                      (5, 7), (1, 6), (3, 8), (2, 9), (7, 9), (6, 8)]

    @ViewBuilder @MainActor
    static func s4CrashRestart(_ t: Double) -> some View {
        let deadIdx = 4
        let dead = t >= 0.9 && t < 1.6
        let alive = Ease.easeOut(Ease.clip(t, 0.0, 0.5))
        let stamp1 = Ease.easeOutBack(Ease.clip(t, 0.3, 0.6))
        let stamp2 = Ease.easeOutBack(Ease.clip(t, 1.9, 2.2))
        let exit = Ease.easeIn(Ease.clip(t, 3.4, 3.8))
        ZStack {
            Canvas { ctx, _ in
                let trem: (Int, Double) -> (Double, Double) = { i, tt in
                    let p = nodePts[i]
                    return (p.0 + sin(tt * 9 + Double(i) * 2.3) * 5,
                            p.1 + cos(tt * 8 + Double(i) * 1.7) * 5)
                }
                for (a, b) in links {
                    let touchesDead = a == deadIdx || b == deadIdx
                    let la = touchesDead ? (dead ? 0.06 : (t >= 1.75 ? 0.45 : 0.45)) : 0.45
                    let pa = trem(a, t), pb = trem(b, t)
                    var path = Path()
                    path.move(to: CGPoint(x: pa.0, y: pa.1))
                    path.addLine(to: CGPoint(x: pb.0, y: pb.1))
                    ctx.stroke(path, with: .color(.black.opacity(la * alive)), lineWidth: 2)
                }
                for i in 0..<nodePts.count {
                    let p = trem(i, t)
                    if i == deadIdx {
                        if dead {
                            // the × — a dead insect
                            var x1 = Path(); var x2 = Path()
                            x1.move(to: CGPoint(x: p.0 - 20, y: p.1 - 20))
                            x1.addLine(to: CGPoint(x: p.0 + 20, y: p.1 + 20))
                            x2.move(to: CGPoint(x: p.0 + 20, y: p.1 - 20))
                            x2.addLine(to: CGPoint(x: p.0 - 20, y: p.1 + 20))
                            ctx.stroke(x1, with: .color(.black.opacity(0.9)), lineWidth: 6)
                            ctx.stroke(x2, with: .color(.black.opacity(0.9)), lineWidth: 6)
                        } else {
                            let re = t >= 1.6 ? Ease.easeOutBack(Ease.clip(t, 1.6, 1.85)) : 1.0
                            let s = 24 * re
                            ctx.fill(Path(ellipseIn: CGRect(x: p.0 - s / 2, y: p.1 - s / 2, width: s, height: s)),
                                     with: .color(.black.opacity(0.9 * alive)))
                        }
                        // supervisor pulse ring after the death
                        let pulse = Ease.clip(t, 1.25, 1.7)
                        if pulse > 0 && pulse < 1 {
                            let r = 20 + pulse * 110
                            ctx.stroke(Path(ellipseIn: CGRect(x: p.0 - r, y: p.1 - r, width: r * 2, height: r * 2)),
                                       with: .color(.black.opacity((1 - pulse) * 0.7)), lineWidth: 3)
                        }
                    } else {
                        let s = 20.0 + h(Double(i) * 31) * 8
                        ctx.fill(Path(ellipseIn: CGRect(x: p.0 - s / 2, y: p.1 - s / 2, width: s, height: s)),
                                 with: .color(.black.opacity(0.9 * alive)))
                    }
                }
            }
            .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 26) {
                Text("processes crash.")
                    .font(.system(size: 74, weight: .black)).fontWidth(.expanded)
                    .foregroundStyle(.black)
                    .scaleEffect(1.4 - 0.4 * stamp1, anchor: .leading)
                    .opacity(min(1, stamp1 * 2))
                Text("the swarm doesn't.")
                    .font(.system(size: 96, weight: .black)).fontWidth(.expanded)
                    .foregroundStyle(.black)
                    .scaleEffect(1.4 - 0.4 * stamp2, anchor: .leading)
                    .opacity(min(1, stamp2 * 2))
                Text("link · monitor · trap_exit · supervise")
                    .font(.system(size: 26, weight: .medium, design: .monospaced))
                    .foregroundStyle(.black.opacity(0.7))
                    .opacity(Ease.easeOut(Ease.clip(t, 2.5, 2.9)))
            }
            .frame(width: 760, alignment: .leading)
            .position(x: 1330, y: 540)
        }
        .opacity(1 - exit)
    }

    // MARK: - S5 · three stats

    @ViewBuilder @MainActor
    static func s5Stats(_ t: Double) -> some View {
        let stats: [(String, String)] = [
            ("100ns", "CONTEXT SWITCH"),
            ("<10ms", "COLD BOOT"),
            ("180KB", "THE WHOLE RUNTIME"),
        ]
        let idx = min(2, Int(t / 1.2))
        let local = t - Double(idx) * 1.2
        let stamp = Ease.easeOutBack(min(1, local / 0.22))
        VStack(spacing: 22) {
            Text(stats[idx].0)
                .font(.system(size: 330, weight: .black)).fontWidth(.expanded)
                .foregroundStyle(.black)
                .scaleEffect(1.5 - 0.5 * stamp)
                .rotationEffect(.degrees((1 - stamp) * 3))
                .opacity(min(1, stamp * 2))
            Text(stats[idx].1)
                .font(.system(size: 36, weight: .black)).fontWidth(.expanded)
                .tracking(14)
                .foregroundStyle(.black.opacity(0.8))
                .opacity(Ease.easeOut(Ease.clip(local, 0.25, 0.5)))
        }
    }

    // MARK: - S6 · batteries marquee

    @ViewBuilder @MainActor
    static func s6Marquee(_ t: Double) -> some View {
        let row1 = String(repeating: "SUPERVISORS ✕ LINKS ✕ MONITORS ✕ HOT STATE ✕ ", count: 6)
        let row2 = String(repeating: "SQLITE ✕ MCP ✕ HTTP ✕ WEBSOCKET ✕ SANDBOX ✕ CROSS-COMPILE ✕ ", count: 5)
        let enter = Ease.easeOut(min(1, t / 0.4))
        let cap = Ease.easeOut(Ease.clip(t, 1.2, 1.7))
        ZStack {
            Text(row1)
                .font(.system(size: 96, weight: .black)).fontWidth(.expanded)
                .foregroundStyle(.black)
                .fixedSize()
                .offset(x: 2200 - CGFloat(t) * 420, y: -190)
                .opacity(enter)
            Text(row2)
                .font(.system(size: 96, weight: .black)).fontWidth(.expanded)
                .foregroundStyle(.black.opacity(0.3))
                .fixedSize()
                .offset(x: -2600 + CGFloat(t) * 460, y: 70)
                .opacity(enter)
            VStack {
                Spacer()
                Text("batteries in the binary.")
                    .font(.system(size: 40, weight: .medium, design: .monospaced))
                    .foregroundStyle(.black)
                    .opacity(cap)
                    .padding(.bottom, 150)
            }
        }
    }

    // MARK: - S7 · ring lockup

    @ViewBuilder @MainActor
    static func s7Lockup(_ t: Double) -> some View {
        let stamp = Ease.easeOutBack(Ease.clip(t, 0.05, 0.35))
        let url = Ease.easeOut(Ease.clip(t, 0.9, 1.4))
        let sub = Ease.easeOut(Ease.clip(t, 1.4, 1.9))
        VStack(spacing: 30) {
            Text("swarmrt")
                .font(.system(size: 176, weight: .black)).fontWidth(.expanded)
                .foregroundStyle(.black)
                .scaleEffect(1.5 - 0.5 * stamp)
                .rotationEffect(.degrees((1 - stamp) * -3))
                .opacity(min(1, stamp * 2))
            Text("github.com/skyblanket/swarmrt")
                .font(.system(size: 32, weight: .semibold, design: .monospaced))
                .foregroundStyle(.black.opacity(0.85))
                .opacity(url)
            Text("HUNDREDS OF THOUSANDS OF PROCESSES · ONE NATIVE BINARY · MIT")
                .font(.system(size: 22, weight: .black)).fontWidth(.expanded)
                .tracking(6)
                .foregroundStyle(.black.opacity(0.6))
                .opacity(sub)
        }
    }

    // MARK: - Blink splice on section cuts (black, not white — house style here)

    @MainActor
    static func blink(_ t: Double) -> some View {
        let hit = cuts.map { max(0, 1 - abs(t - $0) / 0.045) }.max() ?? 0
        return Color.black.opacity(hit).ignoresSafeArea()
    }
}
