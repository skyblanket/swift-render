import SwiftUI

/// FutureOfTheFirm — an animated, narrated explainer of the essay
/// "The future of the firm in an AI-driven economy."
///
/// Fourteen chapters on a shared anchor grid. Each chapter is a pure function
/// of local time that *illustrates* an idea (a cognitive loop, two kinds of
/// capital, a hill-climbing machine, a frontier ecosystem …) rather than just
/// captioning it. A synthesized ambient score is declared next to the same
/// `anchors` array that drives the cuts, so music can't drift from picture.
///
/// Narration (TTS) is layered on top at render time — see
/// `tools/make_firm_audio.sh`, whose VO start times mirror `anchors` below.
///
///   # one command does the whole pipeline (music → TTS → mix → render):
///   bash tools/make_firm_audio.sh
///
///   # or render the silent picture with just the score:
///   swift run swift-render render FutureOfTheFirm --out out/firm.mp4
public struct FutureOfTheFirm: RenderScene {
    // 14 chapter lengths in seconds. KEEP IN SYNC with tools/make_firm_audio.sh.
    static let durs: [Double] = [9, 12, 11, 14, 11, 13, 13, 14, 14, 14, 12, 13, 13, 6]
    static let cross: Double = 0.5   // crossfade overlap between chapters

    /// Absolute start time of each chapter. anchors[i+1] = anchors[i] + durs[i] - cross.
    static let anchors: [Double] = {
        var out: [Double] = []; var c = 0.0
        for d in durs { out.append(c); c += d - cross }
        return out
    }()

    public static let defaultDuration: Double = anchors.last! + durs.last!  // 162.5s

    // MARK: palette
    static let bg     = Color(red: 0.039, green: 0.039, blue: 0.047)
    static let ink    = Color(red: 0.961, green: 0.949, blue: 0.918)
    static let dim    = Color(red: 0.56,  green: 0.57,  blue: 0.60)
    static let faint  = Color(red: 0.30,  green: 0.31,  blue: 0.34)
    static let accent = Color(red: 0.776, green: 1.0,   blue: 0.102)   // #C7FF1A
    static let warn   = Color(red: 0.965, green: 0.467, blue: 0.247)
    static let panel  = Color(white: 0.075)

    // MARK: - Body

