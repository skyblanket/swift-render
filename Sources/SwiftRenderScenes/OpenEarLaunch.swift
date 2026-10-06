import SwiftUI
import SwiftRender

/// OpenEarLaunch — 45.6s launch film for OpenEar's on-device meeting notes.
///
///   swift run swift-render render OpenEarLaunch --out out/openear_launch.mp4
///
/// Brand: jet-black stage, cream ink, Inter Display + mono, the red record dot,
/// and the record-store idiom from openear.fyi (SIDE A, OE · 0001, the ledger).
/// 100 BPM, nineteen 2.4s bars. The score carries the music *and* the foley:
/// one-shots in assets/openear-foley, sliced from the HunyuanVideo-Foley passes
/// made for the OpenEar launch, placed on the same section starts as the visuals.
public struct OpenEarLaunch: RenderScene {
    public static let defaultDuration: Double = 45.6

    static let beat = 0.6
    static let bar = 2.4
    /// Section starts in bars: open, problem, logo, calendar, notch, both, notes, ask, ledger, dictation, end.
    static let sections: [Double] = [0, 2, 4, 5, 7, 9, 10, 12, 14, 16, 17, 19]

    // MARK: palette + type

    static let cream = Color(red: 0.878, green: 0.831, blue: 0.761)
    static let paper = Color(red: 0.93, green: 0.90, blue: 0.84)
    static let paperInk = Color(red: 0.11, green: 0.10, blue: 0.09)
    static let ink = Color(red: 0.012, green: 0.012, blue: 0.014)
    static let card = Color(red: 0.078, green: 0.078, blue: 0.086)
    static let elevated = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let rec = Color(red: 0.95, green: 0.11, blue: 0.04)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.42)
    static let mint = Color(red: 0.62, green: 0.95, blue: 0.72)

    static func display(_ s: CGFloat, _ w: String = "SemiBold") -> Font { .custom("InterDisplay-\(w)", size: s) }
    static func inter(_ s: CGFloat, _ w: String = "Medium") -> Font { .custom("Inter-\(w)", size: s) }
    static func mono(_ s: CGFloat, _ w: Font.Weight = .medium) -> Font { .system(size: s, weight: w, design: .monospaced) }

    static func ease(_ t: Double, _ a: Double, _ b: Double) -> Double { Ease.easeOut(Ease.clip(t, a, b)) }
    static func pop(_ t: Double, _ start: Double, from: Double = 0, to: Double = 1,
                    r: Double = 0.42, d: Double = 0.74) -> Double {
        t < start ? from : Ease.spring(t - start, from: from, to: to, response: r, dampingFraction: d)
    }
    static func typed(_ s: String, _ t: Double, _ start: Double, cps: Double = 40) -> String {
        String(s.prefix(max(0, Int((t - start) * cps))))
    }
    static func h(_ n: Int) -> Double {
        let x = sin(Double(n) * 12.9898 + 78.233) * 43758.5453
        return x - floor(x)
    }

    // MARK: soundtrack — music + foley

    public static func soundtrack(duration: Double) -> Score? {
        var ev: [ScoreEvent] = []
        let m = Note.midi
        func at(_ b: Int, _ beats: Double) -> Double { Double(b) * Self.bar + beats * beat }
        func chord(_ notes: [Int], _ start: Double, _ dur: Double, _ amp: Double = 0.026) {
            for (i, n) in notes.enumerated() {
                ev += pad(m(n), at: start, amp: amp, duration: dur, pan: Double(i - notes.count / 2) * 0.25)
            }
        }
        let fm9 = [53, 56, 60, 63, 67], db = [49, 53, 56, 60, 63], ab = [56, 60, 63, 67], eb = [51, 55, 58, 62]
        let cm = [48, 51, 55, 58]

        // A · needle drop
        chord(fm9, 0, 4.9, 0.026)
        for (t, n) in [(1.15, 77), (1.75, 72), (2.6, 75), (3.4, 70)] { ev += bell(m(n), at: t, amp: 0.08, pan: n > 73 ? 0.3 : -0.3) }
        ev += boom(at: 1.15, amp: 0.4, duration: 1.6)

        // B · the problem: heartbeat + building eighths, then a held breath before the logo
        chord(db, at(2, 0), 4.9, 0.02)
        for b in [2, 3] {
            for x in [0.0, 2.0] { ev += kick(at: at(b, x), amp: 0.36); ev += kick(at: at(b, x + 0.4), amp: 0.2) }
        }
        for i in 0..<14 { ev += triBass(m(41), at: at(2, Double(i) * 0.5), amp: 0.08 + 0.012 * Double(i), duration: 0.28) }
        ev += boom(at: at(2, 0) + 3.7, amp: 0.25, duration: 0.8)

        // C · logo
        ev += boom(at: at(4, 0), amp: 0.85, duration: 2.2); ev += crash(at: at(4, 0), amp: 0.22)
        chord(ab, at(4, 0), 2.6, 0.034)
        for (i, n) in [72, 75, 79, 84].enumerated() { ev += bell(m(n), at: at(4, 0) + 0.15 * Double(i), amp: 0.1, pan: Double(i - 2) * 0.25) }
        ev += triBass(m(44), at: at(4, 0), amp: 0.24, duration: 2.2)

        // D–H · the groove (bars 5…13), every bar a different bass + arp shape
        let prog: [([Int], Int)] = [(fm9, 41), (db, 37), (ab, 44), (eb, 39)]
        let kicks: [[Double]] = [[0, 2], [0, 1.5, 2], [0, 2, 2.75], [0, 2, 3.5]]
        let bassShapes: [[(Double, Int, Double)]] = [
            [(0, 0, 1.5), (1.5, 0, 0.5), (2, 12, 0.5), (3, 7, 1)],
            [(0, 0, 0.75), (0.75, 0, 0.75), (2, 0, 1), (3.5, 7, 0.5)],
            [(0, 0, 2), (2.5, 7, 0.5), (3, 12, 1)],
            [(0, 0, 0.5), (1, 12, 0.5), (1.5, 0, 1), (3, 7, 1)],
        ]
        let arps: [[Int]] = [[0, 1, 2, 3, 2, 1, 3, 4], [0, 2, 1, 3, 0, 2, 4, 3], [1, 3, 2, 4, 1, 2, 0, 3], [0, 3, 1, 4, 2, 3, 1, 2]]
        for b in 5...13 {
            let (notes, root) = prog[(b - 5) % 4]
            chord(notes, at(b, 0), bar + 0.3, 0.02)
            for x in kicks[b % 4] { ev += kick(at: at(b, x), amp: 0.5) }
            for x in [1.0, 3.0] { ev += clap(at: at(b, x), amp: 0.2) }
            for s in 0..<16 where s % 4 == 2 || h(b * 16 + s) > 0.74 {
                ev += hat(at: at(b, Double(s) * 0.25), amp: s % 4 == 2 ? 0.05 : 0.024, pan: s % 2 == 0 ? -0.3 : 0.3)
            }
            for (x, semi, len) in bassShapes[(b * 3) % 4] {
                ev += triBass(m(root + semi), at: at(b, x), amp: 0.27, duration: len * beat)
                ev += triBass(m(root + semi + 12), at: at(b, x), amp: 0.06, duration: len * beat)
            }
            let order = arps[(b + 1) % 4]
            for (i, k) in order.enumerated() where h(b * 8 + i + 300) > 0.2 {
                ev += pluck(m(notes[k % notes.count] + 12), at: at(b, Double(i) * 0.5), amp: 0.05,
                            duration: 0.6, pan: Double(i % 3 - 1) * 0.3)
            }
        }
        ev += bell(m(84), at: at(7, 0) + 1.9, amp: 0.09); ev += bell(m(79), at: at(7, 0) + 2.05, amp: 0.08)
        for (b, x, n) in [(10, 0.5, 77), (10, 1.5, 80), (10, 2.5, 79), (11, 0.0, 75), (11, 1.0, 72),
                          (12, 2.0, 84), (12, 3.0, 82), (13, 0.0, 80), (13, 1.5, 77)] {
            ev += bell(m(n), at: at(b, x), amp: 0.075, pan: 0.2)
        }

        // I · ledger breakdown
        chord(cm, at(14, 0), bar * 2 + 0.3, 0.03)
        for b in [14, 15] { ev += kick(at: at(b, 0), amp: 0.32) }
        ev += triBass(m(36), at: at(14, 0), amp: 0.2, duration: bar * 2)
        for i in 0..<8 { ev += pluck(m(cm[i % 4] + 12), at: at(14, Double(i)), amp: 0.04, duration: 0.8) }
        ev += boom(at: at(14, 0) + 3.2, amp: 0.32, duration: 1.0)

        // J · dictation
        chord(db, at(16, 0), bar + 0.3, 0.022)
        for x in [0.0, 2.0] { ev += kick(at: at(16, x), amp: 0.45) }
        for x in [1.0, 3.0] { ev += clap(at: at(16, x), amp: 0.18) }
        for s in stride(from: 2, to: 16, by: 4) { ev += hat(at: at(16, Double(s) * 0.25), amp: 0.045) }
        ev += triBass(m(37), at: at(16, 0), amp: 0.25, duration: 1.0); ev += triBass(m(44), at: at(16, 2), amp: 0.22, duration: 1.0)

        // K · end card
        ev += boom(at: at(17, 0), amp: 0.8, duration: 2.4); ev += crash(at: at(17, 0), amp: 0.2)
        chord(fm9, at(17, 0), bar * 2, 0.03)
        for x in [0.0, 2.0] { ev += kick(at: at(17, x), amp: 0.45) }
        for x in [1.0, 3.0] { ev += clap(at: at(17, x), amp: 0.16) }
        ev += triBass(m(41), at: at(17, 0), amp: 0.24, duration: bar * 2)
        for (i, n) in [72, 75, 79, 82, 84].enumerated() { ev += bell(m(n), at: at(17, 1) + Double(i) * 0.3, amp: 0.085, duration: 2.0, pan: Double(i - 2) * 0.2) }
        ev += bell(m(91), at: at(18, 0), amp: 0.06, duration: 2.0)

        // Foley. `db` is relative to the mastered music (calibrated against the original mix: amp = 1.1·10^((db−3)/20)).
        func fx(_ name: String, _ t: Double, _ db: Double, pan: Double = 0, rate: Double = 1) {
            ev += sample("openear-foley/\(name).wav", at: t, amp: 1.1 * Foundation.pow(10, (db - 3) / 20),
                         pan: pan, rate: rate)
        }
        func typing(_ t0: Double, _ chars: Int, _ cps: Double, every: Int, _ db: Double, keys: Bool = false, seed: Int) {
            for c in stride(from: 0, to: chars, by: every) {
                let k = seed * 1000 + c
                let name = keys ? "key_\(1 + Int(h(k) * 15) % 15)" : "tick_\(5 + Int(h(k) * 6) % 6)"
                fx(name, t0 + Double(c) / cps, db + h(k + 500) * 4 - 2.5,
                   pan: (h(k + 900) - 0.5) * 0.5, rate: 0.95 + 0.1 * h(k + 77))
            }
        }
        // A · needle drop
        ev += crackle(from: 0, to: 4.7, amp: 0.026)
        fx("click_1", 1.12, -6); fx("card_1", 1.13, -12); fx("swish_1", 4.2, -8)
        // B · the problem
        fx("key_1", 4.85, -9); fx("key_3", 6.0, -9); fx("key_5", 7.25, -9)
        fx("card_2", 7.72, -11, pan: 0.3); fx("click_3", 8.55, -7); fx("key_7", 8.56, -10)
        fx("swish_2", 9.1, -15, pan: 0.3)
        // C · logo
        fx("card_4", 9.6, -11)
        // D · calendar
        fx("swish_2", 12.0, -13, pan: 0.25)
        for (i, t) in [12.5, 12.8, 13.1, 13.4].enumerated() { fx("card_\(i + 1)", t, -10, pan: 0.25) }
        // E · notch
        fx("card_5", 17.0, -9); fx("click_2", 18.7, -4, pan: 0.2); fx("card_6", 19.15, -13)
        // F · both sides
        typing(21.8, 36, 40, every: 2, -19, seed: 3); typing(22.85, 43, 44, every: 2, -19, seed: 4)
        // G · notes
        fx("click_4", 24.45, -4, pan: 0.2); fx("card_3", 24.95, -11); fx("swish_1", 25.35, -15)
        typing(25.65, 130, 72, every: 3, -21, seed: 5)
        for (i, t) in [27.2, 27.45, 27.7].enumerated() { fx("card_\(i + 4)", t, -11, pan: 0.2) }
        fx("click_5", 28.3, -7, pan: 0.2)
        // H · ask
        fx("click_1", 29.0, -14)
        typing(29.2, 34, 27, every: 1, -12, keys: true, seed: 6)
        fx("card_5", 30.75, -10); fx("swish_2", 30.75, -17)
        typing(30.9, 100, 62, every: 3, -21, seed: 7)
        // I · ledger
        fx("swish_1", 33.75, -11, pan: 0.25)
        for i in 0..<5 { fx("tick_\(i % 4 + 1)", 34.5 + 0.3 * Double(i), -9, pan: 0.25) }
        fx("card_6", 36.15, -9, pan: 0.25); fx("tick_2", 36.45, -14, pan: 0.25)
        fx("click_1", 36.75, -3, pan: 0.25); fx("card_1", 36.76, -7, pan: 0.25)
        for t in [36.6, 37.2, 37.8] { fx("key_12", t, -15, pan: -0.2) }
        // J · dictation
        fx("key_9", 38.7, -5); typing(38.85, 58, 58, every: 3, -21, seed: 8)
        fx("key_11", 39.85, -7); fx("click_5", 39.95, -11)
        // K · end card
        fx("swish_1", 40.85, -11, pan: -0.2); fx("swish_2", 41.25, -13, pan: -0.3)
        fx("card_2", 43.15, -9, pan: -0.1); fx("click_3", 45.0, -15)
        ev += crackle(from: 40.8, to: 45.6, amp: 0.023)

        return Score(duration: duration) { ev }
    }

    // MARK: body

    @MainActor
    public static func body(at t: Double, duration: Double) -> some View {
        ZStack {
            ink
            Timeline(t) {
                Clip(bar * 2) { l in coldOpen(l) }
                Clip(bar * 2) { l in problem(l) }
                Clip(bar) { l in logo(l) }
                Clip(bar * 2) { l in calendar(l) }
                Clip(bar * 2) { l in notchScene(l) }
                Clip(bar) { l in bothSides(l) }
                Clip(bar * 2) { l in notes(l) }
                Clip(bar * 2) { l in ask(l) }
                Clip(bar * 2) { l in ledger(l) }
                Clip(bar) { l in dictation(l) }
                Clip(bar * 2) { l in endCard(l) }
            }
            Color.black.opacity(1 - Ease.clip(t, 0, 0.5))
            Color.black.opacity(Ease.easeIn(Ease.clip(t, duration - 0.9, duration)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: shared pieces

    @ViewBuilder @MainActor
    static func stage(_ glow: Double = 0.1, _ center: UnitPoint = .top) -> some View {
        ZStack {
            ink
            RadialGradient(colors: [cream.opacity(glow), .clear], center: center, startRadius: 0, endRadius: 1150)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder @MainActor
    static func eyebrow(_ s: String, _ t: Double, _ start: Double) -> some View {
        Text(s).font(mono(20, .semibold)).tracking(5).foregroundStyle(.white.opacity(0.42))
            .opacity(ease(t, start, start + 0.4))
    }

    @ViewBuilder @MainActor
    static func headline(_ s: String, _ t: Double, _ start: Double, size: CGFloat, color: Color) -> some View {
        let p = ease(t, start, start + 0.5)
        Text(s).font(display(size)).tracking(-size * 0.025).foregroundStyle(color)
            .opacity(p).offset(y: (1 - p) * 28)
    }

    @ViewBuilder @MainActor
    static func caption(_ brow: String, _ lines: [String], t: Double, start: Double = 0.1,
                        size: CGFloat = 92, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow(brow, t, start).padding(.bottom, 24)
            ForEach(lines.indices, id: \.self) { i in
                headline(lines[i], t, start + 0.12 + Double(i) * 0.14, size: size, color: i == 0 ? .white : cream)
            }
            if let sub {
                Text(sub).font(inter(27, "Regular")).foregroundStyle(.white.opacity(0.6))
                    .lineSpacing(6)
                    .frame(width: 600, alignment: .leading)
                    .padding(.top, 26)
                    .opacity(ease(t, start + 0.5, start + 1.0))
            }
        }
    }

    enum Prov { case google, outlook, apple, exchange }

    @ViewBuilder @MainActor
    static func badge(_ p: Prov, _ s: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: s * 0.24, style: .continuous)
        switch p {
        case .google:
            ZStack(alignment: .top) {
                shape.fill(Color.white)
                HStack(spacing: 0) {
                    Color(red: 0.26, green: 0.52, blue: 0.96); Color(red: 0.94, green: 0.27, blue: 0.21)
                    Color(red: 0.99, green: 0.74, blue: 0.02); Color(red: 0.20, green: 0.66, blue: 0.33)
                }
                .frame(height: s * 0.26)
                Text("14").font(inter(s * 0.42, "Bold")).foregroundStyle(Color(white: 0.2)).padding(.top, s * 0.3)
            }
            .frame(width: s, height: s).clipShape(shape)
        case .outlook:
            ZStack {
                shape.fill(Color(red: 0.0, green: 0.45, blue: 0.85))
                Text("O").font(inter(s * 0.5, "Bold")).foregroundStyle(.white)
            }
            .frame(width: s, height: s)
        case .apple:
            ZStack(alignment: .top) {
                shape.fill(Color.white)
                Color(red: 0.98, green: 0.24, blue: 0.22).frame(height: s * 0.26)
                Text("14").font(inter(s * 0.42, "Bold")).foregroundStyle(Color(white: 0.15)).padding(.top, s * 0.3)
            }
            .frame(width: s, height: s).clipShape(shape)
        case .exchange:
            ZStack {
                shape.fill(Color(red: 0.0, green: 0.36, blue: 0.65))
                Text("E").font(inter(s * 0.5, "Bold")).foregroundStyle(.white)
            }
            .frame(width: s, height: s)
        }
    }

    @ViewBuilder @MainActor
    static func recordButton(_ s: CGFloat, pressed: Bool = false) -> some View {
        HStack(spacing: s * 0.45) {
            Circle().fill(rec).frame(width: s * 0.55, height: s * 0.55)
            Text("Record").font(inter(s, "SemiBold")).foregroundStyle(.white)
        }
        .padding(.horizontal, s * 0.9).padding(.vertical, s * 0.5)
        .background(Capsule().fill(rec.opacity(pressed ? 0.42 : 0.18)))
        .overlay(Capsule().stroke(rec.opacity(0.6), lineWidth: 1.5))
        .scaleEffect(pressed ? 0.94 : 1)
    }

    @ViewBuilder @MainActor
    static func trafficLights() -> some View {
        HStack(spacing: 9) {
            Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
            Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18))
            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
        }
        .frame(width: 60, height: 13)
    }

    @ViewBuilder @MainActor
    static func cursor(_ x: Double, _ y: Double, pressed: Bool, size: CGFloat = 46) -> some View {
        OELCursorShape().fill(Color.white)
            .overlay(OELCursorShape().stroke(Color.black, lineWidth: 2))
            .frame(width: size * 0.62, height: size)
            .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
            .scaleEffect(pressed ? 0.86 : 1, anchor: .topLeading)
            .position(x: x + size * 0.31, y: y + size * 0.5)
    }

    static func level(_ t: Double, _ seed: Double) -> Double {
        let a = 0.5 + 0.28 * sin(t * 11.3 + seed) + 0.22 * sin(t * 23.7 + seed * 1.7)
        let b = 0.5 + 0.5 * sin(t * 3.1 + seed * 0.6)
        return max(0.05, min(1, a * (0.35 + 0.65 * b)))
    }

    @ViewBuilder @MainActor
    static func spinner(_ t: Double, _ s: CGFloat, _ color: Color = .white) -> some View {
        Circle().trim(from: 0, to: 0.72)
            .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: s * 0.12, lineCap: .round))
            .frame(width: s, height: s)
            .rotationEffect(.degrees(t * 420))
    }

    @ViewBuilder @MainActor
    static func micSystemBadge(_ s: CGFloat) -> some View {
        HStack(spacing: s * 0.35) {
            Image(systemName: "mic.fill")
            Image(systemName: "speaker.wave.2.fill")
            Text("Mic + System").font(inter(s * 0.82, "SemiBold"))
        }
        .font(.system(size: s * 0.72, weight: .semibold))
        .foregroundStyle(mint.opacity(0.95))
        .padding(.horizontal, s * 0.6).padding(.vertical, s * 0.3)
        .background(Capsule().fill(Color(red: 0.20, green: 0.55, blue: 0.30).opacity(0.34)))
    }

    // MARK: A · needle drop

    static let vinylC = CGPoint(x: 1330, y: 580)

    @ViewBuilder @MainActor
    static func coldOpen(_ l: Double) -> some View {
        let spin = 200 * (l - 0.6 * (1 - exp(-l / 0.6)))
        let arm = Ease.easeInOut(Ease.clip(l, 0.35, 1.1))
        let dive = Ease.easeIn(Ease.clip(l, 3.9, 4.8))
        let push = 0.94 + 0.06 * Ease.easeOut(Ease.clip(l, 0, 3.9))
        ZStack {
            stage(0.12)
            ZStack {
                VinylDiscView(size: 820, title: "Meetings", date: "Side A", externalSpinAngle: spin)
                    .shadow(color: .black.opacity(0.8), radius: 40, y: 20)
                    .position(vinylC)
                tonearm(arm)
            }
            .frame(width: 1920, height: 1080)
            .scaleEffect(push * (1 + 5 * dive), anchor: UnitPoint(x: vinylC.x / 1920, y: vinylC.y / 1080))
            .opacity(1 - Ease.clip(l, 4.45, 4.8))
            VStack(alignment: .leading, spacing: 0) {
                eyebrow("OE · 0001  —  SIDE A", l, 0.3).padding(.bottom, 30)
                headline("Every meeting,", l, 1.25, size: 96, color: .white)
                headline("on the record.", l, 1.85, size: 96, color: cream)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 150)
            .opacity(1 - Ease.clip(l, 3.6, 4.1))
        }
    }

    @MainActor
    static func tonearm(_ p: Double) -> some View {
        Canvas { ctx, _ in
            let P = CGPoint(x: vinylC.x + 470, y: vinylC.y - 360)
            let a0 = atan2(330.0, 60.0), a1 = atan2(150.0, -300.0)
            let a = a0 + (a1 - a0) * p
            let L = 335.0
            let head = CGPoint(x: P.x + cos(a) * L, y: P.y + sin(a) * L)
            let tail = CGPoint(x: P.x - cos(a) * 72, y: P.y - sin(a) * 72)
            ctx.fill(Path(ellipseIn: CGRect(x: P.x - 60, y: P.y - 60, width: 120, height: 120)), with: .color(Color(white: 0.08)))
            ctx.stroke(Path(ellipseIn: CGRect(x: P.x - 60, y: P.y - 60, width: 120, height: 120)), with: .color(.white.opacity(0.14)), lineWidth: 2)
            var arm = Path(); arm.move(to: tail); arm.addLine(to: head)
            ctx.stroke(arm, with: .linearGradient(Gradient(colors: [Color(white: 0.9), Color(white: 0.42)]), startPoint: tail, endPoint: head),
                       style: StrokeStyle(lineWidth: 12, lineCap: .round))
            ctx.fill(Path(ellipseIn: CGRect(x: tail.x - 30, y: tail.y - 30, width: 60, height: 60)),
                     with: .linearGradient(Gradient(colors: [Color(white: 0.55), Color(white: 0.18)]), startPoint: CGPoint(x: tail.x - 30, y: tail.y - 30), endPoint: CGPoint(x: tail.x + 30, y: tail.y + 30)))
            var hs = ctx
            hs.translateBy(x: head.x, y: head.y); hs.rotate(by: .radians(a + 0.45))
            hs.fill(Path(roundedRect: CGRect(x: -10, y: -20, width: 72, height: 40), cornerRadius: 6), with: .color(Color(white: 0.75)))
            hs.fill(Path(roundedRect: CGRect(x: 40, y: -12, width: 16, height: 24), cornerRadius: 3), with: .color(rec))
            ctx.fill(Path(ellipseIn: CGRect(x: P.x - 22, y: P.y - 22, width: 44, height: 44)), with: .color(Color(white: 0.7)))
        }
        .frame(width: 1920, height: 1080)
    }

    // MARK: B · the problem

    @ViewBuilder @MainActor
    static func slam(_ s: String, _ l: Double, _ start: Double, _ color: Color, size: CGFloat = 118) -> some View {
        let p = pop(l, start, r: 0.32, d: 0.82)
        Text(s).font(display(size)).tracking(-3).foregroundStyle(color)
            .opacity(min(1, max(0, (l - start) / 0.1)))
            .offset(y: (1 - p) * 70)
    }

    @ViewBuilder @MainActor
    static func problem(_ l: Double) -> some View {
        ZStack {
            stage(0.06)
            VStack(alignment: .leading, spacing: 14) {
                if l < 2.4 {
                    slam("Someone said a number.", l, 0.05, .white)
                    slam("Nobody wrote it down.", l, 1.2, cream)
                } else {
                    slam("So you invited a bot.", l, 2.45, .white)
                    slam("It sent the call to a server.", l, 3.75, cream, size: 96)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 150).padding(.bottom, 230)
            botToast(l - 2.9)
        }
    }

    @ViewBuilder @MainActor
    static func botToast(_ u: Double) -> some View {
        if u > 0 {
            let inP = pop(u, 0, r: 0.4, d: 0.8)
            let strike = Ease.easeOut(Ease.clip(u, 0.85, 1.1))
            let out = Ease.easeIn(Ease.clip(u, 1.45, 1.85))
            let pct = min(97, Int(u * 64))
            HStack(spacing: 24) {
                ZStack {
                    Circle().fill(Color(white: 0.22))
                    Text("AI").font(inter(24, "Bold")).foregroundStyle(.white.opacity(0.85))
                }
                .frame(width: 66, height: 66)
                VStack(alignment: .leading, spacing: 9) {
                    Text("Notetaker bot joined the call").font(inter(27, "SemiBold")).foregroundStyle(.white)
                    Text("Uploading audio to cloud · \(pct)%").font(mono(19)).foregroundStyle(.white.opacity(0.55))
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule().fill(.white.opacity(0.6)).frame(width: 440 * Double(pct) / 100)
                    }
                    .frame(width: 440, height: 6)
                }
            }
            .padding(30)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.11)))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.1)))
            .overlay(Capsule().fill(rec).frame(width: 720 * strike, height: 7).rotationEffect(.degrees(-5)))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
            .scaleEffect(0.9 + 0.1 * inP)
            .offset(x: (1 - inP) * 520, y: out * 50)
            .opacity((1 - out) * min(1, inP * 2))
            .position(x: 1420, y: 280)
        }
    }

    // MARK: C · logo

    @ViewBuilder @MainActor
    static func logo(_ l: Double) -> some View {
        let s = pop(l, 0, from: 0.5, to: 1, r: 0.5, d: 0.6)
        let pulse = exp(-(l.truncatingRemainder(dividingBy: beat)) * 5)
        ZStack {
            stage(0.1)
            VStack(spacing: 34) {
                ZStack {
                    bundledImage("logo-stacked").resizable().interpolation(.high)
                        .frame(width: 300, height: 300)
                        .shadow(color: .black.opacity(0.8), radius: 40, y: 20)
                    Circle().fill(rec).frame(width: 140, height: 140).blur(radius: 50)
                        .opacity(0.35 + 0.4 * pulse).blendMode(.screen)
                }
                .scaleEffect(s)
                headline("OpenEar", l, 0.35, size: 150, color: .white)
                Text("AI MEETING NOTES  ·  ON YOUR MAC  ·  NO CLOUD")
                    .font(mono(22, .semibold)).tracking(6).foregroundStyle(cream.opacity(0.85))
                    .opacity(ease(l, 0.8, 1.2))
            }
        }
    }

    // MARK: D · calendar

    static let meetings: [(Prov, String, String, String?)] = [
        (.google, "Design review", "10:00 – 10:45 · Meet · 6 people", "in 2m"),
        (.outlook, "Investor update", "11:30 – 12:00 · Teams · 3 people", nil),
        (.apple, "1:1 with Maya", "14:00 – 14:30 · Zoom · 2 people", nil),
        (.exchange, "Pricing workshop", "16:00 – 17:00 · Room 4B · 8 people", nil),
    ]

    @ViewBuilder @MainActor
    static func calendar(_ l: Double) -> some View {
        let win = ease(l, 0, 1.0)
        ZStack {
            stage(0.08)
            caption("01 · UPCOMING", ["Every calendar.", "One place."], t: l, start: 0.1, size: 88,
                    sub: "Apple, Google, Outlook, Exchange — whatever your Mac already knows.")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 140)
            upcomingWindow(l)
                .rotation3DEffect(.degrees(-14 * (1 - win)), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .scaleEffect(0.92 + 0.08 * win)
                .opacity(ease(l, 0, 0.4))
                .position(x: 1360, y: 560)
        }
        .scaleEffect(1 + 0.3 * Ease.easeIn(Ease.clip(l, 4.25, 4.8)), anchor: .top)
    }

    @ViewBuilder @MainActor
    static func upcomingWindow(_ l: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { trafficLights(); Spacer() }.padding(.horizontal, 22).frame(height: 54)
            VStack(alignment: .leading, spacing: 8) {
                Text("Upcoming").font(inter(32, "SemiBold")).foregroundStyle(.white)
                Text("Every meeting across your connected calendars, in one place.")
                    .font(inter(17, "Regular")).foregroundStyle(.white.opacity(0.5))
            }
            .padding(.horizontal, 34).padding(.bottom, 24)
            Text("TODAY").font(mono(15, .semibold)).tracking(3).foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 34).padding(.bottom, 12)
            ForEach(0..<4, id: \.self) { i in meetingRow(i, l) }
            Spacer(minLength: 0)
        }
        .frame(width: 840, height: 650, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(LinearGradient(colors: [elevated, card], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.7), radius: 50, y: 30)
    }

    @ViewBuilder @MainActor
    static func meetingRow(_ i: Int, _ l: Double) -> some View {
        let mt = meetings[i]
        let p = pop(l, 0.5 + Double(i) * 0.3, r: 0.4, d: 0.8)
        HStack(spacing: 20) {
            badge(mt.0, 46)
            VStack(alignment: .leading, spacing: 6) {
                Text(mt.1).font(inter(23, "SemiBold")).foregroundStyle(.white)
                Text(mt.2).font(mono(15)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            if let chip = mt.3 {
                Text(chip).font(mono(15, .semibold)).foregroundStyle(amber)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(amber.opacity(0.12)))
                recordButton(18)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 92)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(i == 0 ? 0.06 : 0.025)))
        .padding(.horizontal, 22).padding(.bottom, 10)
        .opacity(min(1, max(0, p * 1.5)))
        .offset(x: (1 - p) * 70)
    }

    // MARK: E · the notch

    static let S: CGFloat = 2.2

    @ViewBuilder @MainActor
    static func desktop(_ glow: Double = 0.5) -> some View {
        ZStack {
            ink
            RadialGradient(colors: [Color(red: 0.36, green: 0.25, blue: 0.17).opacity(glow), .clear],
                           center: UnitPoint(x: 0.5, y: 1.25), startRadius: 0, endRadius: 1150)
            RadialGradient(colors: [cream.opacity(0.06), .clear], center: .top, startRadius: 0, endRadius: 700)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder @MainActor
    static func menuBar() -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14 * S) {
                Text("Finder").font(inter(13 * S, "Bold"))
                Text("File"); Text("Edit"); Text("View")
                Spacer()
                ZStack {
                    Circle().stroke(.white.opacity(0.85), lineWidth: 1.6 * S).frame(width: 14 * S, height: 14 * S)
                    Circle().fill(rec).frame(width: 5 * S, height: 5 * S)
                }
                Text("Tue 9:58")
            }
            .font(inter(13 * S, "Regular"))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 22 * S)
            .frame(height: 30 * S)
            .background(Color.white.opacity(0.05))
            Spacer()
        }
    }

    @ViewBuilder @MainActor
    static func callWindow() -> some View {
        let names = ["MK", "DV", "AS", "You"]
        let tones: [Double] = [0.16, 0.13, 0.19, 0.11]
        VStack(spacing: 14) {
            ForEach(0..<2, id: \.self) { r in
                HStack(spacing: 14) {
                    ForEach(0..<2, id: \.self) { c in
                        let i = r * 2 + c
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: tones[i]))
                            Circle().fill(Color(white: 0.3)).frame(width: 110, height: 110)
                            Text(names[i]).font(inter(34, "SemiBold")).foregroundStyle(.white.opacity(0.8))
                        }
                        .frame(width: 560, height: 250)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Color(white: 0.06)))
    }

    @ViewBuilder @MainActor
    static func notchShell<Content: View>(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            OELNotchShape(r: min(56, height * 0.36)).fill(Color.black)
            content()
        }
        .frame(width: width, height: height)
        .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
    }

    @ViewBuilder @MainActor
    static func notchScene(_ l: Double) -> some View {
        let e = pop(l, 0.2, r: 0.5, d: 0.78)
        let w = 440 + (1180 - 440) * e
        let hgt = 70 + (172 - 70) * e
        let clickT = 1.9
        let pressed = l >= clickT && l < clickT + 0.12
        let move = Ease.easeInOut(Ease.clip(l, 0.85, 1.75))
        let cx = 1720 + (1380 - 1720) * move, cy = 760 + (104 - 760) * move
        ZStack(alignment: .top) {
            desktop()
            callWindow().opacity(0.15).blur(radius: 1.5).position(x: 960, y: 640)
            menuBar()
            notchShell(width: w, height: hgt) {
                Group {
                    if l < clickT + 0.05 {
                        promptRow(l, pressed: pressed)
                    } else if l < 2.35 {
                        HStack(spacing: 24) {
                            spinner(l, 40)
                            Text("Starting recording…").font(inter(34, "SemiBold")).foregroundStyle(.white)
                        }
                    } else {
                        recordingRow(l - 2.35, title: "Design review")
                    }
                }
                .padding(.top, 34)
                .opacity(ease(l, 0.45, 0.7))
            }
            VStack(spacing: 22) {
                eyebrow("02 · THE NOTCH", l, 0.2)
                if l < 2.3 {
                    headline("It taps you on the shoulder.", l, 0.4, size: 80, color: .white)
                } else {
                    headline("One tap. No bot in the call.", l, 2.4, size: 80, color: .white)
                }
            }
            .padding(.top, 640)
            if l > 0.85 && l < 2.6 {
                cursor(cx, cy, pressed: pressed, size: 56)
                    .opacity(1 - Ease.clip(l, 2.3, 2.6))
            }
        }
    }

    @ViewBuilder @MainActor
    static func promptRow(_ l: Double, pressed: Bool) -> some View {
        HStack(spacing: 26) {
            badge(.google, 64)
            VStack(alignment: .leading, spacing: 6) {
                Text("Design review").font(inter(40, "SemiBold")).foregroundStyle(.white)
                Text("Starts in 1m").font(inter(28, "Medium")).foregroundStyle(amber.opacity(0.85))
            }
            Spacer()
            Text("⌃R").font(mono(22, .semibold)).foregroundStyle(.white.opacity(0.4))
            recordButton(30, pressed: pressed)
                .shadow(color: rec.opacity(0.35 * (0.5 + 0.5 * sin(l * 6))), radius: 18)
        }
        .padding(.horizontal, 58)
    }

    @ViewBuilder @MainActor
    static func recordingRow(_ u: Double, title: String) -> some View {
        let secs = Int(u * 9)
        let breathe = 0.6 + 0.4 * (0.5 + 0.5 * sin(u * 5))
        HStack(spacing: 26) {
            Circle().fill(rec).frame(width: 30, height: 30)
                .shadow(color: rec.opacity(breathe), radius: 16)
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(inter(36, "SemiBold")).foregroundStyle(.white)
                HStack(spacing: 16) {
                    Text(String(format: "%d:%02d", secs / 60, secs % 60)).font(mono(26, .semibold)).foregroundStyle(.white.opacity(0.8))
                    micSystemBadge(22)
                }
            }
            Spacer()
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<14, id: \.self) { i in
                    Capsule().fill(Color.white.opacity(0.85))
                        .frame(width: 7, height: 10 + 52 * level(u + Double(i) * 0.05, Double(i) * 1.3))
                }
            }
            .frame(height: 64)
            ZStack {
                Circle().fill(Color.white).frame(width: 64, height: 64)
                RoundedRectangle(cornerRadius: 4).fill(Color.black).frame(width: 22, height: 22)
            }
        }
        .padding(.horizontal, 58)
    }

    // MARK: F · both sides

    @ViewBuilder @MainActor
    static func bothSides(_ l: Double) -> some View {
        let them = l < 1.2 ? 1.0 : 0.25
        let you = l < 1.2 ? 0.25 : 1.0
        ZStack {
            stage(0.07)
            caption("03 · BOTH SIDES", ["Both sides of the call."], t: l, start: 0.05, size: 72,
                    sub: "Your mic and the call's audio, transcribed on your Mac as it happens.")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 140).padding(.top, 140)
            VStack(alignment: .leading, spacing: 46) {
                lane("THEM · SYSTEM AUDIO", l, seed: 2, gain: them, color: mint)
                lane("YOU · MIC", l, seed: 7, gain: you, color: .white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 140).padding(.bottom, 150)
            transcriptCard(l)
                .position(x: 1400, y: 640)
        }
    }

    @ViewBuilder @MainActor
    static func lane(_ label: String, _ l: Double, seed: Double, gain: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(label).font(mono(17, .semibold)).tracking(3).foregroundStyle(color.opacity(0.7))
            HStack(alignment: .center, spacing: 6) {
                ForEach(0..<44, id: \.self) { i in
                    let v = level(l * 1.6 - Double(i) * 0.04, seed + Double(i) * 0.37) * gain
                    Capsule().fill(color.opacity(0.35 + 0.6 * gain)).frame(width: 9, height: 6 + 110 * v)
                }
            }
            .frame(height: 120)
        }
    }

    @ViewBuilder @MainActor
    static func transcriptCard(_ l: Double) -> some View {
        let line1 = "We can run the pilot at forty-two K."
        let line2 = "Let's lock forty-two and kick off in March."
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                Text("LIVE TRANSCRIPT").font(mono(16, .semibold)).tracking(3).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Circle().fill(rec).frame(width: 12, height: 12)
                Text("12:41").font(mono(16, .semibold)).foregroundStyle(.white.opacity(0.6))
            }
            transcriptLine("MAYA", typed(line1, l, 0.2, cps: 40), mint)
            transcriptLine("YOU", typed(line2, l, 1.25, cps: 44), .white)
            Spacer(minLength: 0)
            Text("Whisper · runs on your Mac").font(mono(15, .semibold)).foregroundStyle(cream.opacity(0.8))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().stroke(cream.opacity(0.35)))
        }
        .padding(34)
        .frame(width: 720, height: 440, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(card))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
        .opacity(ease(l, 0, 0.3))
    }

    @ViewBuilder @MainActor
    static func transcriptLine(_ who: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(who).font(mono(17, .bold)).foregroundStyle(color).frame(width: 64, alignment: .leading)
            Text(text).font(inter(30, "Medium")).foregroundStyle(.white.opacity(0.92))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(text.isEmpty ? 0 : 1)
    }

    // MARK: G · notes

    @ViewBuilder @MainActor
    static func notes(_ l: Double) -> some View {
        ZStack {
            stage(0.08)
            if l < 1.35 {
                notchEnding(l)
            } else {
                notesLayout(l)
            }
        }
    }

    @ViewBuilder @MainActor
    static func notchEnding(_ l: Double) -> some View {
        let stopT = 0.45
        let pressed = l >= stopT && l < stopT + 0.12
        let move = Ease.easeInOut(Ease.clip(l, 0.0, 0.4))
        ZStack(alignment: .top) {
            desktop(0.35)
            notchShell(width: 1180, height: 172) {
                Group {
                    if l < stopT + 0.05 {
                        HStack(spacing: 26) {
                            Circle().fill(rec).frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Design review").font(inter(40, "SemiBold")).foregroundStyle(.white)
                                Text("Ended 1m · still recording").font(inter(28, "Medium")).foregroundStyle(.red.opacity(0.75))
                            }
                            Spacer()
                            Text("Stop").font(inter(30, "SemiBold")).foregroundStyle(.white)
                                .padding(.horizontal, 30).padding(.vertical, 14)
                                .background(Capsule().fill(Color.red.opacity(pressed ? 0.4 : 0.16)))
                                .overlay(Capsule().stroke(Color.red.opacity(0.6), lineWidth: 1.5))
                                .scaleEffect(pressed ? 0.94 : 1)
                        }
                    } else if l < 0.95 {
                        HStack(spacing: 24) {
                            spinner(l, 40)
                            Text("Saving recording…").font(inter(34, "SemiBold")).foregroundStyle(.white)
                        }
                    } else {
                        HStack(spacing: 20) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 44, weight: .semibold)).foregroundStyle(mint)
                            Text("Saved · Design review").font(inter(34, "SemiBold")).foregroundStyle(.white)
                        }
                    }
                }
                .padding(.horizontal, 58).padding(.top, 34)
            }
            if l < 0.75 {
                cursor(1700 + (1400 - 1700) * move, 600 + (104 - 600) * move, pressed: pressed, size: 56)
            }
        }
        .opacity(1 - Ease.clip(l, 1.15, 1.35))
    }

    @ViewBuilder @MainActor
    static func notesLayout(_ l: Double) -> some View {
        let u = l - 1.35
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                eyebrow("04 · NOTES", u, 0.0).padding(.bottom, 22)
                headline("Notes write", u, 0.1, size: 80, color: .white)
                headline("themselves.", u, 0.22, size: 80, color: cream)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.leading, 140).padding(.top, 130)
            VinylDiscView(size: 470, title: "Design review", date: "Today", externalSpinAngle: l * 120)
                .shadow(color: .black.opacity(0.8), radius: 30, y: 18)
                .scaleEffect(0.9 + 0.1 * ease(u, 0, 0.6))
                .opacity(ease(u, 0, 0.4))
                .position(x: 460, y: 720)
            notesCard(u)
                .position(x: 1330, y: 560)
        }
    }

    static let summary = "Pilot approved at $42K. Kickoff the first week of March. Maya owns the vendor shortlist; the security review is the only open risk."
    static let actions: [(String, String)] = [
        ("Send the pilot contract", "YOU · FRI"),
        ("Shortlist three vendors", "MAYA · WED"),
        ("Book the security review", "DEV · NEXT WEEK"),
    ]

    @ViewBuilder @MainActor
    static func notesCard(_ u: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Design review").font(display(46)).foregroundStyle(.white)
                Spacer()
                Text("Qwen3.5 · on-device").font(mono(15, .semibold)).foregroundStyle(cream.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().stroke(cream.opacity(0.35)))
            }
            Text("TODAY · 10:00 · 38 MIN · 2 SPEAKERS").font(mono(16, .medium)).tracking(2)
                .foregroundStyle(.white.opacity(0.42)).padding(.top, 10)
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1).padding(.vertical, 26)
            Text("SUMMARY").font(mono(16, .semibold)).tracking(3).foregroundStyle(.white.opacity(0.45))
                .padding(.bottom, 12)
            Text(typed(summary, u, 0.3, cps: 72))
                .font(inter(27, "Regular")).foregroundStyle(.white.opacity(0.88)).lineSpacing(7)
                .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
            Text("ACTION ITEMS").font(mono(16, .semibold)).tracking(3).foregroundStyle(.white.opacity(0.45))
                .padding(.top, 26).padding(.bottom, 14)
                .opacity(ease(u, 1.75, 2.0))
            ForEach(0..<3, id: \.self) { i in actionRow(i, u) }
        }
        .padding(40)
        .frame(width: 880, height: 760, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(LinearGradient(colors: [elevated, card], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.7), radius: 50, y: 26)
        .opacity(ease(u, 0, 0.35))
        .offset(y: (1 - ease(u, 0, 0.5)) * 40)
    }

    @ViewBuilder @MainActor
    static func actionRow(_ i: Int, _ u: Double) -> some View {
        let start = 1.85 + Double(i) * 0.25
        let p = pop(u, start, r: 0.35, d: 0.8)
        let done = i == 0 && u > 2.95
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).stroke(done ? mint : .white.opacity(0.4), lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 7).fill(done ? mint.opacity(0.2) : .clear))
                if done { Image(systemName: "checkmark").font(.system(size: 18, weight: .bold)).foregroundStyle(mint) }
            }
            .frame(width: 30, height: 30)
            Text(actions[i].0).font(inter(26, "Medium")).foregroundStyle(.white.opacity(done ? 0.5 : 0.9))
                .strikethrough(done, color: .white.opacity(0.5))
            Spacer()
            Text(actions[i].1).font(mono(15, .semibold)).tracking(1.5).foregroundStyle(.white.opacity(0.45))
        }
        .padding(.vertical, 12)
        .opacity(u < start ? 0 : min(1, p * 1.4))
        .offset(x: (1 - p) * 40)
    }

    // MARK: H · ask

    static let query = "what did Maya say about the budget?"
    static let answer = "Maya proposed $42K for the pilot — and said she could stretch to $45K if the security review slips."
    static let snippet = ["“…we", "can", "run", "the", "pilot", "at", "forty-two", "K,", "maybe", "forty-five", "if", "security", "takes", "longer…”"]

    @ViewBuilder @MainActor
    static func ask(_ l: Double) -> some View {
        ZStack {
            stage(0.09)
            VStack(spacing: 0) {
                eyebrow("05 · MEMORY", l, 0.0).padding(.bottom, 20)
                headline("Ask anything you've said.", l, 0.08, size: 84, color: .white)
                searchBar(l).padding(.top, 54)
                resultCard(l).padding(.top, 28)
                Spacer(minLength: 0)
            }
            .padding(.top, 120)
        }
    }

    @ViewBuilder @MainActor
    static func searchBar(_ l: Double) -> some View {
        let q = typed(query, l, 0.4, cps: 27)
        let caret = Int(l * 2.4) % 2 == 0 || (l > 0.4 && l < 1.75)
        HStack(spacing: 20) {
            Image(systemName: "magnifyingglass").font(.system(size: 32, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            Text(q.isEmpty ? "Ask anything you've said…" : q)
                .font(inter(34, q.isEmpty ? "Regular" : "Medium"))
                .foregroundStyle(.white.opacity(q.isEmpty ? 0.35 : 0.95))
            Rectangle().fill(cream).frame(width: 3, height: 40).opacity(caret && l < 1.95 ? 1 : 0)
            Spacer()
            Text("⏎").font(mono(24, .semibold)).foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 34)
        .frame(width: 1240, height: 100)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(elevated))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(l > 0.3 && l < 1.95 ? 0.28 : 0.12), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 14)
        .opacity(ease(l, 0.15, 0.4))
    }

    @ViewBuilder @MainActor
    static func resultCard(_ l: Double) -> some View {
        let p = pop(l, 1.95, r: 0.42, d: 0.78)
        let sweep = Ease.clip(l, 3.05, 4.5) * Double(snippet.count)
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Circle().fill(Color(white: 0.06)).overlay(Circle().fill(Color(red: 0.45, green: 0.12, blue: 0.11)).frame(width: 14, height: 14))
                    .frame(width: 36, height: 36)
                Text("Design review · Today 10:00").font(inter(22, "SemiBold")).foregroundStyle(.white.opacity(0.85))
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "play.fill").font(.system(size: 14, weight: .bold))
                    Text("12:41").font(mono(18, .semibold))
                }
                .foregroundStyle(cream)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Capsule().fill(cream.opacity(0.12)))
            }
            Text(typed(answer, l, 2.1, cps: 62))
                .font(display(36, "Medium")).foregroundStyle(.white).lineSpacing(6)
                .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            HStack(spacing: 9) {
                ForEach(snippet.indices, id: \.self) { i in
                    let lit = Double(i) < sweep
                    Text(snippet[i]).font(inter(24, "Medium"))
                        .foregroundStyle(lit ? Color.black.opacity(0.85) : .white.opacity(0.5))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(lit ? cream : .clear))
                }
            }
            .opacity(ease(l, 2.9, 3.1))
        }
        .padding(34)
        .frame(width: 1240, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(card))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.1)))
        .shadow(color: .black.opacity(0.6), radius: 40, y: 20)
        .scaleEffect(0.96 + 0.04 * p, anchor: .top)
        .opacity(l < 1.95 ? 0 : min(1, p * 1.5))
        .offset(y: (1 - p) * 30)
    }

    // MARK: I · ledger

    static let ledgerRows = ["Audio bytes uploaded", "Voice servers contacted", "Transcripts uploaded",
                             "Bots in your meetings", "Accounts required"]

    @ViewBuilder @MainActor
    static func ledger(_ l: Double) -> some View {
        ZStack {
            stage(0.09)
            VStack(alignment: .leading, spacing: 0) {
                eyebrow("06 · PRIVACY", l, 0.05).padding(.bottom, 24)
                headline("Your voice never", l, 0.15, size: 86, color: .white)
                headline("leaves your Mac.", l, 0.3, size: 86, color: cream)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(["We don't record it.", "We don't read it.", "We don't have it."].enumerated()), id: \.offset) { i, s in
                        Text(s).font(mono(28, .semibold)).foregroundStyle(.white.opacity(0.75))
                            .opacity(ease(l, 3.0 + Double(i) * 0.6, 3.2 + Double(i) * 0.6))
                    }
                }
                .padding(.top, 50)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 140)
            receipt(l).position(x: 1390, y: 540)
        }
    }

    @ViewBuilder @MainActor
    static func receipt(_ l: Double) -> some View {
        let printP = Ease.easeOut(Ease.clip(l, 0.15, 1.5))
        let paperH: CGFloat = 800
        VStack(spacing: 0) {
            Capsule().fill(Color(white: 0.16)).frame(width: 700, height: 20)
                .overlay(Capsule().fill(Color.black).frame(width: 650, height: 6))
            ZStack(alignment: .top) {
                receiptPaper(l)
                    .frame(width: 600, height: paperH, alignment: .top)
                    .offset(y: -paperH * (1 - printP))
            }
            .frame(width: 600, height: paperH, alignment: .top)
            .clipped()
        }
    }

    @ViewBuilder @MainActor
    static func receiptPaper(_ l: Double) -> some View {
        let seal = pop(l, 3.15, from: 1.8, to: 1.0, r: 0.3, d: 0.6)
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text("OE").font(display(64, "Black")).foregroundStyle(paperInk)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        Text("VOICE PRIVACY LEDGER").font(mono(16, .bold)).tracking(2)
                        Text("OE · 0001 · SIDE A").font(mono(14, .medium))
                    }
                    .foregroundStyle(paperInk)
                }
                dashed().padding(.vertical, 22)
                ForEach(ledgerRows.indices, id: \.self) { i in
                    ledgerRow(ledgerRows[i], "0", bold: false)
                        .opacity(ease(l, 0.9 + Double(i) * 0.3, 1.0 + Double(i) * 0.3))
                }
                dashed().padding(.vertical, 18)
                ledgerRow("Total voice data shared", "0 bytes", bold: true)
                    .opacity(ease(l, 2.55, 2.7))
                Text("Signed · Your Mac, locally").font(inter(21, "Italic")).foregroundStyle(paperInk.opacity(0.75))
                    .padding(.top, 34)
                    .opacity(ease(l, 2.85, 3.0))
                Spacer(minLength: 0)
                Text("EVERY SECOND · ALWAYS").font(mono(13, .semibold)).tracking(2).foregroundStyle(paperInk.opacity(0.5))
            }
            .padding(42)
            ZStack {
                Circle().stroke(rec, lineWidth: 5).frame(width: 170, height: 170)
                Circle().stroke(rec, lineWidth: 2).frame(width: 146, height: 146)
                VStack(spacing: 2) {
                    Text("ON").font(mono(17, .heavy))
                    Text("DEVICE").font(mono(22, .heavy))
                    Text("OE · 0001").font(mono(11, .bold))
                }
                .foregroundStyle(rec)
            }
            .rotationEffect(.degrees(-14))
            .scaleEffect(seal)
            .opacity(l < 3.15 ? 0 : 0.88)
            .padding(.trailing, 44).padding(.bottom, 80)
        }
        .background(paper)
        .overlay(LinearGradient(colors: [.black.opacity(0.12), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.08)))
    }

    @ViewBuilder @MainActor
    static func dashed() -> some View {
        OELHLine().stroke(paperInk.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [7, 6])).frame(height: 2)
    }

    @ViewBuilder @MainActor
    static func ledgerRow(_ label: String, _ value: String, bold: Bool) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            Text(label).font(inter(bold ? 23 : 22, bold ? "Bold" : "Medium")).foregroundStyle(paperInk)
                .lineLimit(1).fixedSize()
            OELHLine().stroke(paperInk.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [2, 6]))
                .frame(height: 2).offset(y: -6)
            Text(value).font(mono(bold ? 24 : 23, .bold)).foregroundStyle(paperInk).fixedSize()
        }
        .padding(.vertical, 9)
    }

    // MARK: J · dictation

    static let raw = "um so ship it friday and uh i'll send the contract tonight"
    static let clean = "Ship it Friday — I'll send the contract tonight."

    @ViewBuilder @MainActor
    static func dictation(_ l: Double) -> some View {
        let down = l > 0.3 && l < 1.45
        let cleaned = l > 1.55
        ZStack {
            stage(0.08)
            VStack(spacing: 0) {
                eyebrow("07 · PLUS", l, 0.0).padding(.bottom, 34)
                HStack(spacing: 34) {
                    Text("Hold").font(display(96)).tracking(-2).foregroundStyle(.white)
                    keycap(down)
                    Text("to dictate anywhere.").font(display(96)).tracking(-2).foregroundStyle(cream)
                }
                .opacity(ease(l, 0.0, 0.25))
                HStack(spacing: 16) {
                    Text(cleaned ? clean : typed(raw, l, 0.45, cps: 58))
                        .font(cleaned ? inter(34, "Medium") : inter(34, "Italic"))
                        .foregroundStyle(cleaned ? .white : .white.opacity(0.45))
                    Spacer()
                    Text("cleaned up on-device").font(mono(16, .semibold)).foregroundStyle(mint)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(mint.opacity(0.12)))
                        .opacity(ease(l, 1.6, 1.8))
                }
                .padding(.horizontal, 36)
                .frame(width: 1240, height: 112)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(card))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12)))
                .padding(.top, 70)
                .opacity(ease(l, 0.35, 0.55))
            }
        }
    }

    @ViewBuilder @MainActor
    static func keycap(_ down: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: down ? 0.13 : 0.2), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(down ? 0.12 : 0.22), lineWidth: 1.5)
            Text("fn").font(inter(44, "Medium")).foregroundStyle(.white.opacity(0.9)).padding(22)
            Image(systemName: "globe").font(.system(size: 26, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(20)
        }
        .frame(width: 150, height: 136)
        .shadow(color: .black.opacity(down ? 0.2 : 0.7), radius: down ? 4 : 16, y: down ? 2 : 10)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(rec.opacity(down ? 0.7 : 0), lineWidth: 3))
        .offset(y: down ? 6 : 0)
    }

    // MARK: K · end card

    @ViewBuilder @MainActor
    static func endCard(_ l: Double) -> some View {
        let sleeveIn = pop(l, 0.05, r: 0.5, d: 0.8)
        let slide = Ease.easeInOut(Ease.clip(l, 0.45, 1.5))
        ZStack {
            stage(0.12)
            ZStack {
                VinylDiscView(size: 500, title: "OpenEar", date: "Side A", externalSpinAngle: l * 60)
                    .offset(x: 150 * slide)
                SleeveView(size: 540, seed: 7)
                    .overlay(sleeveArt())
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.8), radius: 40, y: 24)
            }
            .offset(y: (1 - sleeveIn) * 90)
            .opacity(min(1, sleeveIn * 1.4))
            .position(x: 540, y: 560)
            priceTag(l - 2.35).position(x: 690, y: 0)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 26) {
                    bundledImage("logo-stacked").resizable().interpolation(.high).frame(width: 110, height: 110)
                    Text("OpenEar").font(display(108)).tracking(-3).foregroundStyle(.white)
                }
                .opacity(ease(l, 0.25, 0.65)).offset(y: (1 - ease(l, 0.25, 0.65)) * 24)
                Text("On-device dictation, recording,\nand AI meeting notes for Mac.")
                    .font(inter(34, "Regular")).foregroundStyle(.white.opacity(0.72)).lineSpacing(8)
                    .padding(.top, 30)
                    .opacity(ease(l, 0.5, 0.9))
                HStack(spacing: 26) {
                    HStack(spacing: 12) {
                        Image(systemName: "apple.logo").font(.system(size: 26, weight: .semibold))
                        Text("Download for Mac").font(inter(28, "SemiBold"))
                    }
                    .foregroundStyle(Color.black.opacity(0.88))
                    .padding(.horizontal, 34).frame(height: 78)
                    .background(Capsule().fill(Color.white))
                    Text("7-DAY FREE TRIAL").font(mono(19, .semibold)).tracking(3).foregroundStyle(.white.opacity(0.55))
                }
                .padding(.top, 50)
                .opacity(ease(l, 0.8, 1.2))
                Text("openear.fyi").font(mono(36, .semibold)).foregroundStyle(cream)
                    .padding(.top, 46)
                    .opacity(ease(l, 1.1, 1.5))
                Text("macOS 14+ · Apple Silicon · Made for the Mac").font(mono(17, .medium)).tracking(1.5)
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.top, 22)
                    .opacity(ease(l, 1.3, 1.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 1010)
        }
    }

    @ViewBuilder @MainActor
    static func sleeveArt() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OE · 0001").font(mono(16, .semibold)).tracking(2)
            Spacer()
            Text("MEETINGS · DICTATION · MEMORY").font(mono(12, .medium)).tracking(1.5).opacity(0.7)
        }
        .foregroundStyle(cream.opacity(0.75))
        .padding(34)
        .frame(width: 540, height: 540, alignment: .topLeading)
    }

    @ViewBuilder @MainActor
    static func priceTag(_ u: Double) -> some View {
        if u > 0 {
            let drop = pop(u, 0, r: 0.45, d: 0.62)
            let swing = 10 * exp(-u * 1.4) * sin(u * 5.5)
            VStack(spacing: 0) {
                Rectangle().fill(cream.opacity(0.6)).frame(width: 2, height: 120)
                VStack(spacing: 6) {
                    Circle().stroke(paperInk.opacity(0.5), lineWidth: 2).frame(width: 18, height: 18).padding(.bottom, 8)
                    Text("PAY ONCE").font(mono(26, .heavy)).tracking(2).foregroundStyle(paperInk)
                    Text("yours forever").font(inter(26, "Italic")).foregroundStyle(paperInk.opacity(0.8))
                    Text("NO SUBSCRIPTION · OE · 0001").font(mono(11, .bold)).tracking(1).foregroundStyle(paperInk.opacity(0.5))
                        .padding(.top, 6)
                }
                .padding(.vertical, 22).padding(.horizontal, 30)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(paper))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 10)
            }
            .rotationEffect(.degrees(swing - 6), anchor: .top)
            .offset(y: -420 + 420 * drop + 160)
            .frame(height: 0, alignment: .top)
        }
    }
}

// MARK: - shapes

struct OELNotchShape: Shape {
    var r: CGFloat
    func path(in rect: CGRect) -> Path {
        let e = r * 0.5
        var p = Path()
        p.move(to: CGPoint(x: -e, y: 0))
        p.addQuadCurve(to: CGPoint(x: 0, y: e), control: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: 0, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: r, y: rect.maxY), control: CGPoint(x: 0, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - r), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: e))
        p.addQuadCurve(to: CGPoint(x: rect.maxX + e, y: 0), control: CGPoint(x: rect.maxX, y: 0))
        p.closeSubpath()
        return p
    }
}

struct OELCursorShape: Shape {
    func path(in r: CGRect) -> Path {
        let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 0.8), (0.3, 0.6), (0.48, 0.97), (0.66, 0.89), (0.48, 0.54), (0.95, 0.54)]
        var p = Path()
        p.move(to: CGPoint(x: r.minX + pts[0].0 * r.width, y: r.minY + pts[0].1 * r.height))
        for q in pts.dropFirst() { p.addLine(to: CGPoint(x: r.minX + q.0 * r.width, y: r.minY + q.1 * r.height)) }
        p.closeSubpath()
        return p
    }
}

struct OELHLine: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY)); return p
    }
}