    @MainActor public static func body(at t: Double, duration: Double) -> some View {
        let a = anchors
        return ZStack {
            bg.ignoresSafeArea()
            Timeline(t) {
                Clip(at: a[0],  for: durs[0])  { l in wrap(l, durs[0])  { titleCard(l, durs[0]) } }
                Clip(at: a[1],  for: durs[1])  { l in wrap(l, durs[1])  { cognitiveLoop(l, durs[1]) } }
                Clip(at: a[2],  for: durs[2])  { l in wrap(l, durs[2])  { atStake(l, durs[2]) } }
                Clip(at: a[3],  for: durs[3])  { l in wrap(l, durs[3])  { twoCapitals(l, durs[3]) } }
                Clip(at: a[4],  for: durs[4])  { l in wrap(l, durs[4])  { moreValuable(l, durs[4]) } }
                Clip(at: a[5],  for: durs[5])  { l in wrap(l, durs[5])  { learningLoop(l, durs[5]) } }
                Clip(at: a[6],  for: durs[6])  { l in wrap(l, durs[6])  { sovereignty(l, durs[6]) } }
                Clip(at: a[7],  for: durs[7])  { l in wrap(l, durs[7])  { components(l, durs[7]) } }
                Clip(at: a[8],  for: durs[8])  { l in wrap(l, durs[8])  { hillClimb(l, durs[8]) } }
                Clip(at: a[9],  for: durs[9])  { l in wrap(l, durs[9])  { theWarning(l, durs[9]) } }
                Clip(at: a[10], for: durs[10]) { l in wrap(l, durs[10]) { globalization(l, durs[10]) } }
                Clip(at: a[11], for: durs[11]) { l in wrap(l, durs[11]) { ecosystem(l, durs[11]) } }
                Clip(at: a[12], for: durs[12]) { l in wrap(l, durs[12]) { payoff(l, durs[12]) } }
                Clip(at: a[13], for: durs[13]) { l in wrap(l, durs[13]) { lockup(l, durs[13]) } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The soundtrack lives next to the Timeline: `anchors` drives both the
    /// cuts and the hits, so audio and video share one source of truth.
    ///
    /// MUSICAL DESIGN — a slow harmonic journey in A minor that opens up toward
    /// C major by the finale, scored so a ducked voiceover sits cleanly on top.
    /// The bed is built almost entirely from sustained sub-bass + layered pad
    /// drones (warm low/low-mid harmony), keeping the 1–4 kHz vocal band sparse.
    ///
    ///   sec  bars                 chord        feeling
    ///   00   title (0–20)         Am  (A·C·E)  contemplative, hollow open fifth
    ///   01   two-capitals (20–44) F  (F·A·C)   warm IV/VI lift — "two capitals"
    ///   02   learning (44–67)     C  (C·E·G)   brightening — the loop compounds
    ///   03   build (67–93)        Dm→Asus      tension/momentum into the climax
    ///   04   CLIMAX (93–106)      Am  (A·C·E)  full, ringing — hill-climbing machine
    ///   05   warning (106–120)    Em  (E·G·B)  darker dominant — the failure mode
    ///   06   ecosystem (120–144)  F→C          turn outward, resolving upward
    ///   07   FINALE (144–162.5)   C  (C·E·G·C) fullest, resolved major chord
    public static func soundtrack(duration: Double) -> Score? {
        let a = anchors
        let cuts = Array(a.dropFirst())
        return Score(duration: duration) {
            // ── Sub-bass foundation: one continuous low root under the whole
            //    piece, gently following the harmony so it never fights the VO.
            drone(.a1, from: 0,    for: 70,  amp: 0.10)            // A  · opening
            drone(Note(43.65), from: a[3] - 1, for: 30, amp: 0.085) // F  · two-capitals
            drone(Note(32.70), from: a[5] - 1, for: 42, amp: 0.085) // C  · learning/build
            drone(.a1, from: a[8] - 1, for: 16,  amp: 0.11)         // A  · climax
            drone(.e1, from: a[9] - 1, for: 16,  amp: 0.085)        // E  · warning
            drone(Note(32.70), from: a[10] - 1, for: 26, amp: 0.10) // C  · ecosystem/finale

            // ── Evolving pad harmony (chord stacks of drones, gentle overlaps).
            chordPad([.a1, .e2, c3],      from: 0,        until: a[3], amp: 0.052) // Am
            chordPad([f2, .a2, c3],       from: a[3] - 1, until: a[5], amp: 0.050) // F
            chordPad([.c2, .g2, e3],      from: a[5] - 1, until: a[7], amp: 0.048) // C
            chordPad([.d2, .a2, f3],      from: a[7] - 1, until: a[8], amp: 0.052) // Dm — tension
            chordPad([.a1, .e2, .b1, c3], from: a[8] - 0.6, until: a[9], amp: 0.060) // Asus/Am climax
            chordPad([.e1, .b1, .g2],     from: a[9] - 0.8, until: a[10], amp: 0.052) // Em — warning
            chordPad([f2, c3, .a2],       from: a[10] - 0.8, until: a[12], amp: 0.052) // F — turn
            chordPad([.c2, .g2, e3, c4],  from: a[12] - 0.8, until: duration, amp: 0.058) // C — finale

            // ── Cut accents: a faint crash on every transition.
            crashes(at: cuts, amp: 0.11)

            // ── Opening downbeat, very soft.
            boom(at: 0.2, amp: 0.42, duration: 2.6)

            // ── Momentum into the hill-climbing-machine climax (anchors[8]).
            every(1.2, from: a[6], to: a[9] - 0.5) { kick(at: $0, amp: 0.24) }
            boom(at: a[8], amp: 0.58, duration: 2.2)            // "a hill-climbing machine"

            // ── Ecosystem turn (anchors[11]).

            // ── Resolved finale (anchors[13]).
            boom(at: a[13], amp: 0.82, duration: 3.0)
        }
    }

    // MARK: Score helpers

    /// Higher named pitches (an octave above the bank's bass set) used as pad
    /// chord tones — they sit *below* the 1–4 kHz vocal band so the voiceover
    /// stays clear, while still giving the harmony body.
    static let f2 = Note(87.31), f3 = Note(174.61)
    static let c3 = Note(130.81), e3 = Note(164.81)
    static let c4 = Note(261.63)

    /// A sustained chord: one `drone` per pitch, all spanning the same window,
    /// with an amp taper (root loudest) so stacked tones blend warmly instead of
    /// summing into a harsh peak — each `drone` adds its own fifth-harmonic and
    /// slow LFO for movement. Overlapping `from`/`until` across calls makes
    /// adjacent sections dissolve into one another.
    static func chordPad(_ notes: [Note], from: Double, until: Double,
                         amp: Double) -> [ScoreEvent] {
        let dur = max(0.5, until - from + 1.4)   // overlap into the next chord
        var out: [ScoreEvent] = []
        for (i, n) in notes.enumerated() {
            // upper voices slightly quieter so the root anchors the chord
            let voiceAmp = amp * (i == 0 ? 1.0 : 0.78 - 0.07 * Double(i - 1))
            out += drone(n, from: from, for: dur, amp: max(0.012, voiceAmp))
        }
        return out
    }


    // MARK: - Shared building blocks

    /// Per-chapter crossfade: fade content up over the first `cross` seconds and
    /// down over the last `cross`. Overlapping anchors make adjacent chapters
    /// dissolve into one another with no black gap.
    @ViewBuilder @MainActor
    static func wrap<V: View>(_ l: Double, _ dur: Double, @ViewBuilder _ content: () -> V) -> some View {
        let fin = Ease.easeInOut(Ease.clip(l, 0, cross))
        let fout = 1 - Ease.easeInOut(Ease.clip(l, dur - cross, dur))
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(fin * fout)
    }

    /// Small mono uppercase kicker label with an accent tick.
    @ViewBuilder
    static func kicker(_ text: String, _ p: Double, color: Color = accent) -> some View {
        HStack(spacing: 12) {
            Rectangle().fill(color).frame(width: 22, height: 3)
            Text(text)
                .font(.system(size: 24, weight: .semibold, design: .monospaced))
                .tracking(4)
                .foregroundStyle(color)
        }
        .opacity(p)
        .offset(x: (1 - p) * -24)
    }

    /// A line that wipes up behind a moving mask (the IGHook reveal).
    @ViewBuilder
    static func reveal<V: View>(_ p: Double, height: CGFloat, @ViewBuilder _ content: () -> V) -> some View {
        content()
            .opacity(p)
            .mask(Rectangle().frame(height: CGFloat(p) * height).frame(maxHeight: .infinity, alignment: .top))
    }

    /// Marker / node orbiting the center of a 2R box at `angleDeg`.
    @ViewBuilder
    static func orbit<V: View>(radius R: CGFloat, angleDeg: Double, @ViewBuilder _ child: () -> V) -> some View {
        ZStack { child().offset(x: R) }
            .frame(width: 2 * R, height: 2 * R)
            .rotationEffect(.degrees(angleDeg))
    }

    /// A spoke from center out to radius R at `angleDeg`.
    @ViewBuilder
    static func spoke(radius R: CGFloat, angleDeg: Double, color: Color, weight: CGFloat = 2) -> some View {
        ZStack { Rectangle().fill(color).frame(width: R, height: weight).offset(x: R / 2) }
            .frame(width: 2 * R, height: 2 * R)
            .rotationEffect(.degrees(angleDeg))
    }

    static func hash01(_ x: Double) -> Double {
        abs((sin(x) * 43758.5453).truncatingRemainder(dividingBy: 1.0))
    }

    // MARK: - 00 · Title

    @MainActor static func titleCard(_ t: Double, _ dur: Double) -> some View {
        let glow  = Ease.easeOut(Ease.clip(t, 0.0, 2.5))
        let k     = Ease.easeOut(Ease.clip(t, 0.3, 1.0))
        let l1    = Ease.easeOut(Ease.clip(t, 0.7, 1.6))
        let l2    = Ease.easeOut(Ease.clip(t, 1.1, 2.0))
        let sub   = Ease.easeOut(Ease.clip(t, 2.0, 2.9))
        let line  = Ease.easeInOut(Ease.clip(t, 2.2, 3.2))
        return ZStack {
            Rectangle().fill(.black)
                .colorEffect(ShaderLibrary.bundle(.module).plasmaField(
                    .float2(1920, 1080), .float(Float(t * 0.6)), .float(1.5)))
                .opacity(glow * 0.22)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                kicker("AN ESSAY ON", k)
                    .padding(.bottom, 30)
                reveal(l1, height: 190) {
                    Text("The future")
                        .font(.custom("Inter-Black", size: 150)).tracking(-5)
                        .foregroundStyle(ink)
                }
                reveal(l2, height: 190) {
                    Text("of the firm.")
                        .font(.custom("Inter-Black", size: 150)).tracking(-5)
                        .foregroundStyle(ink)
                }
                Rectangle().fill(accent)
                    .frame(width: CGFloat(line) * 520, height: 8)
                    .padding(.top, 22).padding(.bottom, 26)
                Text("in an AI-driven economy")
                    .font(.custom("Inter-Light", size: 46)).tracking(-0.5)
                    .foregroundStyle(dim)
                    .opacity(sub)
                    .offset(y: (1 - sub) * 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 160)
        }
    }

    // MARK: - 01 · The cognitive loop

    @MainActor static func cognitiveLoop(_ t: Double, _ dur: Double) -> some View {
        let R: CGFloat = 250
        let ringP = Ease.easeInOut(Ease.clip(t, 0.7, 1.9))
        let left  = Ease.spring(t, from: -260, to: 0, response: 0.6, dampingFraction: 0.7)
        let right = Ease.spring(t, from: 260, to: 0, response: 0.6, dampingFraction: 0.7)
        let marker = (t - 1.6) * 95                     // degrees/sec once the ring is drawn
        let labelP = Ease.easeOut(Ease.clip(t, 1.9, 2.6))
        return ZStack {
            kicker("FOR THE FIRST TIME", Ease.easeOut(Ease.clip(t, 0.0, 0.7)))
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 150)

            Circle().trim(from: 0, to: ringP)
                .stroke(faint, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 14]))
                .frame(width: 2 * R, height: 2 * R)
                .rotationEffect(.degrees(-90))
            if t > 1.6 {
                orbit(radius: R, angleDeg: marker) {
                    Circle().fill(accent).frame(width: 22, height: 22)
                        .shadow(color: accent.opacity(0.8), radius: 14)
                }
                orbit(radius: R, angleDeg: marker + 180) {
                    Circle().fill(ink).frame(width: 14, height: 14)
                }
            }

            HStack(spacing: 2 * R + 60) {
                loopNode("PEOPLE", "judgment · ingenuity", ink).offset(x: left)
                loopNode("MACHINES", "compute · models", accent).offset(x: right)
            }

            VStack(spacing: 6) {
                Text("a cognitive loop")
                    .font(.custom("Inter-Bold", size: 40)).foregroundStyle(ink)
                Text("people and digital systems, learning together")
                    .font(.custom("Inter-Light", size: 24)).foregroundStyle(dim)
            }
            .opacity(labelP)
            .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 150)
        }
    }

    @ViewBuilder static func loopNode(_ title: String, _ sub: String, _ color: Color) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.custom("Inter-Bold", size: 54)).tracking(-1).foregroundStyle(color)
            Text(sub).font(.system(size: 22, design: .monospaced)).foregroundStyle(dim)
        }
        .padding(.vertical, 34).padding(.horizontal, 44)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(panel))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(color.opacity(0.4), lineWidth: 1.5))
    }

    // MARK: - 02 · What's at stake

    @MainActor static func atStake(_ t: Double, _ dur: Double) -> some View {
        let k  = Ease.easeOut(Ease.clip(t, 0.0, 0.7))
        let l1 = Ease.easeOut(Ease.clip(t, 0.6, 1.5))
        let words = ["learn", "build IP", "differentiate", "thrive"]
        let comm = Ease.easeIn(Ease.clip(t, 4.2, 6.5))          // "commoditize" pressure
        return ZStack {
            VStack(alignment: .leading, spacing: 28) {
                kicker("WHAT'S AT STAKE", k)
                reveal(l1, height: 160) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not a tool, or a system —")
                            .font(.custom("Inter-Light", size: 52)).foregroundStyle(dim)
                        Text("how organizations keep learning.")
                            .font(.custom("Inter-Bold", size: 72)).tracking(-2).foregroundStyle(ink)
                    }
                }
                HStack(spacing: 18) {
                    ForEach(0..<words.count, id: \.self) { i in
                        let p = Ease.easeOutBack(Ease.clip(t, 1.7 + Double(i) * 0.22, 2.4 + Double(i) * 0.22))
                        Text(words[i])
                            .font(.custom("Inter-Bold", size: 34)).foregroundStyle(accent)
                            .padding(.vertical, 12).padding(.horizontal, 24)
                            .background(Capsule().stroke(accent.opacity(0.5), lineWidth: 1.5))
                            .opacity(p).scaleEffect(0.8 + 0.2 * p)
                    }
                }
                .padding(.top, 8)
                Text("…while AI can absorb that expertise and commoditize it.")
                    .font(.custom("Inter-Light", size: 38)).foregroundStyle(ink.opacity(1 - comm * 0.65))
                    .blur(radius: comm * 4)
                    .opacity(Ease.easeOut(Ease.clip(t, 3.4, 4.2)))
                    .padding(.top, 18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 160)
        }
    }

    // MARK: - 03 · Two kinds of capital

    @MainActor static func twoCapitals(_ t: Double, _ dur: Double) -> some View {
        let k  = Ease.easeOut(Ease.clip(t, 0.0, 0.8))
        let lp = Ease.spring(t, from: -420, to: 0, response: 0.7, dampingFraction: 0.78)
        let rp = Ease.spring(t, from: 420, to: 0, response: 0.7, dampingFraction: 0.78)
        let plus = Ease.easeOutBack(Ease.clip(t, 1.2, 1.9))
        let human = ["knowledge", "judgment", "relationships", "ingenuity", "pattern recognition"]
        let token = ["the AI capability", "you build", "and own"]
        return ZStack {
            kicker("EVERY COMPANY WILL BUILD TWO KINDS OF CAPITAL", k)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 110)
            HStack(spacing: 0) {
                capitalPanel("HUMAN CAPITAL", "of its people", human, ink, t: t, base: 1.6)
                    .offset(x: lp)
                Text("+")
                    .font(.custom("Inter-Light", size: 96)).foregroundStyle(accent)
                    .opacity(plus).scaleEffect(0.5 + 0.5 * plus)
                    .frame(width: 120)
                capitalPanel("TOKEN CAPITAL", "the firm builds & owns", token, accent, t: t, base: 1.9)
                    .offset(x: rp)
            }
            .padding(.horizontal, 120)
        }
    }

    @ViewBuilder
    static func capitalPanel(_ title: String, _ sub: String, _ rows: [String], _ color: Color,
                             t: Double, base: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.custom("Inter-Black", size: 58)).tracking(-1.5).foregroundStyle(color)
            Text(sub).font(.custom("Inter-Light", size: 28)).foregroundStyle(dim).padding(.top, 4)
            Rectangle().fill(color.opacity(0.5)).frame(height: 2).padding(.vertical, 26)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(0..<rows.count, id: \.self) { i in
                    let p = Ease.easeOut(Ease.clip(t, base + Double(i) * 0.16, base + 0.6 + Double(i) * 0.16))
                    HStack(spacing: 16) {
                        Circle().fill(color).frame(width: 10, height: 10)
                        Text(rows[i]).font(.custom("Inter-Medium", size: 34)).foregroundStyle(ink)
                    }
                    .opacity(p).offset(x: (1 - p) * 26)
                }
            }
        }
        .padding(40)
        .frame(width: 620, height: 540, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(panel))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(color.opacity(0.35), lineWidth: 1.5))
    }

    // MARK: - 04 · Human capital grows more valuable

    @MainActor static func moreValuable(_ t: Double, _ dur: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.0, 0.7))
        let grow = Ease.easeInOut(Ease.clip(t, 0.8, 3.6))       // both series climb together
        let labelP = Ease.easeOut(Ease.clip(t, 3.2, 4.0))
        let spinP = Ease.easeOut(Ease.clip(t, 4.6, 5.4))
        return ZStack {
            VStack(spacing: 40) {
                kicker("AND HUMAN CAPITAL ONLY GETS MORE VALUABLE", k)
                HStack(alignment: .bottom, spacing: 64) {
                    riseChart(grow, color: accent, label: "token capital", bars: 7)
                    riseChart(grow, color: ink, label: "human capital", bars: 7, lift: 1.18)
                }
                .frame(height: 360)
                HStack(spacing: 26) {
                    Text("human agency drives token capital")
                        .font(.custom("Inter-Medium", size: 34)).foregroundStyle(ink)
                    Text("·").foregroundStyle(dim)
                    HStack(spacing: 12) {
                        Circle().trim(from: 0, to: 0.8)
                            .stroke(warn, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .frame(width: 30, height: 30)
                            .rotationEffect(.degrees(t * 220))
                        Text("without it, compute runs in circles")
                            .font(.custom("Inter-Light", size: 30)).foregroundStyle(dim)
                    }
                    .opacity(spinP)
                }
                .opacity(labelP)
            }
            .padding(.horizontal, 150)
        }
    }

    @ViewBuilder
    static func riseChart(_ p: Double, color: Color, label: String, bars: Int, lift: Double = 1.0) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .bottom, spacing: 12) {
                ForEach(0..<bars, id: \.self) { i in
                    let target = (0.28 + 0.72 * Double(i) / Double(bars - 1)) * lift
                    let h = min(1.0, target) * p * 300
                    Capsule().fill(color.opacity(0.55 + 0.45 * Double(i) / Double(bars - 1)))
                        .frame(width: 34, height: max(6, CGFloat(h)))
                }
            }
            .frame(height: 300, alignment: .bottom)
            Rectangle().fill(faint).frame(width: 320, height: 2)
            Text(label).font(.system(size: 24, weight: .semibold, design: .monospaced))
                .tracking(2).foregroundStyle(color)
        }
    }

    // MARK: - 05 · The learning loop

    @MainActor static func learningLoop(_ t: Double, _ dur: Double) -> some View {
        let R: CGFloat = 230
        let k = Ease.easeOut(Ease.clip(t, 0.0, 0.7))
        let boxP = Ease.easeOutBack(Ease.clip(t, 0.5, 1.3))
        let ringP = Ease.easeInOut(Ease.clip(t, 1.1, 2.4))
        let marker = (t - 2.0) * 110
        let tag = Ease.easeOut(Ease.clip(t, 3.0, 3.8))
        return ZStack {
            kicker("THE REAL OPPORTUNITY", k)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 120)

            Circle().trim(from: 0, to: ringP)
                .stroke(accent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 2 * R, height: 2 * R)
                .rotationEffect(.degrees(-90))
            if t > 2.0 {
                orbit(radius: R, angleDeg: marker) {
                    Circle().fill(accent).frame(width: 26, height: 26)
                        .shadow(color: accent.opacity(0.9), radius: 16)
                }
            }
            // labels riding the loop
            orbit(radius: R, angleDeg: -40) { tagText("human capital", ink).opacity(ringP) }
            orbit(radius: R, angleDeg: 140) { tagText("token capital", accent).opacity(ringP) }

            VStack(spacing: 6) {
                Text("a learning loop").font(.custom("Inter-Light", size: 30)).foregroundStyle(dim)
                Text("MODELS").font(.custom("Inter-Black", size: 64)).tracking(2).foregroundStyle(ink)
                Text("they compound").font(.custom("Inter-Light", size: 30)).foregroundStyle(accent)
            }
            .scaleEffect(0.7 + 0.3 * boxP).opacity(boxP)

            Text("you can offload a task — never your learning")
                .font(.custom("Inter-Medium", size: 38)).foregroundStyle(ink)
                .opacity(tag)
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 120)
        }
    }

    @ViewBuilder static func tagText(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 22, weight: .semibold, design: .monospaced))
            .foregroundStyle(c)
            .padding(.vertical, 8).padding(.horizontal, 16)
            .background(Capsule().fill(bg))
            .overlay(Capsule().stroke(c.opacity(0.5), lineWidth: 1))
            .fixedSize()
    }

    // MARK: - 06 · Control & sovereignty (swap the model, keep the expertise)

    @MainActor static func sovereignty(_ t: Double, _ dur: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.0, 0.7))
        let frameP = Ease.easeOut(Ease.clip(t, 0.4, 1.2))
        // model chip swap: v1 slides out left, v2 slides in from right around t≈3.2
        let swap = Ease.easeInOut(Ease.clip(t, 3.0, 4.2))
        let v1x = swap * -900
        let v2x = (1 - swap) * 900
        let pulse = 1 + 0.03 * sin(t * 3)
        let tag = Ease.easeOut(Ease.clip(t, 5.0, 5.8))
        return ZStack {
            kicker("THE TEST: CONTROL & SOVEREIGNTY", k)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 120)
            VStack(spacing: 28) {
                Text("YOUR LEARNING SYSTEM")
                    .font(.system(size: 24, weight: .semibold, design: .monospaced)).tracking(4)
                    .foregroundStyle(dim)
                // the asset you keep
                VStack(spacing: 8) {
                    Text("COMPANY-VETERAN EXPERTISE")
                        .font(.custom("Inter-Black", size: 50)).tracking(-1).foregroundStyle(ink)
                    Text("workflows · domain knowledge · accumulated judgment")
                        .font(.custom("Inter-Light", size: 26)).foregroundStyle(dim)
                }
                .padding(.vertical, 40).frame(width: 880)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(panel))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(accent.opacity(0.6), lineWidth: 2))
                .scaleEffect(pulse)
                // the swappable slot
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(faint, style: StrokeStyle(lineWidth: 2, dash: [8, 8]))
                        .frame(width: 520, height: 110)
                    modelChip("GENERALIST MODEL  v1", dim).offset(x: v1x).opacity(1 - swap)
                    modelChip("GENERALIST MODEL  v2", accent).offset(x: v2x).opacity(swap)
                }
                .frame(width: 880)
            }
            .opacity(frameP)
            Text("swap the model — keep the expertise")
                .font(.custom("Inter-Medium", size: 38)).foregroundStyle(accent)
                .opacity(tag)
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 110)
        }
    }

    @ViewBuilder static func modelChip(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 30, weight: .bold, design: .monospaced)).foregroundStyle(c)
            .padding(.vertical, 22).padding(.horizontal, 36)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.11)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(c.opacity(0.6), lineWidth: 1.5))
    }

    // MARK: - 07 · Three components

    @MainActor static func components(_ t: Double, _ dur: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.0, 0.7))
        let cards: [(String, String, String)] = [
            ("◇", "PRIVATE EVALS", "measure what actually matters — not external benchmarks"),
            ("⟳", "PRIVATE RL", "models grow stronger on real traces from inside the org"),
            ("▦", "KNOWLEDGE BASE", "institutional memory, queryable — tokens spent efficiently"),
        ]
        return ZStack {
            kicker("TURN JUDGMENT INTO SYSTEMS THAT IMPROVE WITH USE", k)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 130)
            HStack(spacing: 36) {
                ForEach(0..<cards.count, id: \.self) { i in
                    let p = Ease.easeOutBack(Ease.clip(t, 1.0 + Double(i) * 0.45, 1.8 + Double(i) * 0.45))
                    componentCard(cards[i].0, cards[i].1, cards[i].2)
                        .opacity(p).scaleEffect(0.85 + 0.15 * p).offset(y: (1 - p) * 50)
                }
            }
        }
    }

    @ViewBuilder static func componentCard(_ icon: String, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(icon).font(.system(size: 64)).foregroundStyle(accent)
            Text(title).font(.custom("Inter-Bold", size: 40)).tracking(-0.5).foregroundStyle(ink)
            Text(body).font(.custom("Inter-Light", size: 28)).foregroundStyle(dim)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(6)
            Spacer(minLength: 0)
        }
        .padding(36)
        .frame(width: 470, height: 420, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(panel))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(accent.opacity(0.3), lineWidth: 1.5))
    }

    // MARK: - 08 · A hill-climbing machine (climax)

    @MainActor static func hillClimb(_ t: Double, _ dur: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.0, 0.7))
        let steps = 7
        let climb = Ease.easeInOut(Ease.clip(t, 0.8, 5.5))
        let titleP = Ease.easeOutBack(Ease.clip(t, 1.0, 1.8))
        let tag = Ease.easeOut(Ease.clip(t, 5.6, 6.4))
        // the climbing marker rides the top of the most-recent revealed step
        let progressed = climb * Double(steps)
        let cur = min(steps - 1, Int(progressed))
        return ZStack {
            kicker("THE NEW IP OF THE FIRM", k)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 110)

            // staircase of rising bars
            HStack(alignment: .bottom, spacing: 16) {
                ForEach(0..<steps, id: \.self) { i in
                    let appear = Ease.easeOutBack(Ease.clip(t, 0.9 + Double(i) * 0.62, 1.5 + Double(i) * 0.62))
                    let h = (90.0 + Double(i) * 52.0)
                    ZStack(alignment: .top) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(i == cur ? accent : accent.opacity(0.28 + 0.5 * Double(i) / Double(steps)))
                            .frame(width: 74, height: CGFloat(h) * appear)
                        if i == cur && climb < 1.0 {
                            Circle().fill(ink).frame(width: 20, height: 20)
                                .shadow(color: accent.opacity(0.9), radius: 14)
                                .offset(y: -14)
                        }
                    }
                }
            }
            .frame(height: 460, alignment: .bottom)
            .offset(y: 60)

            VStack(spacing: 10) {
                Text("a hill-climbing machine")
                    .font(.custom("Inter-Black", size: 78)).tracking(-2).foregroundStyle(ink)
                    .scaleEffect(0.9 + 0.1 * titleP)
                Text("every improved workflow → a better training signal → it compounds")
                    .font(.custom("Inter-Light", size: 30)).foregroundStyle(dim)
                    .opacity(tag)
            }
            .frame(maxHeight: .infinity, alignment: .top).padding(.top, 220)
        }
    }

    // MARK: - 09 · The warning

    @MainActor static func theWarning(_ t: Double, _ dur: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.0, 0.7))
        let absorb = Ease.easeInOut(Ease.clip(t, 0.8, 4.5))     // small dots pulled into big ones
        let l1 = Ease.easeOut(Ease.clip(t, 3.4, 4.2))
        let l2 = Ease.easeOut(Ease.clip(t, 5.6, 6.4))
        return ZStack {
            warn.opacity(0.05).ignoresSafeArea()
            kicker("THE FAILURE MODE", k, color: warn)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 110)

            // three large "models" eating a field of small dots
            ZStack {
                ForEach(0..<3, id: \.self) { g in
                    let gx = CGFloat([-360.0, 0.0, 360.0][g])
                    Circle().fill(warn.opacity(0.9))
                        .frame(width: 90 + CGFloat(absorb) * 60, height: 90 + CGFloat(absorb) * 60)
                        .offset(x: gx, y: -10)
                        .shadow(color: warn.opacity(0.5), radius: 20)
                }
                ForEach(0..<48, id: \.self) { i in
                    let g = i % 3
                    let gx = CGFloat([-360.0, 0.0, 360.0][g])
                    let ang: Double = hash01(Double(i) * 1.7) * 2 * Double.pi
                    let rad: Double = 120.0 + hash01(Double(i) * 3.1) * 320.0
                    let p: Double = Ease.easeIn(Ease.clip(absorb, 0, 1))   // 0 = scattered, 1 = absorbed
                    let spread: Double = rad * (1 - p)
                    let dx: CGFloat = gx + CGFloat(cos(ang) * spread)
                    let dy: CGFloat = CGFloat(-10 + sin(ang) * spread * 0.7)
                    Circle().fill(ink.opacity(0.85))
                        .frame(width: 8, height: 8)
                        .position(x: 960 + dx, y: 540 + dy)
                        .opacity(0.85 * (1 - p))
                }
            }
            .frame(width: 1920, height: 1080)

            VStack(spacing: 10) {
                Text("a few models eat everything they see")
                    .font(.custom("Inter-Bold", size: 50)).foregroundStyle(ink).opacity(l1)
                Text("the political economy will not tolerate it")
                    .font(.custom("Inter-Light", size: 34)).foregroundStyle(warn).opacity(l2)
            }
            .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 120)
        }
    }

    // MARK: - 10 · The globalization parallel

    @MainActor static func globalization(_ t: Double, _ dur: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.0, 0.7))
        let lineP = Ease.easeInOut(Ease.clip(t, 0.7, 2.2))      // GDP line draws, stays flat/up
        let collapse = Ease.easeInOut(Ease.clip(t, 1.6, 4.6))   // bars beneath fall
        let cap = Ease.easeOut(Ease.clip(t, 4.4, 5.2))
        let bars = 11
        return ZStack {
            kicker("WE HAVE SEEN THIS BEFORE", k, color: dim)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 120)
            VStack(spacing: 8) {
                // "GDP looked fine" — a steady line near the top
                ZStack(alignment: .leading) {
                    Rectangle().fill(dim.opacity(0.7))
                        .frame(width: CGFloat(lineP) * 1100, height: 5)
                    Text("GDP")
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundStyle(dim).offset(x: CGFloat(lineP) * 1100 + 16, y: 0)
                }
                .frame(width: 1280, alignment: .leading)
                .padding(.bottom, 18)
                // industries / jobs collapsing underneath
                HStack(alignment: .top, spacing: 18) {
                    ForEach(0..<bars, id: \.self) { i in
                        let full = 70.0 + hash01(Double(i) * 9.3) * 180.0
                        let fall = collapse * (0.55 + 0.4 * hash01(Double(i) * 2.2))
                        let h = full * (1 - fall)
                        Capsule().fill(ink.opacity(0.55))
                            .frame(width: 70, height: max(6, CGFloat(h)))
                    }
                }
                .frame(width: 1280, height: 260, alignment: .top)
                Rectangle().fill(faint).frame(width: 1280, height: 2)
            }
            Text("the GDP looked fine — the displacement was real. not again.")
                .font(.custom("Inter-Medium", size: 38)).foregroundStyle(ink)
                .opacity(cap)
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 120)
        }
    }

    // MARK: - 11 · A frontier ecosystem

    @MainActor static func ecosystem(_ t: Double, _ dur: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.0, 0.7))
        let R: CGFloat = 320
        let n = 12
        let coreP = Ease.easeOutBack(Ease.clip(t, 0.5, 1.3))
        let cap = Ease.easeOut(Ease.clip(t, 4.4, 5.2))
        return ZStack {
            Rectangle().fill(.black)
                .colorEffect(ShaderLibrary.bundle(.module).galaxy(.float2(1920, 1080), .float(Float(t * 0.5))))
                .opacity(0.16 * Ease.easeOut(Ease.clip(t, 0.2, 1.5)))
                .ignoresSafeArea()
            kicker("THE PRIORITY", k)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 90)

            // spokes + outer nodes lighting up; value flows OUTWARD
            ForEach(0..<n, id: \.self) { i in
                let ang = Double(i) / Double(n) * 360.0
                let appear = Ease.easeOut(Ease.clip(t, 1.4 + Double(i) * 0.12, 2.1 + Double(i) * 0.12))
                spoke(radius: R, angleDeg: ang, color: accent.opacity(0.35 * appear), weight: 2)
                orbit(radius: R, angleDeg: ang) {
                    Circle().fill(accent.opacity(0.9))
                        .frame(width: 26, height: 26)
                        .scaleEffect(appear).opacity(appear)
                        .shadow(color: accent.opacity(0.7), radius: 10)
                }
            }
            // pulse traveling outward along the spokes
            ForEach(0..<n, id: \.self) { i in
                let ang = Double(i) / Double(n) * 360.0
                let phase = (t * 0.6 + Double(i) * 0.08).truncatingRemainder(dividingBy: 1.0)
                orbit(radius: R * CGFloat(phase), angleDeg: ang) {
                    Circle().fill(ink).frame(width: 8, height: 8).opacity((1 - phase) * 0.9)
                }
            }

            VStack(spacing: 4) {
                Text("a frontier").font(.custom("Inter-Light", size: 34)).foregroundStyle(dim)
                Text("ECOSYSTEM").font(.custom("Inter-Black", size: 76)).tracking(0).foregroundStyle(accent)
                Text("not just a frontier model").font(.custom("Inter-Light", size: 30)).foregroundStyle(dim)
            }
            .scaleEffect(0.7 + 0.3 * coreP).opacity(coreP)

            Text("value flows across every company, industry, and country")
                .font(.custom("Inter-Medium", size: 36)).foregroundStyle(ink)
                .opacity(cap)
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 90)
        }
    }

    // MARK: - 12 · The payoff / stable equilibrium

    @MainActor static func payoff(_ t: Double, _ dur: Double) -> some View {
        let k = Ease.easeOut(Ease.clip(t, 0.0, 0.7))
        let grow = Ease.easeInOut(Ease.clip(t, 0.8, 4.0))
        let l1 = Ease.easeOut(Ease.clip(t, 2.6, 3.4))
        let l2 = Ease.easeOut(Ease.clip(t, 4.4, 5.2))
        return ZStack {
            kicker("WHEN THAT HAPPENS", k)
                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 120)
            VStack(spacing: 34) {
                HStack(alignment: .bottom, spacing: 80) {
                    riseChart(grow, color: accent, label: "your company", bars: 6, lift: 1.0)
                    riseChart(grow, color: ink, label: "the economy", bars: 6, lift: 1.12)
                }
                .frame(height: 340)
                VStack(spacing: 10) {
                    Text("expertise amplified — judgment made replicable & scalable")
                        .font(.custom("Inter-Medium", size: 38)).foregroundStyle(ink).opacity(l1)
                    Text("the stable equilibrium we should build together")
                        .font(.custom("Inter-Light", size: 34)).foregroundStyle(accent).opacity(l2)
                }
            }
            .padding(.horizontal, 150)
        }
    }

    // MARK: - 13 · Lockup

    @MainActor static func lockup(_ t: Double, _ dur: Double) -> some View {
        let p = Ease.easeOutBack(Ease.clip(t, 0.2, 1.1))
        let sweep = Ease.easeInOut(Ease.clip(t, 0.9, 1.6))
        let sub = Ease.easeOut(Ease.clip(t, 1.4, 2.1))
        let credit = Ease.easeOut(Ease.clip(t, 2.2, 3.0))
        return ZStack {
            VStack(spacing: 26) {
                Text("Own the learning loop.")
                    .font(.custom("Inter-Black", size: 104)).tracking(-3).foregroundStyle(ink)
                    .scaleEffect(0.9 + 0.1 * p).opacity(Ease.easeOut(Ease.clip(t, 0.2, 0.9)))
                Rectangle().fill(accent).frame(width: CGFloat(sweep) * 760, height: 8)
                Text("compound your human and token capital")
                    .font(.custom("Inter-Light", size: 44)).foregroundStyle(dim).opacity(sub)
                Text("rendered in Swift · swift-render")
                    .font(.system(size: 26, design: .monospaced)).foregroundStyle(faint)
                    .opacity(credit).padding(.top, 18)
            }
        }
    }
}
